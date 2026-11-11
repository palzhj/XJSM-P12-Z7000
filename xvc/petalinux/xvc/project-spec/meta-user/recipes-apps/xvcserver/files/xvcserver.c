/*
 * xvcserver_g1.c - XVC server (single channel, port 2543), following XAPP1251
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
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/wait.h>
#include <sys/file.h>
#include <signal.h>

#define MAP_SIZE 0x1000
#define XVC_MAX_BITS 4194304   /* 4 Mbit: covers the large packets Vivado may send */
#define CTRL_BASE 0x43C00000u
#define XVC_PORT 2543

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
    /* Simple, reliable flow control: push 32 words -> wait until RX has 32 -> pop 32 */
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
}static int do_shift(int nbits, const uint8_t *tms, const uint8_t *tdi, uint8_t *tdo)
{
    int done = 0;

    bus_lock();

    /* Flush the FIFO (leftovers from the previous session would desync the flow counters) */
    wr(0x10, 4);        /* CTRL bit2 = flush */
    wr(0x10, 0);

    while (done < nbits) {
        int chunk = nbits - done;
        uint32_t m = 0, d = 0, r;
        int i, guard = 100000;

        if (chunk >= FIFO_MIN) {
            int run = zero_run(tms, done, chunk);
            int K = run & ~31;
            if (K >= FIFO_MIN) {
                if (stream_zero(K, tdi, tdo, done) < 0) {
                    fprintf(stderr, "stream failed at %d, falling back to 32-bit\n", done);
                    /* fallback: keep processing the rest in chunked mode */
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
        /* The TDO register is filled by right-shifting: for n<32 the data sits in the high bits and must be aligned down */
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
                if (period_ns == 0) period_ns = 100;      /* 0 => default 10 MHz */
                tck_div = (period_ns + 19) / 20;
                if (tck_div < g_min_div) tck_div = g_min_div;   /* never faster than the speed set by -d */
                if (tck_div < 1) tck_div = 1;
                if (tck_div > 65535) tck_div = 65535;
                printf("settck: %u ns -> DIV %u (TCK %.3f MHz)\n",
                       period_ns, tck_div, 100.0 / (2.0 * tck_div));
                fflush(stdout);
            }
            /* Per XVC convention, echo the requested period (actual speed is limited by -d) */
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
            /* recorded after do_shift, includes TDO */

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
                    fwrite(buffer + nr_bytes, 1, nr_bytes, g_dump);   /* large transfers: raw TDI */
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
    int fd, s, one = 1;
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

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    map = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, base);
    close(fd);
    if (map == MAP_FAILED) { perror("mmap"); return 1; }
    regs = (volatile uint32_t *)map;
    wr(0x14, tck_div);          /* DIV @0x14 (register address 0x14) */
    printf("PL_TAG=0x%08X (expect 0xA7xxxxxx)\n", rd(0x14));
    { uint32_t st = rd(0x24);
      printf("FIFO_STATUS=0x%08X  tx_free=%u rx_used=%u (expect tx_free=128 rx_used=0)\n",
             st, st & 0xFF, (st >> 8) & 0xFF); }

    signal(SIGCHLD, SIG_IGN);
    snprintf(xvc_info, sizeof(xvc_info), "xvcServer_v1.0:%u\n", XVC_MAX_BITS);
    printf("xvcserver_g1: JTAG@0x%08X, TCP %d, max %d bits, default DIV %u (%.3f MHz)\n",
           base, XVC_PORT, XVC_MAX_BITS, tck_div, 100.0 / (2.0 * tck_div));
    fflush(stdout);

    s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); return 1; }
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(XVC_PORT);
    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
    if (listen(s, 4) < 0) { perror("listen"); return 1; }

    for (;;) {
        struct sockaddr_in peer;
        socklen_t plen = sizeof(peer);
        int cfd = accept(s, (struct sockaddr *)&peer, &plen);
        if (cfd < 0) { perror("accept"); continue; }
        setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        { int bufsz = 1 << 20;
          setsockopt(cfd, SOL_SOCKET, SO_RCVBUF, &bufsz, sizeof(bufsz));
          setsockopt(cfd, SOL_SOCKET, SO_SNDBUF, &bufsz, sizeof(bufsz)); }
        printf("client connected\n"); fflush(stdout);
        if (fork() == 0) {
            close(s);
            handle_client(cfd);
            close(cfd);
            printf("client closed\n"); fflush(stdout);
            _exit(0);
        }
        close(cfd);
    }
}
