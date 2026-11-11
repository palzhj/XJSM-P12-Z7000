# RTL Lint Report — XJSM-P12-Z7000 XVC Project

| Item | Value |
|---|---|
| Tool | Vivado 2023.1 |
| Device | xc7z020clg400-2 |
| Top | system_wrapper (IPI Block Design) |
| Date | 2026-11-03 |
| **Reported by Vivado** | **79 linter messages** |
| **CSV rows** | **79** (consistent ✓) |

---

## 1. Statistics by rule

| Rule | Count | Share | Meaning |
|---|---|---|---|
| **ASSIGN-10** | 58 | 73.4% | IO bit(s) not read |
| **ASSIGN-5** | 21 | 26.6% | Bit(s) not assigned |

---

## 2. Statistics by file (hot spots)

| File | Count | Notes |
|---|---|---|
| **system.v** | **79** | Vivado IPI auto-generated Block Design wrapper |
| jtag_ctrl.v | **0** | ✅ Hand-written RTL |
| jtag_repeater.v | **0** | ✅ Hand-written RTL |
| jtag_bcast_regs.v | **0** | ✅ Hand-written RTL |

**Conclusion: zero violations in hand-written RTL ✓** — all 79 are in the Vivado auto-generated `system.v`.

---

## 3. Violation details

### 3.1 ASSIGN-10 — IO bit(s) not read (58)

**Sample** (`system.v:52`):

```
ASSIGN-10,IO bit(s) not read,0,M_ACLK,m00_couplers_imp_1S4FO20,system.v,52
```

**Occurrences**: `m00_couplers_imp_*` .. `m13_couplers_imp_*`, `s00_couplers_imp_*`

**Cause**: The per-port `M_ACLK` input of each AXI Interconnect is driven but not used inside the generated module — this is inherent to IPI-generated code (the clock goes through a global net, and the module does not "read" that signal).

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

**Cause**: The **DDR hard interface** of the Zynq PS7 is **not brought out** in the Block Design (DDR is managed directly by the PS internal controller and needs no PL wiring) → these ports are left unconnected in the generated wrapper module.

**Severity**: 🟢 Harmless — standard Zynq design pattern.

**Recommendation**: **Accept / waive** ✓

---

## 4. Project-specific checks

| Check | Result |
|---|---|
| Hand-written RTL syntax | ✅ 0 violations |
| Inferred latches (INFER-1/2/3) | ✅ 0 |
| Undriven signals | ✅ 0 |
| Arithmetic overflow | ✅ 0 |
| Reset issues (RESET-2) | ✅ 0 |
| Clock issues (CLOCK-1) | ✅ 0 |

**Key point**: `jtag_ctrl.v`, the file I changed the most this time (added the `S_BC` state machine, `fifo_clr`, `bcast_sel`), **introduced no lint issues** ✓

---

## 5. Recommendations

### Act immediately
None ✓

### Waivable (creating waivers recommended)
- `ASSIGN-10` × 58 (IPI-generated code)
- `ASSIGN-5` × 21 (Zynq DDR hard interface)

Vivado Tcl:
```tcl
create_waiver -id ASSIGN-10 -description "IPI-generated interconnect clock ports"
create_waiver -id ASSIGN-5  -description "Zynq PS7 DDR hard interface (unused in BD)"
```

### No code changes needed
All violations come from the Vivado auto-generated `system.v`; edits would be overwritten by the next `generate_target`.

---

## 6. Quality conclusion

| Dimension | Assessment |
|---|---|
| Hand-written RTL quality | 🟢 **Zero lint violations** |
| Violation source | 🟢 100% from auto-generated code |
| Items requiring fixes | **0** |
| Items safely waivable | 79 (all) |

**This project's RTL passes lint review ✓**
