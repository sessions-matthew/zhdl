const std = @import("std");
const zhdl = @import("zhdl");

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
        clk: zhdl.In(zhdl.Clock),
        rst_n: zhdl.In(zhdl.AsyncResetActiveLow),
        ext_enable: zhdl.In(zhdl.Async(u1)),
        cmd: zhdl.In(PacketCommand),
        rx_stream: zhdl.Out(?zhdl.UInt(W)),

        active_header: zhdl.Reg(?PacketHeader) = .init(null),
        _sync_s1: zhdl.Reg(u1) = .init(0),
        _sync_s2: zhdl.Reg(u1) = .init(0),

        pub fn build(b: *zhdl.Builder) !void {
            _ = b.sync2ff("clk", "ext_enable", 1);
        }

        pub fn comb(self: *@This()) void {
            self._sync_s1.set(self.ext_enable.get());
            self._sync_s2.set(self._sync_s1.get());
            const enable = self._sync_s2.get() == 1;

            switch (self.cmd.get()) {
                .ping => |echo| {
                    self.rx_stream.set(if (enable) @as(zhdl.UInt(W), @truncate(echo)) else null);
                },
                .data => |hdr| {
                    if (hdr.isNull() or !enable) {
                        self.active_header.set(null);
                        self.rx_stream.set(null);
                    } else {
                        self.active_header.set(hdr);
                        self.rx_stream.set(@as(zhdl.UInt(W), @truncate(hdr.len)));
                    }
                },
                .idle => {
                    self.rx_stream.set(null);
                },
            }
        }
    };
}

test "PacketFilter synthesis to SystemVerilog" {
    const allocator = std.testing.allocator;

    const sv = try zhdl.emitSystemVerilog(PacketFilter(8), allocator);
    defer allocator.free(sv);

    try std.testing.expect(std.mem.indexOf(u8, sv, "module PacketFilter_8 (") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "input  logic       ext_enable") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "output logic [ 8:0] rx_stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "_sync_ext_enable_s1") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "_sync_ext_enable_s2") != null);
}

test "PacketFilter CDC synchronization and command decoding" {
    var sim = zhdl.Sim(PacketFilter(8)).init();

    // Reset module
    sim.pulseReset(2);
    try std.testing.expectEqual(@as(?u8, null), sim.dut.rx_stream.get());

    // Set async enable pin and step 2 cycles for 2-stage synchronizer
    sim.dut.ext_enable.set(1);
    sim.step(2);

    // Send ping
    sim.dut.cmd.set(PacketCommand{ .ping = 0xA5 });
    sim.settle();
    try std.testing.expectEqual(@as(?u8, 0xA5), sim.dut.rx_stream.get());

    // Send valid packet
    const hdr = PacketHeader{ .tag = 1, .len = 0x55 };
    sim.dut.cmd.set(PacketCommand{ .data = hdr });
    sim.step(1);
    try std.testing.expectEqual(@as(?u8, 0x55), sim.dut.rx_stream.get());
    try std.testing.expectEqual(@as(?PacketHeader, hdr), sim.dut.active_header.get());

    // Send null packet (tag = 0)
    const null_hdr = PacketHeader{ .tag = 0, .len = 0x99 };
    sim.dut.cmd.set(PacketCommand{ .data = null_hdr });
    sim.step(1);
    try std.testing.expectEqual(@as(?u8, null), sim.dut.rx_stream.get());
    try std.testing.expectEqual(@as(?PacketHeader, null), sim.dut.active_header.get());
}
