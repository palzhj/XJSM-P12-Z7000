/*
 * jtag_idcode.c - read the IDCODE straight out of the jtag_ctrl shift engine.
 *
 * Bypasses the XVC server and Vivado entirely: this is the shortest path from
 * "are the JTAG pins actually returning anything?" to an answer. Ported from
 * tools/idcode_test.py, which needs python on the board.
 *
 *   cc -O2 -o jtag_idcode jtag_idcode.c
 *   ./jtag_idcode            # channel 0 at 0x43C00000, DIV default 5 (10 MHz)
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/mman.h>

#define JTAG0_BASE 0x43C00000u

static volatile uint32_t *jt;

static uint32_t rd(unsigned off) { return jt[off / 4]; }
static void wr(unsigned off, uint32_t v) { jt[off / 4] = v; }

static uint32_t shift(int nbits, uint32_t tms, uint32_t tdi)
{
    long g = 0;
    wr(0x00, (uint32_t)nbits);
    wr(0x04, tms);
    wr(0x08, tdi);
    wr(0x10, 1);                     /* CTRL bit0: start, self-clearing     */
    while (rd(0x10) & 1)             /* it reads back 0 once done */
        if (++g > 200000000L) { fprintf(stderr, "shift timed out\n"); break; }
    return rd(0x0C);
}

int main(int argc, char **argv)
{
    int div = (argc > 1) ? atoi(argv[1]) : 5;
    int seq[64], n = 0, i;
    uint32_t tms_lo = 0, tms_hi = 0, c1, c2, comb;
    int rem;
    int fd = open("/dev/mem", O_RDWR | O_SYNC);

    if (fd < 0) { perror("open /dev/mem"); return 1; }
    jt = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, JTAG0_BASE);
    if (jt == MAP_FAILED) { perror("mmap"); return 1; }
    close(fd);

    wr(0x14, (uint32_t)div);         /* DIV */
    wr(0x44, 0);                     /* disarm TLAST */
    wr(0x10, 4); wr(0x10, 0);        /* flush both FIFOs */

    /* 5x TMS=1 -> Test-Logic-Reset; 0 -> Run-Test/Idle; 1,0,0 -> Select-DR,
     * Capture-DR, Shift-DR; 32 clocks at TMS=0 shift the IDCODE out; 1 leaves. */
    for (i = 0; i < 5; i++) seq[n++] = 1;
    seq[n++] = 0;
    seq[n++] = 1; seq[n++] = 0; seq[n++] = 0;
    for (i = 0; i < 32; i++) seq[n++] = 0;
    seq[n++] = 1;

    /* the sequence spans two shifts, so keep the TMS bits for each half:
     * bit 41 (the Exit1-DR clock) lands in the second shift. */
    for (i = 0; i < n; i++) {
        if (!seq[i]) continue;
        if (i < 32) tms_lo |= 1u << i;
        else        tms_hi |= 1u << (i - 32);
    }

    printf("shifting %d bits at DIV=%d (%.2f MHz)\n", n, div, 100.0 / (2.0 * div));

    c1 = shift(32, tms_lo, 0);
    rem = n - 32;
    c2 = shift(rem, tms_hi & ((1u << rem) - 1u), 0);

    comb = c1 | ((uint64_t)(c2 & ((1u << rem) - 1u)) << 32);

    printf("chunk1   = 0x%08X\n", c1);
    printf("chunk2   = 0x%X\n", c2 & ((1u << rem) - 1u));
    printf("combined = 0x%llX\n", (unsigned long long)comb);
    printf("window@9  = 0x%08X\n", (uint32_t)((comb >> 9) & 0xFFFFFFFFu));
    printf("window@10 = 0x%08X\n", (uint32_t)((comb >> 10) & 0xFFFFFFFFu));

    /* A real IDCODE has bit0 = 1; 0xFFFFFFFF / 0x00000000 means nothing drove TDO. */
    if (c1 == 0xFFFFFFFFu || c1 == 0)
        printf("VERDICT: TDO is stuck at %s - no device is answering\n",
               c1 ? "1" : "0");
    else
        printf("VERDICT: TDO is toggling, something is on the chain\n");
    return 0;
}
