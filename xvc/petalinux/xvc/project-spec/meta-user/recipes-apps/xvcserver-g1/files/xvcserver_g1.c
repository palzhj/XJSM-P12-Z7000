/*
 * xvcserver_g1.c - XVC server (single channel, port 2543), per XAPP1251
 * Hardware: AXI4-Lite JTAG controller @0x43C00000
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/wait.h>
#include <sys/file.h>
#include <signal.h>
#include <setjmp.h>
#include <dirent.h>

#define MAP_SIZE 0x1000
#define XVC_MAX_BITS 4194304   /* 4 Mbit: covers the large packets Vivado may send */
#define CTRL_BASE 0x43C00000u
#define XVC_BASE_PORT  2543
#define XVC_BCAST_PORT 2542
#define XVC_BUILD_ID   "v18 (2026-11-06) auto byte-order detect (BE/LE) + apply DIV"  /* printed at startup, so you can confirm which build is running */
#define XVC_NCH        12
#define BCAST_CH       12      /* 13th engine: broadcast only (0x43CC0000) */
#define REGS_CH        13      /* broadcast control register block (0x43CD0000) */
#define REG_CHSEL      0x3C
#define REG_BCMASK     0x40

static volatile uint32_t *regs;
static char xvc_info[32];
static uint32_t tck_div = 8;
static uint32_t g_min_div = 50;
static FILE *g_dump = NULL;      /* -l file: records the TDI of large shifts */   /* fastest allowed speed (DIV lower bound) */

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


/* ---- streaming FIFO ---- */
#define FIFO_MIN 8192
static uint32_t get_word(const uint8_t *src, int bitpos)
{ uint32_t v = 0; int i; for (i=0;i<32;i++){int b=bitpos+i; if (src[b>>3] & (1<<(b&7))) v |= 1u<<i;} return v; }
static void put_word(uint8_t *dst, int bitpos, uint32_t v)
{ int i; for (i=0;i<32;i++){int b=bitpos+i; if (v & (1u<<i)) dst[b>>3] |= (1<<(b&7)); else dst[b>>3] &= ~(1<<(b&7));} }
static int zero_run(const uint8_t *tms, int start, int maxbits)
{
    int b=start, end=start+maxbits;
    while (b<end) { int bit=b&7, avail=8-bit; int n=(end-b<avail)?(end-b):avail;
        unsigned v=(unsigned)(tms[b>>3]>>bit)&((1u<<n)-1u);
        if (v){int i; for(i=0;i<n;i++) if((v>>i)&1u) return b+i-start;} b+=n; }
    return maxbits;
}
static int stream_zero(int nbits, const uint8_t *tdi, uint8_t *tdo, int start)
{
    /* Simple, reliable flow control: push 32 words -> wait until RX has 32 words -> pop 32 words */
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

static uint32_t g_base = CTRL_BASE;   /* base address */
static int g_ch = 0;        /* current channel 0..11 */
static int g_bcast = 0;          /* 1 = broadcast mode */
static unsigned g_bcast_mask = 0xFFF; /* which channels follow broadcast (all selected by default) */

/* Each channel has its own address space, no CHSEL needed */
static void select_channel(int ch) { (void)ch; }

/* Point regs at the given channel */
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

    /* Q3: this channel is owned by broadcast (S_BC) -> fail immediately, do not hang waiting */
    if ((((rd(0x30)) >> 8) & 3) == 3) {   /* state is in bit[9:8], bits in bit[7:2] */
        fprintf(stderr, "channel in S_BC (broadcast owns pins), refusing shift\n");
        return -1;
    }

    bus_lock();

    /* Apply the current TCK divider.
     * settck only changed the global tck_div, and early on it was never written to hardware (BUG)
     * so a client asking for 1 MHz still ran at 10 MHz -- marginal timing on long cables,
     * which showed up as "Vivado can see the K7/A7 but loses it very quickly". */
    wr(0x14, (uint32_t)tck_div);

    /* Flush the FIFO (leftovers from the previous session would skew the flow-control counts) */
    wr(0x10, 4);        /* CTRL bit2 = flush */
    wr(0x10, 0);

    while (done < nbits) {
        int chunk = nbits - done;
        uint32_t m = 0, d = 0, r;
        int i, guard = 100000;

        /* The streaming path (stream_zero) has a bug: it never writes the LEN register (0x00),
         * RTL does not know how many bits to shift -> long shifts return corrupt data.
         * Measured: 4096 bit through the 32-bit path is 100% correct; 65536 bit streaming only 50% (BUG)
         * so streaming is disabled here and everything uses the proven 32-bit chunk path.
         * Performance: 32 bit per chunk, about 3 us per chunk measured -> 91.5 Mbit in about 9 seconds, acceptable. */
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
        if (guard <= 0) { fprintf(stderr, "shift timeout\n"); bus_unlock(); return -1; }

        r = rd(0x0C);
        /* TDO register is filled by right shifting: for n<32 the data is in the high bits and must be aligned down to the low bits */
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

/* XVC 4-byte integers have a byte-order disagreement:
 *   - XVC 1.0 spec requires network order (big endian)
 *   - **Vivado XVC client actually sends little endian** (BUG)
 * Detected automatically here: take the smaller of the two interpretations (valid widths/periods are far below 2^24,
 * the other interpretation is always astronomically large), and return the detected byte order.
 * order: 0=big endian (BE)  1=little endian (LE) -- echo with the same order to stay consistent with the client.
 */
static uint32_t pick_u32(const uint8_t *p, int *order)
{
    uint32_t be = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
                  ((uint32_t)p[2] <<  8) |  (uint32_t)p[3];
    uint32_t le = ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) |
                  ((uint32_t)p[1] <<  8) |  (uint32_t)p[0];
    if (order) *order = (be <= le) ? 0 : 1;
    return (be <= le) ? be : le;
}

/* The byte order is consistent within one connection (a client only uses one).
 * Strategy: keep byte_order per connection (-1=unknown), lock it on the first settck or shift,
 *       then parse every later 4-byte field with it -- avoids per-field "big/little endian" guessing errors.
 * Lock rules:
 *   settck -- the period is usually <= 10^7 ns and the other interpretation is >= 2.5e9, take the smaller one;
 *   shift  -- if it comes first (rare), take the smaller value that is <= XVC_MAX_BITS.
 */
static uint32_t decode_u32(const uint8_t *p, int *order, uint32_t limit)
{
    uint32_t be = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
                  ((uint32_t)p[2] <<  8) |  (uint32_t)p[3];
    uint32_t le = ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) |
                  ((uint32_t)p[1] <<  8) |  (uint32_t)p[0];
    int be_ok, le_ok;
    if (*order >= 0)                       /* already locked, use it directly */
        return (*order == 0) ? be : le;

    /* Not locked: the XVC 1.0 spec requires big endian -> interpret as big endian by default and lock.
     * A little-endian client (Vivado) is recognized on its first settck:
     * the period is <= 10^7 ns, little endian gives a sane value while big endian is astronomically large, so take the smaller. */
    if (limit) {
        be_ok = (be >= 1 && be <= limit);
        le_ok = (le >= 1 && le <= limit);
        if (be_ok && !le_ok) { *order = 0; return be; }
        if (!be_ok && le_ok) { *order = 1; return le; }
        if (be_ok && le_ok) {
            /* both valid: the spec prefers big endian */
            *order = 0; return be;
        }
        *order = 0; return be;             /* neither valid, let the caller reject it */
    }
    /* settck mode (limit==0): the period is always far below its byte swap, take the smaller */
    if (be <= le) { *order = 0; return be; }
    *order = 1; return le;
}

static void put_u32(uint8_t *p, uint32_t v, int order)
{
    if (order == 0) {          /* big endian */
        p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
        p[2] = (uint8_t)(v >>  8); p[3] = (uint8_t)v;
    } else {                   /* little endian */
        p[0] = (uint8_t)v;         p[1] = (uint8_t)(v >>  8);
        p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
    }
}


/* Broadcast: one shift is applied to the 12 channels in sequence;
 * register 0x3C selects which TDO is returned (ch0 window, default 0 = G1) */
/* Broadcast: the hardware has a new 13th "broadcast engine" (0x43CC0000).
 * - CTRL bit4 = bcast_en: the selected channels switch TCK/TMS/TDI to the broadcast engine
 * - 0x40 BCMASK: which channels follow broadcast (1 = follow)
 * - 0x3C CHSEL: which TDO is read back
 * So a broadcast only needs **one** shift on ch12 and the 12 interfaces move at the same time. */

/* Check whether a port has an established connection (used during broadcast to exclude channels already taken over) */
static int port_busy(int port)
{
    FILE *f = fopen("/proc/net/tcp", "r");
    char line[512];
    if (!f) return 0;
    if (!fgets(line, sizeof(line), f)) { fclose(f); return 0; }
    while (fgets(line, sizeof(line), f)) {
        unsigned la, lp;
        int st;
        if (sscanf(line, " %*d: %8x:%4x %*8x:%*4x %2x", &la, &lp, &st) == 3) {
            if (st == 0x01 && (int)lp == port) { fclose(f); return 1; }   /* ESTABLISHED */
        }
    }
    fclose(f);
    return 0;
}

/* Broadcast priority: when a broadcast connects, actively drop all single-channel XVC connections (keep the parent and ourselves) */
static pid_t g_parent_pid = 0;

static void kill_other_clients(void)
{
    DIR *d = opendir("/proc");
    struct dirent *e;
    pid_t me = getpid();
    int killed = 0;
    if (!d) return;
    while ((e = readdir(d)) != NULL) {
        char path[64], cmd[256];
        int fd2, n;
        pid_t pid;
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        pid = (pid_t)atoi(e->d_name);
        if (pid == me || pid == g_parent_pid || pid <= 1) continue;
        snprintf(path, sizeof(path), "/proc/%d/cmdline", (int)pid);
        fd2 = open(path, O_RDONLY);
        if (fd2 < 0) continue;
        n = (int)read(fd2, cmd, sizeof(cmd) - 1);
        close(fd2);
        if (n <= 0) continue;
        cmd[n] = 0;
        if (strstr(cmd, "xvcserver_g1")) {
            kill(pid, SIGTERM);
            killed++;
            fprintf(stderr, "bcast priority: killed single-channel client pid %d\n", (int)pid);
        }
    }
    closedir(d);
    if (killed) {
        usleep(300000);
        /* second pass: SIGKILL */
        d = opendir("/proc");
        if (d) {
            while ((e = readdir(d)) != NULL) {
                char path[64], cmd[256];
                int fd2, n;
                pid_t pid;
                if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
                pid = (pid_t)atoi(e->d_name);
                if (pid == me || pid == g_parent_pid || pid <= 1) continue;
                snprintf(path, sizeof(path), "/proc/%d/cmdline", (int)pid);
                fd2 = open(path, O_RDONLY);
                if (fd2 < 0) continue;
                n = (int)read(fd2, cmd, sizeof(cmd) - 1);
                close(fd2);
                if (n <= 0) continue;
                cmd[n] = 0;
                if (strstr(cmd, "xvcserver_g1")) kill(pid, SIGKILL);
            }
            closedir(d);
        }
    }
}

/* Broadcast: the hardware is a clean three-part structure
 *   13 identical jtag_ctrl (ch0..ch11 channels + ch12 broadcast)
 *   1 jtag_bcast_regs register block (0x43CD0000)
 *   1 jtag_repeater combinational arbiter
 *
 * During broadcast:
 *   1. write the register block: CTRL.bit0 = bcast_en=1, BCMASK = mask, CHSEL = TDO source
 *   2. run one shift on the broadcast engine (ch12)
 *   3. clear bcast_en, the channels become independent again
 */
/* Broadcast: bcast_en and BCMASK are owned by the **session** (see the broadcast child process after accept),
 * the registers are the single source of truth; each shift here only makes sure CHSEL is valid. */
static int do_shift(int nbits, const uint8_t *tms, const uint8_t *tdi, uint8_t *tdo)
{
    int sel;
    if (!g_bcast) return do_shift_one(nbits, tms, tdi, tdo);

    if (map_channel(g_base, REGS_CH) < 0) return -1;
    sel = (int)(rd(0x08) & 0xF);
    if (sel >= XVC_NCH) wr(0x08, 0);        /* CHSEL out of range -> reset to zero */

    if (map_channel(g_base, BCAST_CH) < 0) return -1;
    wr(0x14, (uint32_t)tck_div);
    return do_shift_one(nbits, tms, tdi, tdo);
}

static int handle_client(int fd)
{
    int byte_order = -1;   /* -1=unknown; 0=big endian; 1=little endian. Locked by the first settck/shift */
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
                uint32_t period_ns = decode_u32((const uint8_t *)(cmd + 5), &byte_order, 0);
                /* f_TCK = 100MHz / (2*DIV)  =>  DIV = period_ns / 20 */
                if (period_ns == 0) period_ns = 100;      /* 0 => default 10 MHz */
                tck_div = (period_ns + 19) / 20;          /* round up, never faster than requested */

                /* v14: honor the period the client asks for.
                 * Early on this unconditionally wrote g_min_div (the -d value), so Vivado asking for 1 MHz
                 * was still forced to 10 MHz, marginal JTAG timing on long cables, which showed up as
                 * "Vivado can see the K7/A7, but loses it very quickly".
                 * -d is now only an **upper bound** (fastest allowed speed): never faster than that. */
                if (tck_div < g_min_div) tck_div = g_min_div;
                if (tck_div < 1)     tck_div = 1;
                if (tck_div > 65535) tck_div = 65535;

                printf("settck: requested %u ns (%s) -> DIV %u (TCK %.3f MHz)%s\n",
                       period_ns, byte_order ? "LE" : "BE", tck_div, 100.0 / (2.0 * tck_div),
                       (tck_div == g_min_div && period_ns < 20u*g_min_div) ? "  [limited by -d upper bound]" : "");
                fflush(stdout);
            }
            /* Echo the **actual** period, using the same byte order as the client */
            {
              uint32_t actual = (uint32_t)(20u * tck_div);
              put_u32((uint8_t *)cmd, actual, byte_order < 0 ? 0 : byte_order);
            }
            if (write_full(fd, cmd, 4) != 4) return 1;
        } else if (!memcmp(cmd, "sh", 2)) {
            uint8_t lbuf[4];
            if (read_full(fd, cmd, 4) != 4) return 1;
            if (read_full(fd, lbuf, 4) != 4) return 1;
            len = (int)decode_u32(lbuf, &byte_order, XVC_MAX_BITS);
            nr_bytes = (len + 7) / 8;
            if (len <= 0 || len > XVC_MAX_BITS || nr_bytes * 3 > (int)sizeof(buffer)) return 1;
            if (read_full(fd, buffer, nr_bytes * 2) != nr_bytes * 2) return 1;
            memset(buffer + nr_bytes * 2, 0, nr_bytes);
            /* recorded after do_shift, including TDO */

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
                    fwrite(buffer + nr_bytes, 1, nr_bytes, g_dump);   /* large payload: raw TDI */
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


/* ===== Used by the parent: read the broadcast register block to tell whether a channel is owned by broadcast =====
 *
 * Note: old bitstreams do not have this register block, reading it triggers an AXI external abort (SIGBUS).
 * Guarded with sigsetjmp/siglongjmp here; a failed probe is treated as "broadcast not supported".
 */
static sigjmp_buf bus_jb;
static volatile sig_atomic_t bus_trapped;

static void bus_handler(int sig)
{
    (void)sig;
    bus_trapped = 1;
    siglongjmp(bus_jb, 1);
}

static int bcast_blocks_channel(int ch)
{
    static int regfd = -1;
    static volatile unsigned *regs = NULL;
    static int probed = 0;
    static int present = 0;
    unsigned en, mask;

    if (!probed) {
        probed = 1;
        regfd = open("/dev/mem", O_RDWR | O_SYNC);
        if (regfd < 0) return 0;
        regs = (volatile unsigned *)mmap(NULL, 0x1000, PROT_READ | PROT_WRITE,
                                         MAP_SHARED, regfd, 0x43CD0000u);
        if (regs == MAP_FAILED) { regs = NULL; close(regfd); regfd = -1; return 0; }

        {
            struct sigaction sa, old;
            memset(&sa, 0, sizeof(sa));
            sa.sa_handler = bus_handler;
            sigemptyset(&sa.sa_mask);
            sigaction(SIGBUS, &sa, &old);

            bus_trapped = 0;
            if (sigsetjmp(bus_jb, 1) == 0) {
                volatile unsigned tag = regs[0x0C / 4];
                if (!bus_trapped && tag == 0xB7000000u) present = 1;
            }
            sigaction(SIGBUS, &old, NULL);
            if (!present) {
                munmap((void *)regs, 0x1000);
                regs = NULL;
                if (regfd >= 0) { close(regfd); regfd = -1; }
                fprintf(stderr, "broadcast regs not present (old bitstream) - REFUSE disabled\n");
                return 0;
            }
        }
    }
    if (!present || !regs) return 0;

    en   = regs[0x00 / 4] & 1;
    mask = regs[0x04 / 4] & 0xFFF;
    /* bcast_en is the master switch: the UI writes 0 when nothing is selected, so this broadcast owns no channel */
    if (!en) return 0;
    return (mask >> ch) & 1;
}


/* ================= one session per port (pid file) ================= */
#define PIDFILE_FMT "/tmp/xvcsrv-%d.pid"

static int read_pid_file(int port)
{
    char path[64], buf[32];
    int fd, n, pid = -1;
    snprintf(path, sizeof(path), PIDFILE_FMT, port);
    fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    n = (int)read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    pid = atoi(buf);
    return (pid > 0) ? pid : -1;
}

static void write_pid_file(int port)
{
    char path[64], buf[32];
    int fd, n;
    snprintf(path, sizeof(path), PIDFILE_FMT, port);
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    n = snprintf(buf, sizeof(buf), "%d\n", (int)getpid());
    if (write(fd, buf, n) != n) { /* ignore */ }
    close(fd);
}

static void unlink_pid_file(int port)
{
    char path[64];
    snprintf(path, sizeof(path), PIDFILE_FMT, port);
    unlink(path);
}

/* Verify that a pid really is this program (avoid killing a reused pid) */
static int proc_is_xvcsrv(int pid)
{
    char path[64], comm[64];
    int fd, n;
    if (pid <= 1) return 0;
    snprintf(path, sizeof(path), "/proc/%d/comm", pid);
    fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    n = (int)read(fd, comm, sizeof(comm) - 1);
    close(fd);
    if (n <= 0) return 0;
    comm[n] = 0;
    return (strstr(comm, "xvcserver_g1") != NULL);
}

/* Whether the port already has an active session (alive and really this program) */
static int port_has_session(int port)
{
    int pid = read_pid_file(port);
    if (pid > 0 && proc_is_xvcsrv(pid)) return 1;
    /* stale file: clean it up while we are here */
    unlink_pid_file(port);
    return 0;
}

/* Broadcast self-heal: bcast_en=1 but the broadcast session process is gone -> clean up (option C) */
/* Clean up a stale broadcast pid file.
 *
 * Note: bcast_en must NOT be changed here (BUG)
 *   bcast_en now means "the UI broadcast mask is non-empty",
 *   maintained by CGI setbcmask; whether a broadcast session exists is unrelated to it.
 *   Earlier this code cleared bcast_en, so a mask the UI had just set was wiped by the server,
 *   which showed up as "broadcast never takes effect" or "one port is always selected".
 */
static void heal_bcast_if_stale(void)
{
    int pid;
    pid = read_pid_file(XVC_BCAST_PORT);
    if (pid > 0 && proc_is_xvcsrv(pid)) return;      /* session is alive, do nothing */
    {
        char path[64];
        snprintf(path, sizeof(path), PIDFILE_FMT, XVC_BCAST_PORT);
        if (access(path, F_OK) == 0) {
            unlink(path);
            fprintf(stderr, "self-heal: removed stale bcast pid file\n");
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
    uint32_t def_div = 50;      /* default 1 MHz */

    opterr = 0;
    const char *dump_path = NULL;
    while ((c = getopt(argc, argv, "a:d:l:")) != -1) {
        if (c == 'a') base = (uint32_t)strtoul(optarg, NULL, 0);
        else if (c == 'd') def_div = (uint32_t)strtoul(optarg, NULL, 0);
        else if (c == 'l') dump_path = optarg;
        else { fprintf(stderr, "usage: %s [-a addr] [-d div] [-l dumpfile]\n", argv[0]); return 1; }
    }
    if (dump_path) { g_dump = fopen(dump_path, "wb"); if (!g_dump) perror("dump"); }
    if (def_div < 1) def_div = 1;
    if (def_div > 65535) def_div = 65535;
    g_min_div = def_div;
    tck_div = def_div;

    g_base = base;
    (void)map; (void)fd;
    /* Channel mapping is deferred to the child (each channel has its own 64KB window) */
    if (map_channel(base, 0) < 0) return 1;
    { int i; for (i = 0; i < XVC_NCH; i++) wr(0x14, tck_div), map_channel(base, i); }
    if (map_channel(base, 0) < 0) return 1;
    wr(0x14, tck_div);
    printf("ch0 PL_TAG=0x%08X (expected 0xA7xxxxxx)\n", rd(0x14));
    { uint32_t st = rd(0x24);
      printf("ch0 FIFO_STATUS=0x%08X  tx_free=%u rx_used=%u\n",
             st, st & 0xFF, (st >> 8) & 0xFF); }

    /* Q5: clear the broadcast flag once at startup, so an abnormal exit cannot leave it behind */
    if (map_channel(base, REGS_CH) >= 0) wr(0x00, 0);

    signal(SIGCHLD, SIG_IGN);
    snprintf(xvc_info, sizeof(xvc_info), "xvcServer_v1.0:%u\n", XVC_MAX_BITS);
    printf("xvcserver_g1 %s\n", XVC_BUILD_ID);
    printf("xvcserver_g1: JTAG@0x%08X, TCP %d(+%d), %d channels, max %d bits, default DIV %u (%.3f MHz)\n",
           base, XVC_BASE_PORT, XVC_BCAST_PORT, XVC_NCH, XVC_MAX_BITS, tck_div, 100.0 / (2.0 * tck_div));
    fflush(stdout);

    /* ---- 13 listening ports: 2542 (broadcast) + 2543..2554 (channels 0..11) ---- */
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
                fprintf(stderr, "bind %d failed: %s\n", port, strerror(errno));
                fprintf(stderr, "  ==> port already in use: an old xvcserver_g1 is most likely still running.\n"
                                "      kill it completely first, then start:\n"
                                "        for p in $(pidof xvcserver_g1); do kill -9 $p; done; sleep 1\n"
                                "      then start this program once pidof xvcserver_g1 prints nothing.\n");
                return 1;
            }
            if (listen(lsock[i], 4) < 0) { perror("listen"); return 1; }
        }
        printf("listening: %d (broadcast) + %d..%d (ch0..ch11)\n",
               XVC_BCAST_PORT, XVC_BASE_PORT, XVC_BASE_PORT + XVC_NCH - 1);
        fflush(stdout);
    }

    g_parent_pid = getpid();

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
            int cfd, port_i;
            if (!FD_ISSET(lsock[i], &rf)) continue;
            cfd = accept(lsock[i], (struct sockaddr *)&peer, &plen);
            if (cfd < 0) continue;
            setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            { int bufsz = 1 << 20;
              setsockopt(cfd, SOL_SOCKET, SO_RCVBUF, &bufsz, sizeof(bufsz));
              setsockopt(cfd, SOL_SOCKET, SO_SNDBUF, &bufsz, sizeof(bufsz)); }
            g_bcast = (i == 0);
            g_ch    = (i == 0) ? 0 : (i - 1);
            port_i  = (i == 0) ? XVC_BCAST_PORT : (XVC_BASE_PORT + i - 1);

            /* N4 (option C): self-heal when a broadcast flag is left behind */
            heal_bcast_if_stale();

            /* N1/N2: only one session per port */
            /* The previous session just disconnected and its child may not have exited yet (exit race) -> wait at most 1.5s */
            {
                int tries = 0;
                while (port_has_session(port_i) && tries < 15) {
                    usleep(100000);
                    tries++;
                }
                if (tries) fprintf(stderr, "waited %d00ms for previous session to exit\n", tries);
            }
            if (port_has_session(port_i)) {
                fprintf(stderr, "refuse: port %d already has a session\n", port_i);
                close(cfd);
                continue;
            }

            /* Broadcast priority: refuse any new connection on a channel port selected by broadcast */
            if (!g_bcast && bcast_blocks_channel(g_ch)) {
                fprintf(stderr, "refuse: channel %d is in broadcast mask\n", g_ch);
                close(cfd);
                continue;
            }
            if (g_bcast) printf("client connected: BROADCAST\n");
            else         printf("client connected: channel %d (port %d)\n", g_ch, XVC_BASE_PORT + g_ch);
            fflush(stdout);
            if (fork() == 0) {
                for (i = 0; i <= XVC_NCH; i++) close(lsock[i]);

                if (g_bcast) {
                    /* ===== broadcast session start ===== */
                    write_pid_file(XVC_BCAST_PORT);       /* 1) prove "I am here" first (the self-heal check depends on it) */
                    if (map_channel(base, REGS_CH) < 0) _exit(1);
                    /* 2) the gate is maintained by the UI: CGI setbcmask writes BCMASK and CTRL.bit0 together.
                     *    RTL expands bcmask==0 to "all selected", so the server cannot tell an
                     *    "empty mask" by reading 0x04; only the bcast_en master switch works. It is not modified here. */
                    {
                        unsigned en0 = rd(0x00) & 1;
                        if (!en0) {
                            fprintf(stderr, "bcast: mask empty (bcast_en=0) - no channel taken over\n");
                        } else {
                            /* 3) only kick the channel sessions inside the mask (mask is non-zero here, so this reads the real value) */
                            unsigned eff = rd(0x04) & 0xFFF;
                            int c2;
                            for (c2 = 0; c2 < XVC_NCH; c2++) {
                                int tp, pid;
                                if (!((eff >> c2) & 1)) continue;
                                tp = XVC_BASE_PORT + c2;
                                pid = read_pid_file(tp);
                                if (pid > 0 && proc_is_xvcsrv(pid)) {
                                    kill(pid, SIGTERM);
                                    fprintf(stderr, "bcast: killed ch%d (pid %d)\n", c2, pid);
                                }
                            }
                            usleep(300000);
                        }
                    }
                    if (map_channel(base, BCAST_CH) < 0) _exit(1);
                } else {
                    write_pid_file(port_i);               /* channel sessions register too */
                    if (map_channel(base, g_ch) < 0) _exit(1);
                }

                wr(0x14, g_min_div);
                handle_client(cfd);
                close(cfd);

                if (g_bcast) {
                    /* ===== broadcast session end =====
                     * bcast_en is NOT cleared (BUG) -- it means "the UI mask is non-empty", unrelated to this session.
                     * The mask is a static reservation: a session ending does not release a channel, the UI decides. */
                    unlink_pid_file(XVC_BCAST_PORT);
                } else {
                    unlink_pid_file(port_i);
                }
                printf("client closed\n"); fflush(stdout);
                _exit(0);
            }
            close(cfd);
        }
    }
}
