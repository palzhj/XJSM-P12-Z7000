// xvcinfo.c -- XVC status collection and control (web console backend)
//
// Usage:
//   xvcinfo json            print JSON status
//   xvcinfo start           start /tmp/xv12p
//   xvcinfo stop            stop
//   xvcinfo restart         restart
//   xvcinfo div <n>         set DIV on all channels
//
// Channel register base: 0x43C00000 + ch*0x10000
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <signal.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#define BASE        0x43C00000u
#define NCH         12
#define BCAST_CH    12      /* broadcast engine window */
#define REGS_CH     13      /* broadcast register block window */
#define WIN         0x10000u
#define MAP_SIZE    ((NCH + 2) * WIN)   /* +2: broadcast engine + register block */   /* +1: the 13th window is the broadcast engine */

static volatile unsigned *regs;

static unsigned rd(int ch, unsigned off) { return regs[(ch * WIN + off) / 4]; }
static void     wr(int ch, unsigned off, unsigned v) { regs[(ch * WIN + off) / 4] = v; }

static int server_pid(void)
{
    FILE *f = popen("pidof xvcserver_g1 xv12p 2>/dev/null", "r");
    int pid = 0;
    if (f) { if (fscanf(f, "%d", &pid) != 1) pid = 0; pclose(f); }
    return pid;
}

/* Number of established connections on the given port */
static int port_clients(int port)
{
    FILE *f = fopen("/proc/net/tcp", "r");
    char line[512];
    int n = 0;
    if (!f) return 0;
    if (!fgets(line, sizeof(line), f)) { fclose(f); return 0; }
    while (fgets(line, sizeof(line), f)) {
        unsigned lport, rport; char st[8];
        if (sscanf(line, " %*d: %*[0-9A-Fa-f]:%X %*[0-9A-Fa-f]:%X %s",
                   &lport, &rport, st) >= 3) {
            if ((int)lport == port && !strcmp(st, "01")) n++;
        }
    }
    fclose(f);
    return n;
}

static int count_clients(void)
{
    FILE *f = fopen("/proc/net/tcp", "r");
    char line[512];
    int n = 0;
    if (!f) return 0;
    if (!fgets(line, sizeof(line), f)) { fclose(f); return 0; }
    while (fgets(line, sizeof(line), f)) {
        unsigned lip, rip; int lport, rport; char st[8];
        if (sscanf(line, " %*d: %*[0-9A-Fa-f]:%X %*[0-9A-Fa-f]:%X %s",
                   &lport, &rport, st) >= 3) {
            if (lport >= 2542 && lport <= 2554 && !strcmp(st, "01")) n++;   /* 01 = ESTABLISHED */
        }
        (void)lip; (void)rip;
    }
    fclose(f);
    return n;
}


/* ---------- network info / configuration ---------- */
static const char *IFACE = "eth0";

static int if_ip(const char *ifn, int req, char *out, size_t n)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct ifreq ifr;
    if (fd < 0) return -1;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifn, IFNAMSIZ - 1);
    if (ioctl(fd, req, &ifr) < 0) { close(fd); return -1; }
    strncpy(out, inet_ntoa(((struct sockaddr_in *)&ifr.ifr_addr)->sin_addr), n - 1);
    close(fd);
    return 0;
}

static void if_mac(const char *ifn, char *out, size_t n)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct ifreq ifr;
    out[0] = 0;
    if (fd < 0) return;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifn, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFHWADDR, &ifr) == 0) {
        unsigned char *m = (unsigned char *)ifr.ifr_hwaddr.sa_data;
        snprintf(out, n, "%02x:%02x:%02x:%02x:%02x:%02x",
                 m[0], m[1], m[2], m[3], m[4], m[5]);
    }
    close(fd);
}

static void get_gateway(char *out, size_t n)
{
    FILE *f = fopen("/proc/net/route", "r");
    char line[256];
    out[0] = 0;
    if (!f) return;
    if (!fgets(line, sizeof(line), f)) { fclose(f); return; }
    while (fgets(line, sizeof(line), f)) {
        char ifn[32]; unsigned dest, gw, flags;
        if (sscanf(line, "%31s %x %x %x", ifn, &dest, &gw, &flags) == 4) {
            if (dest == 0 && (flags & 2)) {
                struct in_addr a; a.s_addr = gw;
                strncpy(out, inet_ntoa(a), n - 1);
                break;
            }
        }
    }
    fclose(f);
}

static int if_up(const char *ifn)
{
    FILE *f = fopen("/sys/class/net/eth0/operstate", "r");
    char s[32] = "";
    if (f) { if (fgets(s, sizeof(s), f)) { } fclose(f); }
    return strncmp(s, "up", 2) == 0;
}

static void net_json(void)
{
    char ip[64] = "-", mask[64] = "-", mac[64] = "-", gw[64] = "-";
    if_ip(IFACE, SIOCGIFADDR, ip, sizeof(ip));
    if_ip(IFACE, SIOCGIFNETMASK, mask, sizeof(mask));
    if_mac(IFACE, mac, sizeof(mac));
    get_gateway(gw, sizeof(gw));
    printf("{\"iface\":\"%s\",\"mac\":\"%s\",\"ip\":\"%s\",\"netmask\":\"%s\",\"gateway\":\"%s\",\"link_up\":%d}\n",
           IFACE, mac, ip, mask, gw, if_up(IFACE));
}

static void net_set(const char *ip, const char *mask, const char *gw)
{
    char cmd[512];
    if (!strcmp(ip, "dhcp")) {
        system("kill $(pidof udhcpc) 2>/dev/null");
        snprintf(cmd, sizeof(cmd), "udhcpc -i %s -b -q > /tmp/udhcpc.log 2>&1 &", IFACE);
        system(cmd);
        printf("dhcp requested\n");
        return;
    }
    snprintf(cmd, sizeof(cmd), "ifconfig %s %s netmask %s up", IFACE, ip, mask);
    system(cmd);
    if (gw && gw[0]) {
        system("route del default 2>/dev/null");
        snprintf(cmd, sizeof(cmd), "route add default gw %s", gw);
        system(cmd);
    }
    printf("applied: %s/%s gw %s\n", ip, mask, gw && gw[0] ? gw : "-");
}

int main(int argc, char **argv)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    void *m;
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    m = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, BASE);
    close(fd);
    if (m == MAP_FAILED) { perror("mmap"); return 1; }
    regs = (volatile unsigned *)m;

    if (argc < 2) { fprintf(stderr, "usage: %s json|start|stop|restart|div <n>\n", argv[0]); return 1; }

    if (!strcmp(argv[1], "json")) {
        int ch, pid = server_pid(), clients = count_clients();
        printf("{");
        printf("\"server_pid\":%d,\"clients\":%d,\"nch\":%d,\"bcast\":%u,\"bcast_tdo\":%u,\"bcmask\":%u,\"bcast_clients\":%d,",
               pid, clients, NCH,
               rd(REGS_CH, 0x00) & 1,           /* register block CTRL.bit0 = bcast_en */
               rd(REGS_CH, 0x08) & 0xF,         /* CHSEL */
               /* RTL expands bcmask==0 to "all selected", so reports are corrected with bcast_en:
                  bcast_en=0 means "owns no channel", and the mask is always reported as 0 */
               (rd(REGS_CH, 0x00) & 1) ? (rd(REGS_CH, 0x04) & 0xFFF) : 0u,
               port_clients(2542));
        {
            unsigned tag = rd(BCAST_CH, 0x14), div = rd(BCAST_CH, 0x18), st = rd(BCAST_CH, 0x24);
            unsigned done = rd(BCAST_CH, 0x28), st2 = rd(BCAST_CH, 0x30);
            printf("\"bcast_ch\":{\"tag\":\"0x%08X\",\"div\":%u,\"tck_mhz\":%.3f,"
                   "\"tx_free\":%u,\"rx_used\":%u,\"done\":%u,\"busy\":%u,\"state\":%u},",
                   tag, div, div ? 100.0 / (2.0 * div) : 0.0,
                   st & 0xFF, (st >> 8) & 0xFF, done, st2 & 1, (st2 >> 2) & 3);
        }
        printf("\"channels\":[");
        for (ch = 0; ch < NCH; ch++) {
            unsigned tag = rd(ch, 0x14), div = rd(ch, 0x18), st = rd(ch, 0x24);
            unsigned done = rd(ch, 0x28), st2 = rd(ch, 0x30);
            printf("%s{\"ch\":%d,\"tag\":\"0x%08X\",\"div\":%u,\"tck_mhz\":%.3f,"
                   "\"tx_free\":%u,\"rx_used\":%u,\"done\":%u,\"busy\":%u,\"state\":%u,\"clients\":%d}",
                   ch ? "," : "", ch, tag, div, div ? 100.0 / (2.0 * div) : 0.0,
                   st & 0xFF, (st >> 8) & 0xFF, done, st2 & 1, (st2 >> 2) & 3,
                   port_clients(2543 + ch));
        }
        printf("]}");
        printf("\n");
        return 0;
    }
    if (!strcmp(argv[1], "start")) {
        if (server_pid()) { printf("already running\n"); return 0; }
        system("nohup /usr/bin/xvcserver_g1 -a 0x43C00000 -d 5 > /tmp/xv12p.log 2>&1 &");
        usleep(800000);
        printf(server_pid() ? "started pid=%d\n" : "start failed\n", server_pid());
        return 0;
    }
    if (!strcmp(argv[1], "stop")) {
        int pid = server_pid();
        if (pid) kill(pid, SIGKILL);
        usleep(300000);
        printf("stopped\n");
        return 0;
    }
    if (!strcmp(argv[1], "restart")) {
        int pid = server_pid();
        if (pid) { kill(pid, SIGKILL); usleep(500000); }
        system("nohup /usr/bin/xvcserver_g1 -a 0x43C00000 -d 5 > /tmp/xv12p.log 2>&1 &");
        usleep(800000);
        printf("restarted pid=%d\n", server_pid());
        return 0;
    }
    if (!strcmp(argv[1], "setbcast") && argc >= 3) {
        unsigned v = (unsigned)strtoul(argv[2], NULL, 0);
        if (v >= NCH) v = 0;
        wr(REGS_CH, 0x08, v);    /* register block CHSEL */
        printf("broadcast TDO source = AMC%u\n", v + 1);
        return 0;
    }
    if (!strcmp(argv[1], "bcast")) { printf("%u\n", rd(0, 0x3C) & 0xF); return 0; }
    if (!strcmp(argv[1], "setbcmask") && argc >= 3) {
        unsigned m = (unsigned)strtoul(argv[2], NULL, 0) & 0xFFF;
        /* m == 0 is allowed (own no channel).
         * Note: in the RTL bcmask==0 expands to "all selected", so the mask alone cannot express "none selected".
         * Use CTRL bit0 (bcast_en) as the master switch: clear it when the mask is empty, so the broadcast engine drives no pins. */
        wr(REGS_CH, 0x04, m);              /* BCMASK (keep whatever the user wrote, including 0) */
        wr(REGS_CH, 0x00, m ? 1u : 0u);    /* bcast_en = mask is non-empty */
        printf("broadcast mask = 0x%03X, enabled = %u\n", m, m ? 1u : 0u);
        return 0;
    }
    if (!strcmp(argv[1], "bcmask")) { printf("0x%03X\n", rd(0, 0x40) & 0xFFF); return 0; }
    if (!strcmp(argv[1], "net")) { net_json(); return 0; }
    if (!strcmp(argv[1], "setnet")) {
        if (argc >= 3 && !strcmp(argv[2], "dhcp")) { net_set("dhcp", "", ""); return 0; }
        if (argc >= 5) { net_set(argv[2], argv[3], argv[4]); return 0; }
        fprintf(stderr, "usage: setnet dhcp | setnet <ip> <mask> <gw>\n");
        return 1;
    }
    if (!strcmp(argv[1], "div") && argc >= 3) {
        unsigned d = (unsigned)strtoul(argv[2], NULL, 0);
        int ch;
        if (d < 1) d = 1;
        if (d > 65535) d = 65535;
        for (ch = 0; ch < NCH; ch++) wr(ch, 0x14, d);
        printf("div=%u (%.3f MHz)\n", d, 100.0 / (2.0 * d));
        return 0;
    }
    fprintf(stderr, "unknown command\n");
    return 1;
}
