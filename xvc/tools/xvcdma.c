/*
 * xvcdma - drive the AXI DMA straight into channel 0's JTAG shift engine
 *
 * The PL exposes AXI-Stream ports on jtag_ctrl, fed by an axi_dma instance, so a
 * bitstream can be pushed from DDR into the shift engine without the CPU
 * touching a register per 32-bit word.
 *
 * Memory: the device tree leaves the top 16 MiB (0x3F000000..0x3FFFFFFF) out of
 * the kernel map with mem=1008M, so mmap(/dev/mem) there is a physically
 * contiguous buffer that nothing else can allocate.
 *
 * Register map
 *   0x40400000  MM2S_DMACR     bit0 RS (run/stop), bit2 reset
 *   0x40400004  MM2S_DMASR     bit0 halted, bit1 idle
 *   0x40400018  MM2S_SA        source address (DDR)
 *   0x40400028  MM2S_LENGTH    bytes to send
 *   0x40400030  S2MM_DMACR
 *   0x40400034  S2MM_DMASR
 *   0x40400048  S2MM_DA        destination address (DDR)
 *   0x40400058  S2MM_LENGTH    bytes to receive (write starts the transfer)
 *   0x43C00044  word count     arms TLAST: the last popped word carries it
 *   0x43C00048  drop count     TDO words discarded because the RX FIFO was full
 *   0x43C0004C  tvalid cycles  clocks m_axis_tdo_tvalid was high
 *   0x43C00050  tready cycles  clocks m_axis_tdo_tready was high
 *   0x43C00054  pop cycles     clocks a word really moved (tvalid & tready)
 *
 * The three handshake counters are free-running at FCLK0, so this tool takes
 * repeated snapshots and compares deltas. Whichever counter stops advancing
 * first names the side that stalled:
 *   tvalid flat, tready climbing  -> the shift engine stopped producing
 *   tready flat, tvalid climbing  -> S2MM stopped accepting
 *   both climbing, pop flat       -> the handshake itself is broken
 *
 * Build:
 *   arm-xilinx-linux-gnueabi-gcc -O2 -o xvcdma xvcdma.c
 * Run:
 *   ./xvcdma -n 65536          # shift 65536 bits of TMS=0 / TDI=0xAA through BYPASS
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <stdint.h>
#include <errno.h>
#include <sys/mman.h>

#define DMA_BASE    0x40400000u
#define JTAG0_BASE  0x43C00000u
#define DMA_POOL    0x3F000000u
#define DMA_POOL_SZ 0x01000000u
/* MM2S_LENGTH / S2MM_LENGTH are 23 bits in this build, so one transfer can be
 * at most 2^23-1 bytes, and it must stay a whole number of 32-bit words. */
#define MAX_XFER    0x007FFFFCu

/* AXI DMA register offsets (simple mode) */
#define MM2S_DMACR   0x00
#define MM2S_DMASR   0x04
#define MM2S_SA      0x18
#define MM2S_LENGTH  0x28
#define S2MM_DMACR   0x30
#define S2MM_DMASR   0x34
#define S2MM_DA      0x48
#define S2MM_LENGTH  0x58

/* jtag_ctrl register offsets */
#define J_LEN   0x00
#define J_TMS   0x04
#define J_TDI   0x08
#define J_TDO   0x0C
#define J_CTRL  0x10
#define J_DIV   0x14
#define J_STATE 0x30
#define J_STATUS 0x24
#define J_DMAW  0x44
#define J_DROP  0x48
#define J_TVALID 0x4C
#define J_TREADY 0x50
#define J_POP    0x54

static volatile uint32_t *dma, *jt;
static uint8_t *pool;

static inline uint32_t rd(volatile uint32_t *b, unsigned off) { return b[off / 4]; }
static inline void wr(volatile uint32_t *b, unsigned off, uint32_t v) { b[off / 4] = v; }

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void die(const char *what)
{
    fprintf(stderr, "xvcdma: %s: %s\n", what, strerror(errno));
    exit(1);
}

/* ------------------------------------------------------------------ *
 * Handshake trace: which side of the m_axis_tdo stream stops first?
 *
 * 0x4C/0x50/0x54 are free-running cycle counters, so every sample is compared
 * with the previous one. A counter that stops advancing has stopped being
 * asserted, and the time of its last advance says which end gave up first.
 * ------------------------------------------------------------------ */
struct hs_trace {
    uint32_t tvalid, tready, pop;        /* latest raw counts            */
    uint32_t d_tvalid, d_tready, d_pop;  /* change since previous sample */
    double   t_tvalid, t_tready, t_pop;  /* when each last advanced (s)  */
    int      samples;
};

/* Returns 0 once every armed word has been popped, -1 on timeout. */
static int trace_run(int timeout_ms, uint32_t words, uint32_t pop0)
{
    struct hs_trace h;
    uint32_t moved;
    double t0 = now_s(), next_print = 0.0;
    uint32_t pv, pt, pp;
    int i, rc = -1;

    memset(&h, 0, sizeof(h));
    pv = rd(jt, J_TVALID);
    pt = rd(jt, J_TREADY);
    pp = rd(jt, J_POP);

    for (i = 0; i < timeout_ms; i++) {
        double now = now_s() - t0;
        uint32_t v = rd(jt, J_TVALID);
        uint32_t t = rd(jt, J_TREADY);
        uint32_t p = rd(jt, J_POP);

        h.d_tvalid = v - pv;
        h.d_tready = t - pt;
        h.d_pop    = p - pp;
        if (h.d_tvalid) h.t_tvalid = now;
        if (h.d_tready) h.t_tready = now;
        if (h.d_pop)    h.t_pop    = now;
        pv = v; pt = t; pp = p;
        h.tvalid = v; h.tready = t; h.pop = p;
        h.samples++;

        if (now >= next_print) {
            next_print = now + 0.25;
            printf("    t=%7.3f s  tvalid=%u (+%u)  tready=%u (+%u)  pop=%u (+%u)"
                   "  wleft=%u  drop=%u  stat=0x%08X\n",
                   now, v, h.d_tvalid, t, h.d_tready, p, h.d_pop,
                   rd(jt, J_DMAW), rd(jt, J_DROP), rd(jt, J_STATUS));
        }

        if (rd(jt, J_DMAW) == 0) {
            int k;                            /* let S2MM retire the TLAST */
            for (k = 0; k < 1000; k++) {
                if (rd(dma, S2MM_DMASR) & 2) break;
                usleep(1000);
            }
            rc = 0;
            break;
        }
        usleep(1000);
    }

    printf("  ---- handshake trace (%d samples) ----\n", h.samples);
    printf("  final:  tvalid=%u  tready=%u  pop=%u\n", h.tvalid, h.tready, h.pop);
    printf("  last advance:  tvalid %.3f s   tready %.3f s   pop %.3f s  (from DMA start)\n",
           h.t_tvalid, h.t_tready, h.t_pop);

    /* Complete means the armed run was fully consumed (0x44 back to 0) with no
     * word thrown away. The pop counter is cumulative from PL configuration, so
     * only its delta over this run is meaningful. */
    moved = h.pop - pop0;
    if ((rd(jt, J_DMAW) == 0) && (rd(jt, J_DROP) == 0)) {
        printf("  RESULT: COMPLETE - %u words armed, %u popped this run, 0x44 back to 0, 0 dropped\n",
               words, moved);
        if (moved == words)
            printf("           pop == words exactly: one pop per word, no lost or phantom transfers\n");
        else
            printf("           (%u extra pops are TDO words left in the RX FIFO by the TAP setup)\n",
                   moved > words ? moved - words : 0);
        return rc;
    }

    printf("  RESULT: INCOMPLETE - %u words armed, %u popped this run, %u still armed, %u dropped\n",
           words, moved, rd(jt, J_DMAW), rd(jt, J_DROP));

    if (h.t_tvalid + 0.005 < h.t_tready)
        printf("  VERDICT: tvalid stopped first, %.3f s before tready\n"
               "           -> the SHIFT ENGINE stopped producing words (RX FIFO starved)\n",
               h.t_tready - h.t_tvalid);
    else if (h.t_tready + 0.005 < h.t_tvalid)
        printf("  VERDICT: tready stopped first, %.3f s before tvalid\n"
               "           -> S2MM stopped accepting words\n",
               h.t_tvalid - h.t_tready);
    else
        printf("  VERDICT: tvalid and tready stopped together\n"
               "           -> both sides stalled at once; check whether pop was flat while\n"
               "              tvalid and tready were still high (handshake bug)\n");
    return rc;
}

int main(int argc, char **argv)
{
    int nbits = 65536, div = 5, i, fd, words, bytes;
    long chunk_req = MAX_XFER;
    unsigned dst_off;
    double t0, dt;
    volatile uint32_t *map;
    uint32_t *tdo, pop0;

    setvbuf(stdout, NULL, _IONBF, 0);   /* unbuffered: a hang must still show progress */
    setvbuf(stderr, NULL, _IONBF, 0);

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-n") && i + 1 < argc) nbits = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-d") && i + 1 < argc) div = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-c") && i + 1 < argc) chunk_req = atol(argv[++i]);
    }
    if (nbits % 32) { fprintf(stderr, "nbits must be a multiple of 32\n"); return 1; }
    words = nbits / 32;
    bytes = words * 4;
    if (chunk_req <= 0 || chunk_req > MAX_XFER) chunk_req = MAX_XFER;
    chunk_req &= ~3L;                       /* whole words only */
    if (chunk_req < 4) chunk_req = 4;
    /* TDO staging only has to hold ONE chunk, so put it at the top of the pool
     * and let the source use everything below: a full bitstream is 11.4 MiB,
     * which does not fit in a fixed half of the 16 MiB reservation. */
    dst_off = (unsigned)(DMA_POOL_SZ - (uint32_t)chunk_req);
    if (bytes > (int)dst_off) {
        fprintf(stderr, "too many bits for the pool: %d bytes, %u available"
                        " (lower -c to give the source more room)\n", bytes, dst_off);
        return 1;
    }

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) die("open /dev/mem");

    /* Map the two blocks separately - simpler and it always works. */
    dma = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, DMA_BASE);
    if (dma == MAP_FAILED) die("mmap dma block 0x40400000");
    jt  = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, JTAG0_BASE);
    if (jt == MAP_FAILED) die("mmap jtag0 block 0x43C00000");
    printf("  mapped dma=%p jt=%p\n", (void *)dma, (void *)jt);

    pool = mmap(NULL, DMA_POOL_SZ, PROT_READ | PROT_WRITE, MAP_SHARED, fd, DMA_POOL);
    if (pool == MAP_FAILED) die("mmap dma pool (did the DT set mem=1008M?)");
    close(fd);

    printf("xvcdma  bits=%d  words=%d  bytes=%d\n", nbits, words, bytes);
    printf("  dma MM2S_DMASR=0x%08X  S2MM_DMASR=0x%08X\n",
           rd(dma, MM2S_DMASR), rd(dma, S2MM_DMASR));

    /* ---- buffers in the reserved pool ---- */
    {
        uint32_t *src = (uint32_t *)pool;             /* TDI words */
        tdo = (uint32_t *)(pool + dst_off);           /* TDO staging, one chunk */
        for (i = 0; i < words; i++) src[i] = 0xAAAAAAAAu;   /* any pattern */
        memset((void *)tdo, 0, chunk_req);
    }
    printf("  src=0x%08X  tdo=0x%08X  src room=%u bytes\n",
           DMA_POOL, DMA_POOL + dst_off, dst_off);

    /* ---- do NOT pulse Reset: the core is already reset by PL configuration,
     * and on this design the DMACR Reset bit (bit1) never self-clears, which
     * left both channels permanently in reset and silently refused to start.
     * Clear it explicitly, then just run. */
    wr(dma, MM2S_DMACR, 0); wr(dma, S2MM_DMACR, 0);
    usleep(1000);
    printf("  cleared: MM2S_DMACR=0x%08X  S2MM_DMACR=0x%08X\n",
           rd(dma, MM2S_DMACR), rd(dma, S2MM_DMACR));
    if (rd(dma, MM2S_DMACR) & 2) printf("  WARNING: MM2S Reset bit will not clear\n");
    if (rd(dma, S2MM_DMACR) & 2) printf("  WARNING: S2MM Reset bit will not clear\n");

    /* ---- TAP: reset, then BYPASS, so the DR is one bit per device ---- */
    printf("  step A: TAP reset\n");
    wr(jt, J_DIV, (uint32_t)div);
    wr(jt, J_DMAW, 0);                 /* disarm TLAST while doing the TAP setup */
    wr(jt, J_LEN, 6); wr(jt, J_TMS, 0x3F); wr(jt, J_TDI, 0x00); wr(jt, J_CTRL, 1);
    while (rd(jt, J_CTRL) & 1) ;
    wr(jt, J_LEN, 1); wr(jt, J_TMS, 0); wr(jt, J_TDI, 0); wr(jt, J_CTRL, 1);
    while (rd(jt, J_CTRL) & 1) ;
    /* IR scan: Select-DR, Select-IR, Capture-IR, Shift-IR x6 (all ones), Exit1 */
    {
        /* TMS bit order is LSB-first per byte */
        uint32_t tms = 0, tdi = 0x3F;   /* 11111100 = ShiftIR path */
        tms = 0x0000003F;                /* first 6 bits = 1,1,0,0,0,0 ... see below */
        /* build TMS: 1,1,0,0,0,0,0,1 -> 0b10000011 */
        tms = 0x83;
        wr(jt, J_LEN, 8); wr(jt, J_TMS, tms); wr(jt, J_TDI, tdi); wr(jt, J_CTRL, 1);
        while (rd(jt, J_CTRL) & 1) ;
    }
    printf("  TAP prepared, DIV=%d (TCK %.2f MHz)\n", div, 100.0 / (2.0 * div));

    /* Flush the TDO words the TAP setup left in the RX FIFO, so the pop delta
     * for this run is exactly the number of words the DMA moved. */
    wr(jt, J_CTRL, 0x4);                    /* ctrl bit2 = FIFO clear */
    wr(jt, J_CTRL, 0x0);

    /* ---- fire the run, in transfers of at most MAX_XFER bytes ---- */
    printf("  step C: arm S2MM\n");
    wr(dma, S2MM_DMACR, 1);                 /* RS, stays set across chunks */
    printf("    S2MM_DMACR reads 0x%08X\n", rd(dma, S2MM_DMACR));
    if (rd(dma, S2MM_DMACR) & 2) printf("    !! S2MM still in Reset, it will not move data\n");
    printf("  step D: arm MM2S\n");
    wr(dma, MM2S_DMACR, 1);
    printf("    MM2S_DMACR reads 0x%08X\n", rd(dma, MM2S_DMACR));

    /* TMS is forced to 0 and the TAP stays in Shift-DR across the seam, so it
     * is safe to stop between chunks: TCK just idles. */
    pop0 = rd(jt, J_POP);
    {
        uint32_t off = 0, total = (uint32_t)bytes, chunk = (uint32_t)chunk_req;
        int nchunk = 0;

        t0 = now_s();
        while (off < total) {
            uint32_t len = total - off;
            uint32_t cw, pop_before, timeout_ms;

            if (len > chunk) len = chunk;
            cw = len / 4;
            pop_before = rd(jt, J_POP);
            timeout_ms = (int)(cw * 0.0032) * 3 + 5000;   /* 320 clk/word @100 MHz */

            nchunk++;
            printf("  chunk %d: src+%u  dst+%u  %u bytes  %u words\n",
                   nchunk, off, off, len, cw);

            wr(jt, J_DMAW, cw);                       /* TLAST on this chunk's last word */
            wr(dma, S2MM_DA, DMA_POOL + dst_off);
            wr(dma, S2MM_LENGTH, len);                /* starts S2MM */
            wr(dma, MM2S_SA, DMA_POOL + off);
            wr(dma, MM2S_LENGTH, len);                /* starts MM2S */

            if (trace_run(timeout_ms, cw, pop_before) < 0) {
                fprintf(stderr, "  chunk %d stalled\n", nchunk);
                break;
            }
            off += len;
        }
        printf("  step E: done, %d chunk(s)\n", nchunk);
    }
    dt = now_s() - t0;

    printf("  done in %.4f s  ->  %.2f Mbit/s\n", dt, nbits / dt / 1e6);
    printf("  MM2S_DMASR=0x%08X  S2MM_DMASR=0x%08X\n",
           rd(dma, MM2S_DMASR), rd(dma, S2MM_DMASR));
    printf("  words left in 0x44 = %u (0 = all consumed)\n", rd(jt, J_DMAW));
    printf("  0x48 drop=%u  0x24 status=0x%08X (rx_used=0x%02X tx_free=0x%02X)\n",
           rd(jt, J_DROP), rd(jt, J_STATUS),
           (rd(jt, J_STATUS) >> 8) & 0xFF, rd(jt, J_STATUS) & 0xFF);
    printf("  0x4C tvalid=%u  0x50 tready=%u  0x54 pop=%u (this run: %u of %d words)\n",
           rd(jt, J_TVALID), rd(jt, J_TREADY), rd(jt, J_POP),
           rd(jt, J_POP) - pop0, words);
    printf("  TDO[0..7] = %08X %08X %08X %08X %08X %08X %08X %08X\n",
           tdo[0], tdo[1], tdo[2], tdo[3], tdo[4], tdo[5], tdo[6], tdo[7]);
    return 0;
}
