# PetaLinux 2022.2 User Manual (VirtualBox VM `u22`)

> Scope: XJSM-P12-Z7000 (AX7Z020B / XC7Z020-2CLG400, Zynq-7000)
> Toolchain: Xilinx PetaLinux 2022.2, already installed inside the VirtualBox VM `u22` (Ubuntu 22.04)
> Manual version: 2026-10-31, covering the completed installation + end-to-end verification

---

## 0. Shortest path for "the next session that builds an image"

```bash
# 1) Confirm the VM is running (run on the host)
VBoxManage list runningvms          # should contain "u22"

# 2) Enter the guest to run commands (see Section 2, use the guestcontrol wrapper function g)

# 3) Build inside the guest (interactive terminal or the g wrapper both work)
cd ~/pl_val/XJSM-P12-Z7000
source /opt/Xilinx/petalinux/2022.2/settings.sh      # already sourced in interactive bash
petalinux-build 2>&1 | tee ~/build-$(date +%F-%H%M).log

# 4) Package the boot files
petalinux-package --boot --fsbl images/linux/zynq_fsbl.elf \
    --fpga images/linux/system.bit --u-boot --force
# Output: images/linux/BOOT.BIN
```

The first full build is estimated at **40–120 minutes** (12 vCPU / 22 GB RAM, needs network access to download sources).
If you only need `BOOT.BIN`, build just the required components first; see Section 7.

---

## 1. Environment inventory (measured values)

| Item | Value |
|---|---|
| VM name / UUID | `u22` / `f6671513-92f8-42cd-8878-ca3e604cbb2f` |
| Guest OS | Ubuntu 22.04 LTS, kernel `6.8.0-138-generic` |
| Resources | 12 vCPU, 24000 MB RAM (22 GB visible in the guest), 504 GB disk |
| Guest login user | `iheper` (**ask the user for the password; this manual does not store it**) |
| PetaLinux install path | `/opt/Xilinx/petalinux/2022.2` (11 GB, vendor 2022.2) |
| Installed platform sources | `arm` (Zynq-7000), `aarch64` (ZynqMP/Versal), `microblaze`, `aarch64_dt` |
| Environment script | `/opt/Xilinx/petalinux/2022.2/settings.sh` (already added to `~/.bashrc`) |
| Shared folder (the whole USB drive) | `/media/sf_a435849f-51ca-4a93-abc2-5d48c0bc1de3` (user already added to the `vboxsf` group) |
| Verification project | `~/pl_val/XJSM-P12-Z7000` (configured with the project XSA, kernel has run `do_configure`) |
| XSA (copy inside the guest) | `~/pl_val/xsa/system.xsa` (source: host `xvc/out/system.xsa`) |
| TFTP service | `tftpd-hpa` installed and started, root directory `/tftpboot` (0777) |
| Network | NAT (`10.0.2.15`), Internet access available; host `127.0.0.1:2222` forwarded to guest port 22 |
| Free disk space | 37 GB used / 440 GB available |

> ⚠️ PetaLinux **cannot run as root** (both installation and building must be done as the regular user `iheper`). `sudo` is used only for system packages, the owner of `/opt`, and similar.

### 1.1 Second VM: `u20` (Ubuntu 20.04, officially supported release)

The same toolchain is also installed on **`u20`**; **prefer this machine** (20.04 is the officially supported OS for 2022.2):

| Item | u20 |
|---|---|
| Guest OS | Ubuntu 20.04.6 LTS, kernel `5.15.0-139-generic` |
| Resources | 12 vCPU, 20000 MB RAM, 250 GB disk (207 GB free) |
| User / password | `iheper` / same as above (ask the user) |
| PetaLinux | `/opt/Xilinx/petalinux/2022.2` (11 GB, includes `arm/aarch64/microblaze`) |
| Extra components | **both `components/yocto/buildtools` and `buildtools_extended` are installed** (only exists on officially supported 20.04) |
| Verification project | `~/pl_val/XJSM-P12-Z7000` (XSA imported, kernel `do_configure` passed, 7.5 GB) |
| TFTP | `tftpd-hpa` running, root directory `/tftpboot` |

**Key differences between u20 and u22**:

1. **The first build is far faster**: on u22 the kernel `do_configure` has to compile 437 native tasks on the spot (about 8 minutes);
   on u20, because `buildtools*` is pre-installed, only 11 of the 437 tasks actually execute (about 3 minutes). A full build is correspondingly much faster.
2. **apt sources fixed**: u20's initial `sources.list` contained only `focal` and was missing `focal-updates`, so
   `libsdl1.2-dev` (which depends on `libasound2-dev`/`libpulse-dev`) could not be installed. It was backed up as
   `/etc/apt/sources.list.bak.*` and changed to the full four-section USTC mirror (focal / updates / backports / security).
3. Both print `WARNING: This is not a supported OS`; **this is a false positive of the installer's own check** (even 20.04, the officially supported release, reports it),
   it does not affect the build — just ignore it.

> The two VMs do not interfere with each other and can be used as needed; do not put projects in the shared folder, put them under each VM's own `~/`.

### 1.2 Additional PetaLinux 2023.1 installation on u20 (coexisting with 2022.2)

On 2026-11-01, **PetaLinux 2023.1** was additionally installed on u20 (installer `petalinux-v2023.1-05012318-installer.run`,
12 GB in total), coexisting with the existing 2022.2:

| Item | Value |
|---|---|
| Install path | `/opt/Xilinx/petalinux/2023.1` (12 GB) / `/opt/Xilinx/petalinux/2022.2` (11 GB) |
| Components | both `buildtools` and `buildtools_extended` installed (officially supported on 20.04) |
| Default environment | `~/.bashrc` still sources **2022.2** (left unchanged) |
| Switching to 2023.1 | `source /opt/Xilinx/petalinux/2023.1/settings.sh`, or the newly added `pl2023` alias |
| Verification project | `~/pl_val31/XJSM-P12-Z7000` (XSA imported, kernel `do_configure`: all 619 tasks succeeded, about 11 minutes) |

**Note**: sourcing 2023.1 in a terminal that has already sourced 2022.2 **stacks** the PATH. To cleanly use only 2023.1:

```bash
bash --noprofile --norc          # clean shell, does not load 2022.2 from .bashrc
source /opt/Xilinx/petalinux/2023.1/settings.sh
```

Or change `2022.2` on line 118 of `~/.bashrc` to `2023.1`, making 2023.1 the default.

The installation steps are exactly the same as for 2022.2 (non-root, license accepted automatically, `-d /opt/Xilinx/petalinux/2023.1`),
dependencies need not be reinstalled; the installer likewise first reports `WARNING: This is not a supported OS` (false positive).

---

## 2. How to enter the VM and run commands

### Option A: VirtualBox GUI (recommended for manual operation)

Open VirtualBox → select `u22` → "Display" / double-click to open the window (the VM currently runs headless, so you can connect directly).
In the terminal, `petalinux-*` is already on the PATH automatically (`~/.bashrc` has sourced settings.sh).

If the VM is powered off: `VBoxManage startvm u22 --type gui` (or click Start in the GUI).

### Option B: `VBoxManage guestcontrol` from the host (for automation / when there is no GUI)

Guest Additions is installed, so commands can be executed remotely. **Two pitfalls you must know**:

1. `run` does not capture stdout/stderr (returns `VERR_NOT_IMPLEMENTED`) → command output must be redirected to a guest file and then retrieved with `copyfrom`.
2. There is no TTY → **the `petalinux-config` menuconfig interface cannot be used interactively** (see the workaround in Section 6.3).

Paste the following functions into the host's bash (ask the user for the password and fill it into `GUEST_PW`):

```bash
export GUEST_PW='<login password>'

# Run one command as iheper inside the guest and print the result
g() {
  printf '%s\n' "$1" > /tmp/_g.sh
  VBoxManage guestcontrol u22 copyto /tmp/_g.sh /tmp/_g.sh \
      --username=iheper --password="$GUEST_PW" >/dev/null 2>&1
  VBoxManage guestcontrol u22 run --exe=/bin/bash --username=iheper \
      --password="$GUEST_PW" --quiet --wait-stdout -- /tmp/_g.sh 2>&1 \
      | grep -v 'stdout handle\|stderr handle'
}

# Retrieve a file from the guest to the host
gget() {  # gget <guest_path> <host_path>
  VBoxManage guestcontrol u22 copyfrom "$1" "$2" \
      --username=iheper --password="$GUEST_PW" >/dev/null 2>&1
  cat "$2"
}
```

Usage example (note: do not put commands that need interaction into the arguments of `g`):

```bash
g 'cd ~/pl_val/XJSM-P12-Z7000 && source /opt/Xilinx/petalinux/2022.2/settings.sh >/dev/null && petalinux-build > /tmp/build.log 2>&1; echo rc=$? >> /tmp/build.log'
gget /tmp/build.log /tmp/build.log     # retrieve and print
```

For long tasks, it is better to poll the log after `g` returns, or to start the task in the guest background with `nohup` first:

```bash
g 'cd ~/pl_val/XJSM-P12-Z7000 && source /opt/Xilinx/petalinux/2022.2/settings.sh >/dev/null && nohup bash -c "petalinux-build > /tmp/build.log 2>&1; echo DONE_rc=\$? >> /tmp/build.log" >/dev/null 2>&1 & echo started'
```

Check progress repeatedly with `gget /tmp/build.log /tmp/build.log` (same effect as `tail -f`).

### Option C: SSH (optional, requires sshd first)

The VM has no SSH service installed, but port forwarding is already in place. If needed, in the guest:

```bash
sudo apt-get install -y openssh-server
```

Afterwards, from the host: `ssh -p 2222 iheper@127.0.0.1` (key or password both work).
Note: `sudo` requires a password; `echo "$PW" | sudo -S <cmd>` can be used inside scripts.

---

## 3. Environment variables

Takes effect automatically in interactive bash (`~/.bashrc` ends with `source /opt/Xilinx/petalinux/2022.2/settings.sh`).
Non-interactive scripts and commands run through `guestcontrol` **must source it explicitly**:

```bash
source /opt/Xilinx/petalinux/2022.2/settings.sh
echo $PETALINUX        # /opt/Xilinx/petalinux/2022.2
```

`settings.sh` performs an environment self-check each time; a normal run produces only one warning (22.04 is not officially supported):

```
PetaLinux environment set to '/opt/Xilinx/petalinux/2022.2'
WARNING: This is not a supported OS
INFO: Checking free disk space
INFO: Checking installed tools
INFO: Checking installed development libraries
INFO: Checking network and other services
```

---

## 4. Status of the existing project

`~/pl_val/XJSM-P12-Z7000` is the real project I created to verify the toolchain (15 GB including build cache):

| Item | Value |
|---|---|
| Template | `--template zynq` (Zynq-7000) |
| Hardware description | `~/pl_val/xsa/system.xsa` imported (from `xvc/out/`) |
| `CONFIG_YOCTO_MACHINE_NAME` | `zynq-generic` |
| `CONFIG_SUBSYSTEM_HOSTNAME` | `XJSM-P12-Z7000` |
| `CONFIG_SUBSYSTEM_ROOTFS_*` | currently **INITRD** (ramdisk); see 6.2 if you want SD-card ext4 |
| Built so far | only `kernel -x do_configure` (for verification), **no `images/linux` artifacts yet** |

> To start from a clean state: delete `build/` (`rm -rf ~/pl_val/XJSM-P12-Z7000/build`) and run `petalinux-build` again.
> To switch to a new XSA: re-run `petalinux-config --get-hw-description=...` (this overwrites the hardware-related configuration).

---

## 5. Complete flow for creating a project from scratch

```bash
source /opt/Xilinx/petalinux/2022.2/settings.sh

mkdir -p ~/projects && cd ~/projects
petalinux-create -t project -n XJSM-P12-Z7000 --template zynq
cd XJSM-P12-Z7000
```

### 5.1 Import the Vivado hardware description (XSA)

The XSA on the host enters the guest through the shared folder:

```bash
mkdir -p ~/projects/xsa
sg vboxsf -c "cp /media/sf_a435849f-51ca-4a93-abc2-5d48c0bc1de3/work/XJSM-P12-Z7000/xvc/out/system.xsa ~/projects/xsa/"
```

(`sg vboxsf` is required; it works even when the current shell is not directly in the `vboxsf` group — `sg` elevates to that group according to `/etc/group`.)

```bash
cd ~/projects/XJSM-P12-Z7000
petalinux-config --get-hw-description=~/projects/xsa --silentconfig
```

Success indicators: `[INFO] Sourcing buildtools` / `INFO: Getting hardware description...`, plus generation of
`project-spec/configs/config`, `project-spec/configs/rootfs_config`, `project-spec/hw-description/`.

### 5.2 Configuration (three ways, pick by scenario)

| Scenario | Command |
|---|---|
| Interactive (GUI/TTY available) | `petalinux-config`, `petalinux-config -c rootfs`, `-c kernel`, `-c u-boot`, `-c busybox` |
| All defaults, scripted | `petalinux-config --silentconfig` |
| Precise config edits, no TTY | Edit `project-spec/configs/config` directly, then `petalinux-config --silentconfig` (**verified: manual edits are preserved**) |

### 5.3 Building

```bash
petalinux-build 2>&1 | tee ~/build-$(date +%F-%H%M).log
```

Build only one component (faster incremental builds):

```bash
petalinux-build -c kernel
petalinux-build -c rootfs
petalinux-build -c u-boot
petalinux-build -c device-tree
petalinux-build -c <myapp>
petalinux-build -c kernel -x do_listtasks    # list the available bitbake tasks
petalinux-build -c <comp> -x <task> -f      # force a task to run again
```

### 5.4 Packaging the boot files (Zynq-7000)

```bash
cd ~/projects/XJSM-P12-Z7000
petalinux-package --boot --fsbl images/linux/zynq_fsbl.elf \
    --fpga images/linux/system.bit --u-boot --force
```

The output is `images/linux/BOOT.BIN` (= FSBL + bitstream + U-Boot).
Other options: `--dtb <dtb>`, `--kernel <image.ub>`, `--format MCS` (Flash), `--boot-script <boot.scr>`.

### 5.5 Generating an SD card image / SDK

```bash
# Full-disk SD card image (zynq default bootfiles: BOOT.BIN, uImage, boot.scr)
petalinux-package --wic                        # → images/linux/petalinux-sdimage.wic
petalinux-package --wic -o ~/out/              # specify the output directory
petalinux-package --wic -e "system.dtb"        # extra files

# SDK (cross-compile user applications)
petalinux-build --sdk                          # → images/linux/sdk.sh
petalinux-package --sysroot                     # install into images/linux/sdk/
```

### 5.6 Boot / debug

```bash
petalinux-boot --jtag --prebuilt 1     # FSBL+bitstream
petalinux-boot --jtag --prebuilt 2     # U-Boot
petalinux-boot --jtag --prebuilt 3     # Linux
petalinux-boot --qemu --prebuilt 3     # QEMU emulation (verify without hardware)
```

---

## 6. Quick reference for common configuration items

### 6.1 Project level (`petalinux-config` → menu structure)

| Goal | Menu path / config item |
|---|---|
| Change the hostname | `CONFIG_SUBSYSTEM_HOSTNAME` (`Yocto Settings` → or edit the config directly) |
| Serial console | `CONFIG_SUBSYSTEM_SERIAL_*`, `CONFIG_SUBSYSTEM_BAUDRATE` |
| Kernel boot arguments | `CONFIG_SUBSYSTEM_BOOTARGS` |
| Network | `CONFIG_SUBSYSTEM_ETHERNET_*`, `CONFIG_SUBSYSTEM_IP_ADDRESS` |
| Root filesystem type | `CONFIG_SUBSYSTEM_ROOTFS_*` (INITRD / INITRAMFS / EXT4 / JFFS2 / NFS / UBIFS) |
| u-boot environment | `petalinux-config -c u-boot` |
| Kernel | `petalinux-config -c kernel` |

### 6.2 Switching to an SD-card ext4 root filesystem (a common requirement for this board)

The current project uses INITRD (the whole ramdisk lives in RAM and is lost on power-off). To switch to SD-card persistence:

```bash
cd ~/projects/XJSM-P12-Z7000
sed -i 's/^CONFIG_SUBSYSTEM_ROOTFS_INITRD=y/# CONFIG_SUBSYSTEM_ROOTFS_INITRD is not set/' project-spec/configs/config
sed -i 's/^# CONFIG_SUBSYSTEM_ROOTFS_EXT4 is not set/CONFIG_SUBSYSTEM_ROOTFS_EXT4=y/' project-spec/configs/config
petalinux-config --silentconfig        # verified: the manual edits above are preserved
```

After the change you need `rm -rf build`, or at least `petalinux-build -c rootfs -f`, followed by a full build, to obtain an ext4 root filesystem image.
Afterwards use `petalinux-package --wic` to generate an SD image with two partitions (FAT boot + ext4 rootfs).

### 6.3 How to change menuconfig items when there is no TTY

`menuconfig` needs a terminal. Running it under `guestcontrol` fails or hangs. Three workarounds:

1. **Edit `project-spec/configs/config` directly** (recommended, verified); `rootfs` corresponds to `project-spec/configs/rootfs_config`.
2. Fake a TTY with `script` (steadier together with tmux):
   ```bash
   script -qec "petalinux-config -c rootfs" /dev/null
   ```
3. Operate directly in a terminal in the VM GUI (the least effort).

### 6.4 Adding user applications / kernel modules

```bash
petalinux-create -t apps    -n xvcserver --enable      # ← project-spec/meta-user/recipes-apps/
petalinux-create -t modules -n oled      --enable      # ← recipes-modules/
petalinux-build -c xvcserver
```

Put the source code into `project-spec/meta-user/recipes-apps/xvcserver/files/`, then run `petalinux-build`.
To start it automatically at boot on the board: modify `project-spec/meta-user/recipes-apps/<app>/files/<app>.service` or use the systemd configuration in `recipes-core`.

---

## 7. Build artifacts (`images/linux/`)

Typical files after a full Zynq-7000 build:

| File | Description |
|---|---|
| `BOOT.BIN` | FSBL + bitstream + U-Boot, placed in the FAT partition of the SD card |
| `zynq_fsbl.elf` | First-stage boot loader (includes PS initialization) |
| `system.bit` | PL bitstream (from the XSA) |
| `u-boot.elf` / `u-boot.bin` | U-Boot |
| `system.dtb` | Device tree |
| `uImage` | Kernel (traditional Zynq format, used for SD boot) |
| `zImage` | Kernel (another format) |
| `image.ub` | FIT image (kernel+dtb+ramdisk packaged together, used with `--boot --kernel`) |
| `boot.scr` | U-Boot boot script |
| `rootfs.cpio.gz.u-boot` | INITRD root filesystem (current configuration) |
| `rootfs.ext4` / `rootfs.tar.gz` | Root filesystem after switching to EXT4 |
| `sdk.sh` / `sdk/` | Cross-compilation SDK |

Time reference (12 vCPU on this machine): kernel `do_configure` takes about 8 minutes (including 437 native tasks);
a full `petalinux-build` takes about 40–120 minutes, depending on the network (the first run has to pull the kernel/u-boot/rootfs sources).

---

## 8. Cautions & known pitfalls

1. **Do not use root**: both the installer and `petalinux-*` run as `iheper`. Running as root immediately reports
   `Cannot install as root user` (that is how it failed in the past).
2. **`/bin/sh` must be bash**: it has been changed to `ln -sf bash /bin/sh` (it used to point to dash, and `settings.sh` would warn).
3. **"This is not a supported OS"**: PetaLinux 2022.2 officially supports Ubuntu 18.04/20.04, but this installer prints
   **this warning on both 20.04 and 22.04** (measured); it is a false positive, just ignore it. On 22.04 the Yocto side also prints:
   - `Host distribution "ubuntu-22.04" has not been validated...`
   - `Your host glibc version (2.35) is newer than that in uninative (2.34). Disabling uninative...`
   Both can be ignored (437/437 tasks verified successful).
4. **Old libraries such as `libtinfo5`**: available in `universe` on 22.04 and already installed (including i386: `libtinfo5:i386`, `libncurses5:i386`, `libstdc++6:i386`, `zlib1g:i386`).
5. **TFTP warning**: the original install warning `No tftp server found` was resolved by installing `tftpd-hpa` and creating `/tftpboot`;
   `petalinux-build` copies the images into `/tftpboot`, and if the directory does not exist it prints
   `Failed to copy built images to tftp dir: /tftpboot` (now fixed).
6. **Disk**: 440 GB free, enough for one project (about 40–60 GB). Watch the space when several projects coexist.
7. **Network**: builds need outbound Internet access (pulling sources/git). The guest uses NAT, and `apt` points to the USTC mirror.
8. **Shared folder**: `/media/sf_...` belongs to group `vboxsf`; non-interactive shells do not have that group, so `sg vboxsf -c '...'` is needed.
   Also **do not** create projects directly on the shared folder (vboxsf does not support Linux permissions/case sensitivity and performs poorly);
   build on the guest's local disk (`~/` or `/opt`), and use the shared folder only for transferring files.
9. **The first build is very slow**: Yocto first has to compile a batch of host tools such as `python3-native` and `kmod-native`
   (437 tasks); afterwards there is an sstate cache and incremental builds are fast.
10. **The `guestcontrol` stdout pitfall**: see Section 2; output must be written to disk and then retrieved.
11. **Do not put projects on NFS**: on NFS, `petalinux-create` automatically moves `TMPDIR` to `/tmp`; use `--tmpdir` to specify it.

---

## 9. Troubleshooting

| Symptom | Resolution |
|---|---|
| `ERROR: You are not inside a PetaLinux project` | `cd` into the project root first (the level containing `project-spec/`), then run `petalinux-config/build/package` |
| `ERROR: No XSA is found in .../hw-description` | No XSA imported: run `petalinux-config --get-hw-description=<dir>` |
| `ERROR: Hardware description file "" doesn't exist` | Same as above; the directory passed to `--get-hw-description=` contains no `.xsa` |
| bitbake fails | Check `build/config.log`, the logs under `~/.petalinux/`, and `<proj>/build/tmp/work/*/temp/log.do_*` |
| Want a complete restart | `rm -rf build/` (inside the project directory), then `petalinux-build` |
| Only want to re-run a task | `petalinux-build -c <comp> -x <task> -f` |
| The build was interrupted | Simply run `petalinux-build` again; bitbake resumes from where it stopped |
| Out of space | `df -h /`; deleting `build/tmp/work/*/temp` does not save space — deleting `build/` is cleanest |

---

## 10. What this installation did (for rollback/rebuild)

1. `apt-get update` inside the guest, installing about 60 build dependencies (`build-essential`/`gcc-multilib`/`libncurses5-dev`/
   `libtinfo5`(+i386)/`libsdl1.2-dev`/`device-tree-compiler`/`socat`/`python3-pexpect|git|jinja2` etc.), plus `dpkg --add-architecture i386`.
2. The installer was run as `iheper` (**not root**), with the license accepted automatically, installing to `/opt/Xilinx/petalinux/2022.2` (all platforms).
3. `chown -R iheper /opt/Xilinx`; `settings.sh` written into `~/.bashrc`.
4. `ln -sf bash /bin/sh`; installed `tftpd-hpa` and set its root directory to `/tftpboot`.
5. `iheper` added to the `vboxsf` group (shared folder readable).
6. Verified with `xvc/out/system.xsa`: create project → import XSA → `petalinux-build -c kernel -x do_configure` all succeeded.
7. At the VM configuration level, a NAT forwarding rule `ssh,tcp,127.0.0.1,2222,,22` was added (the guest has no sshd; removing it requires shutting down first:
   `VBoxManage modifyvm u22 --natpf1 delete ssh`).

### Installation on u20 (evening of 2026-10-31, same installer)

The steps are exactly the same as for u22 (dependency list, non-root installation, automatic license acceptance, `/bin/sh`→bash, `tftpd-hpa`, `~/.bashrc`),
plus two issues in the VM itself that were fixed:

1. `/etc/apt/sources.list` was missing `focal-updates` → after backing it up, changed to the full four-section USTC mirror; `libsdl1.2-dev` installed successfully.
2. `iheper` added to the `vboxsf` group (shared folder readable).

Verification result: `petalinux-create` → XSA import (`zynq-generic`) → `petalinux-build -c kernel -x do_configure`
**all 437 tasks succeeded** (only 11 really executed; the rest were covered by the pre-installed buildtools), taking about 3 minutes.

> The password is not written to any file; this manual always refers to it as `<login password>` / the environment variable `GUEST_PW`.
