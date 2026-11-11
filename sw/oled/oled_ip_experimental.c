/*
 * oled_ip.c - display the local IP address and the connection status of the
 *             12 JTAG ports on the front-panel 0.96" OLED (SSD1306/SSD1315, 128x64, I2C)
 *
 * Hardware:
 *   J20 pin 35 = V15 = I2C1_SCL   (4.7k pull-up to 3.3V)
 *   J20 pin 33 = U20 = I2C1_SDA
 *   PL: PS7 I2C1 -> EMIO -> i2c_emio -> V15/U20
 *   Linux: /dev/i2c-1, OLED address 0x3C
 *
 * Layout (128x64):
 *
 *     192.168.1.113          <- 9x24 seven-segment font (proportional: digit 10px, dot 5px)
 *
 *     1[■] 2[■] 3[□] 4[■] 5[■] 6[■]     <- 5x8 labels + 6x6 status boxes
 *     7[■] 8[□] 9[■] A[■] B[■] C[■]
 *
 *     BC[■]  12/12  10MHz     <- broadcast session / connection count / TCK frequency
 *
 * Status box:
 *    □ hollow    = no client
 *    ■ solid     = an XVC client is connected
 *    ▣ with dot  = occupied by broadcast (inside the mask and the broadcast session is active)
 *
 * Usage: oled_ip [-b /dev/i2c-1] [-a 0x3c] [-i eth0] [-r 5] [-o]
 *   -r N  refresh period (seconds, default 1)
 *   -o    draw once and exit
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include <stdint.h>

#include "font6x24.h"     /* the IP uses the 6x24 font (8px advance, 2px gap) */
#include "font3x6.h"      /* every text other than the IP uses 3x6 uniformly */

#define WIDTH   128
#define PAGES   8
#define FB_SIZE (WIDTH * PAGES)

#define NCH     12
#define BASE_PORT 2543
#define BCAST_PORT 2542
#define BCAST_REG_ADDR 0x43CD0000u     /* broadcast control register block */
#define ENG_BASE       0x43C00000u     /* engine base address */

static int  g_fd = -1;
static int  g_addr = 0x3C;
static unsigned char g_fb[FB_SIZE];
static int g_shift_x = 0;      /* burn-in protection: whole-screen horizontal shift 0..2 */
static volatile unsigned char *g_reg = NULL;   /* broadcast register block mapping */

/* ---------------- frame buffer ---------------- */
static void fb_clear(void) { memset(g_fb, 0, sizeof(g_fb)); }

static inline void fb_px(int x, int y, int on)
{
    x += g_shift_x;                    /* burn-in protection shift */
    if (x < 0 || x >= WIDTH || y < 0 || y >= 64) return;
    if (on) g_fb[(y >> 3) * WIDTH + x] |=  (unsigned char)(1u << (y & 7));
    else    g_fb[(y >> 3) * WIDTH + x] &= (unsigned char)~(1u << (y & 7));
}

static void fb_rect(int x, int y, int w, int h, int on)
{
    int i, j;
    for (j = 0; j < h; j++)
        for (i = 0; i < w; i++)
            fb_px(x + i, y + j, on);
}

/* ---------------- 6x24 large font (15 chars x 8px advance = 120px) ---------------- */
static void f6_draw(int x, int y, const char *s)
{
    for (; *s; s++) {
        int idx = f6_index(*s);
        int r, c;
        for (r = 0; r < F6_H; r++) {
            unsigned v = font6x24[idx][r];
            for (c = 0; c < F6_W; c++)
                if (v & (1u << (F6_W - 1 - c)))
                    fb_px(x + c, y + r, 1);
        }
        x += F6_ADV;                     /* 8px advance -> 2px gap */
    }
}

/* format dotted decimal as xxx.xxx.xxx.xxx (padded with spaces to 3 digits) */
static void fmt_ip(const char *ip, char *out, size_t outlen)
{
    int a = 0, b = 0, c = 0, d = 0;
    if (sscanf(ip, "%d.%d.%d.%d", &a, &b, &c, &d) != 4) {
        snprintf(out, outlen, "  0.  0.  0.  0");
        return;
    }
    snprintf(out, outlen, "%3d.%3d.%3d.%3d", a, b, c, d);
}

/* ---------------- 3x6 small font (used uniformly) ---------------- */
static void f3x6_draw(int x, int y, const char *s)
{
    for (; *s; s++) {
        int idx = f3x6_index(*s);
        int r, c;
        for (r = 0; r < F3X6_H; r++) {
            unsigned v = font3x6[idx][r];
            for (c = 0; c < F3X6_W; c++)
                if (v & (1u << (F3X6_W - 1 - c)))
                    fb_px(x + c, y + r, 1);
        }
        x += F3X6_ADV;
    }
}

/* pixel width of a string */
static int f3x6_width(const char *s)
{
    int n = (int)strlen(s);
    return n ? n * F3X6_ADV - 1 : 0;
}

/* ---------------- status boxes 6x6 ---------------- */
#define ST_IDLE   0   /* hollow */
#define ST_CONN   1   /* solid */
#define ST_BCAST  2   /* border + centre dot */

static void draw_status(int x, int y, int st, int sz)
{
    int m = sz / 2;
    switch (st) {
    case ST_CONN:                       /* solid */
        fb_rect(x, y, sz, sz, 1);
        break;
    case ST_BCAST + 1:                  /* solid + black centre dot (TDO selected) */
        fb_rect(x, y, sz, sz, 1);
        fb_rect(x + m - 1, y + m - 1, 2, 2, 0);
        break;
    case ST_BCAST:                      /* border + centre dot (occupied by broadcast) */
        fb_rect(x, y, sz, 1, 1);
        fb_rect(x, y + sz - 1, sz, 1, 1);
        fb_rect(x, y, 1, sz, 1);
        fb_rect(x + sz - 1, y, 1, sz, 1);
        fb_rect(x + m - 1, y + m - 1, 2, 2, 1);
        break;
    default:                            /* hollow */
        fb_rect(x, y, sz, 1, 1);
        fb_rect(x, y + sz - 1, sz, 1, 1);
        fb_rect(x, y, 1, sz, 1);
        fb_rect(x + sz - 1, y, 1, sz, 1);
        break;
    }
}

/* ---------------- I2C ---------------- */
static int i2c_open_dev(const char *dev, int addr)
{
    int fd = open(dev, O_RDWR);
    if (fd < 0) return -1;
    if (ioctl(fd, I2C_SLAVE, addr) < 0) { close(fd); return -1; }
    return fd;
}

static int i2c_wr(int fd, const unsigned char *buf, int len)
{
    return write(fd, buf, len) == len ? 0 : -1;
}

static int oled_cmds(int fd, const unsigned char *cmds, int n)
{
    unsigned char buf[64];
    if (n > (int)sizeof(buf) - 1) n = sizeof(buf) - 1;
    buf[0] = 0x00;                       /* Co=0, D/C#=0 -> command stream */
    memcpy(buf + 1, cmds, n);
    return i2c_wr(fd, buf, n + 1);
}

static int oled_init(int fd, int contrast)
{
    unsigned char init[] = {
        0xAE, 0xD5, 0x80, 0xA8, 0x3F, 0xD3, 0x00, 0x40,
        0x8D, 0x14, 0x20, 0x00, 0xA1, 0xC8, 0xDA, 0x12,
        0x81, 0xCF, 0xD9, 0xF1, 0xDB, 0x40, 0xA4, 0xA6, 0xAF
    };
    init[17] = (unsigned char)(contrast & 0xFF);   /* the contrast byte following 0x81 */
    if (oled_cmds(fd, init, sizeof(init)) < 0) return -1;
    usleep(100000);
    return 0;
}

/* change the contrast at runtime: 0x81 <val> */
static int oled_set_contrast(int fd, int c)
{
    unsigned char cmd[2] = { 0x81, (unsigned char)(c & 0xFF) };
    return oled_cmds(fd, cmd, sizeof(cmd));
}

/* full-screen refresh: 8 pages x 128 bytes */
static int oled_flush(int fd)
{
    unsigned char buf[1 + WIDTH];
    int page;
    for (page = 0; page < PAGES; page++) {
        unsigned char cmds[3] = { (unsigned char)(0xB0 + page), 0x00, 0x10 };
        if (oled_cmds(fd, cmds, sizeof(cmds)) < 0) return -1;
        buf[0] = 0x40;                   /* D/C#=1 -> data stream */
        memcpy(buf + 1, g_fb + page * WIDTH, WIDTH);
        if (i2c_wr(fd, buf, sizeof(buf)) < 0) return -1;
    }
    return 0;
}

/* ---------------- data collection ---------------- */

/* read the IP */
static int get_ip(const char *ifname, char *out, size_t outlen)
{
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    struct ifreq ifr;
    struct sockaddr_in *sin;
    if (s < 0) return -1;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(s, SIOCGIFADDR, &ifr) < 0) { close(s); return -1; }
    sin = (struct sockaddr_in *)&ifr.ifr_addr;
    snprintf(out, outlen, "%s", inet_ntoa(sin->sin_addr));
    close(s);
    return 0;
}

/* check in /proc/net/tcp whether a port has an ESTABLISHED connection */
static int port_connected(int port)
{
    FILE *f = fopen("/proc/net/tcp", "r");
    char line[512];
    int found = 0;
    if (!f) return 0;
    if (!fgets(line, sizeof(line), f)) { fclose(f); return 0; }
    while (fgets(line, sizeof(line), f)) {
        unsigned lport;
        char st[8];
        if (sscanf(line, " %*d: %*[0-9A-Fa-f]:%X %*[0-9A-Fa-f]:%*X %7s",
                   &lport, st) == 2) {
            if ((int)lport == port && !strcmp(st, "01")) { found = 1; break; }
        }
    }
    fclose(f);
    return found;
}

/* is the broadcast session alive (pid file exists and the process is alive) */
static int bcast_session_alive(void)
{
    FILE *f = fopen("/tmp/xvcsrv-2542.pid", "r");
    int pid = -1;
    if (!f) return 0;
    if (fscanf(f, "%d", &pid) != 1) pid = -1;
    fclose(f);
    if (pid <= 1) return 0;
    return kill(pid, 0) == 0;
}

/* broadcast mask */
static unsigned bcast_mask(void)
{
    if (!g_reg) return 0;
    return *(volatile uint32_t *)(g_reg + 0x04) & 0xFFF;
}

/* broadcast CHSEL (TDO source); returns -1 when there is no register block */
static int bcast_chsel(void)
{
    if (!g_reg) return -1;
    return (int)(*(volatile uint32_t *)(g_reg + 0x08) & 0xF);
}

/* TCK frequency (MHz x 10, to avoid floating point) */
static unsigned tck_mhz10(void)
{
    static volatile uint32_t *eng = NULL;
    static int inited = 0;
    unsigned div;
    if (!inited) {
        int fd = open("/dev/mem", O_RDWR | O_SYNC);
        inited = 1;
        if (fd >= 0) {
            void *m = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, ENG_BASE);
            close(fd);
            if (m != MAP_FAILED) eng = (volatile uint32_t *)m;
        }
    }
    if (!eng) return 0;
    div = eng[0x18 / 4] & 0xFFFF;        /* DIV_RB */
    if (!div) return 0;
    return (unsigned)(1000u / (2 * div));  /* 100MHz/(2*div) in 0.1MHz units */
}

/* ---------------- rendering ---------------- */
/* New layout:
 *   y  0-23  IP (9x24)
 *   y 26-30  port numbers 12 11 10 9 8 7 6 5 4 3 2 1   (3x5)
 *   y 33-38  status boxes                              (6x6)
 *   y 44-51  BC + status box + frequency               (5x8 / 8x8)
 */
#define NUM_Y       25
#define BOX_Y       33
#define BC_Y        45
#define PITCH       10
#define CELL_X0     4
#define BOX_SZ      8      /* port status box 8x8 (more prominent than 6x6) */
#define BC_SZ       10     /* BC status box 10x10 */

static void render(const char *ip, const char *ifname, unsigned mask)
{
    char buf[16];
    int i;
    int bcast_on = bcast_session_alive();
    int chsel    = bcast_chsel();

    fb_clear();

    /* ---- IP (8x24 monospaced, fixed xxx.xxx.xxx.xxx, 15 chars total = 120px) ---- */
    {
        char ipf[20];
        fmt_ip(ip, ipf, sizeof(ipf));
        f6_draw((WIDTH - 15 * F6_ADV) / 2, 0, ipf);
    }

    /* ---- port numbers 12,11,...,1 on one row + status boxes on another (aligned) ---- */
    for (i = 0; i < NCH; i++) {
        int port = NCH - i;                 /* 12 .. 1 (reverse order) */
        int ch   = port - 1;                /* engine index 11..0 */
        int cx   = CELL_X0 + i * PITCH;
        char nb[3];
        int  nl;
        int  conn = port_connected(BASE_PORT + ch);
        int  bc   = bcast_on && ((mask >> ch) & 1);
        int  st   = bc ? ST_BCAST : (conn ? ST_CONN : ST_IDLE);

        snprintf(nb, sizeof(nb), "%d", port);
        nl = f3x6_width(nb);                            /* 1 digit = 4, 2 digits = 9 */
        f3x6_draw(cx + (PITCH - nl) / 2, NUM_Y, nb);

        draw_status(cx + (PITCH - BOX_SZ) / 2, BOX_Y, st, BOX_SZ);
    }

    /* ---- third line: BC status + frequency ---- */
    f3x6_draw(2, BC_Y, "BC");

    /* BC box 8x8: hollow = unused, solid = connected, solid + black centre dot = TDO selected */
    {
        int bx = 16, by = BC_Y;
        int st = !bcast_on ? ST_IDLE : (chsel >= 0 ? 3 : ST_CONN);
        if (st == ST_IDLE) {
            fb_rect(bx, by,     8, 1, 1);
            fb_rect(bx, by + 7, 8, 1, 1);
            fb_rect(bx,     by, 1, 8, 1);
            fb_rect(bx + 7, by, 1, 8, 1);
        } else {
            fb_rect(bx, by, 8, 8, 1);
            if (st == 3) fb_rect(bx + 3, by + 3, 2, 2, 0);   /* black dot = TDO selected */
        }
    }

    (void)ifname;
}

/* ---------------- main program ---------------- */
static volatile sig_atomic_t g_stop = 0;
static void on_sig(int sig) { (void)sig; g_stop = 1; }

int main(int argc, char **argv)
{
    const char *dev = "/dev/i2c-1";
    const char *ifname = "eth0";
    int once = 0, period = 1, opt;
    char ip[32] = "0.0.0.0", last[32] = "";
    int mfd;
    int contrast   = 0x8F;   /* lower than the 0xCF default, significantly slows burn-in */
    int shift_sec  = 60;     /* shift the whole screen horizontally by 1px every 60 seconds */
    time_t t_shift = 0;

    while ((opt = getopt(argc, argv, "b:a:i:r:c:s:om:h")) != -1) {
        switch (opt) {
        case 'b': dev = optarg; break;
        case 'a': g_addr = (int)strtol(optarg, NULL, 0); break;
        case 'i': ifname = optarg; break;
        case 'r': period = atoi(optarg); if (period < 1) period = 1; break;
        case 'c': contrast = (int)strtol(optarg, NULL, 0); break;
        case 's': shift_sec = atoi(optarg); if (shift_sec < 0) shift_sec = 0; break;
        case 'o': once = 1; break;
        default:
            fprintf(stderr, "usage: %s [-b i2cdev] [-a addr] [-i ifname] [-r sec] "
                            "[-c contrast] [-s shift_sec] [-o]\n", argv[0]);
            return 1;
        }
    }

    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    /* map the broadcast register block (ignore if absent, treat the mask as 0) */
    mfd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mfd >= 0) {
        void *m = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, mfd, BCAST_REG_ADDR);
        close(mfd);
        if (m != MAP_FAILED) g_reg = (volatile unsigned char *)m;
    }

    for (;;) {
        unsigned mask = bcast_mask();

        if (g_fd < 0) {
            g_fd = i2c_open_dev(dev, g_addr);
            if (g_fd < 0) {
                if (once) { perror(dev); return 1; }
                sleep(2);
                continue;
            }
            if (oled_init(g_fd, contrast) < 0) {
                fprintf(stderr, "oled init failed on %s\n", dev);
                close(g_fd); g_fd = -1;
                if (once) return 1;
                sleep(2);
                continue;
            }
        }

        if (get_ip(ifname, ip, sizeof(ip)) < 0)
            strcpy(ip, "0.0.0.0");

        /* IP changed or first time -> full refresh; otherwise still refresh once per second (the state changes) */
        /* burn-in protection: periodically shift the whole screen horizontally by 0/1/2 px */
        if (shift_sec > 0) {
            time_t now = time(NULL);
            if (now - t_shift >= shift_sec) {
                t_shift = now;
                g_shift_x = (g_shift_x + 1) % 3;
            }
        }

        if (once || strcmp(ip, last) != 0 || period) {
            render(ip, ifname, mask);
            if (oled_flush(g_fd) < 0) {
                fprintf(stderr, "i2c write failed\n");
                close(g_fd); g_fd = -1;
                if (once) return 1;
                sleep(2);
                continue;
            }
            if (strcmp(ip, last) != 0) {
                fprintf(stderr, "shown: %s\n", ip);
                strcpy(last, ip);
            }
        }

        if (once || g_stop) break;
        sleep(period);
    }

    if (g_fd >= 0) close(g_fd);
    return 0;
}
