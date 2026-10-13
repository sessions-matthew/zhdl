const std = @import("std");
const zhdl = @import("zhdl");

pub fn Counter(comptime W: u16) type {
    return struct {
        clk: zhdl.In(zhdl.Clock),
        rst_n: zhdl.In(zhdl.AsyncResetActiveLow),
        en: zhdl.In(u1),
        count: zhdl.Out(zhdl.UInt(W)),
        overflow: zhdl.Out(u1),

        count_reg: zhdl.Reg(zhdl.UInt(W)) = .init(0),

        /// Hardware netlist synthesis definition
        pub fn build(b: *zhdl.Builder) !void {
            const htype = zhdl.hir.HirType{ .tag = .bits, .width = W };
            const u1_t = zhdl.hir.HirType{ .tag = .bits, .width = 1 };

            const en_ref = b.ref("en", u1_t);
            const count_q = b.ref("count_reg", htype);
            const count_d = b.ref("count_reg_d", htype);
            const count_out = b.ref("count", htype);
            const ovf_out = b.ref("overflow", u1_t);

            const max_val = (@as(u64, 1) << W) - 1;
            const is_ovf = b.eq(count_q, b.lit(max_val, W));
            const inc_val = b.add(count_q, b.lit(1, W));
            const next_val = b.mux(b.eq(en_ref, b.lit(1, 1)), inc_val, count_q);

            try b.addComb(b.assign(ovf_out, is_ovf));
            try b.addComb(b.assign(count_d, next_val));
            try b.addComb(b.assign(count_out, count_q));
        }

        /// Native cycle-accurate simulation logic (runs at CPU speeds without Verilator)
        pub fn comb(self: *@This()) void {
            const max_val = (@as(u64, 1) << W) - 1;
            self.overflow.set(if (self.count_reg.get() == max_val) @as(u1, 1) else @as(u1, 0));

            if (self.en.get() == 1) {
                self.count_reg.set(self.count_reg.get() +% 1);
            }
            self.count.set(self.count_reg.get());
        }
    };
}

test "Counter synthesis to SystemVerilog" {
    const allocator = std.testing.allocator;

    const sv = try zhdl.emitSystemVerilog(Counter(8), allocator);
    defer allocator.free(sv);

    try std.testing.expect(std.mem.indexOf(u8, sv, "module Counter_8 (") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "input  logic       clk") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "input  logic       rst_n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "input  logic       en") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "output logic [ 7:0] count") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "output logic       overflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "always_ff @(posedge clk or negedge rst_n) begin") != null);
}

test "Counter native simulation: counting and rollover" {
    var sim = zhdl.Sim(Counter(8)).init();

    // Pulse reset
    sim.pulseReset(2);
    try std.testing.expectEqual(@as(u8, 0), sim.dut.count.get());
    try std.testing.expectEqual(@as(u1, 0), sim.dut.overflow.get());

    // Enable counter and step 10 cycles
    sim.dut.en.set(1);
    sim.step(10);
    try std.testing.expectEqual(@as(u8, 10), sim.dut.count.get());
    try std.testing.expectEqual(@as(u1, 0), sim.dut.overflow.get());

    // Step near rollover: 10 + 245 = 255
    sim.step(245);
    try std.testing.expectEqual(@as(u8, 255), sim.dut.count.get());
    try std.testing.expectEqual(@as(u1, 1), sim.dut.overflow.get());

    // Step 1 more cycle to wrap around to 0
    sim.step(1);
    try std.testing.expectEqual(@as(u8, 0), sim.dut.count.get());
    try std.testing.expectEqual(@as(u1, 0), sim.dut.overflow.get());
}
