/*
 * jtagscan - scan the external target on G1 through the AXI-Lite hardware TAP engine (jtag_master)
 *
 * Registers: 0x00 LEN / 0x04 TMS / 0x08 TDI / 0x0C TDO / 0x10 CTRL / 0x14 STATUS / 0x18 DIV
 * Usage: jtagscan [-a 0x41200000] [-d div]
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>

#define MAP_SIZE 0x1000
static volatile uint32_t *regs;

static inline void wr(uint32_t off, uint32_t v) { regs[off/4] = v; }
static inline uint32_t rd(uint32_t off) { return regs[off/4]; }

static uint32_t jtag_shift(int nbits, uint32_t tms, uint32_t tdi, uint32_t div)
{
    wr(0x18, div);
    wr(0x00, (uint32_t)nbits);
    wr(0x04, tms);
    wr(0x08, tdi);
    wr(0x10, 1);
    /* first wait for busy to go high (the engine needs 1~2 clocks to detect start), then wait for it to clear */
    { int guard = 1000000;
      while (!(rd(0x14) & 1) && guard--) ;
      if (guard <= 0) printf("warning: engine did not start\n");
      guard = 1000000;
      while ((rd(0x14) & 1) && guard--) ;
      if (guard <= 0) printf("warning: shift timeout\n");
    }
    return rd(0x0C);
}

static void tap_reset(uint32_t div)
{
    jtag_shift(6, 0x1F, 0x00, div);            /* TLR x5 (bit0..4=1), bit5=0 -> RTI */
}

int main(int argc, char **argv)
{
    int fd, c, i;
    uint32_t base = 0x40000000, div = 8;
    void *map;
    int tms[64], tdi[64], n = 0;
    uint32_t id, tms_w, tdi_w, v1, v2;

    while ((c = getopt(argc, argv, "a:d:")) != -1) {
        switch (c) {
        case 'a': base = (uint32_t)strtoul(optarg, NULL, 0); break;
        case 'd': div = (uint32_t)strtoul(optarg, NULL, 0); break;
        default:
            fprintf(stderr, "usage: %s [-a addr] [-d div]\n", argv[0]);
            return 1;
        }
    }

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    map = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, base);
    close(fd);
    if (map == MAP_FAILED) { perror("mmap"); return 1; }
    regs = (volatile uint32_t *)map;

    printf("jtag_master @ 0x%08X  div=%u  status=%u\n", base, div, rd(0x14));

    /* AXI write/read-back self-test */
    wr(0x00, 0x12345678); wr(0x04, 0x0F0F0F0F); wr(0x08, 0x0000FFFF);
    if (rd(0x00) != 0x12345678 || rd(0x04) != 0x0F0F0F0F || rd(0x08) != 0x0000FFFF) {
        printf("AXI self-test FAILED: LEN=0x%08X TMS=0x%08X TDI=0x%08X\n",
               rd(0x00), rd(0x04), rd(0x08));
        printf("  -> check that the S_AXI interface is really connected in the Tcl and the address is correct\n");
        return 2;
    }
    printf("AXI self-test OK\n");

    tap_reset(div);

    /* TLR(5) -> RTI -> SelDR -> CapDR -> ShiftDR */
    for (i = 0; i < 5; i++) { tms[n] = 1; tdi[n] = 0; n++; }
    tms[n] = 0; tdi[n] = 0; n++;
    tms[n] = 1; tdi[n] = 0; n++;
    tms[n] = 0; tdi[n] = 0; n++;
    tms[n] = 0; tdi[n] = 0; n++;
    for (i = 0; i < 32; i++) { tms[n] = 0; tdi[n] = 0; n++; }   /* 32 bits of data */
    tms[n] = 1; tdi[n] = 0; n++;   /* Exit1DR */
    tms[n] = 0; tdi[n] = 0; n++;   /* UpdateDR */
    tms[n] = 0; tdi[n] = 0; n++;   /* RTI */

    /* in two passes: the first 9 bits set up the state, the next 32 bits read data, the last 3 bits exit */
    tms_w = 0; tdi_w = 0;
    for (i = 0; i < 9; i++) { if (tms[i]) tms_w |= 1u << i; if (tdi[i]) tdi_w |= 1u << i; }
    v1 = jtag_shift(9, tms_w, tdi_w, div);
    (void)v1;

    tms_w = 0; tdi_w = 0;
    for (i = 9; i < 9+32; i++) { if (tms[i]) tms_w |= 1u << (i-9); if (tdi[i]) tdi_w |= 1u << (i-9); }
    v2 = jtag_shift(32, tms_w, tdi_w, div);

    tms_w = 0;
    for (i = 41; i < 44; i++) { if (tms[i]) tms_w |= 1u << (i-41); }
    jtag_shift(3, tms_w, 0, div);

    id = v2;
    printf("IDCODE = 0x%08X\n", id);
    if (id == 0 || id == 0xFFFFFFFF)
        printf("  -> invalid (check TDO wiring / target power / divider)\n");
    else
        printf("  -> a device on the chain responded\n");

    munmap(map, MAP_SIZE);
    return 0;
}
