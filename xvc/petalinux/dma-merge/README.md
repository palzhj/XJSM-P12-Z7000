# dma-proxy as a bitbake module

The DMA proxy driver that exposes `/dev/dma_proxy_tx` and `/dev/dma_proxy_rx`
for the XVC shift engine. It is built as a normal Yocto module recipe, not
out-of-tree, for two reasons:

1. **Out-of-tree builds do not work against this kernel tree.** `linux-xlnx`
   keeps its source in `kernel-source` and its generated headers/`auto.conf`
   in `kernel-build-artifacts`. A plain
   `make -C .../kernel-build-artifacts M=$PWD` fails, `olddefconfig` returns
   rc=2, and the artifacts tree has no `auto.conf`. `inherit module` passes
   both `KERNEL_SRC` and `O=` correctly.
2. **Modules deployed onto the running board live in a ramdisk.** `/lib/modules`
   and `/lib/firmware` vanish on reboot. A module that is part of the image
   recipe is inside the initramfs in `image.ub` and comes up every boot.

## What is in this directory

| File | Purpose |
|---|---|
| [`../../kernel/dma-proxy.c`](../../kernel/dma-proxy.c) | driver source (Xilinx, Apache-2.0) |
| [`../../kernel/dma-proxy.h`](../../kernel/dma-proxy.h) | buffer layout shared with user space |
| [`../../kernel/Makefile`](../../kernel/Makefile) | kbuild forwarder used by `inherit module` |
| [`../../kernel/dma-proxy.bb`](../../kernel/dma-proxy.bb) | the recipe |
| [`system-user.dtsi`](system-user.dtsi) | DT node binding the driver to `&dma` |

The recipe sets `KERNEL_MODULE_AUTOLOAD += "dma-proxy"`, which makes
`kernel-module-split.bbclass` emit `/etc/modules-load.d/dma-proxy.conf`, so the
driver loads at boot without an init script.

## Wiring it into a project

The project must already have the AXI DMA in its hardware description (the DT
needs a `&dma` label — see [`apply.sh`](apply.sh)).

```sh
./apply.sh ~/work/xvc_dma        # inside the VM, recipe+DT+image wiring
```

and add the package to the image:

```bitbake
# project-spec/meta-user/recipes-core/images/petalinux-image-minimal.bbappend
IMAGE_INSTALL:append = " kernel-module-dma-proxy"
```

## Kernel prerequisites

`images/linux/config` is the *project* config, not the kernel `.config`. Check
the real one instead:

```sh
grep -E 'CONFIG_(DMADEVICES|DMA_ENGINE|XILINX_DMA)=' \
  build/tmp/work/*/linux-xlnx/*/linux-*-standard-build/.config
# CONFIG_DMADEVICES=y
# CONFIG_DMA_ENGINE=y
# CONFIG_XILINX_DMA=y
```

## Verifying on hardware

```sh
ls -l /dev/dma_proxy_tx /dev/dma_proxy_rx
dmesg | grep -i dma_proxy        # "Device Tree Channel Count: 2"
```

## Failure signature to know about

If the engine is left with a partial packet (an earlier userspace run stopped
mid-transfer), `S2MM_DMASR` latches `0x5011` (Halted + DMAIntErr + IOC +
Err_Irq) and `S2MM_DMACR` reads back `0x00010002`, i.e. the soft-reset bit never
self-clears — writing 0 to `DMACR` does not take. The channel cannot be
recovered from software; a PL reconfiguration (reboot, since the bitstream is
in `BOOT.BIN`) restores a clean `DMASR=0x1`.

## Status (2026-11-14, image deployed and booting)

Verified on hardware, `xvc_dma` project, image.ub md5 `61de93df…` on the SD
BOOT partition (`image.ub.xvc2` holds the previous product image):

```
dma_proxy: loading out-of-tree module taints kernel.
dma_proxy module initialized
Creating channel dma_proxy_tx
Creating channel dma_proxy_rx
xilinx-vdma 40400000.dma: Xilinx AXI DMA Engine Driver Probed!!
```

| Check | Result |
|---|---|
| `/dev/dma_proxy_tx`, `/dev/dma_proxy_rx` | present (244,0 and 243,0) |
| `/etc/modules-load.d/dma-proxy.conf` | `dma-proxy` — loads every boot |
| DMA IRQs | GIC 61/62 = SPI 29/30, `xilinx-dma-controller` |
| Kernel DMA support | `CONFIG_XILINX_DMA=y`, `DMA_ENGINE=y` |
| Product stack | `xvcserver_g1` running, web console HTTP 200 |

## The real root cause: a stale bitstream in BOOT.BIN

`petalinux-build` rebuilt `images/linux/system.bit` from the current RTL but
`BOOT.BIN` was never re-packaged, so the board kept booting the bitstream from
`xvc/out/v24/BOOT.BIN` (2026-11-12 21:09). That bitstream's engine was built
from RTL that predates the `0x40+` register block, and the difference is
directly visible on the bus:

| engine access | old bitstream | fixed bitstream |
|---|---|---|
| write `0x44` then read | stays `0` (**dropped**) | returns the value |
| read `0x40` | `0x11` (aliases to LEN) | `0x66` (its own value) |
| read `0x44` | `0x22` (aliases to TMS) | its own value |

Reads at `0x40+` alias onto `0x00/0x04/0x08` because the old read decode used
only `araddr[5:2]`. So **the TLAST arm register did not exist**: `dmaw_left`
could never be loaded, `m_axis_tdo_tlast` could never assert, and every S2MM
packet was undelimited - which is the `0x5011` (Halted + DMAIntErr + IOC +
Err_Irq) that killed the server. No amount of software fixing could work, and
`xvcdma`'s "0x44 back to 0 = complete" check was vacuously true.

Fix: re-package the boot image with the current bitstream and deploy it.

```sh
petalinux-package --boot \
    --fsbl images/linux/zynq_fsbl.elf \
    --fpga images/linux/system.bit \
    --u-boot images/linux/u-boot.elf --force
```

`--fpga` must be given explicitly; the default (`images//*.bit`) does not match
this project's layout and silently produces a 1.1 MB BOOT.BIN with no
bitstream. The correct image is ~5.18 MB. Deployed copy verified with
`md5sum` on the SD card.

## Second defect: user mapping is cacheable, so lengths were lost

With the fixed bitstream the DMA ran, but every chunk programmed
`MM2S_LEN = 0x4` - the length from a *previous* transfer - even though user
space had written 4096. Cause: `dma_mmap_coherent()` gives user space a
cacheable mapping of the coherent buffer, while the kernel and the engine read
it through an uncached alias. The user's length write sat dirty in cache and the
transfer silently became 4 bytes, completing instantly (measured 118 Mbit/s
against a 10.00 Mbit/s wire ceiling - the tell-tale).

Fixed in the driver by syncing around the handshake:

- `start_transfer()`: `dma_sync_single_for_device()` before reading `.length`
- `wait_for_transfer()`: `dma_sync_single_for_cpu()` after completion

`DMA_BIDIRECTIONAL` is used because the proxy programs `DMA_MEM_TO_DEV` for both
channels. After the fix `MM2S_LEN` and `S2MM_LEN` both read `0x1000`.

## Third defect (harness): the ioctl index must not live on the stack

`dma_proxy`'s `FINISH_XFER` path writes the transfer length back through the
`ioctl` argument pointer on this kernel. Passing `&stack_int` corrupted the
neighbouring stack slots and produced wild buffer indices (4096) and
out-of-range kernel writes. Keep the argument in a dedicated global.

## RTL fix: only shift while a run is armed

The engine shifted any word that reached the TX FIFO, so a chunk's TDO words
paired with leftovers from the previous chunk and the run ended one word short
of TLAST. Added to `jtag_ctrl.v`:

```verilog
/* only shift while software has armed a run */
wire stream_go = !dma_en || (dmaw_left != 32'd0);
...
S_IDLE: if (stream_go && !tx_empty_x && !rx_full_x) begin ...
```

The register path (`dma_en = 0`) is unaffected. Timing after the change:
WNS +1.580 ns, WHS +0.045 ns.

## Result: DMA streaming works

`dmaprobe -d 5 -n 1024`, 16 chunks of 1024 words, rotating the three proxy
buffers, with the polled handshake:

```
step3: 16/16 chunks ok, 0.0571 s -> 9.18 Mbit/s (wire ceiling 10.00 at div 5)
after 0x44(left)=0 0x48(drop)=0 STATUS=00000080 tx_free=128 rx_used=0
      status rx=0 tx=0 | 0/1024 words still sentinel
```

- every chunk consumed its armed word count exactly (`0x44` back to 0)
- **zero** `stream_drop` (no RX-FIFO overflow)
- all 1024 received words per chunk were written (none left at the sentinel)
- 9.18 Mbit/s vs 10.00 ceiling; the ~8% gap is per-chunk setup
  (flush + arm + two START ioctls + FINISH), 0.29 ms of each 3.28 ms chunk.
  Overlapping the next chunk's setup with the current shift would recover it.

Two things matter for correctness and are easy to get wrong:

1. **Poll the DMA status; do not trust the blocking `FINISH_XFER`** as the
   handshake. On this kernel it can return before the channel is done, which
   made 16 chunks "complete" in 5 ms while moving nothing.
2. **Validate received data**, not just `status`: an untouched status field
   reads 0 = `PROXY_NO_ERROR`, so a no-op looks like 16/16 successes.

## Single-channel DMA server

[`../../tools/xvcserver_dma.c`](../../tools/xvcserver_dma.c) now serves XVC on
port 2543 for **one** engine and moves long TMS=0 runs through `dma_proxy`
instead of the raw `/dev/mem` pool. It is the boot default: the init script and
the web console `control` CGI launch `/usr/bin/xvcserver_dma -a 0x43C00000 -d 5 -m`.

Changes that mattered, in order of size:

| change | effect |
|---|---|
| proxy buffers 4 KiB -> 64 KiB -> 256 KiB | amortises arm/ioctl/poll per chunk: 9.19 -> 9.54 -> 10.00 Mbit/s shift rate |
| pipelined chunks: start N, fill N+1, copy N-1 while N shifts | overlaps all CPU-side work with the shift |
| `get_word`/`put_word` bit-loop -> 5-byte window | fill+copy 16 ms -> ~0 for a 262144-bit run (was 6.0 Mbit/s) |
| poll `0x44`/`S2MM_DMASR` with a 20 us backoff | a tight uncached-AXI read loop slowed the shift; 30 ms -> 26 ms per 256 Kbit |
| 64 KiB buffers instead of the uncached pool | fill/copy no longer exceed the shift time |

Measured with [`../../tools/xvc_binary_client.py`](../../tools/xvc_binary_client.py)
(the binary XAPP1251 protocol; `xvc_client.py` speaks the ASCII variant and
cannot talk to this server):

```
4,194,304-bit run:  0.4823 s end to end -> 8.70 Mbit/s
  server-side: dma_bits=4194272  xfers=2  fill=0.00 s  wait=0.41 s  copy=0.01 s
  => shift rate 10.00 Mbit/s - at the wire limit
1,048,576-bit run:  0.1254 s end to end -> 8.36 Mbit/s
  262,144-bit run:  0.0344 s end to end -> 7.63 Mbit/s
IDCODE through XVC: window@9 = 0x14A56093, identical to the direct register read
```

The shift is now at the wire limit; what remains is protocol overhead. An XVC
exchange carries 3x the payload (TMS + TDI in, TDO out), so a 4 Mbit run moves
1.5 MB over TCP - about 60 ms against a 419 ms shift, which is the whole gap.

`chunk_bits=0` in the stats means nothing fell back to the 32-bit register path.
The end-to-end figure is below the shift rate because the XVC exchange moves
3x the payload (TMS + TDI out, TDO back) over TCP.

## End-to-end: programming a real 36 MB device

Vivado drives the server directly (`open_hw_target -xvc_url 192.168.1.113:2543`)
and programs `test_bits/top.bit` (XCKU15P, IDCODE 0x14A56093):

```
=== PROGRAM_MS=34117          (36,343,220 bytes -> 8.52 Mbit/s end to end)
=== idcode after=00010100101001010110000010010011   (device alive)
STATS  dma_bits=290962304 chunk_bits=0 xfers=563 fill=0.00s wait=29.27s copy=0.89s
STATS2 reg_bits=279946 read=0.83s write=0.49s reg=0.07s
```

Phase budget for 36 MB:

| phase | time | note |
|---|---|---|
| shift (`wait`) | 29.27 s | 9.94 Mbit/s, the 10.00 wire limit |
| TDO copy out | 0.89 s | put_word over 9M words |
| socket read | 0.83 s | 72 MB of TMS+TDI |
| socket write | 0.49 s | 36 MB of TDO |
| register path | 0.07 s | only 0.28 Mbit is not a TMS=0 run |

`chunk_bits=0` means the DMA path was used throughout with no fallback.

For comparison, the FIFO path measured 32.62 s and the register path 50.29 s
for the same 36 MB job. The DMA server is ~4% slower end-to-end than the FIFO
path but shifts at the wire limit; its cost is the extra TDO copy out of the
proxy buffer. **CPU is the open question**: the server child burned ~10.5 s for
a 34 s program (~30% of one core), against ~3 s of "essential" CPU reported for
the FIFO path. That was resolved: timing every phase showed the fill is only
0.13 s and the 2.6 s "unaccounted" time was the server blocked waiting for
Vivado's next shift (4.13 s measured), not server work. CPU came down to 5.17 s
(0.57 us/word, 15.5% duty) after the TDO packer rewrite.

## Note: this bitstream is DMA-only

The `stream_go` gate means the engine only shifts stream data while `0x44` is
armed. On the DMA bitstream `dma_en` is tied high, so the register/FIFO stream
path (`xvcserver_dma` without `-m`) no longer shifts at all - it times out and
leaves the device unconfigured ("End of startup status: LOW"). Serve this
bitstream with `-m` only.

## Final measured state (2026-11-15, 10 MHz)

| workload | C (this design) | note |
|---|---|---|
| 36 MB configuration, 3 runs | **33.377 s** (sigma 30 ms) | shift 29.28 s = 9.94 Mbit/s; no fallback |
| SPI bridge, 7 MB | **8.40 s** | fastest of A/B/C - few large shifts |
| flash, 34.7 MB erase+program+verify | **1293.2 s = 21 min 33 s** | verified; 360,680 transfers |
| CPU | 5.17 s/run = 0.57 us/word, 15.5% duty | was 6.47 s before the packer fix |

Deployed: `image.ub bfcd3b3a…`, `BOOT.BIN fd2b51f0…`, server
`xvcserver_dma -a 0x43C00000 -d 5 -m` on 2543. Rollback: `image.ub.xvc2` /
`BOOT.BIN.xvc2`.

Overlapping the socket traffic with the shift was implemented and measured - it
lost at every block size (see the [A/B/C table in the top-level
README](../../../README.md#single-channel-comparison-projects)). The budget at
10 MHz is 85% shift, 12% client round-trip idle, ~3% TCP.

## Still to do

1. The server still opens 2543..2554 (12 listeners inherited from the
   multi-channel design); only 2543 is backed by this bitstream.
2. The 13-engine product server (`xvcserver_g1`) still cannot run on this
   bitstream - it mmaps the broadcast block at `0x43CD0000`.
3. TCK is deliberately held at 10 MHz. 25 MHz was measured working (16.69 s for
   the same 36 MB job, 5 runs, sigma 20 ms); the server exposes it as `-d 2`.
