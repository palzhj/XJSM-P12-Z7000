/*
 * perfprobe - measure where the XVC shift time actually goes
 *
 * Runs on the board against the PL registers and reports the cost of each
 * primitive the server uses, so optimisation effort goes to the right place.
 *
 * Build (cross):
 *   arm-xilinx-linux-gnueabi-gcc -O2 -o perfprobe perfprobe.c
 * Run:
 *   ./perfprobe [-n iterations] [-d div]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <stdint.h>
#include <sys/mman.h>

#define BASE     0x43C00000u
#define WIN      0x10000u
#define NCH      12
#define REGS_CH  13

static volatile uint32_t *regs;

static inline uint32_t rd(unsigned off) { return regs[off / 4]; }
static inline void     wr(unsigned off, uint32_t v) { regs[off / 4] = v; }

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
    int n = 200000;
    int div = 5;
    int fd, i;
    double t0, dt;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-n") && i + 1 < argc) n = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-d") && i + 1 < argc) div = atoi(argv[++i]);
    }

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    regs = mmap(NULL, (NCH + 2) * WIN, PROT_READ | PROT_WRITE,
                MAP_SHARED, fd, BASE);
    if (regs == MAP_FAILED) { perror("mmap"); return 1; }
    close(fd);

    printf("perfprobe  iterations=%d  div=%d  TCK=%.3f MHz\n",
           n, div, 100.0 / (2.0 * div));
    printf("-------------------------------------------------------------\n");

    /* 1) a bare register read */
    t0 = now_s();
    {
        uint32_t s = 0;
        for (i = 0; i < n; i++) s += rd(0x24);
        if (s == 0xDEADBEEF) printf(" ");
    }
    dt = now_s() - t0;
    printf("  rd(0x24) STATUS      %8.0f ns/op\n", dt / n * 1e9);

    /* 2) a bare register write */
    t0 = now_s();
    for (i = 0; i < n; i++) wr(0x1C, (uint32_t)i);
    dt = now_s() - t0;
    printf("  wr(0x1C) TXD         %8.0f ns/op\n", dt / n * 1e9);

    /* 3) four writes + one read, i.e. one chunked-path iteration */
    t0 = now_s();
    for (i = 0; i < n; i++) {
        wr(0x00, 32); wr(0x04, 0); wr(0x08, 0); wr(0x10, 1);
        (void)rd(0x0C);
    }
    dt = now_s() - t0;
    printf("  4 writes + 1 read    %8.0f ns/op   (no wait for done)\n", dt / n * 1e9);

    /* 4) a real 32-bit shift: the above plus polling until CTRL.bit0 clears */
    t0 = now_s();
    for (i = 0; i < n; i++) {
        wr(0x14, (uint32_t)div);
        wr(0x00, 32); wr(0x04, 0); wr(0x08, (uint32_t)i);
        wr(0x10, 1);
        while (rd(0x10) & 1) ;
        (void)rd(0x0C);
    }
    dt = now_s() - t0;
    printf("  32-bit shift (full)  %8.0f ns/op   = %.2f Mbit/s\n",
           dt / n * 1e9, 32.0 / (dt / n) / 1e6);

    /* 5) FIFO push only: what streaming saves */
    t0 = now_s();
    for (i = 0; i < n; i++) wr(0x1C, (uint32_t)i);
    dt = now_s() - t0;
    printf("  1 word via FIFO      %8.0f ns/op   = %.2f Mbit/s\n",
           dt / n * 1e9, 32.0 / (dt / n) / 1e6);

    /* 6) FIFO streaming loop, no TCP: push/drain keeping the FIFO full */
    {
        const int WORDS = 8192;          /* 256 Kbit */
        uint32_t pushed = 0, popped = 0;
        int idle = 0;
        t0 = now_s();
        while (popped < WORDS) {
            uint32_t st = rd(0x24);
            int freew = (int)(st & 0xFF);
            int avail = (int)((st >> 8) & 0xFF);
            int did = 0;
            while (freew-- > 0 && pushed < WORDS) { wr(0x1C, pushed); pushed++; did = 1; }
            while (avail-- > 0 && popped < WORDS) { (void)rd(0x20); popped++; did = 1; }
            if (!did) { if (++idle > 2000000) break; } else idle = 0;
        }
        dt = now_s() - t0;
        printf("  FIFO stream 262144b  %8.0f ns/word  = %.2f Mbit/s\n",
               dt / (double)WORDS * 1e9, WORDS * 32.0 / dt / 1e6);
    }

    printf("-------------------------------------------------------------\n");
    printf("  wire time for 32 bit at this TCK: %.0f ns\n", 32.0 * 2.0 * div * 10.0);
    printf("  AXI4-Lite on this SoC is 100 MHz, so one access is at least 10 ns;\n");
    printf("  anything far above that is CPU/mmap overhead, not bus speed.\n");

    return 0;
}
