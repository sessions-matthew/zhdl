const std = @import("std");
const zhdl = @import("zhdl");

pub const counter = @import("counter.zig");
pub const packet_filter = @import("packet_filter.zig");
pub const fsm = @import("fsm.zig");
pub const fifo = @import("fifo.zig");
pub const arbiter = @import("arbiter.zig");

test {
    // Reference modules to force evaluation of their test blocks
    std.testing.refAllDecls(@This());
}

test "comptime type reflection comprehensive assertions" {
    const allocator = std.testing.allocator;

    const ComplexPayload = packed struct {
        valid: u1,
        source_id: u7,
        dest_id: u8,
        length: u16,
    };

    try std.testing.expectEqual(@as(u32, 32), zhdl.bitWidth(ComplexPayload));

    const hir_t = try zhdl.toHirType(allocator, ComplexPayload);
    defer allocator.free(hir_t.struct_fields);

    try std.testing.expectEqual(zhdl.hir.HirTypeTag.packed_struct, hir_t.tag);
    try std.testing.expectEqual(@as(u32, 32), hir_t.width);
    try std.testing.expectEqual(@as(usize, 4), hir_t.struct_fields.len);
    try std.testing.expectEqualStrings("valid", hir_t.struct_fields[0].name);
    try std.testing.expectEqual(@as(u32, 1), hir_t.struct_fields[0].width);
    try std.testing.expectEqualStrings("source_id", hir_t.struct_fields[1].name);
    try std.testing.expectEqual(@as(u32, 7), hir_t.struct_fields[1].width);
    try std.testing.expectEqualStrings("dest_id", hir_t.struct_fields[2].name);
    try std.testing.expectEqual(@as(u32, 8), hir_t.struct_fields[2].width);
    try std.testing.expectEqualStrings("length", hir_t.struct_fields[3].name);
    try std.testing.expectEqual(@as(u32, 16), hir_t.struct_fields[3].width);
}

test "arbitrary width generic counters (Counter(3), Counter(17), Counter(32))" {
    const allocator = std.testing.allocator;

    // Test Counter(3): 3-bit counter wrapping at 7
    {
        const sv = try zhdl.emitSystemVerilog(counter.Counter(3), allocator);
        defer allocator.free(sv);
        try std.testing.expect(std.mem.indexOf(u8, sv, "output logic [ 2:0] count") != null);

        var sim = zhdl.Sim(counter.Counter(3)).init();
        sim.pulseReset(1);
        sim.dut.en.set(1);
        sim.step(7);
        try std.testing.expectEqual(@as(u3, 7), sim.dut.count.get());
        try std.testing.expectEqual(@as(u1, 1), sim.dut.overflow.get());
        sim.step(1);
        try std.testing.expectEqual(@as(u3, 0), sim.dut.count.get());
        try std.testing.expectEqual(@as(u1, 0), sim.dut.overflow.get());
    }

    // Test Counter(17): non-power-of-two 17-bit counter
    {
        const sv = try zhdl.emitSystemVerilog(counter.Counter(17), allocator);
        defer allocator.free(sv);
        try std.testing.expect(std.mem.indexOf(u8, sv, "output logic [16:0] count") != null);

        var sim = zhdl.Sim(counter.Counter(17)).init();
        sim.pulseReset(1);
        sim.dut.en.set(1);
        sim.step(100);
        try std.testing.expectEqual(@as(u17, 100), sim.dut.count.get());
    }

    // Test Counter(32): standard 32-bit counter
    {
        const sv = try zhdl.emitSystemVerilog(counter.Counter(32), allocator);
        defer allocator.free(sv);
        try std.testing.expect(std.mem.indexOf(u8, sv, "output logic [31:0] count") != null);

        var sim = zhdl.Sim(counter.Counter(32)).init();
        sim.pulseReset(1);
        sim.dut.en.set(1);
        sim.step(1000);
        try std.testing.expectEqual(@as(u32, 1000), sim.dut.count.get());
    }
}
