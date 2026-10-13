const std = @import("std");
const zhdl = @import("zhdl");

/// AXI4-Stream UART Transmitter
pub const UartTx = struct {
    clk: zhdl.In(zhdl.Clock),
    rst_n: zhdl.In(zhdl.AsyncResetActiveLow),

    s_axis_tdata: zhdl.In(u8),
    s_axis_tvalid: zhdl.In(u1),
    s_axis_tready: zhdl.Out(u1),

    txd: zhdl.Out(u1),
    busy: zhdl.Out(u1),
    prescale: zhdl.In(u16),

    txd_reg: zhdl.Reg(u1) = .init(1), // UART line idles high
    busy_reg: zhdl.Reg(u1) = .init(0),
    data_reg: zhdl.Reg(u9) = .init(0), // 8 data bits + 1 stop bit
    prescale_reg: zhdl.Reg(u16) = .init(0),
    bit_cnt: zhdl.Reg(u4) = .init(0),

    pub fn build(b: *zhdl.Builder) !void {
        const u1_t = zhdl.hir.HirType{ .tag = .bits, .width = 1 };
        const txd_q = b.ref("txd_reg", u1_t);
        const busy_q = b.ref("busy_reg", u1_t);

        try b.addComb(b.assign(b.ref("txd", u1_t), txd_q));
        try b.addComb(b.assign(b.ref("busy", u1_t), busy_q));
        try b.addComb(b.assign(b.ref("s_axis_tready", u1_t), b.eq(busy_q, b.lit(0, 1))));
    }

    pub fn comb(self: *@This()) void {
        self.txd.set(self.txd_reg.get());
        self.busy.set(self.busy_reg.get());
        self.s_axis_tready.set(if (self.busy_reg.get() == 0) @as(u1, 1) else @as(u1, 0));

        if (self.prescale_reg.get() > 0) {
            self.prescale_reg.set(self.prescale_reg.get() -% 1);
        } else if (self.bit_cnt.get() == 0) {
            if (self.s_axis_tvalid.get() == 1 and self.busy_reg.get() == 0) {
                // Load shift register: 8 data bits + 1 stop bit
                self.data_reg.set((@as(u9, 1) << 8) | @as(u9, self.s_axis_tdata.get()));
                self.prescale_reg.set(self.prescale.get());
                self.bit_cnt.set(10); // 1 start + 8 data + 1 stop
                self.txd_reg.set(0); // Start bit = 0
                self.busy_reg.set(1);
            } else {
                self.busy_reg.set(0);
                self.txd_reg.set(1);
            }
        } else {
            // Next bit interval
            self.prescale_reg.set(self.prescale.get());
            const cnt = self.bit_cnt.get() -% 1;
            self.bit_cnt.set(cnt);

            if (cnt > 0) {
                // Shift out LSB
                const bit: u1 = @truncate(self.data_reg.get());
                self.txd_reg.set(bit);
                self.data_reg.set(self.data_reg.get() >> 1);
            } else {
                // Transmission complete
                self.txd_reg.set(1);
                self.busy_reg.set(0);
            }
        }
    }
};

/// AXI4-Stream UART Receiver
pub const UartRx = struct {
    clk: zhdl.In(zhdl.Clock),
    rst_n: zhdl.In(zhdl.AsyncResetActiveLow),

    rxd: zhdl.In(u1),

    m_axis_tdata: zhdl.Out(u8),
    m_axis_tvalid: zhdl.Out(u1),
    m_axis_tready: zhdl.In(u1),
    prescale: zhdl.In(u16),

    data_reg: zhdl.Reg(u8) = .init(0),
    m_axis_tvalid_reg: zhdl.Reg(u1) = .init(0),
    prescale_reg: zhdl.Reg(u16) = .init(0),
    bit_cnt: zhdl.Reg(u4) = .init(0),
    rxd_sync: zhdl.Reg(u1) = .init(1),

    pub fn build(b: *zhdl.Builder) !void {
        const u1_t = zhdl.hir.HirType{ .tag = .bits, .width = 1 };
        const u8_t = zhdl.hir.HirType{ .tag = .bits, .width = 8 };

        try b.addComb(b.assign(b.ref("m_axis_tdata", u8_t), b.ref("data_reg", u8_t)));
        try b.addComb(b.assign(b.ref("m_axis_tvalid", u1_t), b.ref("m_axis_tvalid_reg", u1_t)));
    }

    pub fn comb(self: *@This()) void {
        self.rxd_sync.set(self.rxd.get());
        self.m_axis_tdata.set(self.data_reg.get());
        self.m_axis_tvalid.set(self.m_axis_tvalid_reg.get());

        // Clear valid flag on consumer handshake
        if (self.m_axis_tvalid_reg.get() == 1 and self.m_axis_tready.get() == 1) {
            self.m_axis_tvalid_reg.set(0);
        }

        if (self.prescale_reg.get() > 0) {
            self.prescale_reg.set(self.prescale_reg.get() -% 1);
        } else if (self.bit_cnt.get() > 0) {
            const cnt = self.bit_cnt.get();
            if (cnt > 9) {
                // Verified start bit
                if (self.rxd_sync.get() == 0) {
                    self.bit_cnt.set(cnt - 1);
                    self.prescale_reg.set(self.prescale.get());
                } else {
                    self.bit_cnt.set(0);
                }
            } else if (cnt > 1) {
                // 8 Data bits (LSB first)
                self.bit_cnt.set(cnt - 1);
                self.prescale_reg.set(self.prescale.get());
                const new_data = (self.data_reg.get() >> 1) | (@as(u8, self.rxd_sync.get()) << 7);
                self.data_reg.set(new_data);
            } else {
                // Stop bit
                self.bit_cnt.set(0);
                if (self.rxd_sync.get() == 1) {
                    self.m_axis_tvalid_reg.set(1);
                }
            }
        } else {
            // Waiting for falling edge of start bit
            if (self.rxd_sync.get() == 0) {
                self.prescale_reg.set(self.prescale.get() / 2);
                self.bit_cnt.set(10);
            }
        }
    }
};

test "UartTx and UartRx synthesis to SystemVerilog" {
    const allocator = std.testing.allocator;

    const tx_sv = try zhdl.emitSystemVerilog(UartTx, allocator);
    defer allocator.free(tx_sv);
    try std.testing.expect(std.mem.indexOf(u8, tx_sv, "module UartTx (") != null);
    try std.testing.expect(std.mem.indexOf(u8, tx_sv, "output logic       txd") != null);
    try std.testing.expect(std.mem.indexOf(u8, tx_sv, "output logic       busy") != null);

    const rx_sv = try zhdl.emitSystemVerilog(UartRx, allocator);
    defer allocator.free(rx_sv);
    try std.testing.expect(std.mem.indexOf(u8, rx_sv, "module UartRx (") != null);
    try std.testing.expect(std.mem.indexOf(u8, rx_sv, "input  logic       rxd") != null);
    try std.testing.expect(std.mem.indexOf(u8, rx_sv, "output logic [ 7:0] m_axis_tdata") != null);
}

test "UartTx to UartRx loopback simulation" {
    var tx = zhdl.Sim(UartTx).init();
    var rx = zhdl.Sim(UartRx).init();

    // Fast prescaler for simulation (4 clocks per bit)
    const prescale: u16 = 4;
    tx.dut.prescale.set(prescale);
    rx.dut.prescale.set(prescale);

    // Initial reset
    tx.pulseReset(2);
    rx.pulseReset(2);

    try std.testing.expectEqual(@as(u1, 1), tx.dut.txd.get());
    try std.testing.expectEqual(@as(u1, 0), rx.dut.m_axis_tvalid.get());

    // Transmit byte 0xA5
    tx.dut.s_axis_tdata.set(0xA5);
    tx.dut.s_axis_tvalid.set(1);
    tx.step(1);
    tx.dut.s_axis_tvalid.set(0);

    // Step loopback simulation cycle-by-cycle (connect tx.txd -> rx.rxd)
    var cycles: usize = 0;
    while (cycles < 60) : (cycles += 1) {
        // Loopback wire connection
        rx.dut.rxd.set(tx.dut.txd.get());

        tx.step(1);
        rx.step(1);

        if (rx.dut.m_axis_tvalid.get() == 1) break;
    }

    // Verify received data matches transmitted byte
    try std.testing.expectEqual(@as(u1, 1), rx.dut.m_axis_tvalid.get());
    try std.testing.expectEqual(@as(u8, 0xA5), rx.dut.m_axis_tdata.get());

    // Acknowledge read handshake
    rx.dut.m_axis_tready.set(1);
    rx.step(1);
    try std.testing.expectEqual(@as(u1, 0), rx.dut.m_axis_tvalid.get());
}
