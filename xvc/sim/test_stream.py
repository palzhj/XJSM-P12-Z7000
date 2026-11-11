import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from test_jtag_ctrl import axi_write, axi_read


@cocotb.test()
async def stream_test(dut):
    """Verify FIFO streaming: write 4 words, check the completion count and read-back"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rstn.value = 0
    dut.awvalid.value = 0; dut.wvalid.value = 0; dut.bready.value = 0
    dut.arvalid.value = 0; dut.rready.value = 0
    dut.tdo.value = 0
    for _ in range(10):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)

    # Set DIV = 1 (shortest)
    await axi_write(dut, 0x14, 1)

    st = await axi_read(dut, 0x24)
    dut._log.info("initial STATUS=0x%08X (tx_free=%d)" % (st, st & 0xFF))

    # Write four 32-bit words
    for w in range(4):
        await axi_write(dut, 0x1C, 0x11111111 * (w + 1))

    st = await axi_read(dut, 0x24)
    cnt = await axi_read(dut, 0x28)
    dut._log.info("after write STATUS=0x%08X tx_free=%d rx_used=%d CNT=%d"
                  % (st, st & 0xFF, (st >> 8) & 0xFF, cnt))

    # Wait for the engine to finish (at most 32*4*16 cycles)
    for _ in range(3000):
        await RisingEdge(dut.clk)
        cnt = await axi_read(dut, 0x28)
        if cnt >= 4:
            break

    st = await axi_read(dut, 0x24)
    busy = await axi_read(dut, 0x10)
    dut._log.info("done: CNT=%d STATUS=0x%08X rx_used=%d busy=%d"
                  % (cnt, st, (st >> 8) & 0xFF, busy & 1))
    assert cnt == 4, "stream chunks not completed: %d" % cnt
