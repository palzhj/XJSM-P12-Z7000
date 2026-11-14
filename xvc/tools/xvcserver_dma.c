/*
 * xvcserver_g1.c - XVC 服务（单通道，端口 2543），按 XAPP1251
 * 硬件：AXI4-Lite JTAG 控制器 @0x43C00000
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <sys/mman.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/wait.h>
#include <sys/file.h>
#include <signal.h>

#define MAP_SIZE 0x1000
#define XVC_MAX_BITS 4194304   /* 4 Mbit：覆盖 Vivado 可能的大包 */
#define CTRL_BASE 0x43C00000u
#define XVC_BASE_PORT  2543
#define XVC_BCAST_PORT 2542
#define XVC_NCH        12
#define REG_CHSEL      0x3C
#define REG_BCMASK     0x40

static volatile uint32_t *regs;
static char xvc_info[32];
static uint32_t tck_div = 8;
static uint32_t g_min_div = 50;
static FILE *g_dump = NULL;      /* -l 文件：记录大块移位的 TDI */   /* 允许的最快速度（DIV 下限） */

static inline void wr(uint32_t off, uint32_t v) { regs[off / 4] = v; }
static inline uint32_t rd(uint32_t off) { return regs[off / 4]; }

static int lock_fd = -1;

static void bus_lock(void)
{
    if (lock_fd < 0)
        lock_fd = open("/tmp/xvc.lock", O_CREAT | O_RDWR, 0666);
    if (lock_fd >= 0)
        flock(lock_fd, LOCK_EX);
}

static void bus_unlock(void)
{
    if (lock_fd >= 0)
        flock(lock_fd, LOCK_UN);
}


/* ---- 流式 FIFO ---- */
#define FIFO_MIN 8192
/* Little-endian bit order: stream bit n is byte n>>3, bit n&7. A 5-byte window
 * turns 32 bit tests into one shift. This is not cosmetic: on a 262144-bit bulk
 * run the bit-at-a-time loops cost ~16 ms against a ~26 ms JTAG shift, which is
 * what held the DMA server at 6 Mbit/s while the bare probe reached 9.5. The
 * 64-byte slack on `buffer` covers the 4-byte overrun of the last word. */
static uint32_t get_word(const uint8_t *src, int bitpos)
{
    unsigned byte = (unsigned)bitpos >> 3, sh = (unsigned)bitpos & 7;
    uint64_t w;
    if (sh == 0) { uint32_t v; memcpy(&v, src + byte, 4); return v; }
    memcpy(&w, src + byte, 5);
    return (uint32_t)(w >> sh);
}
static void put_word(uint8_t *dst, int bitpos, uint32_t v)
{
    unsigned byte = (unsigned)bitpos >> 3, sh = (unsigned)bitpos & 7;
    uint64_t w;
    if (sh == 0) { memcpy(dst + byte, &v, 4); return; }
    memcpy(&w, dst + byte, 5);
    w &= ~(((uint64_t)0xFFFFFFFFu) << sh);
    w |= ((uint64_t)v) << sh;
    memcpy(dst + byte, &w, 5);
}
static int zero_run(const uint8_t *tms, int start, int maxbits)
{
    int b=start, end=start+maxbits;
    while (b<end) { int bit=b&7, avail=8-bit; int n=(end-b<avail)?(end-b):avail;
        unsigned v=(unsigned)(tms[b>>3]>>bit)&((1u<<n)-1u);
        if (v){int i; for(i=0;i<n;i++) if((v>>i)&1u) return b+i-start;} b+=n; }
    return maxbits;
}

/* ---------------------------------------------------------------------------
 * DMA mode (-m)
 *
 * Long TMS=0 runs are the bulk of every bitstream, and the FIFO path burns the
 * CPU pushing and draining one word at a time. In DMA mode that run is handed
 * to the axi_dma: the server fills a DDR buffer with the TDI words, starts
 * MM2S into the engine's stream port and S2MM back out, and only touches the
 * register path for TAP navigation and IR loads.
 *
 * Memory: the board boots mem=1008M, so 0x3F000000..0x40000000 is outside
 * Linux and is used as the DMA pool - source in the low half, TDO in the high
 * half so the receive cannot overwrite the transmit.
 * ------------------------------------------------------------------------- */
#define DMA_BASE     0x40400000u
#define DMA_POOL     0x3F000000u
#define DMA_POOL_SZ  0x01000000u
#define DMA_SRC_OFF  0x00000000u
#define DMA_DST_OFF  0x00800000u

#define D_MM2S_DMACR 0x00
#define D_MM2S_DMASR 0x04
#define D_MM2S_SA    0x18
#define D_MM2S_LEN   0x28
#define D_S2MM_DMACR 0x30
#define D_S2MM_DMASR 0x34
#define D_S2MM_DA    0x48
#define D_S2MM_LEN   0x58

#define DMA_CHUNK_W  (1024 * 1024)   /* words per transfer = 4 MiB */

/* instrumentation: where does the DMA mode spend its time? */
static double g_t_fill, g_t_wait, g_t_copy;
static unsigned long long g_dma_bits, g_chunk_bits;
static unsigned g_dma_xfers;
static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}
static void dump_stats(void)
{
    fprintf(stderr,
            "STATS dma_bits=%llu chunk_bits=%llu xfers=%u fill=%.2fs wait=%.2fs "
            "copy=%.2fs\n",
            g_dma_bits, g_chunk_bits, g_dma_xfers, g_t_fill, g_t_wait, g_t_copy);
}

static int g_dma = 0;

/* ---- DMA path through the dma_proxy driver --------------------------------
 * The engine asserts m_axis_tdo_tlast only while its 0x44 counter reads 1, and
 * software loads that counter, so each transfer is armed with its exact word
 * count before S2MM starts. The proxy buffers are 64 KiB (16384 words) and are
 * cached for the CPU, so filling them and reading the results back is cheap -
 * the raw /dev/mem pool this server used before is uncached and cost more in
 * fill+copy than the shift itself (6.0 vs 9.5 Mbit/s).
 *
 * The proxy's blocking FINISH_XFER is not a reliable handshake on this kernel:
 * it can return before the channel is idle. Completion is therefore polled from
 * the engine side (0x44 back to 0), and the received words are checked against
 * a sentinel so a no-op transfer cannot pass as success.
 */
#define PROXY_BUFFER_SIZE 1048576
#define PROXY_WORDS       (PROXY_BUFFER_SIZE / 4)
#define PROXY_COUNT       3
#define J_ARM             0x44

enum proxy_status { PROXY_NO_ERROR = 0, PROXY_BUSY = 1,
                    PROXY_TIMEOUT = 2, PROXY_ERROR = 3 };

struct channel_buffer {
    unsigned int buffer[PROXY_WORDS];
    enum proxy_status status;
    unsigned int length;
} __attribute__((aligned(1024)));

#define START_XFER  1
#define FINISH_XFER 2

static int g_txfd = -1, g_rxfd = -1;
static struct channel_buffer *g_txbuf = NULL, *g_rxbuf = NULL;
static size_t g_maplen;
static volatile uint32_t *g_dmasr = NULL;
/* the ioctl argument must not live on the stack: the FINISH path writes the
 * transfer length back through this pointer on this kernel */
static int g_io_arg;
static int g_bd = 0;
/* TDO streaming: bytes already final are sent as soon as a chunk is packed,
 * so the socket write overlaps the next chunk's shift instead of running after
 * the whole shift command. */

static int dma_setup(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    void *p;

    if (fd < 0) { perror("open /dev/mem (dma status)"); return -1; }
    p = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, DMA_BASE);
    if (p == MAP_FAILED) { perror("mmap axi_dma"); close(fd); return -1; }
    g_dmasr = (volatile uint32_t *)p;
    close(fd);

    g_txfd = open("/dev/dma_proxy_tx", O_RDWR);
    g_rxfd = open("/dev/dma_proxy_rx", O_RDWR);
    if (g_txfd < 0 || g_rxfd < 0) {
        fprintf(stderr, "open dma_proxy: %s (is dma-proxy loaded?)\n",
                strerror(errno));
        return -1;
    }
    g_maplen = sizeof(struct channel_buffer) * PROXY_COUNT;
    g_txbuf = mmap(NULL, g_maplen, PROT_READ | PROT_WRITE, MAP_SHARED, g_txfd, 0);
    g_rxbuf = mmap(NULL, g_maplen, PROT_READ | PROT_WRITE, MAP_SHARED, g_rxfd, 0);
    if (g_txbuf == MAP_FAILED || g_rxbuf == MAP_FAILED) {
        perror("mmap proxy buffers");
        return -1;
    }
    fprintf(stderr, "dma: proxy path, %d x %d-word buffers\n", PROXY_COUNT,
            PROXY_WORDS);
    return 0;
}

/* Fill chunk `w` words starting at bit `off` into tx buffer `bd`, arm its
 * receive buffer and set both lengths. CPU-side only. */
static void proxy_fill(int bd, int off, int w, const uint8_t *tdi, int start)
{
    struct channel_buffer *tx = &g_txbuf[bd], *rx = &g_rxbuf[bd];
    double t0 = now_s();
    int i;

    for (i = 0; i < w; i++)
        tx->buffer[i] = get_word(tdi, start + (off + i) * 32);
    g_t_fill += now_s() - t0;
    for (i = 0; i < w; i++)
        rx->buffer[i] = 0xDEADBEEFu;
    tx->length = (unsigned)w * 4;
    rx->length = (unsigned)w * 4;
}

/* Arm TLAST and start S2MM before MM2S. The engine only asserts TLAST while
 * its 0x44 counter reads 1, so the arm must carry this chunk's exact word
 * count. The FIFO pointers are cleared first so no word from the previous run
 * can be popped into this packet; the TAP stays in Shift-DR. */
static int proxy_start(int bd, int w)
{
    wr(0x10, 4);
    usleep(5);
    wr(0x10, 0);
    wr(J_ARM, (uint32_t)w);

    g_dma_bits += (unsigned long long)w * 32;
    g_dma_xfers++;

    g_io_arg = bd;
    if (ioctl(g_rxfd, START_XFER, &g_io_arg) != 0) return -1;
    g_io_arg = bd;
    if (ioctl(g_txfd, START_XFER, &g_io_arg) != 0) return -1;
    return 0;
}

static int proxy_wait(int bd, int w)
{
    struct channel_buffer *rx = &g_rxbuf[bd], *tx = &g_txbuf[bd];
    int guard = 4000000, sentinel_hits = 0, i;
    double t0 = now_s();
    uint32_t sr;

    {
    int npoll = 0;
    for (;;) {
        if (rd(J_ARM) == 0) break;                /* every armed word popped */
        if ((++npoll & 15) == 0) {                /* status only now and then */
            sr = g_dmasr[0x34 / 4];
            if (sr & 0x70) {                      /* IntErr|SlvErr|DecErr */
                fprintf(stderr, "DMA error: S2MM_DMASR=0x%08X MM2S_DMASR=0x%08X "
                        "words=%d left=%u\n", sr, g_dmasr[0x04 / 4], w,
                        rd(J_ARM));
                break;
            }
        }
        if (--guard <= 0) {
            fprintf(stderr, "DMA timeout, %u words left\n", rd(J_ARM));
            break;
        }
        /* 200 us between polls, and the status register only every 16th time.
         * A 20 us loop meant ~2600 poll iterations per 64 KiB chunk, each with
         * an uncached AXI read and a syscall - that was several seconds of CPU
         * over a 36 MB bitstream. */
        usleep(200);
    }
    }
    g_t_wait += now_s() - t0;

    g_io_arg = bd;
    ioctl(g_rxfd, FINISH_XFER, &g_io_arg);
    g_io_arg = bd;
    ioctl(g_txfd, FINISH_XFER, &g_io_arg);

    if (rd(J_ARM) != 0 || rx->status != PROXY_NO_ERROR ||
        tx->status != PROXY_NO_ERROR) {
        fprintf(stderr, "chunk failed: left=%u rx=%d tx=%d\n", rd(J_ARM),
                (int)rx->status, (int)tx->status);
        return -1;
    }
    for (i = 0; i < w; i++)
        if (rx->buffer[i] == 0xDEADBEEFu) sentinel_hits++;
    if (sentinel_hits == w)
        fprintf(stderr, "WARNING: chunk of %d words wrote nothing\n", w);
    return 0;
}

/* Pack w 32-bit words into the bit stream at bit position `bitpos`, which is
 * what the DMA run produced. The old path called put_word per word, i.e. a
 * 5-byte read-modify-write on both sides for every word (overlapping unaligned
 * accesses): 0.95 s for 9M words, 2.4x slower than the socket copies of the
 * same volume. Carrying the spill bits in a register turns it into one 32-bit
 * load plus one 32-bit store per word.
 *
 * The destination area is zeroed before the shift; the low bits of the first
 * byte belong to whatever the register path wrote before this run, so they are
 * preserved. */
static void pack_words(uint8_t *dst, int bitpos, const unsigned int *src, int w)
{
    unsigned byte = (unsigned)bitpos >> 3;
    unsigned sh = (unsigned)bitpos & 7;
    uint64_t acc = 0;
    int i;

    if (sh == 0) {
        memcpy(dst + byte, src, (size_t)w * 4);
        return;
    }
    {
        uint8_t keep = (uint8_t)(dst[byte] & ((1u << sh) - 1));
        for (i = 0; i < w; i++) {
            acc |= (uint64_t)src[i] << sh;   /* 32 + sh valid bits */
            memcpy(dst + byte, &acc, 4);     /* low 32 bits */
            byte += 4;
            acc >>= 32;
        }
        dst[byte] = (uint8_t)acc;            /* the sh bits that spilled */
        if (i > 0) dst[(unsigned)bitpos >> 3] |= keep;
    }
}

static void proxy_copy_out(int bd, int off, int w, uint8_t *tdo, int start)
{
    struct channel_buffer *rx = &g_rxbuf[bd];
    double t0 = now_s();

    pack_words(tdo, start + off * 32, rx->buffer, w);
    g_t_copy += now_s() - t0;
}

/* Pipeline: start chunk N, then fill N+1 and copy N-1 out while N shifts, so
 * only the first fill and the last copy are serialised against the shift. With
 * three buffers, N (shifting), N-1 (being copied) and N+1 (being filled) never
 * collide. */
static int dma_stream_zero(int nbits, const uint8_t *tdi, uint8_t *tdo, int start)
{
    int words = nbits / 32;
    int cw = PROXY_WORDS;
    int nchunks, c;

    nchunks = (words + cw - 1) / cw;
    if (nchunks <= 0) return 0;

    proxy_fill(0, 0, words > cw ? cw : words, tdi, start);

    for (c = 0; c < nchunks; c++) {
        int off = c * cw;
        int w = words - off > cw ? cw : words - off;
        int bd = c % PROXY_COUNT;

        if (proxy_start(bd, w) < 0) return -1;

        if (c + 1 < nchunks) {
            int noff = off + w;
            int nw = words - noff > cw ? cw : words - noff;
            proxy_fill((c + 1) % PROXY_COUNT, noff, nw, tdi, start);
        }
        if (c > 0) {
            int poff = (c - 1) * cw;
            int pw = words - poff > cw ? cw : words - poff;
            proxy_copy_out((c - 1) % PROXY_COUNT, poff, pw, tdo, start);
        }
        if (proxy_wait(bd, w) < 0) return -1;
    }

    {
        int poff = (nchunks - 1) * cw;
        int pw = words - poff > cw ? cw : words - poff;
        proxy_copy_out((nchunks - 1) % PROXY_COUNT, poff, pw, tdo, start);
    }
    return 0;
}

static int stream_zero(int nbits, const uint8_t *tdi, uint8_t *tdo, int start)
{
    /* 简单可靠流控：每次推 32 字 -> 等 RX 凑够 32 字 -> 取 32 字 */
    const int BATCH = 32;
    int words = nbits / 32, done = 0;

    while (done < words) {
        int batch = words - done;
        int sent = 0, got = 0, guard;
        if (batch > BATCH) batch = BATCH;

        guard = 500000;
        while (sent < batch && --guard > 0) {
            uint32_t st = rd(0x24);
            int freew = (int)(st & 0xFF);
            while (freew-- > 0 && sent < batch) {
                wr(0x1C, get_word(tdi, start + (done + sent) * 32));
                sent++;
            }
        }
        if (sent < batch) { fprintf(stderr, "stream push timeout\n"); return -1; }

        guard = 500000;
        while (got < batch && --guard > 0) {
            uint32_t st = rd(0x24);
            int avail = (int)((st >> 8) & 0xFF);
            while (avail-- > 0 && got < batch) {
                put_word(tdo, start + (done + got) * 32, rd(0x20));
                got++;
            }
        }
        if (got < batch) { fprintf(stderr, "stream pop timeout\n"); return -1; }

        done += batch;
    }
    return 0;
}

static uint32_t g_base = CTRL_BASE;   /* 基地址 */
static int g_ch = 0;        /* 当前通道 0..11 */
static int g_bcast = 0;     /* 1 = 广播模式 */

/* 每通道有独立地址空间，无需 CHSEL */
static void select_channel(int ch) { (void)ch; }

/* 把 regs 指向指定通道 */
static int map_channel(uint32_t base, int ch)
{
    int fd;
    void *m;
    uint32_t addr = base + (uint32_t)ch * 0x10000u;
    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return -1; }
    m = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, addr);
    close(fd);
    if (m == MAP_FAILED) { perror("mmap"); return -1; }
    regs = (volatile uint32_t *)m;
    return 0;
}

static int do_shift_one(int nbits, const uint8_t *tms, const uint8_t *tdi, uint8_t *tdo)
{
    int done = 0;
    select_channel(g_ch);

    bus_lock();

    /* Flush the queues before a shift. Skipped in DMA mode: xvcdma - which works -
     * never flushes between transfers, and a flush mid-sequence can clear the
     * TLAST countdown so S2MM sees an end-of-packet before any data. */
    if (!g_dma) {
        wr(0x10, 4);        /* CTRL bit2 = flush */
        wr(0x10, 0);
    }

    while (done < nbits) {
        int chunk = nbits - done;
        uint32_t m = 0, d = 0, r;
        int i, guard = 100000;

        if (chunk >= FIFO_MIN) {
            int run = zero_run(tms, done, chunk);
            int K = run & ~31;
            if (K >= FIFO_MIN) {
                if ((g_dma ? dma_stream_zero(K, tdi, tdo, done)
                           : stream_zero(K, tdi, tdo, done)) < 0) {
                    fprintf(stderr, "stream failed at %d, falling back to 32-bit\n", done);
                    /* 回退：继续用逐块模式处理剩余部分 */
                } else {
                    done += K; continue;
                }
            }
        }
        if (chunk > 32) chunk = 32;

        for (i = 0; i < chunk; i++) {
            int bit = done + i;
            if (tms[bit >> 3] & (1 << (bit & 7))) m |= 1u << i;
            if (tdi[bit >> 3] & (1 << (bit & 7))) d |= 1u << i;
        }

        wr(0x00, (uint32_t)chunk);
        wr(0x04, m);
        wr(0x08, d);
        wr(0x10, 1);
        while ((rd(0x10) & 1) && --guard) ;
        if (guard <= 0) { fprintf(stderr, "shift timeout\n"); return -1; }

        r = rd(0x0C);
        /* TDO 寄存器是右移填充的：n<32 时数据在高位，需要对齐到低位 */
        if (chunk < 32) r >>= (32 - chunk);
        for (i = 0; i < chunk; i++) {
            int bit = done + i;
            if (r & (1u << i)) tdo[bit >> 3] |=  (1 << (bit & 7));
            else               tdo[bit >> 3] &= ~(1 << (bit & 7));
        }
        done += chunk;
    }

    bus_unlock();
    return 0;
}

static int write_full(int fd, const void *buf, int n)
{
    int sent = 0;
    while (sent < n) {
        int w = write(fd, (const char *)buf + sent, n - sent);
        if (w <= 0) return sent;
        sent += w;
    }
    return sent;
}

static int read_full(int fd, void *buf, int n)
{
    int got = 0;
    while (got < n) {
        int r = read(fd, (char *)buf + got, n - got);
        if (r <= 0) return got;
        got += r;
    }
    return got;
}

/* 广播：同一条 shift 依次作用到 12 通道；
 * 返回哪一路的 TDO 由寄存器 0x3C 选择（ch0 窗口，默认 0 = G1） */
static int do_shift(int nbits, const uint8_t *tms, const uint8_t *tdi, uint8_t *tdo)
{
    int ch, sel;
    unsigned mask;
    static uint8_t scratch[XVC_MAX_BITS / 8 + 8];
    if (!g_bcast) return do_shift_one(nbits, tms, tdi, tdo);

    /* 读广播配置（ch0 的 0x3C = TDO 来源，0x40 = 通道掩码） */
    if (map_channel(g_base, 0) < 0) return -1;
    sel  = (int)(rd(REG_CHSEL) & 0xF);
    mask = rd(REG_BCMASK) & 0xFFF;
    if (!mask) mask = 0xFFF;                       /* 掩码为 0 时按全 1 处理 */
    if (!(mask & (1u << sel))) {                   /* 选中的来源不在掩码内 -> 用第一个使能的 */
        int k;
        for (k = 0; k < XVC_NCH; k++) if (mask & (1u << k)) break;
        sel = (k < XVC_NCH) ? k : 0;
    }

    for (ch = 0; ch < XVC_NCH; ch++) {
        uint8_t *dst;
        if (!(mask & (1u << ch))) continue;        /* 跳过未使能的通道 */
        dst = (ch == sel) ? tdo : scratch;
        if (map_channel(g_base, ch) < 0) return -1;
        wr(0x14, g_min_div);
        if (do_shift_one(nbits, tms, tdi, dst) < 0) return -1;
    }
    /* 恢复到选择寄存器（下次广播仍然有效；map 回到 ch0） */
    if (map_channel(g_base, 0) < 0) return -1;
    return 0;
}

static int handle_client(int fd)
{
    static uint8_t buffer[XVC_MAX_BITS * 3 / 8 + 64];   /* TMS + TDI + TDO */
    char cmd[16];

    for (;;) {
        int len, nr_bytes;

        memset(cmd, 0, sizeof(cmd));
        if (read_full(fd, cmd, 2) != 2) {
            fprintf(stderr, "close: read cmd failed (errno=%d)\n", errno);
            return 1;
        }
        fprintf(stderr, "cmd=%.2s\n", cmd);

        if (!memcmp(cmd, "ge", 2)) {
            fprintf(stderr, "CMD getinfo\n");
            if (read_full(fd, cmd, 6) != 6) return 1;
            if (write_full(fd, xvc_info, strlen(xvc_info)) != (int)strlen(xvc_info)) return 1;
        } else if (!memcmp(cmd, "se", 2)) {
            fprintf(stderr, "CMD settck\n");
            if (read_full(fd, cmd, 9) != 9) return 1;
            {
                uint32_t period_ns;
                memcpy(&period_ns, cmd + 5, 4);
                /* f_TCK = 100MHz / (2*DIV)  =>  DIV = period_ns / 20 */
                if (period_ns == 0) period_ns = 100;      /* 0 => 默认 10 MHz */
                tck_div = (period_ns + 19) / 20;
                /* 锁定为 -d 指定的速度：忽略客户端请求的其它值（Vivado 常请求更慢的时钟） */
                tck_div = g_min_div;
                if (tck_div < 1) tck_div = 1;
                if (tck_div > 65535) tck_div = 65535;
                printf("settck: %u ns -> DIV %u (TCK %.3f MHz)\n",
                       period_ns, tck_div, 100.0 / (2.0 * tck_div));
                fflush(stdout);
            }
            /* 按 XVC 惯例回显请求的周期（实际速度由 -d 限制） */
            {
              uint32_t req;
              memcpy(&req, cmd + 5, 4);
              cmd[0] = (char)(req & 0xff);
              cmd[1] = (char)((req >> 8) & 0xff);
              cmd[2] = (char)((req >> 16) & 0xff);
              cmd[3] = (char)((req >> 24) & 0xff);
            }
            if (write_full(fd, cmd, 4) != 4) return 1;
        } else if (!memcmp(cmd, "sh", 2)) {
            if (read_full(fd, cmd, 4) != 4) return 1;
            if (read_full(fd, &len, 4) != 4) return 1;
            nr_bytes = (len + 7) / 8;
            if (len <= 0 || len > XVC_MAX_BITS || nr_bytes * 3 > (int)sizeof(buffer)) return 1;
            if (read_full(fd, buffer, nr_bytes * 2) != nr_bytes * 2) return 1;
            memset(buffer + nr_bytes * 2, 0, nr_bytes);
            /* 记录在 do_shift 之后，含 TDO */

            {
                static int dbg = 0;
                if (dbg < 6) {
                    int k, n = nr_bytes > 48 ? 48 : nr_bytes;
                    fprintf(stderr, "  len=%d\n   TMS=", len);
                    for (k = n - 1; k >= 0; k--) fprintf(stderr, "%02X", buffer[k]);
                    fprintf(stderr, "\n   TDI=");
                    for (k = n - 1; k >= 0; k--) fprintf(stderr, "%02X", buffer[nr_bytes + k]);
                    fprintf(stderr, "\n");
                    dbg++;
                }
            }

            if (do_shift(len, buffer, buffer + nr_bytes, buffer + nr_bytes * 2) < 0) return 1;

            {
                static int dbg2 = 0;
                if (dbg2 < 6) {
                    int k, n = nr_bytes > 48 ? 48 : nr_bytes;
                    fprintf(stderr, "   TDO=");
                    for (k = n - 1; k >= 0; k--) fprintf(stderr, "%02X", buffer[nr_bytes * 2 + k]);
                    fprintf(stderr, "\n");
                    dbg2++;
                }
            }

            if (g_dump) {
                fprintf(g_dump, "L %d\n", len);
                fflush(g_dump);
                if (len > 1000) {
                    fwrite(buffer + nr_bytes, 1, nr_bytes, g_dump);   /* 大数据：原始 TDI */
                } else {
                    int k;
                    fprintf(g_dump, "S %d TMS=", len);
                    for (k = nr_bytes - 1; k >= 0; k--) fprintf(g_dump, "%02X", buffer[k]);
                    fprintf(g_dump, " TDI=");
                    for (k = nr_bytes - 1; k >= 0; k--) fprintf(g_dump, "%02X", buffer[nr_bytes + k]);
                    fprintf(g_dump, " TDO=");
                    for (k = nr_bytes - 1; k >= 0; k--) fprintf(g_dump, "%02X", buffer[nr_bytes * 2 + k]);
                    fprintf(g_dump, "\n");
                }
                fflush(g_dump);
            }
            if (write_full(fd, buffer + nr_bytes * 2, nr_bytes) != nr_bytes) return 1;
        } else {
            fprintf(stderr, "close: unknown cmd %02X %02X\n", (unsigned char)cmd[0], (unsigned char)cmd[1]);
            return 1;
        }
    }
}

int main(int argc, char **argv)
{
    int fd, one = 1;
    int lsock[XVC_NCH + 1];
    struct sockaddr_in addr;
    void *map;
    uint32_t base = CTRL_BASE;
    int c;
    uint32_t def_div = 50;      /* 默认 1 MHz */

    opterr = 0;
    const char *dump_path = NULL;
    while ((c = getopt(argc, argv, "a:d:l:m")) != -1) {
        if (c == 'a') base = (uint32_t)strtoul(optarg, NULL, 0);
        else if (c == 'd') def_div = (uint32_t)strtoul(optarg, NULL, 0);
        else if (c == 'l') dump_path = optarg;
        else if (c == 'm') g_dma = 1;
        else { fprintf(stderr, "usage: %s [-a addr] [-d div] [-l dumpfile] [-m dma]\n", argv[0]); return 1; }
    }
    if (dump_path) { g_dump = fopen(dump_path, "wb"); if (!g_dump) perror("dump"); }
    if (g_dma && dma_setup() < 0) {
        fprintf(stderr, "dma setup failed - falling back to the FIFO path\n");
        g_dma = 0;
    }
    if (def_div < 1) def_div = 1;
    if (def_div > 65535) def_div = 65535;
    g_min_div = def_div;
    tck_div = def_div;

    g_base = base;
    (void)map; (void)fd;
    /* Single-channel builds only. The original loop touched all 12 channels to
     * push DIV to each; on a one-engine bitstream those addresses are outside
     * the interconnect's decode window and the access raises SIGBUS
     * ("external abort on non-linefetch"). Touch channel 0 only. */
    if (map_channel(base, 0) < 0) return 1;
    wr(0x14, tck_div);
    printf("ch0 PL_TAG=0x%08X (期望 0xA7xxxxxx)\n", rd(0x14));
    { uint32_t st = rd(0x24);
      printf("ch0 FIFO_STATUS=0x%08X  tx_free=%u rx_used=%u\n",
             st, st & 0xFF, (st >> 8) & 0xFF); }

    signal(SIGCHLD, SIG_IGN);
    snprintf(xvc_info, sizeof(xvc_info), "xvcServer_v1.0:%u\n", XVC_MAX_BITS);
    printf("xvcserver_g1: JTAG@0x%08X, TCP %d(+%d), %d channels, max %d bits, default DIV %u (%.3f MHz)\n",
           base, XVC_BASE_PORT, XVC_BCAST_PORT, XVC_NCH, XVC_MAX_BITS, tck_div, 100.0 / (2.0 * tck_div));
    fflush(stdout);

    /* ---- 13 个监听端口：2542(广播) + 2543..2554(通道 0..11) ---- */
    {
        int i;
        for (i = 0; i <= XVC_NCH; i++) {
            int port = (i == 0) ? XVC_BCAST_PORT : (XVC_BASE_PORT + i - 1);
            lsock[i] = socket(AF_INET, SOCK_STREAM, 0);
            if (lsock[i] < 0) { perror("socket"); return 1; }
            setsockopt(lsock[i], SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
            memset(&addr, 0, sizeof(addr));
            addr.sin_family = AF_INET;
            addr.sin_addr.s_addr = INADDR_ANY;
            addr.sin_port = htons(port);
            if (bind(lsock[i], (struct sockaddr *)&addr, sizeof(addr)) < 0) {
                fprintf(stderr, "bind %d failed: %s\n", port, strerror(errno)); return 1;
            }
            if (listen(lsock[i], 4) < 0) { perror("listen"); return 1; }
        }
        printf("listening: %d (broadcast) + %d..%d (ch0..ch11)\n",
               XVC_BCAST_PORT, XVC_BASE_PORT, XVC_BASE_PORT + XVC_NCH - 1);
        fflush(stdout);
    }

    for (;;) {
        fd_set rf;
        int maxfd = 0, i, ready;
        FD_ZERO(&rf);
        for (i = 0; i <= XVC_NCH; i++) {
            FD_SET(lsock[i], &rf);
            if (lsock[i] > maxfd) maxfd = lsock[i];
        }
        ready = select(maxfd + 1, &rf, NULL, NULL, NULL);
        if (ready < 0) { if (errno == EINTR) continue; perror("select"); break; }

        for (i = 0; i <= XVC_NCH; i++) {
            struct sockaddr_in peer;
            socklen_t plen = sizeof(peer);
            int cfd;
            if (!FD_ISSET(lsock[i], &rf)) continue;
            cfd = accept(lsock[i], (struct sockaddr *)&peer, &plen);
            if (cfd < 0) continue;
            setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            { int bufsz = 1 << 20;
              setsockopt(cfd, SOL_SOCKET, SO_RCVBUF, &bufsz, sizeof(bufsz));
              setsockopt(cfd, SOL_SOCKET, SO_SNDBUF, &bufsz, sizeof(bufsz)); }
            g_bcast = (i == 0);
            g_ch    = (i == 0) ? 0 : (i - 1);
            if (g_bcast) printf("client connected: BROADCAST\n");
            else         printf("client connected: channel %d (port %d)\n", g_ch, XVC_BASE_PORT + g_ch);
            fflush(stdout);
            if (fork() == 0) {
                for (i = 0; i <= XVC_NCH; i++) close(lsock[i]);
                if (map_channel(base, g_bcast ? 0 : g_ch) < 0) _exit(1);
                wr(0x14, g_min_div);
                handle_client(cfd);
                close(cfd);
                printf("client closed\n"); fflush(stdout);
                dump_stats();
                _exit(0);
            }
            close(cfd);
        }
    }
}
