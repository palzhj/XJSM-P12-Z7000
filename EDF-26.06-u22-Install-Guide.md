# AMD EDF 26.06 Installation Guide (VirtualBox VM `u22`)

> Version: **AMD Embedded Development Framework 26.06** (based on Yocto Project 4.0 "Scarthgap")
> Release tag: `refs/tags/amd-edf-rel-v26.06` (`yocto-manifests`)
> Official docs: <https://edf.docs.amd.com/en/v26.06/>
> Install location: VM `u22` (Ubuntu 22.04.6 LTS) → `/home/iheper/edf`
> Install date: 2026-10-31

---

## 1. What this is (and how it relates to PetaLinux)

AMD EDF is the **next-generation embedded Linux development framework** that
replaces PetaLinux, built on the open-source Yocto Project. Key differences from
PetaLinux:

| | PetaLinux (2022.2) | EDF (26.06) |
|---|---|---|
| Delivery | `.run` installer + BSP | **Yocto source workspace** (`repo` pulls 18 layers) |
| Build command | `petalinux-build` | `bitbake <target>` |
| Configuration | `petalinux-config` menuconfig | Yocto `local.conf` / machine conf / `gen-machine-conf` |
| Outputs | `images/linux/BOOT.BIN`… | `xilinx-bootbin`, `edf-linux-disk-image`, etc. |

> EDF ships with the AMD toolchain starting from **Vivado 2025.1**; PetaLinux is on
> an EOL path.

---

## 2. Result

| Item | Value |
|---|---|
| Workspace | `/home/iheper/edf` (contains `sources/`, `build/`, `edf-init-build-env`) |
| Source layers | 18 + `meta-xilinx-core/gen-machine-conf` (managed by repo) |
| Build directory | `/home/iheper/edf/build` (initialized, `MACHINE ??= "qemuarm64"`, `DISTRO = amd-edf"`) |
| BitBake | 2.8.1 |
| repo | v2.71 (`/home/iheper/bin/repo`, added to PATH in `~/.bashrc`) |
| gen-machine-conf | v2026.1 (generates machine conf from XSA/SDT) |
| Disk | Workspace 1.9 GB (after parsing cache); ~435 GB free on the root partition |
| Verification | `bitbake -p` parses **15212 recipes, 0 errors** |

### Available machines (excerpt)

```
zynq      : zynq-zc702-sdt-full, zynq-zc706-sdt-full          ← Zynq-7000
zynqmp    : zynqmp-zcu102/104/106/111/208-sdt-full, k26/k24 series
versal    : vek280, vck190, vmk180 etc.
embedded-plus / microblaze-v / zephyr etc.
```

---

## 3. Key pitfalls during installation (important)

1. **The `repo` tool source is blocked**: by default `repo init` downloads the repo
   tool itself from `gerrit.googlesource.com`, which is **refused** on this network.
   Workaround: download the repo launcher, then initialize through the Tsinghua mirror:

   ```bash
   curl https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo && chmod a+x ~/bin/repo
   repo init -u https://github.com/Xilinx/yocto-manifests.git \
             -b refs/tags/amd-edf-rel-v26.06 \
             -m default-edf.xml \
             --repo-url=https://mirrors.tuna.tsinghua.edu.cn/git/git-repo
   ```

   `github.com/Xilinx/*` is reachable directly (measured ~10 MB/s); only
   googlesource is unreachable.

2. **Host dependencies** (already installed): `gawk wget git diffstat unzip texinfo gcc build-essential chrpath socat cpio
   python3 python3-pip python3-pexpect python3-git python3-jinja2 python3-subunit python3-testtools
   zstd lz4 file locales bc rsync libsdl1.2-dev xterm pkg-config libssl-dev bmap-tools`,
   plus `locale-gen en_US.UTF-8` and `git config --global user.name/user.email`.

3. **Ubuntu 22.04 does not need the buildtools extras package** (EDF 26.06 officially
   supports 22.04.5; only if the host tools are too old do you need
   `sources/poky/scripts/install-buildtools`).

---

## 4. Usage

```bash
cd ~/edf
source ./edf-init-build-env        # enter build/, set up the bitbake environment

# Build with the official reference board (Zynq-7000)
MACHINE=zynq-zc702-sdt-full bitbake xilinx-bootbin
MACHINE=zynq-zc702-sdt-full bitbake edf-linux-disk-image

# Other common targets
#   edf-linux-full-cmdline / edf-image-everything / core-image-minimal
```

**Custom board (XJSM-P12-Z7000 / XC7Z020)**: generate a machine conf from the XSA,
then build:

```bash
cd ~/edf && source ./edf-init-build-env
gen-machine-conf --hw-description ~/pl_val/xsa/system.xsa \
                 --soc-family zynq \
                 --machine-name xjsm-p12-z7000 \
                 parse-xsa
# The generated .conf is written into build/conf/ (or the local.conf given by -l)
MACHINE=xjsm-p12-z7000 bitbake xilinx-bootbin
MACHINE=xjsm-p12-z7000 bitbake edf-linux-disk-image
```

> Detailed options: `gen-machine-conf parse-xsa --help`, `parse-sdt --help`.

### First-build notes

- Upstream sources (kernel/u-boot/rootfs) are downloaded **during** the build; the
  first full build may take **1–3 hours** (12 vCPU).
- Set a local `DL_DIR` / `SSTATE_DIR` per the official docs to reuse caches and avoid
  repeated downloads:
  <https://edf.docs.amd.com/en/v26.06/yocto/optimizing-build-time.html>
- Build outputs land in `build/tmp/deploy/images/<MACHINE>/`.

---

## 5. Current status / next steps

- VM `u22` is **running** (headless). Open the VirtualBox window to use it.
- The old PetaLinux 2022.2 has been uninstalled (see the other manual); only EDF
  remains on this machine.
- Not done yet: no full image build has been run; `build/` only holds the recipe
  parsing cache (PRServer database).
- Project data `~/pl_val` (29 GB, including previous PetaLinux build outputs) and
  `/tftpboot` still exist; unrelated to EDF and safe to delete.
