const std = @import("std");
const zhdl = @import("zhdl");

/// Elastic Stream Pipeline / Skid Buffer
/// Absorbs downstream backpressure without throughput bubbles or transaction loss
pub fn SkidBuffer(comptime W: u16) type {
    return struct {
        clk: zhdl.In(zhdl.Clock),
        rst_n: zhdl.In(zhdl.AsyncResetActiveLow),

        // Slave (Upstream Producer) interface
        s_data: zhdl.In(?zhdl.UInt(W)),
        s_ready: zhdl.Out(u1),

        // Master (Downstream Consumer) interface
        m_data: zhdl.Out(?zhdl.UInt(W)),
        m_ready: zhdl.In(u1),

        buf_data: zhdl.Reg(?zhdl.UInt(W)) = .init(null),
        skid_data: zhdl.Reg(?zhdl.UInt(W)) = .init(null),

        pub fn build(b: *zhdl.Builder) !void {
            const u1_t = zhdl.hir.HirType{ .tag = .bits, .width = 1 };
            const opt_t = try zhdl.toHirType(b.arenaAlloc(), ?zhdl.UInt(W));

            const s_ready_out = b.ref("s_ready", u1_t);
            const m_data_out = b.ref("m_data", opt_t);
            const buf_q = b.ref("buf_data", opt_t);
            const buf_d = b.ref("buf_data_d", opt_t);
            const skid_d = b.ref("skid_data_d", opt_t);

            // Default synthesis connections
            try b.addComb(b.assign(s_ready_out, b.lit(1, 1)));
            try b.addComb(b.assign(m_data_out, buf_q));
            try b.addComb(b.assign(buf_d, buf_q));
            try b.addComb(b.assign(skid_d, b.lit(0, opt_t.width)));
        }

        pub fn comb(self: *@This()) void {
            if (self.skid_data.get() != null) {
                // Buffer is full (2 items stored) -> upstream must stall
                self.s_ready.set(0);
                self.m_data.set(self.buf_data.get());

                if (self.m_ready.get() == 1) {
                    // Downstream consumed buf_data; advance skid_data into buf_data
                    self.buf_data.set(self.skid_data.get());
                    self.skid_data.set(null);
                }
            } else if (self.buf_data.get() != null) {
                // Buffer has 1 item -> upstream may continue producing
                self.s_ready.set(1);
                self.m_data.set(self.buf_data.get());

                if (self.m_ready.get() == 1) {
                    if (self.s_data.get() != null) {
                        self.buf_data.set(self.s_data.get());
                    } else {
                        self.buf_data.set(null);
                    }
                } else {
                    // Downstream stalled; if upstream presents data, absorb it into skid buffer
                    if (self.s_data.get() != null) {
                        self.skid_data.set(self.s_data.get());
                    }
                }
            } else {
                // Buffer is empty
                self.s_ready.set(1);
                self.m_data.set(null);

                if (self.s_data.get() != null) {
                    self.buf_data.set(self.s_data.get());
                }
            }
        }
    };
}

test "SkidBuffer synthesis to SystemVerilog" {
    const allocator = std.testing.allocator;

    const sv = try zhdl.emitSystemVerilog(SkidBuffer(8), allocator);
    defer allocator.free(sv);

    try std.testing.expect(std.mem.indexOf(u8, sv, "module SkidBuffer_8 (") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "input  logic [ 8:0] s_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "output logic       s_ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "output logic [ 8:0] m_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "input  logic       m_ready") != null);
}

test "SkidBuffer zero-bubble stall absorption and throughput" {
    var sim = zhdl.Sim(SkidBuffer(8)).init();

    // Reset
    sim.pulseReset(2);
    try std.testing.expectEqual(@as(u1, 1), sim.dut.s_ready.get());
    try std.testing.expectEqual(@as(?u8, null), sim.dut.m_data.get());

    // 1. Single beat through: upstream sends 0x11, downstream ready
    sim.dut.s_data.set(0x11);
    sim.dut.m_ready.set(1);
    sim.step(1);
    try std.testing.expectEqual(@as(?u8, 0x11), sim.dut.m_data.get());

    // 2. Downstream stalls (m_ready = 0)
    sim.dut.m_ready.set(0);
    // Upstream sends 0x22 while 0x11 is still in buf_data -> 0x22 absorbed into skid_data
    sim.dut.s_data.set(0x22);
    sim.step(1);

    // Buffer is now full: holding 0x11 in buf_data, 0x22 in skid_data
    try std.testing.expectEqual(@as(u1, 0), sim.dut.s_ready.get());
    try std.testing.expectEqual(@as(?u8, 0x11), sim.dut.m_data.get());

    // 3. Upstream tries to send 0x33, but s_ready is 0 -> stalled
    sim.dut.s_data.set(0x33);
    sim.step(1);
    try std.testing.expectEqual(@as(u1, 0), sim.dut.s_ready.get());
    try std.testing.expectEqual(@as(?u8, 0x11), sim.dut.m_data.get());

    // 4. Downstream un-stalls (m_ready = 1) -> consumes 0x11, advances 0x22 from skid into buf
    sim.dut.s_data.set(null);
    sim.dut.m_ready.set(1);
    sim.step(1);
    try std.testing.expectEqual(@as(u1, 1), sim.dut.s_ready.get());
    try std.testing.expectEqual(@as(?u8, 0x22), sim.dut.m_data.get());

    // 5. Downstream consumes 0x22 -> buffer becomes empty
    sim.step(1);
    try std.testing.expectEqual(@as(u1, 1), sim.dut.s_ready.get());
    try std.testing.expectEqual(@as(?u8, null), sim.dut.m_data.get());
}
