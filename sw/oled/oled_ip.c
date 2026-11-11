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
 *     192.168.  1.113        <- 6x24 monospaced font (15 chars x 8px = 120px)
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

#include "font6x24.h"     /* the IP uses the 6x24 monospaced font (15 chars x 8px = 120px) */
#include "font3x5.h"      /* port numbers */
#include "font5x8.h"      /* status line */

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
static unsigned char g_fb_prev[FB_SIZE];   /* previous frame, used for diff refresh */
static int g_force_full = 1;               /* force a full refresh on the first frame / after reconnect */
static unsigned g_pages_written = 0;       /* cumulative pages written */
static unsigned g_pages_failed  = 0;       /* cumulative pages failed */
static unsigned g_flush_calls   = 0;       /* cumulative flush calls */
static int g_shift_x = 0;      /* burn-in protection: whole-screen horizontal shift 0..2 */
static int g_debug  = 0;       /* -d diagnostic output */
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

/* format dotted decimal as xxx.xxx.xxx.xxx (padded with spaces to 3 digits), fixed 15 chars */
static void fmt_ip(const char *ip, char *out, size_t outlen)
{
    int a = 0, b = 0, c = 0, d = 0;
    if (sscanf(ip, "%d.%d.%d.%d", &a, &b, &c, &d) != 4) {
        snprintf(out, outlen, "  0.  0.  0.  0");
        return;
    }
    snprintf(out, outlen, "%3d.%3d.%3d.%3d", a, b, c, d);
}

/* ---------------- 6x24 font (used when a long IP does not fit) ---------------- */
static int f6w(const char *s)
{
    int n = (int)strlen(s);
    return n ? n * F6_ADV - 1 : 0;
}

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
        x += F6_ADV;
    }
}

/* ---------------- 5x8 status-line font ---------------- */
static void f5_draw(int x, int y, const char *s)
{
    for (; *s; s++) {
        int idx = f5_index(*s);
        int r, c;
        for (r = 0; r < F5_H; r++) {
            unsigned v = font5x8[idx][r];
            for (c = 0; c < F5_W; c++)
                if (v & (1u << (F5_W - 1 - c)))
                    fb_px(x + c, y + r, 1);
        }
        x += F5_W + 1;
    }
}

/* ---------------- 3x5 port-number font ---------------- */
static void f3_draw(int x, int y, const char *s)
{
    for (; *s; s++) {
        int idx = f3_index(*s);
        int r, c;
        for (r = 0; r < F3_H; r++) {
            unsigned v = font3x5[idx][r];
            for (c = 0; c < F3_W; c++)
                if (v & (1u << (F3_W - 1 - c)))
                    fb_px(x + c, y + r, 1);
        }
        x += F3_W + 1;
    }
}

static int f3w(const char *s)
{
    int n = (int)strlen(s);
    return n ? n * (F3_W + 1) - 1 : 0;
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
        0x81, 0x8F, 0xD9, 0xF1, 0xDB, 0x40, 0xA4, 0xA6, 0xAF
    };
    /* window: whole screen, columns 0..127, pages 0..7 (same as the reference implementation, set once) */
    static const unsigned char win[] = {
        0x21, 0x00, 0x7F,        /* COLUMNADDR */
        0x22, 0x00, 0x07         /* PAGEADDR   */
    };
    init[17] = (unsigned char)(contrast & 0xFF);   /* the contrast byte following 0x81 */
    if (oled_cmds(fd, init, sizeof(init)) < 0) return -1;
    if (oled_cmds(fd, win, sizeof(win)) < 0) return -1;
    usleep(100000);
    return 0;
}

/* change the contrast at runtime: 0x81 <val> */
static int oled_set_contrast(int fd, int c)
{
    unsigned char cmd[2] = { 0x81, (unsigned char)(c & 0xFF) };
    return oled_cmds(fd, cmd, sizeof(cmd));
}

/* write a single page (with retries): avoids stale content caused by sporadic NAKs under weak pull-ups */
static int oled_write_page(int fd, int page)
{
    unsigned char buf[1 + WIDTH];
    unsigned char cmds[3] = { (unsigned char)(0xB0 + page), 0x00, 0x10 };
    int attempt;

    for (attempt = 0; attempt < 3; attempt++) {
        if (oled_cmds(fd, cmds, sizeof(cmds)) < 0) continue;
        buf[0] = 0x40;                   /* D/C#=1 -> data stream */
        memcpy(buf + 1, g_fb + page * WIDTH, WIDTH);
        if (i2c_wr(fd, buf, sizeof(buf)) == 0) {
            memcpy(g_fb_prev + page * WIDTH, g_fb + page * WIDTH, WIDTH);
            g_pages_written++;
            return 0;
        }
    }
    g_pages_failed++;
    return -1;
}

/* diff refresh: rewrite only the pages whose content changed; full refresh on the first frame / after reconnect */
static int oled_flush(int fd)
{
    int page, wrote = 0;

    for (page = 0; page < PAGES; page++) {
        const unsigned char *cur  = g_fb      + page * WIDTH;
        const unsigned char *prev = g_fb_prev + page * WIDTH;
        if (!g_force_full && memcmp(cur, prev, WIDTH) == 0)
            continue;                    /* page unchanged, skip it */
        if (oled_write_page(fd, page) < 0)
            return -1;
        wrote++;
    }
    g_force_full = 0;
    g_flush_calls++;
    (void)wrote;
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
 *   y  0-23  IP (6x24 monospaced, fixed xxx.xxx.xxx.xxx format)
 *   y 26-30  port numbers 12 11 10 9 8 7 6 5 4 3 2 1   (3x5)
 *   y 33-38  status boxes                              (6x6)
 *   y 44-51  BC + status box + frequency               (5x8 / 8x8)
 */
/* Layout: port numbers / status boxes / Broadcast on top, IP at the bottom
 *   y  4-8   port numbers 12->1   (3x5)
 *   y 11-18  status boxes         (8x8)
 *   y 22-29  Broadcast line       (5x8)
 *   y 35-58  IP                   (6x24) */
/* status boxes on top, port numbers below; both rows sit flush against the top */
#define BOX_Y       0      /* status box start y (0..7, flush with the top) */
#define NUM_Y       10     /* port number start y (box bottom is 7, gap 2px) */
#define BC_Y        22     /* Broadcast line (labels end at 18, gap 3px) */
#define PITCH       10
#define CELL_X0     4
#define ROW_LEFT    5      /* left edge of the status-box row */
#define ROW_RIGHT   122    /* right edge of the status-box row */
#define IP_X        ROW_LEFT
#define IP_Y        40     /* IP start y: 24px tall, 40+24-1=63 -> flush with the bottom of the screen */
#define BOX_SZ      8      /* port status box 8x8 (more prominent than 6x6) */
#define BC_SZ       8      /* broadcast legend box: 8x8, same as the port boxes */
#define BC_ICON_X   60     /* legend box: "BROADCAST" ends at x=57, gap 3px */

static void render(const char *ip, const char *ifname, unsigned mask)
{
    char buf[16];
    int i;
    int bcast_on = bcast_session_alive();
    int chsel    = bcast_chsel();
    /* TDO source port number (1..12); 0 when the conditions are not met */
    int tdo_port = (bcast_on && (mask & 0xFFF) && (chsel >= 0)) ? (chsel + 1) : 0;
    int blink    = (int)(time(NULL) & 1);     /* 1Hz blink phase */

    fb_clear();

    /* ---- IP: 6x24 monospaced, left aligned (no padding, use the raw string) ---- */
    f6_draw(IP_X, IP_Y, ip);

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
        nl = f3w(nb);                                  /* 1 digit = 3, 2 digits = 7 */
        f3_draw(cx + (PITCH - nl) / 2, NUM_Y, nb);

        /* draw the base state as usual; for the TDO port drop the centre dot first and overlay the blinking dot later */
        {
            int bx = cx + (PITCH - BOX_SZ) / 2, by = BOX_Y;
            int base_st = (port == tdo_port && st == ST_BCAST) ? ST_IDLE : st;
            draw_status(bx, by, base_st, BOX_SZ);

            /* TDO port: the centre 2x2 dot blinks at 1Hz (black hole on a solid background, bright dot otherwise) */
            if (port == tdo_port && blink) {
                int m = BOX_SZ / 2;
                fb_rect(bx + m - 1, by + m - 1, 2, 2, (st == ST_CONN) ? 0 : 1);
            }
        }
    }

    /* ---- third line: BROADCAST + fixed legend + frequency ---- */
    f5_draw(ROW_LEFT, BC_Y, "Broadcast");

    /* fixed legend "border+centre dot" = broadcast port, always lit (right after the text) */
    draw_status(BC_ICON_X, BC_Y, ST_BCAST, BC_SZ);

    /* ---- right side: TCK frequency + connection count (coordinates do not overlap) ---- */
    {
        unsigned f10 = tck_mhz10();
        if (f10) snprintf(buf, sizeof(buf), "%u.%uMHz", f10 / 10, f10 % 10);
        else     snprintf(buf, sizeof(buf), "--MHz");
        /* right aligned: the last char ends at ROW_RIGHT (=122), i.e. the right edge of the status-box row */
        f5_draw(ROW_RIGHT - ((int)strlen(buf) * (F5_W + 1) - 1) + 1, BC_Y, buf);
    }

    /* -d diagnostics: print the internal model so it can be compared against the screen */
    if (g_debug) {
        fprintf(stderr, "[diag] ip='%s' len=%d w=%d\n", ip, (int)strlen(ip),
                (int)strlen(ip) * F6_ADV - 1);
        for (i = 0; i < NCH; i++) {
            int port = NCH - i, ch = port - 1;
            int conn = port_connected(BASE_PORT + ch);
            int bc   = bcast_on && ((mask >> ch) & 1);
            int st   = bc ? ST_BCAST : (conn ? ST_CONN : ST_IDLE);
            fprintf(stderr, "[diag] x=%3d port=%2d ch=%2d tcp=%d bcmask=%d -> %s%s\n",
                    CELL_X0 + i * PITCH, port, ch, conn, bc,
                    st == ST_BCAST ? "BCAST" : (st == ST_CONN ? "CONN " : "IDLE "),
                    port == tdo_port ? "  <== TDO" : "");
        }
        fprintf(stderr, "[diag] bcast_on=%d mask=0x%03X chsel=%d tdo_port=%d blink=%d\n",
                bcast_on, mask, chsel, tdo_port, blink);
        fprintf(stderr, "[diag] tck10=%u  shift_x=%d\n", tck_mhz10(), g_shift_x);
        fprintf(stderr, "[diag] flush=%u pages_written=%u pages_failed=%u\n",
                g_flush_calls, g_pages_written, g_pages_failed);
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
    int contrast   = 0x8F;   /* the smittytone reference implementation also uses 0x8F; saves panel life versus the chip default 0xCF */
    int shift_sec  = 60;     /* shift the whole screen horizontally by 1px every 60 seconds */
    time_t t_shift = 0;

    while ((opt = getopt(argc, argv, "b:a:i:r:c:s:odm:h")) != -1) {
        switch (opt) {
        case 'b': dev = optarg; break;
        case 'a': g_addr = (int)strtol(optarg, NULL, 0); break;
        case 'i': ifname = optarg; break;
        case 'r': period = atoi(optarg); if (period < 1) period = 1; break;
        case 'c': contrast = (int)strtol(optarg, NULL, 0); break;
        case 's': shift_sec = atoi(optarg); if (shift_sec < 0) shift_sec = 0; break;
        case 'o': once = 1; break;
        case 'd': g_debug = 1; break;
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
            g_force_full = 1;            /* a full refresh is required after re-initialisation */
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
