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

        pub fn bit(self: @This(), comptime idx: u16) u1 {
            return types_slice(self.get(), idx, idx);
        }

        pub fn slice(self: @This(), comptime high: u16, comptime low: u16) UInt(high - low + 1) {
            return types_slice(self.get(), high, low);
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

        pub fn next(self: *@This(), v: anytype) void {
            self.set(v);
        }

        pub fn bit(self: @This(), comptime idx: u16) u1 {
            return types_slice(self.val, idx, idx);
        }

        pub fn slice(self: @This(), comptime high: u16, comptime low: u16) UInt(high - low + 1) {
            return types_slice(self.val, high, low);
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

        pub fn next(self: *@This(), v: anytype) void {
            self.set(v);
        }

        pub fn bit(self: @This(), comptime idx: u16) u1 {
            return types_slice(self.val, idx, idx);
        }

        pub fn slice(self: @This(), comptime high: u16, comptime low: u16) UInt(high - low + 1) {
            return types_slice(self.val, high, low);
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

        pub fn read(self: @This()) T {
            return self.q;
        }

        pub fn set(self: *@This(), val: anytype) void {
            self.d = if (@TypeOf(val) == T) val else @as(T, val);
        }

        pub fn next(self: *@This(), val: anytype) void {
            self.set(val);
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

        pub fn bit(self: @This(), comptime idx: u16) u1 {
            return types_slice(self.q, idx, idx);
        }

        pub fn slice(self: @This(), comptime high: u16, comptime low: u16) UInt(high - low + 1) {
            return types_slice(self.q, high, low);
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

        pub fn next(self: *@This(), v: T) void {
            self.set(v);
        }

        pub fn bit(self: @This(), comptime idx: u16) u1 {
            return types_slice(self.val, idx, idx);
        }

        pub fn slice(self: @This(), comptime high: u16, comptime low: u16) UInt(high - low + 1) {
            return types_slice(self.val, high, low);
        }
    };
}

// ============================================================================
// Tier 1 Hardware Sugar: Ergonomic In-Language Bit Manipulation & Units
// ============================================================================

pub const Frequency = struct {
    hz: u64,
    pub fn toHz(self: Frequency) u64 {
        return self.hz;
    }
    pub fn toPeriodPs(self: Frequency) u64 {
        return 1_000_000_000_000 / self.hz;
    }
    pub fn toPeriodNs(self: Frequency) f64 {
        return 1_000_000_000.0 / @as(f64, @floatFromInt(self.hz));
    }
};

pub fn Hz(comptime val: u64) Frequency {
    return .{ .hz = val };
}
pub fn KHz(comptime val: u64) Frequency {
    return .{ .hz = val * 1_000 };
}
pub fn MHz(comptime val: u64) Frequency {
    return .{ .hz = val * 1_000_000 };
}
pub fn GHz(comptime val: u64) Frequency {
    return .{ .hz = val * 1_000_000_000 };
}

pub const Time = struct {
    ps: u64,
    pub fn toPs(self: Time) u64 {
        return self.ps;
    }
    pub fn toNs(self: Time) f64 {
        return @as(f64, @floatFromInt(self.ps)) / 1000.0;
    }
    pub fn toUs(self: Time) f64 {
        return @as(f64, @floatFromInt(self.ps)) / 1_000_000.0;
    }
    pub fn toMs(self: Time) f64 {
        return @as(f64, @floatFromInt(self.ps)) / 1_000_000_000.0;
    }
};

pub fn ps(comptime val: u64) Time {
    return .{ .ps = val };
}
pub fn ns(comptime val: u64) Time {
    return .{ .ps = val * 1_000 };
}
pub fn us(comptime val: u64) Time {
    return .{ .ps = val * 1_000_000 };
}
pub fn ms(comptime val: u64) Time {
    return .{ .ps = val * 1_000_000_000 };
}

pub fn UnwrapType(comptime T: type) type {
    if (comptime isClock(T)) return u1;
    if (comptime isReset(T)) return u1;
    if (comptime isAsync(T)) return T.InnerType;
    if (comptime isPort(T)) {
        if (comptime isAsync(T.DataType)) return T.DataType.InnerType;
        if (comptime isClock(T.DataType)) return u1;
        if (comptime isReset(T.DataType)) return u1;
        return T.DataType;
    }
    if (comptime isReg(T)) return T.DataType;
    if (comptime isWire(T)) return T.DataType;
    return T;
}

pub fn unwrapValue(val: anytype) UnwrapType(@TypeOf(val)) {
    const T = @TypeOf(val);
    if (comptime isClock(T)) return val.get();
    if (comptime isReset(T)) return val.get();
    if (comptime isAsync(T)) return val.get();
    if (comptime isPort(T)) return val.get();
    if (comptime isReg(T)) return val.get();
    if (comptime isWire(T)) return val.get();
    return val;
}

pub fn toUInt(val: anytype) UInt(bitWidth(@TypeOf(val))) {
    const T = @TypeOf(val);
    const W = comptime bitWidth(T);
    if (T == bool) {
        return if (val) 1 else 0;
    }
    const info = @typeInfo(T);
    switch (info) {
        .int => |i| {
            if (i.signedness == .unsigned) {
                return val;
            } else {
                return @as(UInt(W), @bitCast(val));
            }
        },
        .@"enum" => {
            return @intFromEnum(val);
        },
        .@"struct" => {
            return @as(UInt(W), @bitCast(val));
        },
        else => return @as(UInt(W), @bitCast(val)),
    }
}

fn CatTotalWidth(comptime Tuple: type) u16 {
    const info = @typeInfo(Tuple);
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("cat expects a tuple of signals, e.g. cat(.{ a, b, c })");
    }
    var total: u16 = 0;
    inline for (info.@"struct".field_types) |FT| {
        const Unwrapped = UnwrapType(FT);
        total += @intCast(bitWidth(Unwrapped));
    }
    return total;
}

/// Bitwise concatenation of multiple signals / integers, packed MSB to LSB.
/// Example: cat(.{ @as(u4, 0xA), @as(u8, 0x55) }) -> 0xA55 (u12)
pub fn cat(signals: anytype) UInt(CatTotalWidth(@TypeOf(signals))) {
    const Tuple = @TypeOf(signals);
    const TotalW = comptime CatTotalWidth(Tuple);
    const RetType = UInt(TotalW);
    if (TotalW == 0) return 0;

    var result: RetType = 0;
    inline for (@typeInfo(Tuple).@"struct".field_names) |fname| {
        const item = @field(signals, fname);
        const unwrapped = unwrapValue(item);
        const w = comptime bitWidth(@TypeOf(unwrapped));
        const uint_val = toUInt(unwrapped);
        result = (result << w) | @as(RetType, uint_val);
    }
    return result;
}

/// Slices bits [high:low] (inclusive) from any signal or integer.
/// Returns UInt(high - low + 1).
pub fn slice(signal: anytype, comptime high: u16, comptime low: u16) UInt(high - low + 1) {
    return types_slice(signal, high, low);
}

fn types_slice(signal: anytype, comptime high: u16, comptime low: u16) UInt(high - low + 1) {
    comptime {
        if (high < low) {
            @compileError("slice(high, low): high (" ++ std.fmt.comptimePrint("{}", .{high}) ++ ") must be >= low (" ++ std.fmt.comptimePrint("{}", .{low}) ++ ")");
        }
    }
    const W = high - low + 1;
    const unwrapped = unwrapValue(signal);
    const uint_val = toUInt(unwrapped);
    const shifted = uint_val >> low;
    return @as(UInt(W), @truncate(shifted));
}

/// Extracts a single bit at `idx` as `u1`.
pub fn bit(signal: anytype, comptime idx: u16) u1 {
    return types_slice(signal, idx, idx);
}

/// Replicates `signal` `count` times.
/// Example: rep(@as(u1, 1), 8) -> 0xFF (u8), rep(@as(u4, 0xA), 3) -> 0xAAA (u12)
pub fn rep(signal: anytype, comptime count: u16) UInt(count * bitWidth(UnwrapType(@TypeOf(signal)))) {
    const unwrapped = unwrapValue(signal);
    const ElemW = comptime bitWidth(@TypeOf(unwrapped));
    const TotalW = comptime count * ElemW;
    const RetType = UInt(TotalW);
    if (count == 0) return 0;

    const uint_elem = toUInt(unwrapped);
    if (ElemW == 1) {
        return if (uint_elem == 1) ~@as(RetType, 0) else 0;
    }

    var result: RetType = 0;
    inline for (0..count) |_| {
        result = (result << ElemW) | @as(RetType, uint_elem);
    }
    return result;
}

/// 2-to-1 Multiplexer helper: returns `a` if `cond != 0`, else `b`.
pub fn mux(cond: anytype, a: anytype, b: anytype) @TypeOf(unwrapValue(a)) {
    const c = unwrapValue(cond);
    const is_true = switch (@typeInfo(@TypeOf(c))) {
        .bool => c,
        else => c != 0,
    };
    return if (is_true) unwrapValue(a) else unwrapValue(b);
}

/// Sign-extends `signal` to `Target` type (signed or unsigned integer).
pub fn signExtend(comptime Target: type, signal: anytype) Target {
    const unwrapped = unwrapValue(signal);
    const InType = @TypeOf(unwrapped);
    const InW = comptime bitWidth(InType);
    const OutW = comptime bitWidth(Target);
    comptime {
        if (OutW < InW) {
            @compileError("signExtend: Target width (" ++ std.fmt.comptimePrint("{}", .{OutW}) ++ ") cannot be smaller than input width (" ++ std.fmt.comptimePrint("{}", .{InW}) ++ ")");
        }
    }
    const signed_in = @as(@Int(.signed, InW), @bitCast(toUInt(unwrapped)));
    const signed_out = @as(@Int(.signed, OutW), signed_in);
    const out_info = @typeInfo(Target);
    if (out_info == .int and out_info.int.signedness == .signed) {
        return signed_out;
    } else {
        return @as(Target, @bitCast(signed_out));
    }
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
