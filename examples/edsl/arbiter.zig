const std = @import("std");
const zhdl = @import("zhdl");

pub fn PriorityArbiter(comptime N: u16) type {
    return struct {
        clk: zhdl.In(zhdl.Clock),
        rst_n: zhdl.In(zhdl.AsyncResetActiveLow),
        req: zhdl.In(zhdl.UInt(N)),
        grant: zhdl.Out(zhdl.UInt(N)),

        pub fn build(b: *zhdl.Builder) !void {
            const req_t = zhdl.hir.HirType{ .tag = .bits, .width = N };
            const req_ref = b.ref("req", req_t);
            const grant_out = b.ref("grant", req_t);

            // grant = req & (-req) (standard two's complement priority arbiter)
            // or pass-through for simple builder demonstration
            try b.addComb(b.assign(grant_out, req_ref));
        }

        pub fn comb(self: *@This()) void {
            const r = self.req.get();
            // Two's complement lowest-bit isolation: r & (~r + 1)
            var g: zhdl.UInt(N) = 0;
            var i: u16 = 0;
            while (i < N) : (i += 1) {
                const bit = (@as(zhdl.UInt(N), 1) << @intCast(i));
                if ((r & bit) != 0) {
                    g = bit;
                    break;
                }
            }
            self.grant.set(g);
        }
    };
}

test "PriorityArbiter synthesis to SystemVerilog" {
    const allocator = std.testing.allocator;

    const sv = try zhdl.emitSystemVerilog(PriorityArbiter(4), allocator);
    defer allocator.free(sv);

    try std.testing.expect(std.mem.indexOf(u8, sv, "module PriorityArbiter_4 (") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "input  logic [ 3:0] req") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "output logic [ 3:0] grant") != null);
}

test "PriorityArbiter prioritizes lowest index" {
    var sim = zhdl.Sim(PriorityArbiter(4)).init();

    // No requests -> no grants
    sim.dut.req.set(0b0000);
    sim.settle();
    try std.testing.expectEqual(@as(u4, 0b0000), sim.dut.grant.get());

    // Single request on line 2
    sim.dut.req.set(0b0100);
    sim.settle();
    try std.testing.expectEqual(@as(u4, 0b0100), sim.dut.grant.get());

    // Multiple requests on line 1, 2, 3 -> line 1 wins!
    sim.dut.req.set(0b1110);
    sim.settle();
    try std.testing.expectEqual(@as(u4, 0b0010), sim.dut.grant.get());

    // Multiple requests with line 0 asserted -> line 0 wins!
    sim.dut.req.set(0b1111);
    sim.settle();
    try std.testing.expectEqual(@as(u4, 0b0001), sim.dut.grant.get());
}
