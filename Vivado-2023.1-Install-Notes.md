# Vivado 2023.1 Installation Record (this machine / Ubuntu 26.04)

> Install date: 2026-11-01
> Installer: `/run/media/iheper/a435849f-51ca-4a93-abc2-5d48c0bc1de3/software/vivado2023.1/Xilinx_Unified_2023.1_0507_1903.tar.gz` (111 GB)
> Install location: `/opt/Xilinx/Vivado/2023.1` (56 GB, owned by root)

---

## 1. Result

| Item | Value |
|---|---|
| Version | `vivado v2023.1 (64-bit)`, SW Build 3865809 (2023-05-07) |
| Edition | **Vivado ML Enterprise** (all devices, 4708 parts) |
| Install directory | `/opt/Xilinx/Vivado/2023.1` (56 GB) |
| Other versions | `2022.2` (114 GB) and `2026.1` (119 GB) coexist, independent |
| Registration info | `/opt/Xilinx/.xinstall/Vivado_2023.1` |
| License | Reuses `~/.Xilinx/Xilinx.lic`, `license.lic` (no reconfiguration needed) |
| Alias | `vivado2023` (added to `~/.bashrc`) |
| Verification | `vivado -version` works; batch Tcl runs (`TCL_OK version=2023.1`, `part_count=4708`) |

Usage:

```bash
vivado2023                      # alias: source settings64 + launch GUI
# or
source /opt/Xilinx/Vivado/2023.1/.settings64-Vivado.sh
vivado -mode batch -source build.tcl -nojournal -nolog   # headless Tcl
```

---

## 2. Install command (reproducible)

```bash
# 1) Unpack the 111 GB Unified installer (into /var/tmp; delete afterwards)
mkdir -p /var/tmp/xilinx_2023.1
tar -xzf .../Xilinx_Unified_2023.1_0507_1903.tar.gz -C /var/tmp/xilinx_2023.1
cd /var/tmp/xilinx_2023.1/Xilinx_Unified_2023.1_0507_1903

# 2) Batch install (as root; unlike PetaLinux, Vivado needs root)
sudo env DEBUG_ARGS="-XX:-UseContainerSupport" ./xsetup \
     -a XilinxEULA,3rdPartyEULA -b Install \
     -p "Vivado" -e "Vivado ML Enterprise" -l /opt/Xilinx
```

Optional component names (full list from `xsetup -b ConfigGen`):
`Vitis` / `Vivado` (editions: **Vivado ML Standard**, **Vivado ML Enterprise**) / On-Premises Install for Cloud Deployments /
`BootGen` / `Lab Edition` / `Hardware Server` / `Power Design Manager (PDM)` / `PetaLinux` / `Documentation Navigator (Standalone)`.

---

## 3. Two pitfalls you must know

1. **The installer JVM crashes on newer kernels** (hit in this project): running `./xsetup` directly reports

   ```
   java.lang.ExceptionInInitializerError
   Caused by: NullPointerException: Cannot invoke "jdk.internal.platform.CgroupInfo.getMountPoint()" because "anyController" is null
   ```

   Cause: the bundled JDK fails its container detection on cgroup v2. **Fix**: disable container support for the JVM —

   ```bash
   DEBUG_ARGS="-XX:-UseContainerSupport" ./xsetup ...
   ```

   The `xsetup` script natively supports the `DEBUG_ARGS` environment variable
   (it is prepended to the java arguments), so no script edits are needed.

2. **"OS version that is not officially supported"**: this machine runs Ubuntu 26.04,
   while Vivado 2023.1 officially supports up to 22.04. This is only a `WARN`;
   installation completes and succeeds, and both `vivado -version` and batch Tcl work.

---

## 4. Disk

| Stage | Used |
|---|---|
| Before install | 350 GB |
| After unpack | 461 GB |
| Install complete | 603 GB (including the 112 GB unpack directory) |
| After cleanup | **491 GB** (291 GB free) |

> The unpack directory `/var/tmp/xilinx_2023.1` has been deleted; the 111 GB
> tar.gz remains on the USB drive (untouched).

---

## 5. Uninstalling

```bash
cd /opt/Xilinx/.xinstall/Vivado_2023.1
sudo ./xsetup -b Uninstall          # or simply sudo rm -rf /opt/Xilinx/Vivado/2023.1
```
