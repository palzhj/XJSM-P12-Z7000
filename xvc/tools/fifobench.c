/*
 * fifobench.c - CPU cost of the FIFO streaming path.
 *
 * Pushes words into 0x1C TXD and drains 0x20 RXD, paced by 0x24 STATUS.
 * The engine shifts each word in the background, so the interesting number is
 * how much CPU the loop burns per 32-bit word - compare with regbench, where
 * every word costs a full synchronous round trip.
 *
 *   time ./fifobench -n 262144 -d 5
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
#define J_CTRL   0x10
#define J_DIV    0x14
#define J_TXD    0x1C
#define J_RXD    0x20
#define J_STATUS 0x24

static volatile uint32_t *jt;
static inline uint32_t rd(unsigned off) { return jt[off / 4]; }
static inline void     wr(unsigned off, uint32_t v) { jt[off / 4] = v; }

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
    int n = 262144, div = 5, i, fd;
    uint32_t pushed = 0, popped = 0, drain;
    double t0, dt;

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
    wr(J_CTRL, 4); wr(J_CTRL, 0);          /* flush the queue */

    printf("fifobench  words=%d  DIV=%d  TCK=%.3f MHz\n", n, div, 100.0 / (2.0 * div));

    t0 = now_s();
    while (pushed < (uint32_t)n) {
        uint32_t st = rd(J_STATUS);
        uint32_t free_ = st & 0xFF;
        uint32_t used  = (st >> 8) & 0xFF;
        while (free_ && pushed < (uint32_t)n) {
            wr(J_TXD, 0x12345678u + pushed);
            pushed++;
            free_ = rd(J_STATUS) & 0xFF;
        }
        while (used) {
            (void)rd(J_RXD);
            popped++;
            used = (rd(J_STATUS) >> 8) & 0xFF;
        }
    }
    /* let the engine finish the last words */
    do { drain = (rd(J_STATUS) >> 8) & 0xFF;
         while (drain) { (void)rd(J_RXD); popped++; drain = (rd(J_STATUS) >> 8) & 0xFF; }
    } while (0);
    dt = now_s() - t0;

    printf("  %u words pushed, %u drained\n", pushed, popped);
    printf("  %8.1f ns/word   = %6.2f Mbit/s   (wire floor is %.0f ns/word)\n",
           dt / pushed * 1e9, 32.0 * pushed / dt / 1e6, 32.0 * 2.0 * div * 10.0);
    return 0;
}
