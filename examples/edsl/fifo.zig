const std = @import("std");
const zhdl = @import("zhdl");

pub fn AxisFifo(comptime T: type, comptime depth: usize) type {
    const PtrWidth = 4; // for depth = 8

    return struct {
        clk: zhdl.In(zhdl.Clock),
        rst_n: zhdl.In(zhdl.AsyncResetActiveLow),

        // AXI4-Stream Slave (Input)
        s_axis_tdata: zhdl.In(T),
        s_axis_tvalid: zhdl.In(u1),
        s_axis_tready: zhdl.Out(u1),

        // AXI4-Stream Master (Output)
        m_axis_tdata: zhdl.Out(T),
        m_axis_tvalid: zhdl.Out(u1),
        m_axis_tready: zhdl.In(u1),

        // Status flags
        full: zhdl.Out(u1),
        empty: zhdl.Out(u1),
        occupancy: zhdl.Out(zhdl.UInt(PtrWidth)),

        // State registers
        wr_ptr: zhdl.Reg(zhdl.UInt(PtrWidth)) = .init(0),
        rd_ptr: zhdl.Reg(zhdl.UInt(PtrWidth)) = .init(0),
        count: zhdl.Reg(zhdl.UInt(PtrWidth)) = .init(0),

        // Storage slots
        mem: [depth]T = undefined,

        pub fn build(b: *zhdl.Builder) !void {
            const u1_t = zhdl.hir.HirType{ .tag = .bits, .width = 1 };
            const ptr_t = zhdl.hir.HirType{ .tag = .bits, .width = PtrWidth };
            const data_t = try zhdl.toHirType(b.arenaAlloc(), T);

            const count_q = b.ref("count", ptr_t);
            const count_d = b.ref("count_d", ptr_t);
            const wr_ptr_q = b.ref("wr_ptr", ptr_t);
            const wr_ptr_d = b.ref("wr_ptr_d", ptr_t);
            const rd_ptr_q = b.ref("rd_ptr", ptr_t);
            const rd_ptr_d = b.ref("rd_ptr_d", ptr_t);

            const is_full = b.eq(count_q, b.lit(depth, PtrWidth));
            const is_empty = b.eq(count_q, b.lit(0, PtrWidth));

            try b.addComb(b.assign(b.ref("full", u1_t), is_full));
            try b.addComb(b.assign(b.ref("empty", u1_t), is_empty));
            try b.addComb(b.assign(b.ref("occupancy", ptr_t), count_q));

            const s_ready = b.binary(.equal_equal, is_full, b.lit(0, 1));
            const m_valid = b.binary(.equal_equal, is_empty, b.lit(0, 1));

            try b.addComb(b.assign(b.ref("s_axis_tready", u1_t), s_ready));
            try b.addComb(b.assign(b.ref("m_axis_tvalid", u1_t), m_valid));
            try b.addComb(b.assign(b.ref("m_axis_tdata", data_t), b.lit(0, data_t.width)));

            // Next pointer defaults
            try b.addComb(b.assign(count_d, count_q));
            try b.addComb(b.assign(wr_ptr_d, wr_ptr_q));
            try b.addComb(b.assign(rd_ptr_d, rd_ptr_q));
        }

        pub fn comb(self: *@This()) void {
            const is_full = self.count.get() == depth;
            const is_empty = self.count.get() == 0;

            self.full.set(if (is_full) @as(u1, 1) else @as(u1, 0));
            self.empty.set(if (is_empty) @as(u1, 1) else @as(u1, 0));
            self.occupancy.set(self.count.get());

            const s_ready: u1 = if (!is_full) 1 else 0;
            const m_valid: u1 = if (!is_empty) 1 else 0;

            self.s_axis_tready.set(s_ready);
            self.m_axis_tvalid.set(m_valid);

            // Output top of FIFO
            const rd_idx = self.rd_ptr.get() % depth;
            self.m_axis_tdata.set(if (!is_empty) self.mem[rd_idx] else 0);

            // Compute handshakes
            const wr_fire = (self.s_axis_tvalid.get() == 1) and (s_ready == 1);
            const rd_fire = (m_valid == 1) and (self.m_axis_tready.get() == 1);

            if (wr_fire and !rd_fire) {
                const wr_idx = self.wr_ptr.get() % depth;
                self.mem[wr_idx] = self.s_axis_tdata.get();
                self.wr_ptr.set(self.wr_ptr.get() +% 1);
                self.count.set(self.count.get() +% 1);
            } else if (rd_fire and !wr_fire) {
                self.rd_ptr.set(self.rd_ptr.get() +% 1);
                self.count.set(self.count.get() -% 1);
            } else if (wr_fire and rd_fire) {
                const wr_idx = self.wr_ptr.get() % depth;
                self.mem[wr_idx] = self.s_axis_tdata.get();
                self.wr_ptr.set(self.wr_ptr.get() +% 1);
                self.rd_ptr.set(self.rd_ptr.get() +% 1);
                // count remains unchanged
            }
        }
    };
}

test "AxisFifo synthesis to SystemVerilog" {
    const allocator = std.testing.allocator;

    const sv = try zhdl.emitSystemVerilog(AxisFifo(u8, 8), allocator);
    defer allocator.free(sv);

    try std.testing.expect(std.mem.indexOf(u8, sv, "input  logic [ 7:0] s_axis_tdata") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "input  logic       s_axis_tvalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "output logic       s_axis_tready") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "output logic [ 7:0] m_axis_tdata") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "output logic       full") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "output logic       empty") != null);
}

test "AxisFifo burst write, backpressure, and drain" {
    var sim = zhdl.Sim(AxisFifo(u8, 8)).init();

    // Reset FIFO
    sim.pulseReset(2);
    try std.testing.expectEqual(@as(u1, 1), sim.dut.empty.get());
    try std.testing.expectEqual(@as(u1, 0), sim.dut.full.get());
    try std.testing.expectEqual(@as(u1, 1), sim.dut.s_axis_tready.get());

    // Burst write 8 bytes
    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        sim.dut.s_axis_tvalid.set(1);
        sim.dut.s_axis_tdata.set(0x10 + i);
        sim.step(1);
    }
    sim.dut.s_axis_tvalid.set(0);
    sim.settle();

    // Verify full and backpressure
    try std.testing.expectEqual(@as(u1, 1), sim.dut.full.get());
    try std.testing.expectEqual(@as(u1, 0), sim.dut.empty.get());
    try std.testing.expectEqual(@as(u1, 0), sim.dut.s_axis_tready.get());
    try std.testing.expectEqual(@as(u4, 8), sim.dut.occupancy.get());

    // Drain 8 bytes and verify FIFO order
    i = 0;
    while (i < 8) : (i += 1) {
        try std.testing.expectEqual(@as(u1, 1), sim.dut.m_axis_tvalid.get());
        try std.testing.expectEqual(@as(u8, 0x10 + i), sim.dut.m_axis_tdata.get());

        // Acknowledge read handshake
        sim.dut.m_axis_tready.set(1);
        sim.step(1);
    }
    sim.dut.m_axis_tready.set(0);
    sim.settle();

    // Verify empty out of drain
    try std.testing.expectEqual(@as(u1, 1), sim.dut.empty.get());
    try std.testing.expectEqual(@as(u1, 0), sim.dut.full.get());
    try std.testing.expectEqual(@as(u4, 0), sim.dut.occupancy.get());
}
