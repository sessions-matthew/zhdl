const std = @import("std");

pub const types = @import("edsl/types.zig");
pub const builder = @import("edsl/builder.zig");
pub const hir = @import("hir.zig");
pub const codegen = @import("codegen/systemverilog.zig");

// Re-export core primitives
pub const Clock = types.Clock;
pub const Reset = types.Reset;
pub const ResetMode = types.ResetMode;
pub const ResetPolarity = types.ResetPolarity;
pub const AsyncReset = types.AsyncReset;
pub const AsyncResetActiveLow = types.AsyncResetActiveLow;
pub const SyncReset = types.SyncReset;
pub const SyncResetActiveLow = types.SyncResetActiveLow;
pub const Async = types.Async;

pub const In = types.In;
pub const Out = types.Out;
pub const InOut = types.InOut;
pub const Reg = types.Reg;
pub const Wire = types.Wire;

pub const bitWidth = types.bitWidth;
pub const toHirType = types.toHirType;

pub const UInt = types.UInt;
pub const SInt = types.SInt;

pub const Builder = builder.Builder;
pub const elaborate = builder.elaborate;
pub const Sim = @import("edsl/sim.zig").Sim;

const ArrayList = std.array_list.Managed;

/// Synthesize a pure Zig module into synthesizable IEEE 1800 SystemVerilog
pub fn emitSystemVerilog(comptime Mod: type, allocator: std.mem.Allocator) ![]const u8 {
    var elab = try elaborate(Mod, allocator);
    defer elab.deinit();
    var emitter = codegen.SystemVerilogEmitter.init(allocator);
    var out_buf = ArrayList(u8).init(allocator);
    errdefer out_buf.deinit();
    var sw = codegen.StringWriter{ .list = &out_buf };
    try emitter.emitModule(&elab.module, &sw);
    return out_buf.toOwnedSlice();
}

test "bitWidth and toHirType reflection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    try testing.expectEqual(@as(u32, 1), bitWidth(Clock));
    try testing.expectEqual(@as(u32, 1), bitWidth(AsyncReset));
    try testing.expectEqual(@as(u32, 8), bitWidth(u8));
    try testing.expectEqual(@as(u32, 12), bitWidth(u12));

    const Header = packed struct {
        tag: u4,
        len: u12,
    };
    try testing.expectEqual(@as(u32, 16), bitWidth(Header));

    const header_hir = try toHirType(allocator, Header);
    defer allocator.free(header_hir.struct_fields);
    try testing.expectEqual(hir.HirTypeTag.packed_struct, header_hir.tag);
    try testing.expectEqual(@as(u32, 16), header_hir.width);
    try testing.expectEqual(@as(usize, 2), header_hir.struct_fields.len);
    try testing.expectEqualStrings("tag", header_hir.struct_fields[0].name);
    try testing.expectEqual(@as(u32, 4), header_hir.struct_fields[0].width);
    try testing.expectEqual(@as(u32, 0), header_hir.struct_fields[0].offset);
    try testing.expectEqualStrings("len", header_hir.struct_fields[1].name);
    try testing.expectEqual(@as(u32, 12), header_hir.struct_fields[1].width);
    try testing.expectEqual(@as(u32, 4), header_hir.struct_fields[1].offset);

    // Optional (?u8: 1 bit valid + 8 bits data = 9 bits)
    try testing.expectEqual(@as(u32, 9), bitWidth(?u8));
    const opt_hir = try toHirType(allocator, ?u8);
    try testing.expectEqual(hir.HirTypeTag.optional, opt_hir.tag);
    try testing.expectEqual(@as(u32, 9), opt_hir.width);
    try testing.expectEqual(@as(u32, 8), opt_hir.elem_width);

    // Enum
    const State = enum(u2) {
        idle = 0,
        running = 1,
        done = 2,
    };
    try testing.expectEqual(@as(u32, 2), bitWidth(State));
    const state_hir = try toHirType(allocator, State);
    defer allocator.free(state_hir.enum_variants);
    try testing.expectEqual(hir.HirTypeTag.enum_type, state_hir.tag);
    try testing.expectEqual(@as(u32, 2), state_hir.width);
    try testing.expectEqual(@as(usize, 3), state_hir.enum_variants.len);

    // Tagged Union
    const Command = union(enum) {
        ping: u8,
        data: Header,
        idle: void,
    };
    const cmd_hir = try toHirType(allocator, Command);
    defer allocator.free(cmd_hir.union_fields);
    try testing.expectEqual(hir.HirTypeTag.tagged_union, cmd_hir.tag);
    try testing.expectEqual(@as(u32, 18), cmd_hir.width);
}

// Example Hardware Module defined purely in Zig
pub fn Counter(comptime W: u16) type {
    return struct {
        clk: In(Clock),
        rst_n: In(AsyncResetActiveLow),
        en: In(u1),
        count: Out(UInt(W)),

        cnt: Reg(UInt(W)) = .init(0),

        pub fn build(b: *Builder) !void {
            const htype = hir.HirType{ .tag = .bits, .width = W };
            const u1_t = hir.HirType{ .tag = .bits, .width = 1 };

            const en_ref = b.ref("en", u1_t);
            const cnt_q = b.ref("cnt", htype);
            const cnt_d = b.ref("cnt_d", htype);
            const count_out = b.ref("count", htype);

            // if (en) cnt_d = cnt + 1 else cnt_d = cnt;
            const inc_val = b.add(cnt_q, b.lit(1, W));
            const next_cnt = b.mux(b.eq(en_ref, b.lit(1, 1)), inc_val, cnt_q);

            try b.addComb(b.assign(cnt_d, next_cnt));
            try b.addComb(b.assign(count_out, cnt_q));
        }

        // Native simulation procedural execution
        pub fn comb(self: *@This()) void {
            if (self.en.get() == 1) {
                self.cnt.set(self.cnt.get() +% 1);
            }
            self.count.set(self.cnt.get());
        }
    };
}

test "elaborate and emit SystemVerilog from pure Zig module" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const sv = try emitSystemVerilog(Counter(8), allocator);
    defer allocator.free(sv);

    // Verify module header and ports
    try testing.expect(std.mem.indexOf(u8, sv, "module Counter_8 (") != null);
    try testing.expect(std.mem.indexOf(u8, sv, "input  logic       clk") != null);
    try testing.expect(std.mem.indexOf(u8, sv, "input  logic       rst_n") != null);
    try testing.expect(std.mem.indexOf(u8, sv, "input  logic       en") != null);
    try testing.expect(std.mem.indexOf(u8, sv, "output logic [ 7:0] count") != null);

    // Verify sequential register and always_ff
    try testing.expect(std.mem.indexOf(u8, sv, "logic [7:0] cnt, cnt_d;") != null);
    try testing.expect(std.mem.indexOf(u8, sv, "always_ff @(posedge clk or negedge rst_n) begin") != null);
    try testing.expect(std.mem.indexOf(u8, sv, "cnt <= 8'h0;") != null);
    try testing.expect(std.mem.indexOf(u8, sv, "cnt <= cnt_d;") != null);

    // Verify combinational always_comb
    try testing.expect(std.mem.indexOf(u8, sv, "always_comb begin") != null);
    try testing.expect(std.mem.indexOf(u8, sv, "cnt_d = ((en == 1'd1) ? (cnt + 8'd1) : cnt);") != null);
    try testing.expect(std.mem.indexOf(u8, sv, "count = cnt;") != null);
}

test "native cycle-accurate simulation in pure Zig without external tools" {
    const testing = std.testing;

    var sim = Sim(Counter(8)).init();

    // 1. Initially 0
    try testing.expectEqual(@as(u8, 0), sim.dut.count.get());

    // 2. Pulse reset for 2 cycles
    sim.pulseReset(2);
    try testing.expectEqual(@as(u8, 0), sim.dut.count.get());

    // 3. Step without enable: counter holds 0
    sim.step(3);
    try testing.expectEqual(@as(u8, 0), sim.dut.count.get());

    // 4. Enable counter and step 5 cycles
    sim.dut.en.set(1);
    sim.step(5);
    try testing.expectEqual(@as(u8, 5), sim.dut.count.get());

    // 5. Disable counter and step 3 cycles: holds at 5
    sim.dut.en.set(0);
    sim.step(3);
    try testing.expectEqual(@as(u8, 5), sim.dut.count.get());

    // 6. Enable counter and step 10 more cycles -> 15
    sim.dut.en.set(1);
    sim.step(10);
    try testing.expectEqual(@as(u8, 15), sim.dut.count.get());

    // 7. Pulse reset again -> drops to 0
    sim.pulseReset(1);
    try testing.expectEqual(@as(u8, 0), sim.dut.count.get());
}

pub const PacketHeader = packed struct {
    tag: u4,
    len: u12,

    pub fn isNull(self: PacketHeader) bool {
        return self.tag == 0;
    }
};

pub const PacketCommand = union(enum) {
    ping: u8,
    data: PacketHeader,
    idle: void,
};

pub fn PacketFilter(comptime W: u16) type {
    return struct {
        clk: In(Clock),
        rst_n: In(AsyncResetActiveLow),
        ext_enable: In(Async(u1)),
        cmd: In(PacketCommand),
        rx_stream: Out(?UInt(W)),

        active_header: Reg(?PacketHeader) = .init(null),
        _sync_s1: Reg(u1) = .init(0),
        _sync_s2: Reg(u1) = .init(0),

        pub fn build(b: *Builder) !void {
            _ = b.sync2ff("clk", "ext_enable", 1);
        }

        pub fn comb(self: *@This()) void {
            self._sync_s1.set(self.ext_enable.get());
            self._sync_s2.set(self._sync_s1.get());
            const enable = self._sync_s2.get() == 1;

            switch (self.cmd.get()) {
                .ping => |echo| {
                    self.rx_stream.set(if (enable) @as(UInt(W), @truncate(echo)) else null);
                },
                .data => |hdr| {
                    if (hdr.isNull() or !enable) {
                        self.active_header.set(null);
                        self.rx_stream.set(null);
                    } else {
                        self.active_header.set(hdr);
                        self.rx_stream.set(@as(UInt(W), @truncate(hdr.len)));
                    }
                },
                .idle => {
                    self.rx_stream.set(null);
                },
            }
        }
    };
}

test "PacketFilter synthesis and native simulation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // 1. Test SystemVerilog synthesis
    const sv = try emitSystemVerilog(PacketFilter(8), allocator);
    defer allocator.free(sv);

    try testing.expect(std.mem.indexOf(u8, sv, "module PacketFilter_8 (") != null);
    try testing.expect(std.mem.indexOf(u8, sv, "input  logic       ext_enable") != null);
    try testing.expect(std.mem.indexOf(u8, sv, "output logic [ 8:0] rx_stream") != null);
    try testing.expect(std.mem.indexOf(u8, sv, "_sync_ext_enable_s1") != null);
    try testing.expect(std.mem.indexOf(u8, sv, "_sync_ext_enable_s2") != null);

    // 2. Test native cycle-accurate simulation
    var sim = Sim(PacketFilter(8)).init();

    // Pulse reset
    sim.pulseReset(2);
    try testing.expectEqual(@as(?u8, null), sim.dut.rx_stream.get());

    // Provide async external enable pin
    sim.dut.ext_enable.set(1);

    // Step 2 clock cycles to let 2-stage synchronizer settle
    sim.step(2);

    // Send ping command
    sim.dut.cmd.set(PacketCommand{ .ping = 0xA5 });
    sim.settle();
    try testing.expectEqual(@as(?u8, 0xA5), sim.dut.rx_stream.get());

    // Send data command with valid header
    const hdr = PacketHeader{ .tag = 1, .len = 0x42 };
    sim.dut.cmd.set(PacketCommand{ .data = hdr });
    sim.step(1);
    try testing.expectEqual(@as(?u8, 0x42), sim.dut.rx_stream.get());
    try testing.expectEqual(@as(?PacketHeader, hdr), sim.dut.active_header.get());

    // Send null data (tag = 0) -> should clear active_header and rx_stream
    const null_hdr = PacketHeader{ .tag = 0, .len = 0x10 };
    sim.dut.cmd.set(PacketCommand{ .data = null_hdr });
    sim.step(1);
    try testing.expectEqual(@as(?u8, null), sim.dut.rx_stream.get());
    try testing.expectEqual(@as(?PacketHeader, null), sim.dut.active_header.get());
}
