import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


async def axi_write(dut, addr, data):
    dut.awaddr.value = addr
    dut.wdata.value = data
    dut.wstrb.value = 0xF
    dut.awvalid.value = 1
    dut.wvalid.value = 1
    dut.bready.value = 1
    aw = w = False
    for _ in range(40):
        await RisingEdge(dut.clk)
        if not aw and dut.awready.value:
            aw = True
            dut.awvalid.value = 0
        if not w and dut.wready.value:
            w = True
            dut.wvalid.value = 0
        if aw and w:
            break
    for _ in range(40):
        await RisingEdge(dut.clk)
        if dut.bvalid.value:
            break


async def axi_read(dut, addr):
    dut.araddr.value = addr
    dut.arvalid.value = 1
    dut.rready.value = 1
    val = None
    for _ in range(40):
        await RisingEdge(dut.clk)
        if dut.arready.value:
            dut.arvalid.value = 0
        if dut.rvalid.value:
            val = int(dut.rdata.value)
            break
    await RisingEdge(dut.clk)
    return 0 if val is None else val


async def shift(dut, nbits, tms, tdi):
    await axi_write(dut, 0x00, nbits)
    await axi_write(dut, 0x04, tms & 0xFFFFFFFF)
    await axi_write(dut, 0x08, tdi & 0xFFFFFFFF)
    await axi_write(dut, 0x10, 1)
    for _ in range(2000):
        v = await axi_read(dut, 0x10)
        if (v & 1) == 0:
            break
    r = await axi_read(dut, 0x0C)
    if nbits < 32:
        r >>= (32 - nbits)
    return r


@cocotb.test()
async def idcode_read(dut):
    dut.awaddr.value = 0; dut.awvalid.value = 0
    dut.wdata.value = 0; dut.wstrb.value = 0; dut.wvalid.value = 0
    dut.bready.value = 0
    dut.araddr.value = 0; dut.arvalid.value = 0; dut.rready.value = 0
    dut.rstn.value = 0
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await Timer(100, unit="ns")
    dut.rstn.value = 1
    await Timer(50, unit="ns")

    # TLR 5bit -> RTI -> SelDR -> CapDR -> ShiftDR  = 9 bit, TMS=0b001011111
    await shift(dut, 9, 0x05F, 0)
    tdo = await shift(dut, 32, 0, 0)
    await shift(dut, 3, 0x1, 0)      # Exit1DR, UpdateDR, RTI

    dut._log.info("IDCODE = 0x%08X", tdo)
    assert tdo == 0x23727093, "IDCODE mismatch: 0x%08X" % tdo
