/*
 * w64dma.c - drive a whole TAP sequence through the 64-bit {TMS,TDI} DMA stream.
 *
 * The point of the wide stream is that TMS rides in the queue, so the DMA can
 * carry TAP navigation and not just TMS=0 DR bursts. This builds a real TAP
 * sequence (Test-Logic-Reset -> Run-Test/Idle -> Select-DR -> Capture-DR ->
 * Shift-DR, 32 clocks, Exit1-DR) packed as {TMS[63:32], TDI[31:0]} words,
 * sends it with the DMA, and reads the captured IDCODE back out of DDR.
 *
 * The engine shifts exactly 32 bits per word, so the 42-clock sequence is
 * padded up to 64 clocks with TMS=1, which parks the TAP back in TLR.
 *
 *   ./w64dma -d 5
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>

#define DMA_BASE   0x40400000u
#define JTAG0_BASE 0x43C00000u
#define DMA_POOL   0x3F000000u
#define DMA_POOL_SZ 0x01000000u

#define MM2S_DMACR   0x00
#define MM2S_DMASR   0x04
#define MM2S_SA      0x18
#define MM2S_LENGTH  0x28
#define S2MM_DMACR   0x30
#define S2MM_DMASR   0x34
#define S2MM_DA      0x48
#define S2MM_LENGTH  0x58

#define J_TDO    0x0C
#define J_CTRL   0x10
#define J_DIV    0x14
#define J_STATUS 0x24
#define J_DMAW   0x44
#define J_DROP   0x48

static volatile uint32_t *dma, *jt;
static volatile uint64_t *src64;
static volatile uint32_t *dst32;

static void die(const char *w) { perror(w); exit(1); }

int main(int argc, char **argv)
{
    int div = 5, i, fd;
    uint32_t tms_w0, tms_w1, tdo0, tdo1, sr;
    int guard;

    setvbuf(stdout, NULL, _IONBF, 0);
    for (i = 1; i < argc; i++)
        if (!strcmp(argv[i], "-d") && i + 1 < argc) div = atoi(argv[++i]);

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) die("open /dev/mem");
    dma = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, DMA_BASE);
    if (dma == MAP_FAILED) die("mmap dma");
    jt = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, JTAG0_BASE);
    if (jt == MAP_FAILED) die("mmap jtag0");
    void *pool = mmap(NULL, DMA_POOL_SZ, PROT_READ | PROT_WRITE, MAP_SHARED, fd, DMA_POOL);
    if (pool == MAP_FAILED) die("mmap pool");
    close(fd);
    src64 = (volatile uint64_t *)pool;                  /* 2 x 64-bit words */
    dst32 = (volatile uint32_t *)((char *)pool + 0x1000); /* 2 x 32-bit TDO */

    /* 42-clock sequence: 5x TMS=1 (TLR), 0 (RTI), 1,0,0 (Sel/Cap/Shift-DR),
     * 32 clocks at TMS=0 shift the IDCODE out, then 1 (Exit1-DR). */
    tms_w0 = 0x1F;                                  /* bits 0..4 */
    tms_w0 |= (1u << 6);                            /* bit 6 -> Select-DR */
    /* bit 5 RTI, bit 7 Capture-DR, bit 8 Shift-DR, then 31 shift clocks */
    tms_w1 = 0x1u;                                  /* bit 0 = clock 32 = Exit1-DR */
    tms_w1 |= 0x003FFFFEu;                          /* pad clocks 33..53 at TMS=1 -> back to TLR */

    src64[0] = ((uint64_t)tms_w0 << 32) | 0x00000000u;
    src64[1] = ((uint64_t)tms_w1 << 32) | 0x00000000u;
    dst32[0] = 0xDEADBEEFu;
    dst32[1] = 0xDEADBEEFu;

    jt[J_DIV / 4] = (uint32_t)div;
    jt[J_CTRL / 4] = 4; jt[J_CTRL / 4] = 0;         /* flush the queues */
    jt[J_DMAW / 4] = 2;                             /* 2 words -> TLAST on the last */

    printf("w64dma  DIV=%d  words=2  src=0x%08X  dst=0x%08X\n",
           div, DMA_POOL, DMA_POOL + 0x1000);
    printf("  word0 = {TMS 0x%08X, TDI 0x00000000}\n", tms_w0);
    printf("  word1 = {TMS 0x%08X, TDI 0x00000000}\n", tms_w1);

    dma[MM2S_DMACR / 4] = 1;                        /* RS */
    dma[S2MM_DMACR / 4] = 1;
    dma[S2MM_DA / 4]   = DMA_POOL + 0x1000;
    dma[S2MM_LENGTH / 4] = 2 * 4;                   /* 2 x 32-bit TDO words */
    dma[MM2S_SA / 4]   = DMA_POOL;
    dma[MM2S_LENGTH / 4] = 2 * 8;                   /* 2 x 64-bit {TMS,TDI} */

    guard = 0;
    do {
        sr = dma[S2MM_DMASR / 4];
        if (++guard > 100000000) { printf("  TIMEOUT\n"); break; }
    } while (!(sr & 0x2) && !(sr & 0x1000));        /* idle or IOC */

    printf("  MM2S_DMASR=0x%08X  S2MM_DMASR=0x%08X\n",
           dma[MM2S_DMASR / 4], dma[S2MM_DMASR / 4]);
    printf("  status 0x24=0x%08X  drop 0x48=%u  words 0x44=%u\n",
           jt[J_STATUS / 4], jt[J_DROP / 4], jt[J_DMAW / 4]);

    tdo0 = dst32[0];
    tdo1 = dst32[1];
    printf("  TDO word0 = 0x%08X   word1 = 0x%08X\n", tdo0, tdo1);
    printf("  IDCODE window@9 = 0x%08X   %s\n",
           (tdo0 >> 9) & 0xFFFFFFFFu,
           ((tdo0 >> 9) & 1) ? "bit0=1 (a device answered)" : "bit0=0");
    return 0;
}
