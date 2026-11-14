/*
 * regbench.c - benchmark the AXI4-Lite register ("chunked") JTAG path.
 *
 * One 32-bit chunk costs: write LEN, write TMS, write TDI, strobe CTRL,
 * poll CTRL until the engine is idle, read TDO. This measures that whole
 * round trip against the 3.2 us the wire actually needs at DIV=5 (10 MHz),
 * so the difference is the cost of the register interface.
 *
 * Only uses the chunk registers, so it runs on the single_reg bitstream
 * (USE_FIFO=0), where 0x1C/0x20 do nothing.
 *
 *   ./regbench -n 20000 -d 5
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>

#define JTAG0_BASE 0x43C00000u

#define J_LEN   0x00
#define J_TMS   0x04
#define J_TDI   0x08
#define J_TDO   0x0C
#define J_CTRL  0x10
#define J_DIV   0x14

static volatile uint32_t *jt;

static inline uint32_t rd(unsigned off) { return jt[off / 4]; }
static inline void     wr(unsigned off, uint32_t v) { jt[off / 4] = v; }

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static uint32_t shiftn(int nbits, uint32_t tms, uint32_t tdi)
{
    unsigned guard = 0;
    wr(J_LEN, (uint32_t)nbits);
    wr(J_TMS, tms);
    wr(J_TDI, tdi);
    wr(J_CTRL, 1);
    while (rd(J_CTRL) & 1)
        if (++guard > 100000000u) { fprintf(stderr, "shift timeout\n"); break; }
    return rd(J_TDO);
}
static uint32_t shift32(uint32_t tms, uint32_t tdi) { return shiftn(32, tms, tdi); }

int main(int argc, char **argv)
{
    int n = 20000, div = 5, i;
    uint32_t tdo_a, tdo_b;
    double t0, dt;
    int fd;

    setvbuf(stdout, NULL, _IONBF, 0);
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-n") && i + 1 < argc) n = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-d") && i + 1 < argc) div = atoi(argv[++i]);
    }

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    jt = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, JTAG0_BASE);
    if (jt == MAP_FAILED) { perror("mmap jtag0"); return 1; }
    close(fd);

    wr(J_DIV, (uint32_t)div);
    wr(J_CTRL, 4); wr(J_CTRL, 0);         /* flush (no-op without a FIFO) */

    printf("regbench  iterations=%d  DIV=%d  TCK=%.3f MHz\n", n, div, 100.0 / (2.0 * div));

    /* TAP reset so the target is in a known state */
    wr(J_LEN, 5); wr(J_TMS, 0x1F); wr(J_TDI, 0); wr(J_CTRL, 1);
    while (rd(J_CTRL) & 1) ;

    /* ---- interface cost only: the 4 writes + poll, with a 32-bit shift ---- */
    t0 = now_s();
    for (i = 0; i < n; i++) shift32(0, 0xAAAAAAAAu + i);
    dt = now_s() - t0;
    printf("  32-bit chunk (full)  %8.1f ns/chunk  = %6.2f Mbit/s\n",
           dt / n * 1e9, 32.0 * n / dt / 1e6);

    /* ---- same loop, but only the writes: isolates the AXI4-Lite cost ---- */
    t0 = now_s();
    for (i = 0; i < n; i++) {
        wr(J_LEN, 32); wr(J_TMS, 0); wr(J_TDI, 0x12345678u + i); wr(J_CTRL, 1);
    }
    while (rd(J_CTRL) & 1) ;
    dt = now_s() - t0;
    printf("  4 writes, no poll   %8.1f ns/chunk  (AXI4-Lite cost)\n", dt / n * 1e9);

    /* ---- prove the chain answers, with a real TAP sequence ----
     * A bare 32-clock shift at TMS=0 would leave the TAP parked in Run-Test/
     * Idle, where TDO is not driven by any data register and reads back 1 -
     * so compare patterns only after walking to Shift-DR. */
    {
        int seq[64], n = 0, i;
        uint32_t lo = 0, hi = 0, rem, id;
        uint64_t comb;
        for (i = 0; i < 5; i++) seq[n++] = 1;      /* Test-Logic-Reset */
        seq[n++] = 0;                              /* Run-Test/Idle    */
        seq[n++] = 1; seq[n++] = 0; seq[n++] = 0;  /* Select-DR, Capture-DR, Shift-DR */
        for (i = 0; i < 32; i++) seq[n++] = 0;     /* shift the IDCODE out */
        seq[n++] = 1;                              /* Exit1-DR */
        for (i = 0; i < n; i++) {
            if (!seq[i]) continue;
            if (i < 32) lo |= 1u << i; else hi |= 1u << (i - 32);
        }
        tdo_a = shift32(lo, 0);
        rem = (uint32_t)(n - 32);
        tdo_b = shiftn((int)rem, hi & ((1u << rem) - 1u), 0);
        comb = (uint64_t)tdo_a | ((uint64_t)(tdo_b & ((1u << rem) - 1u)) << 32);
        id = (uint32_t)((comb >> 9) & 0xFFFFFFFFu);
        printf("  IDCODE 0x%08X  ", id);
        if ((id & 1) && (((id >> 1) & 0x7FF) == 0x049))
            printf("valid Xilinx IDCODE -> chain alive\n");
        else
            printf("NOT a valid IDCODE -> check the target\n");
    }

    printf("  wire time for 32 bits at this TCK: %.0f ns\n", 32.0 * 2.0 * div * 10.0);
    return 0;
}
