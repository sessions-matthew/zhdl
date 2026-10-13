const std = @import("std");
const hir = @import("../hir.zig");

pub const Clock = struct {
    _is_clock: void = {},
    val: u1 = 0,

    pub fn get(self: @This()) u1 {
        return self.val;
    }

    pub fn set(self: *@This(), v: u1) void {
        self.val = v;
    }
};

pub const ResetMode = enum {
    async,
    sync,
};

pub fn UInt(comptime bits: u16) type {
    return @Int(.unsigned, bits);
}

pub fn SInt(comptime bits: u16) type {
    return @Int(.signed, bits);
}

pub const ResetPolarity = enum {
    active_high,
    active_low,
};

pub fn Reset(comptime mode: ResetMode, comptime pol: ResetPolarity) type {
    return struct {
        pub const is_reset = true;
        pub const reset_mode = mode;
        pub const polarity = pol;

        val: u1 = if (pol == .active_low) 1 else 0,

        pub fn get(self: @This()) u1 {
            return self.val;
        }

        pub fn set(self: *@This(), v: u1) void {
            self.val = v;
        }

        pub fn isActive(self: @This()) bool {
            return if (pol == .active_low) self.val == 0 else self.val == 1;
        }
    };
}

pub const AsyncReset = Reset(.async, .active_high);
pub const AsyncResetActiveLow = Reset(.async, .active_low);
pub const SyncReset = Reset(.sync, .active_high);
pub const SyncResetActiveLow = Reset(.sync, .active_low);

/// Qualifier for asynchronous external pins (e.g. In(Async(u1)))
pub fn Async(comptime T: type) type {
    return struct {
        pub const is_async_qualifier = true;
        pub const InnerType = T;
        val: T = undefined,

        pub fn get(self: @This()) T {
            return self.val;
        }

        pub fn set(self: *@This(), v: T) void {
            self.val = v;
        }
    };
}

pub const PortDirection = enum {
    in,
    out,
    inout,
};

pub fn In(comptime T: type) type {
    return struct {
        pub const is_port = true;
        pub const direction: PortDirection = .in;
        pub const DataType = T;

        val: T = undefined,

        pub fn get(self: @This()) if (isAsync(T)) T.InnerType else T {
            if (comptime isAsync(T)) {
                return self.val.val;
            } else {
                return self.val;
            }
        }

        pub fn set(self: *@This(), v: anytype) void {
            if (comptime isClock(T)) {
                if (@TypeOf(v) == Clock) {
                    self.val = v;
                } else {
                    self.val.val = @intCast(v);
                }
            } else if (comptime isReset(T)) {
                if (@TypeOf(v) == T) {
                    self.val = v;
                } else {
                    self.val.val = @intCast(v);
                }
            } else if (comptime isAsync(T)) {
                if (@TypeOf(v) == T) {
                    self.val = v;
                } else {
                    self.val.val = @as(T.InnerType, v);
                }
            } else {
                self.val = if (@TypeOf(v) == T) v else @as(T, v);
            }
        }

        pub fn isActive(self: @This()) bool {
            if (comptime isReset(T)) {
                return self.val.isActive();
            }
            return false;
        }
    };
}

pub fn Out(comptime T: type) type {
    return struct {
        pub const is_port = true;
        pub const direction: PortDirection = .out;
        pub const DataType = T;

        val: T = undefined,

        pub fn get(self: @This()) T {
            return self.val;
        }

        pub fn set(self: *@This(), v: anytype) void {
            self.val = if (@TypeOf(v) == T) v else @as(T, v);
        }
    };
}

pub fn InOut(comptime T: type) type {
    return struct {
        pub const is_port = true;
        pub const direction: PortDirection = .inout;
        pub const DataType = T;

        val: T = undefined,

        pub fn get(self: @This()) T {
            return self.val;
        }

        pub fn set(self: *@This(), v: anytype) void {
            self.val = if (@TypeOf(v) == T) v else @as(T, v);
        }
    };
}

/// Sequential clocked register with explicit reset and default-hold semantics
pub fn Reg(comptime T: type) type {
    return struct {
        pub const is_reg = true;
        pub const DataType = T;

        q: T,
        d: T,
        init_val: T,

        pub fn init(reset_value: T) @This() {
            return .{
                .q = reset_value,
                .d = reset_value,
                .init_val = reset_value,
            };
        }

        pub fn get(self: @This()) T {
            return self.q;
        }

        pub fn set(self: *@This(), val: anytype) void {
            self.d = if (@TypeOf(val) == T) val else @as(T, val);
        }

        pub fn commit(self: *@This()) void {
            self.q = self.d;
        }

        pub fn hold(self: *@This()) void {
            self.d = self.q;
        }

        pub fn reset(self: *@This()) void {
            self.q = self.init_val;
            self.d = self.init_val;
        }
    };
}

/// Combinational wire
pub fn Wire(comptime T: type) type {
    return struct {
        pub const is_wire = true;
        pub const DataType = T;

        val: T = if (@typeInfo(T) == .@"struct" or @typeInfo(T) == .int or @typeInfo(T) == .bool) std.mem.zeroes(T) else undefined,

        pub fn get(self: @This()) T {
            return self.val;
        }

        pub fn set(self: *@This(), v: T) void {
            self.val = v;
        }
    };
}

fn isContainer(comptime T: type) bool {
    const tag = @typeInfo(T);
    return tag == .@"struct" or tag == .@"enum" or tag == .@"union" or tag == .@"opaque";
}

pub fn isClock(comptime T: type) bool {
    return T == Clock;
}

pub fn isReset(comptime T: type) bool {
    if (!isContainer(T)) return false;
    return @hasDecl(T, "is_reset") and T.is_reset;
}

pub fn isAsync(comptime T: type) bool {
    if (!isContainer(T)) return false;
    return @hasDecl(T, "is_async_qualifier") and T.is_async_qualifier;
}

pub fn isPort(comptime T: type) bool {
    if (!isContainer(T)) return false;
    return @hasDecl(T, "is_port") and T.is_port;
}

pub fn isReg(comptime T: type) bool {
    if (!isContainer(T)) return false;
    return @hasDecl(T, "is_reg") and T.is_reg;
}

pub fn isWire(comptime T: type) bool {
    if (!isContainer(T)) return false;
    return @hasDecl(T, "is_wire") and T.is_wire;
}

/// Helper to compute bitwidth of any supported hardware type at comptime
pub fn bitWidth(comptime T: type) u32 {
    if (comptime isClock(T)) return 1;
    if (comptime isReset(T)) return 1;
    if (comptime isAsync(T)) return bitWidth(T.InnerType);
    if (T == bool) return 1;

    const info = @typeInfo(T);
    switch (info) {
        .int => |i| return @intCast(i.bits),
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                return @intCast(@bitSizeOf(T));
            }
            var total: u32 = 0;
            inline for (s.field_types) |ft| {
                total += bitWidth(ft);
            }
            return total;
        },
        .@"enum" => |e| {
            return bitWidth(e.tag_type);
        },
        .optional => |opt| {
            return 1 + bitWidth(opt.child);
        },
        .array => |arr| {
            return @intCast(arr.len * bitWidth(arr.child));
        },
        .@"union" => |u| {
            if (u.tag_type) |tag_t| {
                const tag_w = bitWidth(tag_t);
                var max_payload_w: u32 = 0;
                inline for (u.field_types) |ft| {
                    if (ft != void) {
                        const pw = bitWidth(ft);
                        if (pw > max_payload_w) max_payload_w = pw;
                    }
                }
                return tag_w + max_payload_w;
            }
            @compileError("Only tagged unions (union(enum)) are synthesizable in hardware");
        },
        else => @compileError("Unsupported hardware type for bitWidth: " ++ @typeName(T)),
    }
}

/// Convert a pure Zig type into a ZHdl HirType using std.heap / Allocator
pub fn toHirType(allocator: std.mem.Allocator, comptime T: type) !hir.HirType {
    if (comptime isClock(T)) {
        return hir.HirType{
            .tag = .clock,
            .width = 1,
            .name = "clock",
        };
    }

    if (comptime isReset(T)) {
        return hir.HirType{
            .tag = .reset,
            .width = 1,
            .is_active_low = (T.polarity == .active_low),
            .is_sync = (T.reset_mode == .sync),
            .name = "reset",
        };
    }

    if (comptime isAsync(T)) {
        return toHirType(allocator, T.InnerType);
    }

    if (T == bool) {
        return hir.HirType{
            .tag = .bits,
            .width = 1,
            .is_signed = false,
            .name = "bool",
        };
    }

    const info = @typeInfo(T);
    switch (info) {
        .int => |i| {
            return hir.HirType{
                .tag = .bits,
                .width = @intCast(i.bits),
                .is_signed = (i.signedness == .signed),
                .name = @typeName(T),
            };
        },
        .@"struct" => |s| {
            var fields = try allocator.alloc(hir.HirStructField, s.field_names.len);
            var offset: u32 = 0;
            inline for (s.field_names, s.field_types, 0..) |fname, ftype, idx| {
                const fw = bitWidth(ftype);
                fields[idx] = .{
                    .name = fname,
                    .width = fw,
                    .offset = offset,
                };
                offset += fw;
            }

            return hir.HirType{
                .tag = .packed_struct,
                .width = offset,
                .name = @typeName(T),
                .struct_fields = fields,
            };
        },
        .@"enum" => |e| {
            const tag_w = bitWidth(e.tag_type);
            var variants = try allocator.alloc(hir.HirEnumVariant, e.field_names.len);
            inline for (e.field_names, e.field_values, 0..) |fname, fval, idx| {
                variants[idx] = .{
                    .name = fname,
                    .value = @intCast(fval),
                };
            }

            return hir.HirType{
                .tag = .enum_type,
                .width = tag_w,
                .name = @typeName(T),
                .enum_variants = variants,
            };
        },
        .optional => |opt| {
            const inner_w = bitWidth(opt.child);
            return hir.HirType{
                .tag = .optional,
                .width = inner_w + 1,
                .elem_width = inner_w,
                .name = @typeName(T),
            };
        },
        .array => |arr| {
            const elem_w = bitWidth(arr.child);
            return hir.HirType{
                .tag = .array,
                .width = @intCast(arr.len * elem_w),
                .array_len = @intCast(arr.len),
                .elem_width = elem_w,
                .name = @typeName(T),
            };
        },
        .@"union" => |u| {
            if (u.tag_type) |tag_t| {
                const tag_w = bitWidth(tag_t);
                var max_payload_w: u32 = 0;
                var union_fields = try allocator.alloc(hir.HirUnionField, u.field_names.len);

                inline for (u.field_names, u.field_types, 0..) |fname, ftype, idx| {
                    const tag_val: u64 = idx;
                    const pw: u32 = if (ftype == void) 0 else bitWidth(ftype);
                    if (pw > max_payload_w) max_payload_w = pw;

                    union_fields[idx] = .{
                        .name = fname,
                        .tag_value = tag_val,
                        .payload_width = pw,
                        .payload_type_name = if (ftype == void) "" else @typeName(ftype),
                    };
                }

                return hir.HirType{
                    .tag = .tagged_union,
                    .width = tag_w + max_payload_w,
                    .tag_width = tag_w,
                    .name = @typeName(T),
                    .union_fields = union_fields,
                };
            }
            return error.UntaggedUnionNotSupported;
        },
        else => return error.UnsupportedType,
    }
}
