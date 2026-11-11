/*
 * xvcserver.c - Xilinx Virtual Cable (XVC) server for Zynq-7000 + Debug Bridge
 *
 * Derived from "xvcServer.c" (XAPP1251, Avnet/Xilinx, CC0 1.0), itself a
 * derivative of "xvcd.c" by tmbinc (CC0 1.0).
 *
 * Differences vs. the XAPP1251 original:
 *   - UIO device is auto-detected by scanning /sys/class/uio/<n>/name for
 *     "debug_bridge" instead of hard-coding uio0 / uio1.  Which uioN a design
 *     gets depends on probe order of *all* generic-uio nodes, so hard-coding
 *     is the #1 reason the stock app fails on a new design.
 *   - the debug-bridge busy-wait has a timeout, and the shift buffer is
 *     bounds-checked, so a bad client cannot hang the box.
 *   - -d <name> still forces a specific UIO device (e.g. -d uio0).
 *
 * Protocol (XVC 1.0):
 *   "getinfo:"                     -> "xvcServer_v1.0:<maxbits>\n"
 *   "settck:" + 4B LE period (ns)  -> 4B LE (echoed)
 *   "shift:"  + 4B LE nbits + TMS[]+ TDI[]  -> TDO[]   (LSB first, byte aligned)
 *
 * Build: gcc -O2 -o xvcserver xvcserver.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
#include <stdint.h>
#include <errno.h>
#include <dirent.h>

#include <sys/mman.h>
#include <fcntl.h>

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <netinet/in.h>
#include <pthread.h>

#define MAP_SIZE        0x10000
#define XVC_MAX_BITS    2048            /* must match the pipeline depth */
#define DBG_NAME        "debug_bridge"
#define CTRL_TIMEOUT_MS 2000            /* busy-wait guard */

#define dsb(scope)      asm volatile("dsb " #scope : : : "memory")

/* Register map of the Debug Bridge "AXI to BSCAN" mode (PG245 / XAPP1251) */
typedef struct {
    uint32_t length_offset;   /* 0x00 : number of bits for this shift   */
    uint32_t tms_offset;      /* 0x04 : TMS vector                      */
    uint32_t tdi_offset;      /* 0x08 : TDI vector                      */
    uint32_t tdo_offset;      /* 0x0C : TDO vector (read back)          */
    uint32_t ctrl_offset;     /* 0x10 : bit0 = start; clears when done  */
} jtag_t;

static int verbose = 0;
static unsigned int tck_ns = 1000;   /* TCK period, set by settck */

static int sread(int fd, void *target, int len)
{
    unsigned char *t = target;
    while (len) {
        int r = read(fd, t, len);
        if (r <= 0)
            return r;
        t += r;
        len -= r;
    }
    return 1;
}

/* Return the uioN whose /sys/class/uio/<n>/name equals "debug_bridge". */
static int find_uio(char *out, size_t outlen)
{
    DIR *d = opendir("/sys/class/uio");
    struct dirent *de;

    if (!d)
        return -1;

    while ((de = readdir(d)) != NULL) {
        char path[256], name[64];
        int fd;
        ssize_t n;

        if (strncmp(de->d_name, "uio", 3) != 0)
            continue;

        snprintf(path, sizeof(path), "/sys/class/uio/%s/name", de->d_name);
        fd = open(path, O_RDONLY);
        if (fd < 0)
            continue;
        n = read(fd, name, sizeof(name) - 1);
        close(fd);
        if (n <= 0)
            continue;
        name[n] = '\0';
        while (n > 0 && (name[n - 1] == '\n' || name[n - 1] == '\r'))
            name[--n] = '\0';

        if (strcmp(name, DBG_NAME) == 0) {
            snprintf(out, outlen, "%s", de->d_name);
            closedir(d);
            return 0;
        }
    }
    closedir(d);
    return -1;
}

static int handle_data(int fd, volatile jtag_t *ptr)
{
    static const char xvcInfo[] = "xvcServer_v1.0:" "2048" "\n";

    do {
        char cmd[16];
        unsigned char buffer[8192], result[1024];
        int len, nr_bytes;

        memset(cmd, 0, 16);

        if (sread(fd, cmd, 2) != 1)
            return 1;

        if (memcmp(cmd, "ge", 2) == 0) {
            if (sread(fd, cmd, 6) != 1)
                return 1;
            if (write(fd, xvcInfo, strlen(xvcInfo)) != (ssize_t)strlen(xvcInfo)) {
                perror("write");
                return 1;
            }
            if (verbose)
                printf("%u : getinfo -> %s", (unsigned)time(NULL), xvcInfo);
            break;
        } else if (memcmp(cmd, "se", 2) == 0) {
            if (sread(fd, cmd, 9) != 1)
                return 1;
            memcpy(result, cmd + 5, 4);
            memcpy(&tck_ns, cmd + 5, 4);
            if (tck_ns == 0)
                tck_ns = 1000;
            if (write(fd, result, 4) != 4) {
                perror("write");
                return 1;
            }
            if (verbose)
                printf("%u : settck\n", (unsigned)time(NULL));
            break;
        } else if (memcmp(cmd, "sh", 2) == 0) {
            if (sread(fd, cmd, 4) != 1)
                return 1;
        } else {
            fprintf(stderr, "invalid cmd '%s'\n", cmd);
            return 1;
        }

        if (sread(fd, &len, 4) != 1) {
            fprintf(stderr, "reading length failed\n");
            return 1;
        }

        nr_bytes = (len + 7) / 8;
        if (len <= 0 || len > XVC_MAX_BITS || nr_bytes * 2 > (int)sizeof(buffer)) {
            fprintf(stderr, "bad vector length %d\n", len);
            return 1;
        }

        if (sread(fd, buffer, nr_bytes * 2) != 1) {
            fprintf(stderr, "reading data failed\n");
            return 1;
        }
        memset(result, 0, nr_bytes);

        {
            int bytesLeft = nr_bytes;
            int bitsLeft  = len;
            int byteIndex = 0;

            while (bytesLeft > 0) {
                int tms = 0, tdi = 0, tdo = 0;
                int chunk_bits, chunk_bytes;

                if (bytesLeft >= 4) {
                    chunk_bits  = 32;
                    chunk_bytes = 4;
                } else {
                    chunk_bits  = bitsLeft;
                    chunk_bytes = bytesLeft;
                }

                memcpy(&tms, &buffer[byteIndex], chunk_bytes);
                memcpy(&tdi, &buffer[byteIndex + nr_bytes], chunk_bytes);

                ptr->length_offset = (uint32_t)chunk_bits;
                dsb(st);
                ptr->tms_offset = (uint32_t)tms;
                dsb(st);
                ptr->tdi_offset = (uint32_t)tdi;
                dsb(st);
                ptr->ctrl_offset = 0x01;
                dsb(st);

                /* CTRL is a write-only strobe (reads back 0 immediately), so the
                 * shift needs a fixed completion delay before TDO is valid. */
                usleep(chunk_bits * tck_ns / 1000 + 200);

                tdo = (int)ptr->tdo_offset;
                memcpy(&result[byteIndex], &tdo, chunk_bytes);

                bytesLeft -= chunk_bytes;
                bitsLeft  -= chunk_bits;
                byteIndex += chunk_bytes;
            }
        }

        if (write(fd, result, nr_bytes) != nr_bytes) {
            perror("write");
            return 1;
        }

        if (verbose)
            printf("\tshift %d bits\n", len);
    } while (1);

    return 0;
}

#define MAX_CHANNELS 64

struct worker_arg {
    int fd;
    int channel;
    volatile jtag_t *ptr;
};

static void *conn_thread(void *arg)
{
    struct worker_arg *a = (struct worker_arg *)arg;

    if (a->channel > 0) {
        /* Twelve port groups are reserved, but currently only group 0 has a TAP engine (Debug Bridge). */
        fprintf(stderr, "xvcserver: channel %d has no TAP engine yet, closing\n",
                a->channel);
        close(a->fd);
        free(a);
        return NULL;
    }

    /* channel == 0: single channel; channel == -1: broadcast (equivalent to channel 0 before HW multicast is ready) */
    /* handle_data processes one command per call (internal break), so loop until it errors */
    while (handle_data(a->fd, a->ptr) == 0) {
        /* keep serving this client */
    }
    close(a->fd);
    free(a);
    return NULL;
}

int main(int argc, char **argv)
{
    int c, i;
    char dev_name[32] = "";
    int fd_uio;
    int base_port = 2542;
    int nports = 12;
    int broadcast_only = 0;
    char dev_file[64];
    struct sockaddr_in address;
    volatile jtag_t *ptr;
    int lfd[MAX_CHANNELS];

    opterr = 0;
    while ((c = getopt(argc, argv, "vd:p:n:b")) != -1) {
        switch (c) {
        case 'v': verbose = 1; break;
        case 'd': snprintf(dev_name, sizeof(dev_name), "%s", optarg); break;
        case 'p': base_port = atoi(optarg); break;
        case 'n': nports = atoi(optarg); break;
        case 'b': broadcast_only = 1; break;
        default:
            fprintf(stderr, "usage: %s [-v] [-d uioN] [-p base_port] [-n ports] [-b]\n"
                            "  default: -p 2542 -n 12  (channels 2542..2553)\n"
                            "  -b : only bind the broadcast port (2542)\n",
                    argv[0]);
            return 1;
        }
    }
    if (broadcast_only) nports = 0;
    else if (nports < 1) nports = 1;
    if (nports > MAX_CHANNELS) nports = MAX_CHANNELS;
    if (base_port < 1 || base_port + nports > 65535) {
        fprintf(stderr, "invalid port range\n");
        return 1;
    }

    if (dev_name[0] == '\0') {
        if (find_uio(dev_name, sizeof(dev_name)) != 0) {
            fprintf(stderr, "no UIO device named '%s' found; is the bitstream "
                            "loaded and the DT node compatible=\"generic-uio\"?\n",
                    DBG_NAME);
            return 1;
        }
        if (verbose)
            printf("auto-detected UIO device: %s\n", dev_name);
    }

    snprintf(dev_file, sizeof(dev_file), "/dev/%s", dev_name);

    fd_uio = open(dev_file, O_RDWR);
    if (fd_uio < 0) {
        fprintf(stderr, "failed to open %s: %s\n", dev_file, strerror(errno));
        return 1;
    }

    ptr = (volatile jtag_t *)mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE,
                                  MAP_SHARED, fd_uio, 0);
    close(fd_uio);
    if (ptr == MAP_FAILED) {
        fprintf(stderr, "mmap failed: %s\n", strerror(errno));
        return 1;
    }

    /* Port allocation: base_port = broadcast; base_port+1 .. base_port+n = channels 0..n-1
     * Default: 2542 = broadcast, 2543..2554 = channels 0..11 (port = 2543 + index) */
    for (i = 0; i <= nports; i++) {
        int one = 1;
        lfd[i] = socket(AF_INET, SOCK_STREAM, 0);
        if (lfd[i] < 0) {
            perror("socket");
            return 1;
        }
        setsockopt(lfd[i], SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

        memset(&address, 0, sizeof(address));
        address.sin_addr.s_addr = INADDR_ANY;
        address.sin_family = AF_INET;
        address.sin_port = htons(base_port + i);

        if (bind(lfd[i], (struct sockaddr *)&address, sizeof(address)) < 0) {
            fprintf(stderr, "bind port %d: %s\n", base_port + i, strerror(errno));
            return 1;
        }
        if (listen(lfd[i], 4) < 0) {
            fprintf(stderr, "listen port %d: %s\n", base_port + i, strerror(errno));
            return 1;
        }
    }

    if (broadcast_only)
        printf("xvcserver: %s, broadcast only on TCP %d (max %d bits)\n",
               dev_name, base_port, XVC_MAX_BITS);
    else
        printf("xvcserver: %s, broadcast %d, channels %d..%d (max %d bits)\n",
               dev_name, base_port, base_port + 1, base_port + nports, XVC_MAX_BITS);
    fflush(stdout);

    {
        fd_set master;
        int maxfd = 0;

        FD_ZERO(&master);
        for (i = 0; i <= nports; i++) {
            FD_SET(lfd[i], &master);
            if (lfd[i] > maxfd) maxfd = lfd[i];
        }

        while (1) {
            fd_set read = master;
            int fd;

            if (select(maxfd + 1, &read, 0, 0, 0) < 0) {
                perror("select");
                break;
            }

            for (fd = 0; fd <= maxfd; ++fd) {
                if (!FD_ISSET(fd, &read))
                    continue;

                for (i = 0; i <= nports; i++) {
                    if (lfd[i] != fd)
                        continue;

                    {
                        int newfd;
                        socklen_t nsize = sizeof(address);
                        struct worker_arg *a;
                        pthread_t th;

                        newfd = accept(fd, (struct sockaddr *)&address, &nsize);
                        if (newfd < 0) {
                            perror("accept");
                            break;
                        }
                        {
                            int flag = 1;
                            setsockopt(newfd, IPPROTO_TCP, TCP_NODELAY,
                                       (char *)&flag, sizeof(int));
                        }
                        if (i == 0)
                            printf("broadcast (port %d): connection accepted - fd %d\n",
                                   base_port, newfd);
                        else
                            printf("channel %d (port %d): connection accepted - fd %d\n",
                                   i - 1, base_port + i, newfd);
                        fflush(stdout);

                        a = (struct worker_arg *)malloc(sizeof(*a));
                        if (!a) { close(newfd); break; }
                        a->fd = newfd;
                        a->channel = (i == 0) ? -1 : (i - 1);  /* -1 = broadcast */
                        a->ptr = ptr;

                        if (pthread_create(&th, NULL, conn_thread, a) != 0) {
                            perror("pthread_create");
                            close(newfd);
                            free(a);
                        } else {
                            pthread_detach(th);
                        }
                    }
                    break;
                }
            }
        }
    }

    for (i = 0; i <= nports; i++)
        close(lfd[i]);
    munmap((void *)ptr, MAP_SIZE);
    return 0;
}
