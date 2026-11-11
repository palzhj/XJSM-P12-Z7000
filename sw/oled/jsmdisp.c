/*
 * jsmdisp - SSD1315 0.96" 128x64 OLED status display for XJSM-P12-Z7000
 *
 * Renders the top line of the front-panel layout from XJSM-P12-Z7000-Design-Proposal.md
 * (§4.4.4): a fixed-width IP address in an 8x16 font plus a 1 Hz heartbeat dot.
 * Talks to the panel through /dev/i2c-N (i2c-dev), address 0x3C, exactly as the
 * design intends - no DRM/fbtft, no kernel driver.
 *
 * Build:  make            (or: make CC=aarch64-linux-gnu-gcc)
 * Run:    ./jsmdisp -b /dev/i2c-1
 *
 * Wiring (SSD1315, I2C mode):
 *   VDD  = 3.3 V     (2.8 V .. 3.3 V typ; VBAT must be >= VDD)
 *   VBAT = 3.3 V     (charge-pump input, 3.0 V .. 4.5 V on the IC)
 *   GND  = GND
 *   SCL  -> carrier SCL (J20 pin 35 = V15 on AX7Z020B)
 *   SDA  -> carrier SDA (J20 pin 33 = U20 on AX7Z020B)
 *   4.7k pull-ups from SCL and SDA to 3.3 V are REQUIRED (external).
 *
 * SPI/DC/CS are not used in I2C mode: BS0=0, BS1=1, CS#=0, D/C#=0 (addr 0x3C).
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include <linux/i2c-dev.h>

#include "font8x16.h"

#define OLED_W 128
#define OLED_H 64
#define OLED_PAGES (OLED_H / 8)

#define FB_SIZE (OLED_W * OLED_PAGES)

static int  g_fd = -1;
static int  g_addr = 0x3C;
static int  g_verbose = 0;

static uint8_t g_fb[OLED_PAGES][OLED_W];

/* ------------------------------------------------------------------ */
/* I2C plumbing                                                        */
/* ------------------------------------------------------------------ */

static int i2c_write_raw(const uint8_t *buf, size_t len)
{
    while (len) {
        size_t n = len > 32 ? 32 : len;
        ssize_t w = write(g_fd, buf, n);
        if (w != (ssize_t)n) {
            fprintf(stderr, "i2c write failed (%zd/%zu): %s\n",
                    w, n, strerror(errno));
            return -1;
        }
        buf += n;
        len -= n;
    }
    return 0;
}

/* control byte 0x00 = command stream, 0x40 = data stream */
static int oled_stream(uint8_t control, const uint8_t *data, size_t len)
{
    uint8_t chunk[33];

    while (len) {
        size_t n = len > 32 ? 32 : len;
        chunk[0] = control;
        memcpy(chunk + 1, data, n);
        if (i2c_write_raw(chunk, n + 1) < 0)
            return -1;
        data += n;
        len -= n;
    }
    return 0;
}

static int oled_cmds(const uint8_t *cmds, size_t len)
{
    return oled_stream(0x00, cmds, len);
}

static int oled_data(const uint8_t *data, size_t len)
{
    return oled_stream(0x40, data, len);
}

static int i2c_open_ex(const char *path, int quiet)
{
    int fd = open(path, O_RDWR);
    if (fd < 0) {
        if (!quiet)
            fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return -1;
    }
    if (ioctl(fd, I2C_SLAVE, g_addr) < 0) {
        if (!quiet)
            fprintf(stderr, "ioctl(I2C_SLAVE, 0x%02X) on %s: %s\n",
                    g_addr, path, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static int i2c_open(const char *path)
{
    return i2c_open_ex(path, 0);
}

/* One harmless NOP write tells us whether anything ACKs at g_addr. */
static int i2c_probe(int fd)
{
    uint8_t nop[2] = { 0x00, 0xE3 };
    return write(fd, nop, sizeof(nop)) == (ssize_t)sizeof(nop) ? 0 : -1;
}

/* ------------------------------------------------------------------ */
/* SSD1315 panel                                                       */
/* ------------------------------------------------------------------ */

static int panel_init(void)
{
    static const uint8_t init[] = {
        0xAE,               /* display off                        */
        0xD5, 0x80,         /* clock divide / osc freq            */
        0xA8, 0x3F,         /* multiplex ratio 1/64               */
        0xD3, 0x00,         /* display offset 0                   */
        0x40,               /* start line 0                       */
        0x8D, 0x14,         /* charge pump enable                 */
        0x20, 0x00,         /* horizontal addressing mode         */
        0xA1,               /* segment remap                      */
        0xC8,               /* COM scan direction remapped        */
        0xDA, 0x12,         /* COM pins: alternative, 128x64      */
        0x81, 0xCF,         /* contrast                           */
        0xD9, 0xF1,         /* pre-charge period                  */
        0xDB, 0x40,         /* VCOMH deselect level               */
        0xA4,               /* display follows RAM                */
        0xA6,               /* normal (not inverted)              */
        0x2E,               /* deactivate scroll                  */
        0xAF,               /* display on                         */
    };

    if (oled_cmds(init, sizeof(init)) < 0)
        return -1;
    return 0;
}

static void fb_clear(void)
{
    memset(g_fb, 0, sizeof(g_fb));
}

static void fb_pixel(int x, int y, int on)
{
    if (x < 0 || x >= OLED_W || y < 0 || y >= OLED_H)
        return;
    if (on)
        g_fb[y >> 3][x] |= (uint8_t)(1u << (y & 7));
    else
        g_fb[y >> 3][x] &= (uint8_t)~(1u << (y & 7));
}

/* 8x16 glyph, drawn at (x,y); y may be any pixel row */
static void fb_char(int x, int y, char c)
{
    const unsigned char *g;

    if (c < 32 || c > 126)
        c = '?';
    g = &font8x16[(int)(c - 32) * 16];

    for (int row = 0; row < 16; row++) {
        uint8_t bits = g[row];
        for (int col = 0; col < 8; col++) {
            if (bits & (0x80u >> col))
                fb_pixel(x + col, y + row, 1);
        }
    }
}

static void fb_text(int x, int y, const char *s)
{
    while (*s) {
        fb_char(x, y, *s++);
        x += 8;
    }
}

static int fb_flush(void)
{
    static const uint8_t window[] = {
        0x21, 0x00, 0x7F,   /* column 0..127 */
        0x22, 0x00, 0x07,   /* page 0..7     */
    };

    if (oled_cmds(window, sizeof(window)) < 0)
        return -1;

    for (int p = 0; p < OLED_PAGES; p++) {
        if (oled_data(g_fb[p], OLED_W) < 0)
            return -1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Address / status                                                    */
/* ------------------------------------------------------------------ */

static int iface_has_carrier(const char *name)
{
    char path[128];
    char buf[8] = { 0 };
    int fd;

    snprintf(path, sizeof(path), "/sys/class/net/%s/carrier", name);
    fd = open(path, O_RDONLY);
    if (fd < 0)
        return -1;
    if (read(fd, buf, sizeof(buf) - 1) <= 0) {
        close(fd);
        return -1;
    }
    close(fd);
    return atoi(buf) ? 1 : 0;
}

/*
 * Pick the IPv4 address to show: the first UP, non-loopback, non-link-local
 * address, preferring eth0 (the front-panel RJ45 in the XJSM design).
 * Returns 1 with a formatted "a.b.c.d" (3-digit octets, per the doc's
 * fixed-width layout), 0 if there is no address.
 */
static int get_ip(char *out, size_t outlen, int *link_up)
{
    struct ifaddrs *ifa = NULL;
    struct ifaddrs *p;
    int found = 0;
    char fallback[32] = { 0 };

    *link_up = 0;
    if (getifaddrs(&ifa) < 0)
        return 0;

    for (p = ifa; p; p = p->ifa_next) {
        if (!p->ifa_name || !p->ifa_addr)
            continue;
        if (p->ifa_addr->sa_family != AF_INET)
            continue;
        if (p->ifa_flags & IFF_LOOPBACK)
            continue;
        if (!(p->ifa_flags & IFF_UP))
            continue;

        if (iface_has_carrier(p->ifa_name) == 1)
            *link_up = 1;

        {
            struct sockaddr_in *sin = (struct sockaddr_in *)p->ifa_addr;
            uint32_t a = ntohl(sin->sin_addr.s_addr);
            char buf[32];

            if (a == 0)
                continue;
            snprintf(buf, sizeof(buf), "%u.%03u.%03u.%03u",
                     (a >> 24) & 0xFF, (a >> 16) & 0xFF,
                     (a >> 8) & 0xFF, a & 0xFF);

            if (!found || strcmp(p->ifa_name, "eth0") == 0) {
                snprintf(fallback, sizeof(fallback), "%s", buf);
                found = 1;
                if (strcmp(p->ifa_name, "eth0") == 0)
                    break;
            }
        }
    }
    freeifaddrs(ifa);

    if (found) {
        snprintf(out, outlen, "%s", fallback);
        return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Screen contents                                                     */
/* ------------------------------------------------------------------ */

static void draw_heartbeat(int on)
{
    /* 6x6 dot at the right end of the top line */
    if (!on)
        return;
    for (int y = 5; y < 11; y++)
        for (int x = 121; x < 127; x++)
            fb_pixel(x, y, 1);
}

static void draw_screen(const char *ip, int have_ip, int link_up, int beat)
{
    fb_clear();

    if (have_ip) {
        fb_text(0, 0, ip);              /* 15 chars = 120 px, dot at 121..126 */
    } else if (link_up) {
        fb_text(0, 0, "DHCP...");
    } else {
        fb_text(0, 0, "NO LINK");
    }

    draw_heartbeat(beat);

    /* footer: board identity, keep it static so the panel ages evenly */
    fb_text(8, 48, "XJSM-P12-Z7000");
}

static void draw_test_pattern(void)
{
    fb_clear();
    for (int y = 0; y < OLED_H; y++)
        for (int x = 0; x < OLED_W; x++)
            if (((x >> 3) + (y >> 3)) & 1)
                fb_pixel(x, y, 1);
    fb_text(0, 0, "JSM-P12");
    fb_text(0, 16, "I2C 0x3C");
    fb_text(0, 32, "SSD1315");
    fb_text(0, 48, "128x64");
}

/* Debug aid: dump the current frame as a 1-bit PBM (128x64). */
static int dump_pbm(const char *path)
{
    FILE *f = fopen(path, "wb");

    if (!f) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return -1;
    }
    fprintf(f, "P4\n%d %d\n", OLED_W, OLED_H);
    for (int y = 0; y < OLED_H; y++) {
        unsigned char b = 0;
        int n = 0;
        for (int x = 0; x < OLED_W; x++) {
            b = (unsigned char)((b << 1) | ((g_fb[y >> 3][x] >> (y & 7)) & 1));
            if (++n == 8) {
                fputc(b, f);
                n = 0;
                b = 0;
            }
        }
    }
    fclose(f);
    return 0;
}

/* ------------------------------------------------------------------ */
/* main                                                                */
/* ------------------------------------------------------------------ */

static volatile sig_atomic_t g_stop = 0;

static void on_sigint(int sig)
{
    (void)sig;
    g_stop = 1;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s [-b /dev/i2c-N] [-a ADDR] [-i IP] [-t] [-o] [-v]\n"
            "  -b  i2c bus device (default: autodetect /dev/i2c-0 .. /dev/i2c-7)\n"
            "  -a  panel address (default 0x3C)\n"
            "  -i  force the IP string to display instead of the local address\n"
            "  -t  draw a test pattern and exit\n"
            "  -o  render one frame and exit\n"
            "  -x  dump the frame to a PBM file (debug, needs -n without hardware)\n"
            "  -n  dry run: render only, do not touch I2C (use with -x)\n"
            "  -v  verbose\n",
            argv0);
}

int main(int argc, char **argv)
{
    const char *bus = NULL;
    const char *forced_ip = NULL;
    int opt_test = 0, opt_once = 0, opt_dry = 0, opt;
    const char *dump = NULL;
    char ip[32] = { 0 };
    int have_ip, link_up;
    int beat = 1;   /* dot visible on the very first frame */
    int last_state = -1;
    char last_ip[32] = { 0 };

    while ((opt = getopt(argc, argv, "b:a:i:tovhnx:")) != -1) {
        switch (opt) {
        case 'b': bus = optarg; break;
        case 'a': g_addr = (int)strtol(optarg, NULL, 0); break;
        case 'i': forced_ip = optarg; break;
        case 't': opt_test = 1; break;
        case 'o': opt_once = 1; break;
        case 'v': g_verbose++; break;
        case 'n': opt_dry = 1; break;
        case 'x': dump = optarg; break;
        default: usage(argv[0]); return 1;
        }
    }

    if (opt_dry) {
        /* nothing to open; useful for layout checks with -x */
    } else if (bus) {
        g_fd = i2c_open(bus);
        if (g_fd < 0)
            return 1;
        if (i2c_probe(g_fd) < 0) {
            fprintf(stderr, "no ACK from 0x%02X on %s - check SCL/SDA, "
                            "pull-ups and that the PL I2C master is loaded\n",
                    g_addr, bus);
            return 1;
        }
    } else {
        char path[32];
        for (int n = 0; n < 8 && g_fd < 0; n++) {
            snprintf(path, sizeof(path), "/dev/i2c-%d", n);
            int fd = i2c_open_ex(path, 1);
            if (fd < 0)
                continue;
            if (i2c_probe(fd) == 0) {
                g_fd = fd;
                bus = strdup(path);
                if (g_verbose)
                    printf("using %s\n", path);
            } else {
                close(fd);
            }
        }
        if (g_fd < 0) {
            fprintf(stderr, "no SSD1315 found at 0x%02X on /dev/i2c-0..7\n",
                    g_addr);
            return 1;
        }
    }

    if (!opt_dry && g_verbose)
        printf("panel 0x%02X on %s\n", g_addr, bus ? bus : "?");

    if (!opt_dry && panel_init() < 0)
        return 1;

    if (opt_test) {
        draw_test_pattern();
        if (dump && dump_pbm(dump) < 0)
            return 1;
        if (!opt_dry && fb_flush() < 0)
            return 1;
        return 0;
    }

    signal(SIGINT, on_sigint);
    signal(SIGTERM, on_sigint);

    /* first frame */
    if (forced_ip) {
        snprintf(ip, sizeof(ip), "%s", forced_ip);
        have_ip = 1;
        link_up = 1;
    } else {
        have_ip = get_ip(ip, sizeof(ip), &link_up);
    }
    draw_screen(ip, have_ip, link_up, beat);
    if (dump && dump_pbm(dump) < 0)
        return 1;
    if (!opt_dry && fb_flush() < 0)
        return 1;
    last_state = have_ip;
    snprintf(last_ip, sizeof(last_ip), "%s", ip);

    if (opt_once)
        return 0;

    while (!g_stop) {
        struct timespec ts = { 0, 200 * 1000 * 1000 };
        int changed = 0;

        nanosleep(&ts, NULL);

        if (!forced_ip) {
            char now[32];
            int link;
            int ok = get_ip(now, sizeof(now), &link);

            if (ok != last_state || strcmp(now, last_ip) != 0) {
                snprintf(ip, sizeof(ip), "%s", now);
                have_ip = ok;
                link_up = link;
                snprintf(last_ip, sizeof(last_ip), "%s", now);
                last_state = ok;
                changed = 1;
                if (g_verbose)
                    printf("%s %s\n", ok ? "ip" : "no-ip", ok ? ip : "");
            }
        }

        /* heartbeat: toggle once per second, independent of the 200 ms poll */
        {
            static int tick = 0;
            if (++tick >= 5) {
                tick = 0;
                beat ^= 1;
                changed = 1;
            }
        }

        if (changed) {
            draw_screen(ip, have_ip, link_up, beat);
            if (!opt_dry && fb_flush() < 0)
                break;
        }
    }

    /* leave the last frame on screen; panel is the front-panel indicator */
    if (g_fd >= 0)
        close(g_fd);
    return 0;
}
