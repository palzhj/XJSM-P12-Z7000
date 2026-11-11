"""Validate the XVC <-> JTAG bit convention used by xvcserver.

The server turns every XVC vector into <=32-bit register writes: bit k of the
TMS/TDI word is the k-th TCK edge, and bit k of the TDO word is the k-th bit
shifted out. This test drives a small TAP model exactly that way and checks it
reads back the IDCODE, so a bit-order regression fails here instead of on the
board.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

IDCODE = 0x23727093
MAX_CHUNK = 32


def xvc_chunks(bits, n=MAX_CHUNK):
    """Split a bit list into the integer words the server would write."""
    out = []
    for i in range(0, len(bits), n):
        chunk = bits[i:i + n]
        word = 0
        for k, b in enumerate(chunk):
            if b:
                word |= 1 << k
        out.append((len(chunk), word))
    return out


async def shift_chunk(dut, nbits, tms_word, tdi_word):
    """Apply one 32-bit-max chunk and return the TDO word (bit k = k-th edge)."""
    tdo_word = 0
    for k in range(nbits):
        dut.tms.value = (tms_word >> k) & 1
        dut.tdi.value = (tdi_word >> k) & 1
        await Timer(1, units="ns")
        dut.tck.value = 1
        await Timer(1, units="ns")
        bit = int(dut.tdo.value)
        if bit:
            tdo_word |= 1 << k
        dut.tck.value = 0
        await Timer(1, units="ns")
    return tdo_word


async def run_sequence(dut, pairs):
    """pairs: list of (tms, tdi); returns list of tdo bits."""
    out = []
    tms_bits = [p[0] for p in pairs]
    tdi_bits = [p[1] for p in pairs]
    n = len(tms_bits)
    for start in range(0, n, MAX_CHUNK):
        cn = min(MAX_CHUNK, n - start)
        tw = sum(tms_bits[start + k] << k for k in range(cn))
        dw = sum(tdi_bits[start + k] << k for k in range(cn))
        word = await shift_chunk(dut, cn, tw, dw)
        out.extend((word >> k) & 1 for k in range(cn))
    return out


def bits_of(value, n):
    return [(value >> k) & 1 for k in range(n)]


@cocotb.test()
async def idcode_over_32bit_chunks(dut):
    dut.tck.value = 0
    dut.tms.value = 0
    dut.tdi.value = 0
    await Timer(1, units="ns")
    await run_sequence(dut, [(1, 0)] * 5 + [(0, 0)])          # TLR -> RTI
    seq = [(1, 0), (0, 0), (0, 0)]                            # SelDR, CapDR, ShiftDR
    seq += [(0, b) for b in bits_of(IDCODE, 32)]
    seq += [(1, 0), (0, 0), (0, 0)]                           # Exit1, Update, RTI
    tdo = await run_sequence(dut, seq)
    got = 0
    for k, b in enumerate(tdo[3:35]):
        if b:
            got |= 1 << k
    assert got == IDCODE, "IDCODE mismatch: got 0x%08X want 0x%08X" % (got, IDCODE)
    dut._log.info("IDCODE 0x%08X read back correctly", got)
