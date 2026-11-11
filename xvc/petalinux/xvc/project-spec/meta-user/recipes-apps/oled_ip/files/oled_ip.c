/*
 * oled_ip.c - show this host's IP on a 0.96" SSD1315 (SSD1306 compatible, 128x64, I2C)
 *
 * Hardware: AX7Z020B J20 expansion header
 *   J20 pin 35 = V15 = IIC_SCL
 *   J20 pin 33 = U20 = IIC_SDA
 *   PL side: PS7 I2C1 -> EMIO -> i2c_emio (IOBUF, open drain)
 *   Linux side: /dev/i2c-1, OLED address 0x3C
 *
 * Usage: oled_ip [-b /dev/i2c-1] [-a 0x3c] [-i eth0] [-o]
 *   -o  display once and exit (default: refresh in a loop)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include <sys/mman.h>
#include <stdint.h>

#define WIDTH   128
#define PAGES   8
#define FB_SIZE (WIDTH * PAGES)

static int  g_fd = -1;
static int  g_addr = 0x3C;
static unsigned char g_fb[FB_SIZE];

/* ---- PL I2C (/dev/mem @ 0x43C10000) ---- */
static volatile uint32_t *g_reg = NULL;   /* non-NULL means use PL I2C */
#define REG_CTRL   0
#define REG_STATUS 1
#define I2C_DELAY_US 5

static void pl_delay(void)
{
    struct timespec ts = {0, I2C_DELAY_US * 1000};
    nanosleep(&ts, NULL);
}
static void pl_scl(int hi) { g_reg[REG_CTRL] = (g_reg[REG_CTRL] & ~1u) | (hi ? 1u : 0u); }
static void pl_sda(int hi) { g_reg[REG_CTRL] = (g_reg[REG_CTRL] & ~2u) | (hi ? 2u : 0u); }
static int  pl_sda_read(void) { return (int)(g_reg[REG_STATUS] & 1u); }

static void i2c_start(void)
{
    if (g_reg) { pl_sda(1); pl_scl(1); pl_delay(); pl_sda(0); pl_delay(); pl_scl(0); pl_delay(); }
}
static void i2c_stop(void)
{
    if (g_reg) { pl_sda(0); pl_delay(); pl_scl(1); pl_delay(); pl_sda(1); pl_delay(); }
}
static int i2c_putc(unsigned char b)
{
    int i, ack;
    if (!g_reg) return 0;
    for (i = 0; i < 8; i++) {
        pl_sda((b & 0x80) ? 1 : 0); b <<= 1; pl_delay();
        pl_scl(1); pl_delay(); pl_scl(0); pl_delay();
    }
    pl_sda(1); pl_delay();        /* release SDA so the slave can ACK */
    pl_scl(1); pl_delay();
    ack = !pl_sda_read();
    pl_scl(0); pl_delay();
    return ack;
}

/* ---------- I2C ---------- */
static int i2c_open(const char *dev, int addr)
{
    int fd = open(dev, O_RDWR);
    if (fd < 0) return -1;
    if (ioctl(fd, I2C_SLAVE, addr) < 0) { close(fd); return -1; }
    return fd;
}

static int i2c_write(int fd, const unsigned char *buf, int len)
{
    int i;
    if (g_reg) {
        i2c_start();
        if (!i2c_putc((unsigned char)(g_addr << 1))) { i2c_stop(); return -1; }
        for (i = 0; i < len; i++)
            if (!i2c_putc(buf[i])) { i2c_stop(); return -1; }
        i2c_stop();
        return 0;
    }
    return write(fd, buf, len) == len ? 0 : -1;
}

/* SSD1306/SSD1315 commands: 0x00 prefix + several commands sent in one transfer */
static int oled_cmds(int fd, const unsigned char *cmds, int n)
{
    unsigned char buf[64];
    if (n > (int)sizeof(buf) - 1) n = sizeof(buf) - 1;
    buf[0] = 0x00;
    memcpy(buf + 1, cmds, n);
    return i2c_write(fd, buf, n + 1);
}

static int oled_init(int fd)
{
    static const unsigned char init[] = {
        0xAE,             /* display off */
        0xD5, 0x80,       /* clock div */
        0xA8, 0x3F,       /* multiplex = 63 */
        0xD3, 0x00,       /* display offset 0 */
        0x40,             /* start line 0 */
        0x8D, 0x14,       /* charge pump on */
        0x20, 0x00,       /* memory mode: horizontal */
        0xA1,             /* segment remap */
        0xC8,             /* COM scan dec */
        0xDA, 0x12,       /* COM pins */
        0x81, 0xCF,       /* contrast */
        0xD9, 0xF1,       /* pre-charge */
        0xDB, 0x40,       /* VCOMH */
        0xA4,             /* display from RAM */
        0xA6,             /* normal (not inverted) */
        0xAF              /* display on */
    };
    if (oled_cmds(fd, init, sizeof(init)) < 0) return -1;
    usleep(100000);
    return 0;
}

/* Push the whole framebuffer to the OLED */
static int oled_flush(int fd)
{
    unsigned char buf[1 + WIDTH];
    int page;
    for (page = 0; page < PAGES; page++) {
        unsigned char cmds[3] = { 0xB0 + page, 0x00, 0x10 };  /* page, col 0 */
        if (oled_cmds(fd, cmds, sizeof(cmds)) < 0) return -1;
        buf[0] = 0x40;                                        /* data */
        memcpy(buf + 1, g_fb + page * WIDTH, WIDTH);
        if (i2c_write(fd, buf, sizeof(buf)) < 0) return -1;
    }
    return 0;
}

/* ---------- 5x7 font ---------- */
static const unsigned char font5x7[][5] = {
    {0x00,0x00,0x00,0x00,0x00}, /* ' ' */
    {0x00,0x00,0x5F,0x00,0x00}, /* ! */
    {0x00,0x07,0x00,0x07,0x00}, /* " */
    {0x14,0x7F,0x14,0x7F,0x14}, /* # */
    {0x24,0x2A,0x7F,0x2A,0x12}, /* $ */
    {0x23,0x13,0x08,0x64,0x62}, /* % */
    {0x36,0x49,0x55,0x22,0x50}, /* & */
    {0x00,0x05,0x03,0x00,0x00}, /* ' */
    {0x00,0x1C,0x22,0x41,0x00}, /* ( */
    {0x00,0x41,0x22,0x1C,0x00}, /* ) */
    {0x14,0x08,0x3E,0x08,0x14}, /* * */
    {0x08,0x08,0x3E,0x08,0x08}, /* + */
    {0x00,0x50,0x30,0x00,0x00}, /* , */
    {0x08,0x08,0x08,0x08,0x08}, /* - */
    {0x00,0x60,0x60,0x00,0x00}, /* . */
    {0x20,0x10,0x08,0x04,0x02}, /* / */
    {0x3E,0x51,0x49,0x45,0x3E}, /* 0 */
    {0x00,0x42,0x7F,0x40,0x00}, /* 1 */
    {0x42,0x61,0x51,0x49,0x46}, /* 2 */
    {0x21,0x41,0x45,0x4B,0x31}, /* 3 */
    {0x18,0x14,0x12,0x7F,0x10}, /* 4 */
    {0x27,0x45,0x45,0x45,0x39}, /* 5 */
    {0x3C,0x4A,0x49,0x49,0x30}, /* 6 */
    {0x01,0x71,0x09,0x05,0x03}, /* 7 */
    {0x36,0x49,0x49,0x49,0x36}, /* 8 */
    {0x06,0x49,0x49,0x29,0x1E}, /* 9 */
    {0x00,0x36,0x36,0x00,0x00}, /* : */
    {0x00,0x56,0x36,0x00,0x00}, /* ; */
    {0x08,0x14,0x22,0x41,0x00}, /* < */
    {0x14,0x14,0x14,0x14,0x14}, /* = */
    {0x00,0x41,0x22,0x14,0x08}, /* > */
    {0x02,0x01,0x51,0x09,0x06}, /* ? */
    {0x32,0x49,0x79,0x41,0x3E}, /* @ */
    {0x7E,0x11,0x11,0x11,0x7E}, /* A */
    {0x7F,0x49,0x49,0x49,0x36}, /* B */
    {0x3E,0x41,0x41,0x41,0x22}, /* C */
    {0x7F,0x41,0x41,0x22,0x1C}, /* D */
    {0x7F,0x49,0x49,0x49,0x41}, /* E */
    {0x7F,0x09,0x09,0x09,0x01}, /* F */
    {0x3E,0x41,0x49,0x49,0x7A}, /* G */
    {0x7F,0x08,0x08,0x08,0x7F}, /* H */
    {0x00,0x41,0x7F,0x41,0x00}, /* I */
    {0x20,0x40,0x41,0x3F,0x01}, /* J */
    {0x7F,0x08,0x14,0x22,0x41}, /* K */
    {0x7F,0x40,0x40,0x40,0x40}, /* L */
    {0x7F,0x02,0x0C,0x02,0x7F}, /* M */
    {0x7F,0x04,0x08,0x10,0x7F}, /* N */
    {0x3E,0x41,0x41,0x41,0x3E}, /* O */
    {0x7F,0x09,0x09,0x09,0x06}, /* P */
    {0x3E,0x41,0x51,0x21,0x5E}, /* Q */
    {0x7F,0x09,0x19,0x29,0x46}, /* R */
    {0x46,0x49,0x49,0x49,0x31}, /* S */
    {0x01,0x01,0x7F,0x01,0x01}, /* T */
    {0x3F,0x40,0x40,0x40,0x3F}, /* U */
    {0x1F,0x20,0x40,0x20,0x1F}, /* V */
    {0x7F,0x20,0x18,0x20,0x7F}, /* W */
    {0x63,0x14,0x08,0x14,0x63}, /* X */
    {0x03,0x04,0x78,0x04,0x03}, /* Y */
    {0x61,0x51,0x49,0x45,0x43}, /* Z */
    {0x00,0x00,0x7F,0x41,0x41}, /* [ */
    {0x02,0x04,0x08,0x10,0x20}, /* \ */
    {0x41,0x41,0x7F,0x00,0x00}, /* ] */
    {0x04,0x02,0x01,0x02,0x04}, /* ^ */
    {0x40,0x40,0x40,0x40,0x40}, /* _ */
    {0x00,0x01,0x02,0x04,0x00}, /* ` */
    {0x20,0x54,0x54,0x54,0x78}, /* a */
    {0x7F,0x48,0x44,0x44,0x38}, /* b */
    {0x38,0x44,0x44,0x44,0x20}, /* c */
    {0x38,0x44,0x44,0x48,0x7F}, /* d */
    {0x38,0x54,0x54,0x54,0x18}, /* e */
    {0x08,0x7E,0x09,0x01,0x02}, /* f */
    {0x0C,0x52,0x52,0x52,0x3E}, /* g */
    {0x7F,0x08,0x04,0x04,0x78}, /* h */
    {0x00,0x44,0x7D,0x40,0x00}, /* i */
    {0x20,0x40,0x44,0x3D,0x00}, /* j */
    {0x7F,0x10,0x28,0x44,0x00}, /* k */
    {0x00,0x41,0x7F,0x40,0x00}, /* l */
    {0x7C,0x04,0x18,0x04,0x78}, /* m */
    {0x7C,0x08,0x04,0x04,0x78}, /* n */
    {0x38,0x44,0x44,0x44,0x38}, /* o */
    {0x7C,0x14,0x14,0x14,0x08}, /* p */
    {0x08,0x14,0x14,0x18,0x7C}, /* q */
    {0x7C,0x08,0x04,0x04,0x08}, /* r */
    {0x48,0x54,0x54,0x54,0x20}, /* s */
    {0x04,0x3F,0x44,0x40,0x20}, /* t */
    {0x3C,0x40,0x40,0x20,0x7C}, /* u */
    {0x1C,0x20,0x40,0x20,0x1C}, /* v */
    {0x3C,0x40,0x30,0x40,0x3C}, /* w */
    {0x44,0x28,0x10,0x28,0x44}, /* x */
    {0x0C,0x50,0x50,0x50,0x3C}, /* y */
    {0x44,0x64,0x54,0x4C,0x44}, /* z */
    {0x00,0x08,0x36,0x41,0x00}, /* { */
    {0x00,0x00,0x7F,0x00,0x00}, /* | */
    {0x00,0x41,0x36,0x08,0x00}, /* } */
    {0x08,0x08,0x2A,0x1C,0x08}, /* ~ */
};

static void fb_clear(void) { memset(g_fb, 0, sizeof(g_fb)); }

static void fb_pixel(int x, int y, int on)
{
    if (x < 0 || x >= WIDTH || y < 0 || y >= PAGES * 8) return;
    if (on) g_fb[(y / 8) * WIDTH + x] |=  (1 << (y % 8));
    else    g_fb[(y / 8) * WIDTH + x] &= ~(1 << (y % 8));
}

/* Draw one character at (x,y), scale is the magnification, returns the advance width */
static int fb_char(int x, int y, char c, int scale)
{
    const unsigned char *g;
    int i, j, dx, dy;
    if (c < 0x20 || c > 0x7E) c = '?';
    g = font5x7[(unsigned char)c - 0x20];
    for (i = 0; i < 5; i++) {
        unsigned char col = g[i];
        for (j = 0; j < 7; j++) {
            if (col & (1 << j)) {
                for (dy = 0; dy < scale; dy++)
                    for (dx = 0; dx < scale; dx++)
                        fb_pixel(x + i * scale + dx, y + j * scale + dy, 1);
            }
        }
    }
    return 6 * scale;
}

static int fb_text(int x, int y, const char *s, int scale)
{
    while (*s) { x += fb_char(x, y, *s++, scale); }
    return x;
}

/* ---------- get IP ---------- */
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

static void render(const char *ip, const char *ifname)
{
    char line[32];
    char uname[32] = "XVC";
    fb_clear();
    fb_text(2, 0, "IP ADDR", 2);
    if (strlen(ip) <= 10) {
        fb_text(2, 20, ip, 2);
    } else {
        fb_text(2, 18, ip, 1);
        fb_text(2, 28, ip, 1);   /* drawn twice to make it deeper (1x is thin) */
    }
    snprintf(line, sizeof(line), "%s :2543", ifname);
    fb_text(2, 44, line, 1);
    fb_text(2, 54, uname, 1);
}

int main(int argc, char **argv)
{
    const char *dev = "/dev/i2c-1";
    unsigned long pl_base = 0;
    const char *ifname = "eth0";
    int once = 0, opt;
    char ip[32] = "NO IP";

    while ((opt = getopt(argc, argv, "b:a:i:om:h")) != -1) {
        switch (opt) {
        case 'b': dev = optarg; break;
        case 'a': g_addr = (int)strtol(optarg, NULL, 0); break;
        case 'i': ifname = optarg; break;
        case 'o': once = 1; break;
        case 'm': pl_base = strtoul(optarg, NULL, 0); break;
        default:
            fprintf(stderr, "usage: %s [-b /dev/i2c-1] [-a 0x3c] [-i eth0] [-o]\n", argv[0]);
            return 1;
        }
    }

    if (pl_base) {
        int mfd = open("/dev/mem", O_RDWR | O_SYNC);
        void *map;
        if (mfd < 0) { perror("/dev/mem"); return 1; }
        map = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, mfd, pl_base);
        if (map == MAP_FAILED) { perror("mmap"); return 1; }
        g_reg = (volatile uint32_t *)map;
        g_reg[REG_CTRL] = 3;            /* release both lines */
        fprintf(stderr, "using PL I2C at 0x%lx\n", pl_base);
    }

    for (;;) {
        char cur[32] = "NO IP";
        if (g_reg) {
            /* PL mode: initialize once */
            if (g_fd != -2) {
                g_fd = -2;
                if (oled_init(-1) < 0) { fprintf(stderr, "oled init (PL) failed\n"); }
            }
        } else if (g_fd < 0) {
            g_fd = i2c_open(dev, g_addr);
            if (g_fd < 0) {
                if (once) { perror(dev); return 1; }
                sleep(2);
                continue;
            }
            if (oled_init(g_fd) < 0) {
                fprintf(stderr, "oled init failed on %s\n", dev);
                close(g_fd); g_fd = -1;
                if (once) return 1;
                sleep(2);
                continue;
            }
        }
        if (get_ip(ifname, cur, sizeof(cur)) < 0)
            strcpy(cur, "NO IP");
        if (strcmp(cur, ip) != 0 || once) {
            strcpy(ip, cur);
            render(ip, ifname);
            if (oled_flush(g_reg ? -1 : g_fd) < 0) {
                fprintf(stderr, "i2c write failed\n");
                close(g_fd); g_fd = -1;
            } else {
                fprintf(stderr, "shown: %s\n", ip);
            }
        }
        if (once) break;
        sleep(5);
    }
    if (g_fd >= 0) close(g_fd);
    return 0;
}
