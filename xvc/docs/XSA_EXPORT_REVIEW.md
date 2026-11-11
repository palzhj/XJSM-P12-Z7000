# Hardware Description (XSA) Export Flow Review (per vendor manual)

> 2026-11-01 · Based on `cource_s1_ALINX_ZYNQ(AX7Z010_AX7Z020)2023_Development_Platform_Fundamentals_Tutorial_V1.01.pdf`

## 1. Flow specified by the vendor manual

### 1. After completing the Block Design (§28–29, pages 95–98)

```
Generate Output Products
  → Create HDL Wrapper
  → Run Synthesis
  → Run Implementation
  → Generate Bitstream
  → File → Export → Export Hardware...
      ☑ Include bitstream          ← must be checked when the PL is used
  → outputs xxx.xsa
```

### 2. Another emphasis (line 2911)

> "**After** generating the bitstream, export the hardware and **select include bitstream**"

### 3. Order when generating BOOT.BIN (line 2911)

> "The file order of Boot Image Partitions is **fsbl, bitstream, app**; do not get the order wrong"

---

## 2. Our implementation (`build_jtag12p.tcl`)

```tcl
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
write_hw_platform -fixed -include_bit -force $out_dir/system.xsa
```

| Vendor step | Our equivalent | Status |
|---|---|---|
| Generate Output Products | `generate_target all` | ✅ |
| Create HDL Wrapper | `make_wrapper -top` | ✅ |
| Synthesis + Implementation | `launch_runs impl_1` | ✅ |
| Generate Bitstream | `-to_step write_bitstream` | ✅ |
| Export Hardware (with bitstream) | `write_hw_platform -fixed -include_bit` | ✅ |

**Conclusion: the export flow matches the vendor manual** ✅

---

## 3. Validation of the generated XSA

```
system.xsa  535,379 bytes, containing:
  system.bit      4,045,674  ✅ bitstream
  system.hwh        338,604  ✅ hardware description
  ps7_init.c        312,369  ✅ PS initialization
  ps7_init.tcl       24,922
  sysdef.xml / xsa.json / system.bda / xsa.xml
```

`system.hwh` header:

```xml
<EDKSYSTEM EDWVERSION="1.2" VIVADOVERSION="2023.1">
  <SYSTEMINFO ARCH="zynq" DEVICE="7z020" NAME="system" PACKAGE="clg400" SPEEDGRADE="-2"/>
```

The `MODULE` entries include all 12 `jtag_ctrl` + `axi` + `ps7` ✅
and contain the keywords `SDIO`×19, `UART`×31, `ENET`×41 ✅

**The hardware description itself is complete** ✅

---

## 4. But PetaLinux still does not detect the peripherals ❌

| Symptom | Evidence |
|---|---|
| Project config is all `MANUAL_SELECT` | `CONFIG_SUBSYSTEM_PRIMARY_SD_MANUAL_SELECT=y` and 5 similar entries |
| Manual config edits get reset | Restored to the original after running `petalinux-build` |
| FSBL BSP generation fails | `Hsi 55-1442 domain create ... -support-app` |
| DT missing chosen/bootargs | Fixed separately (see system-user.dtsi) |

### Differences still to verify

1. **The `-fixed` flag** — the vendor goes through the GUI's "Export Hardware", which by default exports a
   *post-implementation* platform; `-fixed` means the same thing, but it is worth trying once **without `-fixed`**
2. **The HWH BOM header** — our `system.hwh` starts with a UTF-8 BOM (`EF BB BF`),
   while the vendor toolchain output probably does not; if PetaLinux's parser is incompatible it may drop nodes
3. **The PS7 UART selection** — ours is `EN_UART0=0 / EN_UART1=1` (console on UART1);
   the vendor BSP also uses `ps7_uart_1`, consistent ✅
4. **Export timing** — the vendor exports in the GUI, which implies "Open Implemented Design";
   we write the file directly with `write_hw_platform`

---

## 5. Suggested verification steps

```tcl
# 1) export again without -fixed
write_hw_platform -include_bit -force system_nofix.xsa

# 2) strip the BOM from the HWH
#    (extract the xsa → rewrite the first 3 bytes of system.hwh → repack)

# 3) create a project with the new XSA and inspect the config
petalinux-create -t project -n t1 --template zynq
petalinux-config --get-hw-description=<dir> --silentconfig
grep PRIMARY_SD project-spec/configs/config
# expect to see CONFIG_SUBSYSTEM_PRIMARY_SD_PS7_SD_0_SELECT=y
```

Whichever step makes `PRIMARY_SD_PS7_SD_0_SELECT` appear is where the root cause lies.
