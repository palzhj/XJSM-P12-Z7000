/* i2cprobe - scan the I2C bus for responding addresses, verify whether the OLED can ACK */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>

int main(int argc, char **argv)
{
    const char *dev = (argc > 1) ? argv[1] : "/dev/i2c-1";
    int fd = open(dev, O_RDWR);
    if (fd < 0) { perror(dev); return 1; }

    printf("bus: %s\n", dev);
    printf("scanning 0x03..0x77 ...\n");

    int found = 0;
    for (int a = 0x03; a <= 0x77; a++) {
        /* SMBus "quick write": the minimal transaction, address + write bit only, to see whether it ACKs */
        if (ioctl(fd, I2C_SLAVE, a) < 0) continue;

        unsigned char dummy = 0;
        struct i2c_rdwr_ioctl_data rdwr;
        struct i2c_msg msg;
        msg.addr  = (unsigned short)a;
        msg.flags = 0;
        msg.len   = 1;
        msg.buf   = &dummy;
        rdwr.msgs  = &msg;
        rdwr.nmsgs = 1;

        if (ioctl(fd, I2C_RDWR, &rdwr) >= 0) {
            printf("  ACK  0x%02X\n", a);
            found++;
        } else if (errno == EREMOTEIO) {
            /* NAK -- normal, no device present */
        } else if (errno == ETIMEDOUT) {
            printf("  0x%02X  transfer timeout (bus has no pull-ups or the controller is not routed out)\n", a);
            printf("  skipping the remaining addresses (bus is stuck)\n");
            close(fd);
            return 2;
        }
    }

    printf("\nresult: found %d devices\n", found);
    if (found) {
        printf("  ★ 0x3C present = SSD1306/SSD1315 OLED responding normally\n");
    } else {
        printf("  no response: check wiring / pull-ups / I2C1 EMIO in the bitstream\n");
    }
    close(fd);
    return found ? 0 : 3;
}
