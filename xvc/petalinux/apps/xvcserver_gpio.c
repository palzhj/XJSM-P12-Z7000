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
#include <signal.h>

#define MAP_SIZE 0x1000
#define GPIO_DATA 0x00
#define GPIO2_DATA 0x08
#define XVC_MAX_BITS 2048
#define CTRL_BASE 0x41200000u   /* AXI GPIO */
#define XVC_PORT 2543

static volatile uint32_t *regs;
static char xvc_info[32];
static uint32_t tck_div = 8;
static uint32_t g_min_div = 50;   /* fastest allowed speed (lower bound on DIV) */

static inline void wr(uint32_t off, uint32_t v) { regs[off / 4] = v; }
static inline uint32_t rd(uint32_t off) { return regs[off / 4]; }

static int do_shift(int nbits, const uint8_t *tms, const uint8_t *tdi, uint8_t *tdo)
{
    int i, t;

    for (i = 0; i < nbits; i++) {
        uint32_t v = 0;
        if (tms[i >> 3] & (1 << (i & 7))) v |= 1u << 1;   /* TMS = bit1 */
        if (tdi[i >> 3] & (1 << (i & 7))) v |= 1u << 2;   /* TDI = bit2 */

        wr(GPIO_DATA, v);           /* TCK = 0 */
        wr(GPIO_DATA, v | 1u);      /* TCK = 1, target samples TMS/TDI */
        t = (int)(rd(GPIO2_DATA) & 1u);
        wr(GPIO_DATA, v);           /* TCK = 0 */

        if (t) tdo[i >> 3] |=  (1 << (i & 7));
        else   tdo[i >> 3] &= ~(1 << (i & 7));
    }
    return 0;
}

static int handle_client(int fd)
{
    static uint8_t buffer[XVC_MAX_BITS * 2 / 8 + 16];
    char cmd[16];

    for (;;) {
        int len, nr_bytes;

        memset(cmd, 0, sizeof(cmd));
        if (read(fd, cmd, 2) != 2) return 1;

        if (!memcmp(cmd, "ge", 2)) {
            fprintf(stderr, "CMD getinfo\n");
            if (read(fd, cmd, 6) != 6) return 1;
            if (write(fd, xvc_info, strlen(xvc_info)) < 0) return 1;
        } else if (!memcmp(cmd, "se", 2)) {
            fprintf(stderr, "CMD settck\n");
            if (read(fd, cmd, 9) != 9) return 1;
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
            /* echo back the requested period per XVC convention (actual speed is capped by -d) */
            {
              uint32_t req;
              memcpy(&req, cmd + 5, 4);
              cmd[0] = (char)(req & 0xff);
              cmd[1] = (char)((req >> 8) & 0xff);
              cmd[2] = (char)((req >> 16) & 0xff);
              cmd[3] = (char)((req >> 24) & 0xff);
            }
            if (write(fd, cmd, 4) != 4) return 1;
        } else if (!memcmp(cmd, "sh", 2)) {
            fprintf(stderr, "CMD shift\n");
            if (read(fd, cmd, 4) != 4) return 1;
            if (read(fd, &len, 4) != 4) return 1;
            nr_bytes = (len + 7) / 8;
            {
                static int dbg = 0;
                if (dbg < 12) {
                    int k, nb = (len + 7) / 8;
                    fprintf(stderr, "  len=%d tms=", len);
                    for (k = nb - 1; k >= 0; k--) fprintf(stderr, "%02X", buffer[k]);
                    fprintf(stderr, "\n");
                    dbg++;
                }
            }
            if (len <= 0 || len > XVC_MAX_BITS || nr_bytes * 2 + nr_bytes > (int)sizeof(buffer)) return 1;
            if (read(fd, buffer, nr_bytes * 2) != nr_bytes * 2) return 1;
            memset(buffer + nr_bytes * 2, 0, nr_bytes);
            if (do_shift(len, buffer, buffer + nr_bytes, buffer + nr_bytes * 2) < 0) return 1;
            if (write(fd, buffer + nr_bytes * 2, nr_bytes) != nr_bytes) return 1;
        } else {
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
    while ((c = getopt(argc, argv, "a:d:")) != -1) {
        if (c == 'a') base = (uint32_t)strtoul(optarg, NULL, 0);
        else if (c == 'd') def_div = (uint32_t)strtoul(optarg, NULL, 0);
        else { fprintf(stderr, "usage: %s [-a addr] [-d div]\n", argv[0]); return 1; }
    }
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

    signal(SIGCHLD, SIG_IGN);
    snprintf(xvc_info, sizeof(xvc_info), "xvcServer_v1.0:%u\n", XVC_MAX_BITS);
    printf("xvcserver_gpio: JTAG@0x%08X, TCP %d, max %d bits, default DIV %u (%.3f MHz)\n",
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
        printf("client connected\n"); fflush(stdout);
        /* hw_server may open several connections at once: fork a child per connection */
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
