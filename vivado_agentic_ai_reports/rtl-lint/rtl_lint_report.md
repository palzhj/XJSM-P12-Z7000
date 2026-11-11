# RTL Lint Report — XJSM-P12-Z7000 XVC Project

| Item | Value |
|---|---|
| Tool | Vivado 2023.1 |
| Device | xc7z020clg400-2 |
| Top level | system_wrapper (IPI Block Design) |
| Date | 2026-11-03 |
| **Reported by Vivado** | **79 linter messages** |
| **CSV row count** | **79** (consistent ✓) |

---

## 1. Statistics by Rule

| Rule | Count | Share | Meaning |
|---|---|---|---|
| **ASSIGN-10** | 58 | 73.4% | IO bit(s) not read |
| **ASSIGN-5** | 21 | 26.6% | Bit(s) not assigned |

---

## 2. Statistics by File (Hotspots)

| File | Count | Note |
|---|---|---|
| **system.v** | **79** | Vivado IPI auto-generated Block Design wrapper |
| jtag_ctrl.v | **0** | ✅ Hand-written RTL |
| jtag_repeater.v | **0** | ✅ Hand-written RTL |
| jtag_bcast_regs.v | **0** | ✅ Hand-written RTL |

**Conclusion: zero violations in hand-written RTL ✓** — all 79 are in Vivado's auto-generated `system.v`.

---

## 3. Violation Details

### 3.1 ASSIGN-10 — IO bit(s) not read (58)

**Sample** (`system.v:52`):

```
ASSIGN-10,IO bit(s) not read,0,M_ACLK,m00_couplers_imp_1S4FO20,system.v,52
```

**Occurrences**: `m00_couplers_imp_*` .. `m13_couplers_imp_*`, `s00_couplers_imp_*`

**Cause**: The per-port `M_ACLK` input of the AXI Interconnect is driven but not used inside the generated module — this is an inherent pattern of IPI-generated code (the clock runs on the global network, and the module does not "read" that signal internally).

**Severity**: 🟢 Harmless — produced by Vivado's own IP generator, not user code.

**Recommendation**: **Accept / waive** ✓ Do not modify generated code (it is overwritten on every regeneration).

### 3.2 ASSIGN-5 — Bit(s) not assigned (21)

**Sample** (`system.v:2604`):

```
ASSIGN-5,Bit(s) not assigned,0,ps7_DDR_ADDR,system,system.v,2604
ASSIGN-5,Bit(s) not assigned,0,ps7_DDR_BA,system,system.v,2605
ASSIGN-5,Bit(s) not assigned,0,ps7_DDR_CAS_N,system,system.v,2606
...
```

**Occurrences**: `ps7_DDR_*` ports (ADDR, BA, CAS_N, CKE, CK_N, CK_P, CS_N, DM, DQ, DQS, DRSTB, ODT, RAS_N, WE_N ...)

**Cause**: The Zynq PS7 **DDR hard interface** is **not brought out** in the Block Design (DDR is managed directly by the internal PS controller and needs no PL wiring) → these ports are left dangling in the generated wrapper module.

**Severity**: 🟢 Harmless — the standard pattern for Zynq designs.

**Recommendation**: **Accept / waive** ✓

---

## 4. Project-Relevant Checks

| Check | Result |
|---|---|
| Hand-written RTL syntax | ✅ 0 violations |
| Inferred latches (INFER-1/2/3) | ✅ 0 |
| Undriven signals | ✅ 0 |
| Arithmetic overflow | ✅ 0 |
| Reset issues (RESET-2) | ✅ 0 |
| Clock issues (CLOCK-1) | ✅ 0 |

**Key point**: `jtag_ctrl.v`, the file I changed the most this time (adding the `S_BC` state machine, `fifo_clr`, `bcast_sel`), **introduced no lint issues at all** ✓

---

## 5. Recommendations

### Handle immediately
None ✓

### Waivable (recommend creating waivers)
- `ASSIGN-10` × 58 (IPI-generated code)
- `ASSIGN-5` × 21 (Zynq DDR hard interface)

Vivado Tcl:
```tcl
create_waiver -id ASSIGN-10 -description "IPI-generated interconnect clock ports"
create_waiver -id ASSIGN-5  -description "Zynq PS7 DDR hard interface (unused in BD)"
```

### No code changes needed
All violations come from Vivado's auto-generated `system.v`; edits would be overwritten on the next `generate_target`.

---

## 6. Quality Conclusion

| Dimension | Assessment |
|---|---|
| Hand-written RTL quality | 🟢 **Zero lint violations** |
| Violation source | 🟢 100% from auto-generated code |
| Items requiring fixes | **0** |
| Items safely waivable | 79 (all) |

**The RTL in this project passes the lint review ✓**
