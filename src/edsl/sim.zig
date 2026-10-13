const std = @import("std");
const types = @import("types.zig");

pub fn Sim(comptime Mod: type) type {
    return struct {
        dut: Mod,
        time_ns: u64 = 0,

        pub fn init() @This() {
            var s: @This() = undefined;

            const st = @typeInfo(Mod).@"struct";

            inline for (st.field_names, st.field_types, st.field_attrs) |fname, ftype, fattr| {
                if (comptime types.isReg(ftype)) {
                    if (fattr.defaultValue(ftype)) |def| {
                        @field(s.dut, fname) = def;
                    } else {
                        @field(s.dut, fname) = ftype.init(std.mem.zeroes(ftype.DataType));
                    }
                } else if (comptime types.isPort(ftype)) {
                    if (comptime types.isReset(ftype.DataType)) {
                        @field(s.dut, fname).val = ftype.DataType{};
                        @field(s.dut, fname).set(if (ftype.DataType.polarity == .active_low) 1 else 0);
                    } else if (comptime types.isClock(ftype.DataType)) {
                        @field(s.dut, fname).val = .{ .val = 0 };
                    } else {
                        @field(s.dut, fname).val = undefined;
                    }
                }
            }

            s.time_ns = 0;
            s.settle();
            return s;
        }

        /// Settle combinational logic (enforces default-hold D = Q on registers)
        pub fn settle(self: *@This()) void {
            inline for (@typeInfo(Mod).@"struct".field_names, @typeInfo(Mod).@"struct".field_types) |fname, ftype| {
                if (comptime types.isReg(ftype)) {
                    @field(self.dut, fname).hold();
                }
            }
            if (@hasDecl(Mod, "comb")) {
                self.dut.comb();
            }
        }

        /// Advance simulation clock by N clock cycles
        pub fn step(self: *@This(), cycles: u64) void {
            var c: u64 = 0;
            while (c < cycles) : (c += 1) {
                // Settle logic before rising edge
                self.settle();

                // Rising clock edge
                self.time_ns += 5;
                inline for (@typeInfo(Mod).@"struct".field_names, @typeInfo(Mod).@"struct".field_types) |fname, ftype| {
                    if (comptime types.isPort(ftype) and types.isClock(ftype.DataType)) {
                        @field(self.dut, fname).set(1);
                    }
                }

                // Check if any active reset is asserted
                var in_reset = false;
                inline for (@typeInfo(Mod).@"struct".field_names, @typeInfo(Mod).@"struct".field_types) |fname, ftype| {
                    if (comptime types.isPort(ftype) and types.isReset(ftype.DataType)) {
                        if (@field(self.dut, fname).isActive()) {
                            in_reset = true;
                        }
                    }
                }

                // Clock active flops
                inline for (@typeInfo(Mod).@"struct".field_names, @typeInfo(Mod).@"struct".field_types) |fname, ftype| {
                    if (comptime types.isReg(ftype)) {
                        if (in_reset) {
                            @field(self.dut, fname).reset();
                        } else {
                            @field(self.dut, fname).commit();
                        }
                    }
                }

                // Falling clock edge
                self.time_ns += 5;
                inline for (@typeInfo(Mod).@"struct".field_names, @typeInfo(Mod).@"struct".field_types) |fname, ftype| {
                    if (comptime types.isPort(ftype) and types.isClock(ftype.DataType)) {
                        @field(self.dut, fname).set(0);
                    }
                }

                // Settle after new Q values propagate
                self.settle();
            }
        }

        /// Assert synchronous or asynchronous reset for N cycles
        pub fn pulseReset(self: *@This(), cycles: u64) void {
            // Assert reset
            inline for (@typeInfo(Mod).@"struct".field_names, @typeInfo(Mod).@"struct".field_types) |fname, ftype| {
                if (comptime types.isPort(ftype) and types.isReset(ftype.DataType)) {
                    @field(self.dut, fname).set(if (ftype.DataType.polarity == .active_low) 0 else 1);
                }
            }

            // Immediately reset flops asynchronously
            inline for (@typeInfo(Mod).@"struct".field_names, @typeInfo(Mod).@"struct".field_types) |fname, ftype| {
                if (comptime types.isReg(ftype)) {
                    @field(self.dut, fname).reset();
                }
            }
            self.settle();

            // Clock while in reset
            self.step(cycles);

            // Deassert reset
            inline for (@typeInfo(Mod).@"struct".field_names, @typeInfo(Mod).@"struct".field_types) |fname, ftype| {
                if (comptime types.isPort(ftype) and types.isReset(ftype.DataType)) {
                    @field(self.dut, fname).set(if (ftype.DataType.polarity == .active_low) 1 else 0);
                }
            }
            self.settle();
        }
    };
}
