# Known Issues

This document summarizes the issues in this project that are currently unresolved or that need special attention. For build/usage steps see
[../README.md](../README.md); for the verification evidence for each item see [STATUS.md](STATUS.md).

| ID | Issue | Impact | Status |
|---|---|---|---|
| [KI-1](#ki-1-ila-not-shown-over-xvc-done-status--0) | Vivado cannot see the ILA over XVC (`DONE status = 0`) | Cannot view waveforms remotely; local JTAG only | Unresolved (needs external support) |
| [KI-2](#ki-2-xvc-often-cannot-connect-after-downloading-the-bitstream-with-a-jtag-cable) | XVC cannot connect after downloading the bitstream with a cable | Power-cycle to let FSBL configure PL before remote debugging | Root cause identified, workaround available |
| [KI-3](#ki-3-host-ubuntu-2604-cannot-build-petalinux-20222-directly) | Host distribution too new, PetaLinux 2022.2 fails to build directly | Containerized build only | Worked around (see README §7) |

---

## KI-1: ILA Not Shown Over XVC (`DONE status = 0`)

### Symptoms

Vivado can enumerate the device over XVC, but then reports:

```
INFO: [Labtools 27-1435] Device debug_bridge (JTAG device index = 0)
      is not programmed (DONE status = 0)
WARNING: [Labtoolstcl 44-130] No matching hw_ilas were found.
```

`get_hw_ilas` returns empty, and it is still empty after specifying the `.ltx` and running `refresh_hw_device -update_hw_probes true`.

### Impact

- Remote (XVC) access can only confirm the link and the device; no ILA data can be obtained;
- Capturing the ILA over local JTAG works normally (`hw_ila_1`, probe0 captured a 0x85→0x8a increment), so the PL design and the ILA itself are fine.

### Ruled-Out Causes

| Hypothesis | Result |
|---|---|
| Server-side bit order / timing | Fixed: CTRL is a write-only strobe and always reads back 0, so it was changed to "write CTRL, wait `nbits×TCK+200 µs`, then read TDO"; after the fix the IDCODE reads stably as `0x0A003093` |
| Bitstream loading method (JTAG download vs FSBL configuring from BOOT.BIN) | Both reproduce the same DONE=0 |
| `C_BSCAN_MUX=1` (DISABLED) | That mode has no `m0_bscan` port and the BD errors out immediately, so it is not an option |
| `C_BSCAN_MUX=3` (External_BSCAN_Master) + explicit `BSCANE2` | The bitstream builds, but over XVC not even the device enumerates (worse); reverted |
| `C_USE_STARTUP_CLK=true` | Verified the correct way (packed into BOOT.BIN, loaded by FSBL), still DONE=0 |
| Specifying `PROGRAM.FILE` to bypass the DONE check | No effect |
| Cross-checking with another Vivado version | The local 2026.1 has no license and cannot start |
| Clues in PG245 / XAPP1251 | PG245 has nothing about DONE anywhere; XAPP1251 is a different scheme (AXI-Lite→external JTAG pins), and its register layout matches ours |

### Current Analysis

- There is only one device on the chain, IDCODE `0x0A003093` (Debug Hub, `version 0 / part 0xA003 / mfr 0x049`), consistent with what Vivado enumerates;
- The local Debug Bridge IP is only **v3.0** (the KB uses v2.0 / Vivado 2018.3), and the v3.0 parameter table has no DONE-related option at all;
- The `hw_device` properties on the XVC target also have no writable "programmed" flag;
- Therefore this is judged to be a DONE-detection issue with Vivado 2022.2 + debug_bridge v3.0 for Series-7 XVC, i.e. an external dependency.

### What Further Investigation Requires

1. A newer licensed Vivado (2023.x/2024.x) for comparison; or
2. AMD support's answer / the IP configuration from the forum case *Remote ChipScope with XVC and Debug Bridge*.

### Workaround

Capture the ILA over local JTAG: `xvc/tools/jtag_ila_capture.tcl` (verified to capture waveforms; output `out/ila_capture_jtag.csv`).

---

## KI-2: XVC Often Cannot Connect After Downloading the Bitstream with a JTAG Cable

### Symptoms

After using Vivado (Digilent cable) `program_hw_devices`, a subsequent `open_hw_target -xvc_url <board IP>:2542`
often reports `No devices detected on target`; yet after a power cycle (letting FSBL configure PL from BOOT.BIN),
the same XVC connection can read the IDCODE again.

### Analysis

It is presumed that the Debug Bridge's BSCAN mux switches to the fallback channel and latches once it detects external TCK activity,
and does not switch back to the AXI→BSCAN path automatically.

### Workaround

- In XVC debugging scenarios let **FSBL configure PL from BOOT.BIN**; do not download another bitstream with the cable;
- If downloading with the cable is unavoidable, reset/power-cycle after the download before connecting over XVC.

---

## KI-3: Host Ubuntu 26.04 Cannot Build PetaLinux 2022.2 Directly

### Symptoms

- `bitbake`'s fakeroot worker fails to start: `Failed to spawn fakeroot worker ... [Errno 32] Broken pipe`;
- When the project is located under `/run/media/...` it hits the `/run/` entry in bitbake's default `PSEUDO_IGNORE_PATHS`;
- m4 1.4.19 / gmp 6.2.1 fail to compile under GCC 15 + glibc 2.43.

### Workaround

Build inside an Ubuntu 22.04 container (full commands in [../README.md §7](../README.md#7-containerized-build-when-the-host-is-not-a-supported-distribution)), the
key points: install `x11-utils`/`xvfb`/`locale` (needed by xsct), run bitbake as a non-root uid 1000 user,
and remove the `/run/` entry from `PSEUDO_IGNORE_PATHS` in the project's `petalinuxbsp.conf`.

---

# Known Issues List (Updated 2026-11-03)

## 1. Resolved

| # | Issue | Fix | Verification |
|---|---|---|---|
| 1 | Self-built image would not boot | `apply_ps7_config` not called | FSBL 98,312 = vendor ✅ |
| 2 | bootargs empty | `chosen/bootargs` in `system-user.dtsi` | ✅ |
| 3 | User/password | `extrausers` + `ROOT_PASSWORD` | ✅ |
| 4 | Application not in the image | `user-rootfsconfig` filled in with the application name | ✅ |
| 5 | Web "Server stopped" | CGI overridden by `pidof` | ✅ |
| 6 | Operation prompt text | all silenced | ✅ |
| 7 | Network settings not taking effect | CGI auto-fills the default gateway/netmask + verification | ✅ |
| 8 | Checkbox auto-unchecking | removed register synchronization | ✅ |
| 9 | **Broadcast 12× slower** | 13th dedicated broadcast engine | ✅ |
| 10 | **`0x40` register would not write** | separate register block + `==` decoding | ✅ |
| 11 | Broadcast conflicts with a single channel | broadcast has priority: close the gate before kicking | ✅ |
| 12 | Stop does not kill cleanly | `pidof` all PIDs, no longer `awk '{print $1}'` | ✅ |
| 13 | TDO radio button stuck on AMC6 | `setchsel` writes the register, the UI is no longer overwritten by the server | ✅ |
| 14 | Unchecked channels selectable for TDO | clicking the radio button auto-checks that channel | ✅ |
| 15 | Adding to the mask does not drop the connection | CGI computes the newly added bits and kills | ✅ |
| 16 | **48 × TIMING-18** | I/O delay + multicycle constraints | **0** ✅ |
| 17 | AMD ROSS MCP unavailable | install + fix 3 bugs | 40 tools available ✅ |
| 18 | `start_session` always times out | changed to wait for the `Vivado%` prompt | 5.7 s ✅ |
| 19 | `get_utilization` columns misaligned | regex skips 2 intermediate columns | ✅ |
| 20 | `get_timing_summary` all null | parse table rows | ✅ |
| 21 | **TCP shift completely broken** 🔴 | XVC big-endian length not converted (`len` read as 0x08000000) | ✅ fixed (v12) |
| 22 | Session exit race (reconnect rejected) | judged "session already exists" before the child process fully exited | ✅ fixed (wait 1.5s) |
| 23 | Wrong status bit read (broadcast misjudged) | `0x30` state is in bit[9:8], bit[3:2] was read | ✅ fixed |
| 24 | Timeout leaked the bus lock (permanent deadlock) | the timeout branch missed `bus_unlock()` | ✅ fixed |
| 25 | **root password reset by rebuild** | `petalinux-build` regenerates `rootfs_config` | ✅ bbappend + `\$` escaping |
| 26 | OLED ghosting / flicker | 16 concurrent `oled_ip` processes (busybox has no `pkill`) | ✅ differential refresh + single instance |
| 27 | bitbake eats the `$` in hashes | `$6$...` expanded in `EXTRA_USERS_PARAMS` | ✅ must write `\$6\$...` |
| 28 | **UI: with BC fully unchecked one port is always selected** 🔴 | 4 places force min-one + `bcast_en` semantics conflict | ✅ fixed (v13) |
| 29 | Broadcast settings immediately erased by the server | `heal_bcast_if_stale()` clears `bcast_en` | ✅ fixed |
| 30 | Mask stops working after the broadcast session ends | on session exit `wr(0x00,0)` clears `bcast_en` | ✅ fixed |
| 31 | **Vivado can see K7/A7 but quickly loses them** 🔴 | `settck`'s 4-byte period has **no byte-order conversion** → period_ns becomes astronomical → DIV clamped to 65535 → TCK 0.001 MHz | ✅ fixed (v14) |
| 32 | `settck` computed DIV but **never wrote it to hardware** | `do_shift_one` does not write `0x14`, and the single-channel path wrote it only once at startup | ✅ fixed (v14) |
| 33 | Client requesting 1 MHz forced to 10 MHz | `tck_div = g_min_div` overwrote unconditionally | ✅ fixed (`-d` is an upper bound only) |
| 34 | Channels inside the mask still refused after the session ends | since v13 the mask is a **static reservation** (by design) | needs the UI to clear the mask to recover |

## 2. Unresolved / Pending

| # | Issue | Impact | Workaround |
|---|---|---|---|
| A | ~~Image on the card is still the old version~~ | resolved | v12 written to the card (`835b4152` / `d8685f59`) |
| B | **The bitstream running on the board was loaded via JTAG** | lost on power-off | same as A |
| C | External JTAG chain not connected | on-board programming not verified | test after connecting K7/A7 |
| D | `bcast_en` remains set when the broadcast process is SIGKILLed | channel ports temporarily all REFUSE | self-healing on accept ✓ or restart the server |
| E | Connections made within 3 seconds before the server starts may be wrongly refused | very small window | just retry |
| F | FIFO uses distributed RAM (2,350 LUT) | no practical impact | can switch to BRAM to optimize |
| G | 79 lint warnings come from generated code | no practical impact | can create waivers |

## 3. Notes

### 3.1 PetaLinux Overwrites system.bit

`petalinux-build` regenerates `images/linux/system.bit` from the XSA.
A manually replaced bitstream must be copied again **after the build completes**, followed by `petalinux-package`.

### 3.2 Manually Set Registers Are Cleared After Reset

If `devmem` writes `bcast_en` directly without a broadcast session, the self-healing logic on the next `accept` clears it.
This is by design, not a bug.

### 3.3 Clients Must Be Reconnected Manually After a Broadcast Ends

Channel clients kicked during a broadcast session do not reconnect automatically; the target must be reopened manually.

---

## Appendix: Semantics of `bcast_en` (from v13)

| Period | Meaning of `bcast_en` | Problem |
|---|---|---|
| v12 and earlier | "whether a broadcast session is alive" | cleared as soon as the session ends → mask stops working |
| **from v13** | **"whether the UI broadcast mask is non-empty"** | — |

### Why This Switch Is Needed

In the RTL, `bcmask == 0` expands to `0xFFF` (select all):

```verilog
assign bcmask_eff = (bcmask == 12'd0) ? 12'hFFF : bcmask;
```

So **the mask alone cannot express "select no channel at all"** ✗
Instead `CTRL.bit0 (bcast_en)` is used as the master switch:

```
follow[i] = bcast_en & bcmask_eff[i]
```

- mask non-empty → `bcast_en=1` → channels in the mask are taken over ✓
- mask empty → `bcast_en=0` → **no channel is taken over** ✓

### Maintenance Responsibility

| Who | What to do |
|---|---|
| **Web UI** | on every checkbox change → `POST cgi-bin/control?cmd=setbcmask&v=0xNNN` |
| **CGI `setbcmask`** | write `0x43CD0004 = mask`, and write `0x43CD0000 = (mask?1:0)` |
| **Server** | **never rewrite `bcast_en` again** (not on session setup/exit/self-healing) |

### Acceptance

| Mask | Channel status during a broadcast session |
|---|---|
| `0x000` | **all 12/12 connectable** ✓ |
| `0x004` | only ch2 refused ✓ |
| `0xFFF` | all refused ✓ |
