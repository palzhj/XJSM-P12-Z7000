/* Header for the DMA proxy kernel driver (Xilinx, Apache-2.0).
 * Shared with the user-space test so both agree on the buffer layout. */
#ifndef _DMA_PROXY_H
#define _DMA_PROXY_H

#include <linux/ioctl.h>

#define BUFFER_COUNT 3
/* 64 KiB per buffer: a 1024-word chunk leaves ~9% of the wall time in per-chunk
 * overhead (arm + two ioctls + poll). 16384 words amortises that to <1%, and the
 * coherent buffers are cached for the CPU, so filling and reading back is fast
 * (unlike the uncached /dev/mem pool the raw server uses). */
#define BUFFER_SIZE  1048576

enum proxy_status { PROXY_NO_ERROR = 0, PROXY_BUSY = 1,
                    PROXY_TIMEOUT = 2, PROXY_ERROR = 3 };

/* One buffer plus its metadata; 1024-byte aligned as the driver assumes. */
struct channel_buffer {
    unsigned int buffer[BUFFER_SIZE / sizeof(unsigned int)];
    enum proxy_status status;
    unsigned int length;
} __attribute__((aligned(1024)));

#define START_XFER  1
#define FINISH_XFER 2
#define XFER        3

#endif
