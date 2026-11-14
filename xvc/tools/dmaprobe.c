/*
 * dmaprobe - trace the dma_proxy path (DMA + interrupts) on the XVC engine.
 *
 * Hardware rule under test: the engine asserts m_axis_tdo_tlast only while
 * dmaw_left == 1, and dmaw_left is loaded by a software write to engine 0x44.
 * Arm 0x44 with the word count of THIS transfer before starting S2MM; if S2MM
 * starts first, no TLAST ever arrives and the packet never terminates.
 *
 * The tool is deliberately chatty: every step dumps the registers that decide
 * whether the run can work, so a failure points at one specific wire.
 *
 * Usage: dmaprobe [-d div] [-n words]
 *   -d  TCK divider (engine 0x14 write; read back at 0x18), default 5 = 10 MHz
 *   -n  words for the long transfer test, default 64 (max 1024)
 *
 * Build inside the PetaLinux VM (bitbake recipe: recipes-apps/dmaprobe).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define MIO_MAP     0x10000UL
#define ENGINE_BASE 0x43C00000UL
#define DMA_BASE    0x40400000UL

/* engine registers: writes and reads do NOT share one map (see RTL) */
#define J_LEN     0x00
#define J_TMS     0x04
#define J_TDI     0x08
#define J_TDO     0x0C
#define J_CTRL    0x10
#define J_DIV_W   0x14   /* DIV write port        */
#define J_DIV_R   0x18   /* DIV read port, 0xA7 version otherwise */
#define J_STATUS  0x24
#define J_DMAW    0x44
#define J_DROP    0x48
#define J_POP     0x54

/* AXI DMA registers */
#define D_MM2S_CR   0x00
#define D_MM2S_SR   0x04
#define D_S2MM_CR   0x30
#define D_S2MM_SR   0x34
#define D_S2MM_DA   0x48
#define D_S2MM_LEN  0x58
#define D_MM2S_SA   0x18
#define D_MM2S_LEN  0x28

/* ---- shared with the kernel driver (see dma-proxy.h) ---- */
#define BUFFER_COUNT 3
#define BUFFER_SIZE  1048576

enum proxy_status { PROXY_NO_ERROR = 0, PROXY_BUSY = 1,
                    PROXY_TIMEOUT = 2, PROXY_ERROR = 3 };

struct channel_buffer {
    unsigned int buffer[BUFFER_SIZE / sizeof(unsigned int)];
    enum proxy_status status;
    unsigned int length;
} __attribute__((aligned(1024)));

#define START_XFER  1
#define FINISH_XFER 2

static const char *st(enum proxy_status s)
{
    switch (s) {
    case PROXY_NO_ERROR: return "ok";
    case PROXY_BUSY:     return "busy";
    case PROXY_TIMEOUT:  return "TIMEOUT";
    case PROXY_ERROR:    return "ERROR";
    }
    return "?";
}

static volatile uint32_t *eng, *dma;
/* ioctl argument lives in its own cache line: the driver is also given
 * this address and, on this kernel, the FINISH path appears to write the
 * transfer length back through it. Keeping it off the stack documents
 * that the argument is not a plain input. */
static volatile int xfer_idx __attribute__((aligned(64)));

static inline void ew(uint32_t o, uint32_t v) { eng[o / 4] = v; }
static inline uint32_t er(uint32_t o) { return eng[o / 4]; }
static inline uint32_t dr(uint32_t o) { return dma[o / 4]; }

static void dmasr(const char *tag)
{
    printf("   %-14s MM2S_CR=%08X SR=%08X | S2MM_CR=%08X SR=%08X\n", tag,
           dr(D_MM2S_CR), dr(D_MM2S_SR), dr(D_S2MM_CR), dr(D_S2MM_SR));
}

static void engstate(const char *tag)
{
    uint32_t s = er(J_STATUS);
    printf("   %-14s 0x44(left)=%u 0x48(drop)=%u STATUS=%08X tx_free=%u "
           "rx_used=%u\n", tag, er(J_DMAW), er(J_DROP), s, s & 0xFF,
           (s >> 8) & 0xFF);
}

/* One 32-bit shift through the register path: stays in Shift-DR (TMS=0). */
static uint32_t reg_shift32(uint32_t tdi)
{
    ew(J_TMS, 0);
    ew(J_TDI, tdi);
    ew(J_LEN, 32);
    ew(J_CTRL, 1);
    while (er(J_CTRL) & 1)
        ;
    return er(J_TDO);
}

static void flush_rx(void)
{
    ew(J_CTRL, 0x4);
    usleep(2000);
    ew(J_CTRL, 0x0);
}

int main(int argc, char **argv)
{
    int div = 5, words = 64, i, idx = 0;
    int fd_mem, fd_tx, fd_rx;
    struct channel_buffer *txbuf, *rxbuf;
    size_t maplen = sizeof(struct channel_buffer) * BUFFER_COUNT;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-d") && i + 1 < argc) div = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-n") && i + 1 < argc) words = atoi(argv[++i]);
    }
    if (words < 1) words = 1;
    if (words > (int)(BUFFER_SIZE / 4)) words = BUFFER_SIZE / 4;

    fd_mem = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd_mem < 0) { perror("open /dev/mem"); return 1; }
    eng = mmap(NULL, MIO_MAP, PROT_READ | PROT_WRITE, MAP_SHARED, fd_mem,
               ENGINE_BASE);
    dma = mmap(NULL, MIO_MAP, PROT_READ | PROT_WRITE, MAP_SHARED, fd_mem,
               DMA_BASE);
    if (eng == MAP_FAILED || dma == MAP_FAILED) { perror("mmap"); return 1; }

    fd_tx = open("/dev/dma_proxy_tx", O_RDWR);
    fd_rx = open("/dev/dma_proxy_rx", O_RDWR);
    if (fd_tx < 0 || fd_rx < 0) { perror("open dma_proxy"); return 1; }
    txbuf = mmap(NULL, maplen, PROT_READ | PROT_WRITE, MAP_SHARED, fd_tx, 0);
    rxbuf = mmap(NULL, maplen, PROT_READ | PROT_WRITE, MAP_SHARED, fd_rx, 0);
    if (txbuf == MAP_FAILED || rxbuf == MAP_FAILED) {
        perror("mmap channel buffers"); return 1;
    }
    printf("sizeof(struct channel_buffer)=%zu maplen=%zu\n",
           sizeof(struct channel_buffer), maplen);
    printf("txbuf=%p rxbuf=%p\n", (void *)txbuf, (void *)rxbuf);
    {
        int b2;
        for (b2 = 0; b2 < BUFFER_COUNT; b2++) {
            txbuf[b2].buffer[0] = 0x5A5A0000u | b2;
            txbuf[b2].buffer[BUFFER_SIZE / 4 - 1] = 0xA5A50000u | b2;
            rxbuf[b2].buffer[0] = 0x5A5A0000u | b2;
            rxbuf[b2].buffer[BUFFER_SIZE / 4 - 1] = 0xA5A50000u | b2;
            txbuf[b2].length = 0;
            rxbuf[b2].length = 0;
            printf("touch buf %d ok (last word ofs +%zu)\n", b2,
                   (size_t)b2 * sizeof(struct channel_buffer) +
                   sizeof(txbuf[b2].buffer) - 4);
        }
        fflush(stdout);
    }
    memset(txbuf, 0, maplen);
    memset(rxbuf, 0, maplen);

    ew(J_DIV_W, (uint32_t)div);
    printf("divider: wrote %d to 0x14, read back 0x18 = %u (0xA7.... = version "
           "on 0x14)\n", div, er(J_DIV_R));
    printf("TCK = %.2f MHz if the write took\n", 100.0 / (2.0 * div));

    /* ---- step 1: TAP reset -> Shift-DR, then a 32-bit DR shift ---- */
    ew(J_DMAW, 0);                       /* disarm TLAST during TAP setup */
    ew(J_TMS, 0x3F); ew(J_LEN, 6); ew(J_TDI, 0); ew(J_CTRL, 1);
    while (er(J_CTRL) & 1)
        ;
    ew(J_TMS, 0x02); ew(J_LEN, 4); ew(J_TDI, 0); ew(J_CTRL, 1);
    while (er(J_CTRL) & 1)
        ;
    /* 32 clocks with TMS=0: shifts the DR out. After a TAP reset with no
     * instruction loaded the selected DR is IDCODE, so this must be the
     * device ID - proof that the engine shifts and we are in Shift-DR. */
    {
        uint32_t tdo = reg_shift32(0);
        printf("step1: DR shift -> TDO=%08X %s\n", tdo,
               (tdo == 0xFFFFFFFF || tdo == 0x00000000)
               ? "(all ones/zeros: TAP not shifting!)" : "(looks live)");
    }
    flush_rx();

    /* ---- step 2: one word through the DMA ---- */
    {
        uint32_t tdo;
        int rc;

        ew(J_TMS, 0);
        txbuf[0].buffer[0] = 0x00000000;
        txbuf[0].length = 4;
        rxbuf[0].length = 4;
        rxbuf[0].buffer[0] = 0xDEADBEEF;

        ew(J_DMAW, 1);
        printf("step2: armed 0x44=1, reads back %u\n", er(J_DMAW));
        engstate("before");
        dmasr("before");

        rc = ioctl(fd_rx, START_XFER, &idx);
        printf("step2: START rx rc=%d\n", rc);
        dmasr("rx started");
        rc = ioctl(fd_tx, START_XFER, &idx);
        printf("step2: START tx rc=%d\n", rc);
        dmasr("tx started");

        ioctl(fd_rx, FINISH_XFER, &idx);
        dmasr("rx finished");
        printf("step2: rx.status=%s rx.len=%u rx[0]=%08X\n",
               st(rxbuf[0].status), rxbuf[0].length, rxbuf[0].buffer[0]);
        engstate("after");

        ioctl(fd_tx, FINISH_XFER, &idx);
        printf("step2: tx.status=%s\n", st(txbuf[0].status));
        tdo = rxbuf[0].buffer[0];
        printf("step2: %s (rx[0]=%08X, want an IDCODE, not DEADBEEF)\n",
               (tdo == 0xDEADBEEF) ? "NO DATA LANDED" : "data landed", tdo);
    }

    /* ---- step 3: sustained run, rotating the proxy buffers ----
     * dma_proxy keeps one descriptor/completion per buffer index, so a second
     * transfer on the same index immediately after finishing one reuses stale
     * descriptor state. The reference design rotates 0..BUFFER_COUNT-1; do the
     * same here, which is also what the server must do.
     */
    {
        int chunk_words = words;         /* per transfer */
        int chunks = 16, ok = 0, c;
        struct { double t; unsigned long bits; } run = { 0, 0 };
        struct timespec t0, t1;
        double now_s;

        printf("step3: %d chunks x %d words, rotating buffers\n", chunks,
               chunk_words);
        clock_gettime(CLOCK_MONOTONIC, &t0);
        for (c = 0; c < chunks; c++) {
            int b = c % BUFFER_COUNT;   /* per-buffer completion */
            int rc;

            for (i = 0; i < chunk_words; i++)
                txbuf[b].buffer[i] = 0xAAAAAAAAu;
            txbuf[b].length = (unsigned)chunk_words * 4;
            rxbuf[b].length = (unsigned)chunk_words * 4;
            for (i = 0; i < chunk_words; i++)
                rxbuf[b].buffer[i] = 0xDEADBEEFu;

            if (c > 0 && c < 2) printf("   chunk %d buf %d start\n", c, b);
            if (c < 2) printf("   fill buf %d ofs +%zu\n", b,
                   (size_t)b * sizeof(struct channel_buffer));
            /* Frame-align each chunk: disarm, then clear the TX/RX FIFO
             * pointers so no word from the previous run can be popped into
             * this packet (a leftover TDO word makes S2MM "complete" on a
             * packet that moved nothing). The TAP stays in Shift-DR. */
            ew(J_DMAW, 0);
            ew(J_CTRL, 0x4);
            usleep(5);
            ew(J_CTRL, 0x0);
            ew(J_DMAW, (uint32_t)chunk_words);
            if (c < 2) printf("     filled; 0x44=%u\n", er(J_DMAW));
            xfer_idx = b;
            rc = ioctl(fd_rx, START_XFER, (int *)&xfer_idx);
            if (c < 2) printf("     rx START rc=%d b=%d S2MM_DA=%08X "
                    "S2MM_LEN=%08X\n", rc, b, dr(D_S2MM_DA), dr(D_S2MM_LEN));
            rc |= ioctl(fd_tx, START_XFER, (int *)&xfer_idx);
            if (c < 2) printf("     tx START rc=%d b=%d MM2S_SA=%08X "
                    "MM2S_LEN=%08X\n", rc, b, dr(D_MM2S_SA), dr(D_MM2S_LEN));

            /* Do not trust the driver's blocking FINISH for the handshake: on
             * this kernel it can return before the channel has actually
             * finished, which made 16 chunks "complete" in 5 ms. Poll the DMA
             * status and the armed word count, then FINISH to reap it. */
            {
                struct timespec dp;
                double limit = 0.2 + chunk_words * 0.0032 * 4.0;
                int polled = 0;

                clock_gettime(CLOCK_MONOTONIC, &dp);
                double end = dp.tv_sec + dp.tv_nsec / 1e9 + limit;
                for (;;) {
                    uint32_t sr = dr(D_S2MM_SR);
                    clock_gettime(CLOCK_MONOTONIC, &dp);
                    now_s = dp.tv_sec + dp.tv_nsec / 1e9;
                    if ((sr & 0x1001) || er(J_DMAW) == 0) { polled = 1; break; }
                    if (now_s > end) break;
                    usleep(5);
                }
                if (c < 2) printf("     poll: %s after %.3f s S2MM_SR=%08X "
                        "0x44=%u\n", polled ? "done" : "TIMEOUT",
                        now_s - (end - limit), dr(D_S2MM_SR), er(J_DMAW));
                ioctl(fd_rx, FINISH_XFER, (int *)&xfer_idx);
                ioctl(fd_tx, FINISH_XFER, (int *)&xfer_idx);
                rc |= polled ? 0 : -1;
            }

            /* data really moved? count words that still hold the sentinel */
            {
                int k, same = 0;
                for (k = 0; k < chunk_words; k++)
                    if (rxbuf[b].buffer[k] == 0xDEADBEEFu) same++;
                if (c < 2) printf("     status rx=%d tx=%d | %d/%d words still "
                        "sentinel | first=%08X\n",
                        (int)rxbuf[b].status, (int)txbuf[b].status, same,
                        chunk_words, rxbuf[b].buffer[0]);
            }

            if (rc == 0 && rxbuf[b].status == PROXY_NO_ERROR &&
                txbuf[b].status == PROXY_NO_ERROR &&
                er(J_DMAW) == 0)
                ok++;
            else
                printf("   chunk %d (buf %d): rx=%s tx=%s rc=%d\n", c, b,
                       st(rxbuf[b].status), st(txbuf[b].status), rc);
        }
        clock_gettime(CLOCK_MONOTONIC, &t1);
        run.t = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
        run.bits = (unsigned long)chunks * chunk_words * 32;
        printf("step3: %d/%d chunks ok, %.4f s -> %.2f Mbit/s "
               "(wire ceiling 10.00 at div 5)\n", ok, chunks, run.t,
               run.bits / run.t / 1e6);
        dmasr("after");
        engstate("after");
        printf("step3: last rx[0..3]=%08X %08X %08X %08X\n",
               rxbuf[chunks % BUFFER_COUNT].buffer[0],
               rxbuf[chunks % BUFFER_COUNT].buffer[1],
               rxbuf[chunks % BUFFER_COUNT].buffer[2],
               rxbuf[chunks % BUFFER_COUNT].buffer[3]);
    }

    return 0;
}
