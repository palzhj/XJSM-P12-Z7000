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
#define J_DMAW  0x44

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

/* Wait until SR bit0 (halted) clears - i.e. the channel is running - or idle. */
static int wait_not_halted(volatile uint32_t *base, unsigned sr_off, int ms)
{
    int i;
    for (i = 0; i < ms * 100; i++) {
        if (!(rd(base, sr_off) & 1)) return 0;
        usleep(10);
    }
    return -1;
}

/* Wait until the channel reports idle (bit1) or completes. */
static int wait_idle(volatile uint32_t *base, unsigned sr_off, int ms)
{
    int i;
    for (i = 0; i < ms * 100; i++) {
        uint32_t s = rd(base, sr_off);
        if (s & 2) return 0;                 /* idle */
        usleep(10);
    }
    return -1;
}

int main(int argc, char **argv)
{
    int nbits = 65536, div = 5, i, fd, words, bytes;
    double t0, dt;
    volatile uint32_t *map;
    uint32_t *tdo;

    setvbuf(stdout, NULL, _IONBF, 0);   /* unbuffered: a hang must still show progress */
    setvbuf(stderr, NULL, _IONBF, 0);

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-n") && i + 1 < argc) nbits = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-d") && i + 1 < argc) div = atoi(argv[++i]);
    }
    if (nbits % 32) { fprintf(stderr, "nbits must be a multiple of 32\n"); return 1; }
    words = nbits / 32;
    bytes = words * 4;
    if (bytes > (int)DMA_POOL_SZ / 2) { fprintf(stderr, "too many bits\n"); return 1; }

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
        tdo = (uint32_t *)(pool + (DMA_POOL_SZ / 2)); /* TDO words */
        for (i = 0; i < words; i++) src[i] = 0xAAAAAAAAu;   /* any pattern */
        memset((void *)tdo, 0, bytes);
    }
    printf("  src=0x%08X  dst=0x%08X\n",
           DMA_POOL, DMA_POOL + (DMA_POOL_SZ / 2));

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

    /* ---- arm TLAST, then fire both DMA channels ---- */
    wr(jt, J_DMAW, (uint32_t)words);        /* last popped word carries TLAST */

    printf("  step C: arm S2MM\n");
    wr(dma, S2MM_DMACR, 1);                 /* RS */
    printf("    S2MM_DMACR reads 0x%08X\n", rd(dma, S2MM_DMACR));
    if (rd(dma, S2MM_DMACR) & 2) printf("    !! S2MM still in Reset, it will not move data\n");
    wr(dma, S2MM_DA, DMA_POOL + (DMA_POOL_SZ / 2));
    printf("    S2MM_DA     reads 0x%08X\n", rd(dma, S2MM_DA));
    wr(dma, S2MM_LENGTH, (uint32_t)bytes);  /* writing LENGTH starts S2MM */
    printf("    S2MM_LENGTH reads 0x%08X  (write should start it)\n", rd(dma, S2MM_LENGTH));

    printf("  step D: arm MM2S\n");
    wr(dma, MM2S_DMACR, 1);                 /* RS */
    printf("    MM2S_DMACR reads 0x%08X\n", rd(dma, MM2S_DMACR));
    wr(dma, MM2S_SA, DMA_POOL);
    printf("    MM2S_SA     reads 0x%08X\n", rd(dma, MM2S_SA));
    t0 = now_s();
    wr(dma, MM2S_LENGTH, (uint32_t)bytes);  /* writing LENGTH starts MM2S */
    printf("    MM2S_LENGTH reads 0x%08X\n", rd(dma, MM2S_LENGTH));
    printf("  step E: running\n");

    if (wait_idle(dma, MM2S_DMASR, 20000) < 0)
        fprintf(stderr, "  MM2S did not go idle\n");
    if (wait_idle(dma, S2MM_DMASR, 20000) < 0)
        fprintf(stderr, "  S2MM did not go idle\n");
    dt = now_s() - t0;

    printf("  done in %.4f s  ->  %.2f Mbit/s\n", dt, nbits / dt / 1e6);
    printf("  MM2S_DMASR=0x%08X  S2MM_DMASR=0x%08X\n",
           rd(dma, MM2S_DMASR), rd(dma, S2MM_DMASR));
    printf("  words left in 0x44 = %u (0 = all consumed)\n", rd(jt, J_DMAW));
    printf("  TDO[0..7] = %08X %08X %08X %08X %08X %08X %08X %08X\n",
           tdo[0], tdo[1], tdo[2], tdo[3], tdo[4], tdo[5], tdo[6], tdo[7]);
    return 0;
}
