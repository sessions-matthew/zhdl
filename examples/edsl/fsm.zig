const std = @import("std");
const zhdl = @import("zhdl");

pub const State = enum(u2) {
    idle = 0,
    read = 1,
    write = 2,
    done = 3,
};

pub const Fsm = struct {
    clk: zhdl.In(zhdl.Clock),
    rst_n: zhdl.In(zhdl.AsyncResetActiveLow),
    start: zhdl.In(u1),
    busy: zhdl.Out(u1),
    done_pulse: zhdl.Out(u1),

    state: zhdl.Reg(State) = .init(.idle),

    pub fn build(b: *zhdl.Builder) !void {
        const u1_t = zhdl.hir.HirType{ .tag = .bits, .width = 1 };
        const u2_t = zhdl.hir.HirType{ .tag = .bits, .width = 2 };

        const start_ref = b.ref("start", u1_t);
        const state_q = b.ref("state", u2_t);
        const state_d = b.ref("state_d", u2_t);
        const busy_out = b.ref("busy", u1_t);
        const done_out = b.ref("done_pulse", u1_t);

        // State encoding: 0 = idle, 1 = read, 2 = write, 3 = done
        // busy = (state == 1) or (state == 2)
        const is_read = b.eq(state_q, b.lit(1, 2));
        const is_write = b.eq(state_q, b.lit(2, 2));
        const is_done = b.eq(state_q, b.lit(3, 2));
        const is_idle = b.eq(state_q, b.lit(0, 2));

        const is_busy = b.bitOr(is_read, is_write);
        try b.addComb(b.assign(busy_out, is_busy));
        try b.addComb(b.assign(done_out, is_done));

        // Next state calculation:
        // if (idle and start) read
        // else if (read) write
        // else if (write) done
        // else idle
        const next_from_idle = b.mux(b.eq(start_ref, b.lit(1, 1)), b.lit(1, 2), b.lit(0, 2));
        const next_from_read = b.lit(2, 2);
        const next_from_write = b.lit(3, 2);
        const next_from_done = b.lit(0, 2);

        const s3 = b.mux(is_done, next_from_done, b.lit(0, 2));
        const s2 = b.mux(is_write, next_from_write, s3);
        const s1 = b.mux(is_read, next_from_read, s2);
        const final_next = b.mux(is_idle, next_from_idle, s1);

        try b.addComb(b.assign(state_d, final_next));
    }

    pub fn comb(self: *@This()) void {
        // Safe default outputs prevent transparent latch inference
        self.busy.set(0);
        self.done_pulse.set(0);

        switch (self.state.get()) {
            .idle => {
                if (self.start.get() == 1) {
                    self.state.set(.read);
                }
            },
            .read => {
                self.busy.set(1);
                self.state.set(.write);
            },
            .write => {
                self.busy.set(1);
                self.state.set(.done);
            },
            .done => {
                self.done_pulse.set(1);
                self.state.set(.idle);
            },
        }
    }
};

test "Fsm synthesis to SystemVerilog" {
    const allocator = std.testing.allocator;

    const sv = try zhdl.emitSystemVerilog(Fsm, allocator);
    defer allocator.free(sv);

    try std.testing.expect(std.mem.indexOf(u8, sv, "module Fsm (") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "input  logic       start") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "output logic       busy") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "output logic       done_pulse") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "always_ff @(posedge clk or negedge rst_n) begin") != null);
}

test "Fsm cycle-by-cycle simulation" {
    var sim = zhdl.Sim(Fsm).init();

    // Reset into idle
    sim.pulseReset(2);
    try std.testing.expectEqual(State.idle, sim.dut.state.get());
    try std.testing.expectEqual(@as(u1, 0), sim.dut.busy.get());
    try std.testing.expectEqual(@as(u1, 0), sim.dut.done_pulse.get());

    // Step while in idle: remains idle
    sim.step(3);
    try std.testing.expectEqual(State.idle, sim.dut.state.get());

    // Trigger start pulse
    sim.dut.start.set(1);
    sim.step(1);
    sim.dut.start.set(0);

    // State 1: read (busy = 1)
    try std.testing.expectEqual(State.read, sim.dut.state.get());
    try std.testing.expectEqual(@as(u1, 1), sim.dut.busy.get());
    try std.testing.expectEqual(@as(u1, 0), sim.dut.done_pulse.get());

    // State 2: write (busy = 1)
    sim.step(1);
    try std.testing.expectEqual(State.write, sim.dut.state.get());
    try std.testing.expectEqual(@as(u1, 1), sim.dut.busy.get());
    try std.testing.expectEqual(@as(u1, 0), sim.dut.done_pulse.get());

    // State 3: done (busy = 0, done_pulse = 1)
    sim.step(1);
    try std.testing.expectEqual(State.done, sim.dut.state.get());
    try std.testing.expectEqual(@as(u1, 0), sim.dut.busy.get());
    try std.testing.expectEqual(@as(u1, 1), sim.dut.done_pulse.get());

    // Return to idle
    sim.step(1);
    try std.testing.expectEqual(State.idle, sim.dut.state.get());
    try std.testing.expectEqual(@as(u1, 0), sim.dut.busy.get());
    try std.testing.expectEqual(@as(u1, 0), sim.dut.done_pulse.get());
}
