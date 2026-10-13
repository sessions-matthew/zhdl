const std = @import("std");
const hir = @import("../hir.zig");
const token = @import("../token.zig");
const types = @import("types.zig");
const ArrayList = std.array_list.Managed;

pub const ElaboratedModule = struct {
    arena: *std.heap.ArenaAllocator,
    module: hir.HirModule,

    pub fn deinit(self: *ElaboratedModule) void {
        const child_alloc = self.arena.child_allocator;
        self.arena.deinit();
        child_alloc.destroy(self.arena);
    }
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    mod_name: []const u8,
    ports: ArrayList(hir.HirPort),
    registers: ArrayList(hir.HirRegister),
    local_signals: ArrayList(hir.HirSignal),
    comb_stmts: ArrayList(hir.HirStatement),
    instances: ArrayList(hir.HirSubmoduleInstance),
    clk_name: ?[]const u8 = null,
    rst_name: ?[]const u8 = null,
    rst_active_low: bool = false,
    rst_is_sync: bool = false,
    sync_stage_counter: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, mod_name: []const u8) !Builder {
        const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
        const aa = arena_ptr.allocator();
        return .{
            .allocator = allocator,
            .arena = arena_ptr,
            .mod_name = mod_name,
            .ports = ArrayList(hir.HirPort).init(aa),
            .registers = ArrayList(hir.HirRegister).init(aa),
            .local_signals = ArrayList(hir.HirSignal).init(aa),
            .comb_stmts = ArrayList(hir.HirStatement).init(aa),
            .instances = ArrayList(hir.HirSubmoduleInstance).init(aa),
        };
    }

    pub fn deinit(self: *Builder) void {
        const child_alloc = self.arena.child_allocator;
        self.arena.deinit();
        child_alloc.destroy(self.arena);
    }

    pub fn arenaAlloc(self: *Builder) std.mem.Allocator {
        return self.arena.allocator();
    }

    // --- Expression Builders ---

    pub fn ref(self: *Builder, name: []const u8, hir_type: hir.HirType) *hir.HirExpr {
        const expr = self.arenaAlloc().create(hir.HirExpr) catch @panic("OOM");
        expr.* = .{
            .tag = .signal_ref,
            .hir_type = hir_type,
            .data = .{
                .signal_ref = .{ .name = name },
            },
        };
        return expr;
    }

    pub fn lit(self: *Builder, val: u64, width: u32) *hir.HirExpr {
        const expr = self.arenaAlloc().create(hir.HirExpr) catch @panic("OOM");
        const raw_str = std.fmt.allocPrint(self.arenaAlloc(), "{d}'d{d}", .{ width, val }) catch @panic("OOM");
        expr.* = .{
            .tag = .lit,
            .hir_type = .{
                .tag = .bits,
                .width = width,
                .is_signed = false,
            },
            .data = .{
                .lit = .{
                    .val = val,
                    .raw = raw_str,
                },
            },
        };
        return expr;
    }

    pub fn binary(self: *Builder, op: token.TokenType, left: *hir.HirExpr, right: *hir.HirExpr) *hir.HirExpr {
        const expr = self.arenaAlloc().create(hir.HirExpr) catch @panic("OOM");
        const res_w = @max(left.hir_type.width, right.hir_type.width);
        expr.* = .{
            .tag = .binary,
            .hir_type = .{
                .tag = .bits,
                .width = res_w,
                .is_signed = left.hir_type.is_signed and right.hir_type.is_signed,
            },
            .data = .{
                .binary = .{
                    .op = op,
                    .left = left,
                    .right = right,
                },
            },
        };
        return expr;
    }

    pub fn add(self: *Builder, left: *hir.HirExpr, right: *hir.HirExpr) *hir.HirExpr {
        return self.binary(.plus_percent, left, right);
    }

    pub fn sub(self: *Builder, left: *hir.HirExpr, right: *hir.HirExpr) *hir.HirExpr {
        return self.binary(.minus_percent, left, right);
    }

    pub fn eq(self: *Builder, left: *hir.HirExpr, right: *hir.HirExpr) *hir.HirExpr {
        const expr = self.arenaAlloc().create(hir.HirExpr) catch @panic("OOM");
        expr.* = .{
            .tag = .binary,
            .hir_type = .{ .tag = .bits, .width = 1 },
            .data = .{
                .binary = .{
                    .op = .equal_equal,
                    .left = left,
                    .right = right,
                },
            },
        };
        return expr;
    }

    pub fn ne(self: *Builder, left: *hir.HirExpr, right: *hir.HirExpr) *hir.HirExpr {
        const expr = self.arenaAlloc().create(hir.HirExpr) catch @panic("OOM");
        expr.* = .{
            .tag = .binary,
            .hir_type = .{ .tag = .bits, .width = 1 },
            .data = .{
                .binary = .{
                    .op = .bang_equal,
                    .left = left,
                    .right = right,
                },
            },
        };
        return expr;
    }

    pub fn bitOr(self: *Builder, left: *hir.HirExpr, right: *hir.HirExpr) *hir.HirExpr {
        return self.binary(.pipe, left, right);
    }

    pub fn bitAnd(self: *Builder, left: *hir.HirExpr, right: *hir.HirExpr) *hir.HirExpr {
        return self.binary(.ampersand, left, right);
    }

    pub fn logicalOr(self: *Builder, left: *hir.HirExpr, right: *hir.HirExpr) *hir.HirExpr {
        return self.binary(.kw_or, left, right);
    }

    pub fn logicalAnd(self: *Builder, left: *hir.HirExpr, right: *hir.HirExpr) *hir.HirExpr {
        return self.binary(.kw_and, left, right);
    }

    pub fn mux(self: *Builder, cond: *hir.HirExpr, then_expr: *hir.HirExpr, else_expr: *hir.HirExpr) *hir.HirExpr {
        const expr = self.arenaAlloc().create(hir.HirExpr) catch @panic("OOM");
        expr.* = .{
            .tag = .mux,
            .hir_type = then_expr.hir_type,
            .data = .{
                .mux = .{
                    .cond = cond,
                    .then_expr = then_expr,
                    .else_expr = else_expr,
                },
            },
        };
        return expr;
    }

    pub fn member(self: *Builder, target: *hir.HirExpr, field: []const u8) *hir.HirExpr {
        const expr = self.arenaAlloc().create(hir.HirExpr) catch @panic("OOM");
        var field_width: u32 = 1;
        if (target.hir_type.getStructField(field)) |f| {
            field_width = f.width;
        }
        expr.* = .{
            .tag = .member,
            .hir_type = .{ .tag = .bits, .width = field_width },
            .data = .{
                .member = .{
                    .target = target,
                    .field = field,
                },
            },
        };
        return expr;
    }

    // --- Statement Builders ---

    pub fn assign(self: *Builder, target: *hir.HirExpr, val: *hir.HirExpr) hir.HirStatement {
        _ = self;
        return .{
            .tag = .assign,
            .data = .{
                .assign = .{
                    .target = target,
                    .value = val,
                },
            },
        };
    }

    pub fn ifThen(self: *Builder, cond: *hir.HirExpr, then_body: []const hir.HirStatement) hir.HirStatement {
        const body_copy = self.arenaAlloc().dupe(hir.HirStatement, then_body) catch @panic("OOM");
        return .{
            .tag = .if_stmt,
            .data = .{
                .if_stmt = .{
                    .cond = cond,
                    .then_body = body_copy,
                    .else_body = null,
                },
            },
        };
    }

    pub fn ifElse(self: *Builder, cond: *hir.HirExpr, then_body: []const hir.HirStatement, else_body: []const hir.HirStatement) hir.HirStatement {
        const tb_copy = self.arenaAlloc().dupe(hir.HirStatement, then_body) catch @panic("OOM");
        const eb_copy = self.arenaAlloc().dupe(hir.HirStatement, else_body) catch @panic("OOM");
        return .{
            .tag = .if_stmt,
            .data = .{
                .if_stmt = .{
                    .cond = cond,
                    .then_body = tb_copy,
                    .else_body = eb_copy,
                },
            },
        };
    }

    pub fn addComb(self: *Builder, stmt: hir.HirStatement) !void {
        try self.comb_stmts.append(stmt);
    }

    pub fn addCombSlice(self: *Builder, stmts: []const hir.HirStatement) !void {
        try self.comb_stmts.appendSlice(stmts);
    }

    // --- High-Level Synchronizer Builtin (@sync2ff) ---

    pub fn sync2ff(self: *Builder, clk_name: []const u8, async_signal_name: []const u8, width: u32) []const u8 {
        const alloc = self.arenaAlloc();
        const stage1_name = std.fmt.allocPrint(alloc, "_sync_{s}_s1", .{async_signal_name}) catch @panic("OOM");
        const stage2_name = std.fmt.allocPrint(alloc, "_sync_{s}_s2", .{async_signal_name}) catch @panic("OOM");

        const htype = hir.HirType{
            .tag = .bits,
            .width = width,
        };

        // Create 2 sync flop stages
        self.registers.append(.{
            .name = stage1_name,
            .q_name = stage1_name,
            .d_name = std.fmt.allocPrint(alloc, "{s}_d", .{stage1_name}) catch @panic("OOM"),
            .hir_type = htype,
            .clk_name = clk_name,
            .rst_name = self.rst_name,
            .rst_active_low = self.rst_active_low,
            .rst_is_sync = self.rst_is_sync,
            .init_val = 0,
            .is_sync_stage = true,
        }) catch @panic("OOM");

        self.registers.append(.{
            .name = stage2_name,
            .q_name = stage2_name,
            .d_name = std.fmt.allocPrint(alloc, "{s}_d", .{stage2_name}) catch @panic("OOM"),
            .hir_type = htype,
            .clk_name = clk_name,
            .rst_name = self.rst_name,
            .rst_active_low = self.rst_active_low,
            .rst_is_sync = self.rst_is_sync,
            .init_val = 0,
            .is_sync_stage = true,
        }) catch @panic("OOM");

        // Drive stage 1 from async_signal, stage 2 from stage 1
        const s1_d = self.ref(std.fmt.allocPrint(alloc, "{s}_d", .{stage1_name}) catch @panic("OOM"), htype);
        const async_ref = self.ref(async_signal_name, htype);
        self.comb_stmts.append(self.assign(s1_d, async_ref)) catch @panic("OOM");

        const s2_d = self.ref(std.fmt.allocPrint(alloc, "{s}_d", .{stage2_name}) catch @panic("OOM"), htype);
        const s1_q = self.ref(stage1_name, htype);
        self.comb_stmts.append(self.assign(s2_d, s1_q)) catch @panic("OOM");

        return stage2_name;
    }

    /// Build and freeze final HirModule
    pub fn finish(self: *Builder) !ElaboratedModule {
        const alloc = self.arenaAlloc();
        return .{
            .arena = self.arena,
            .module = hir.HirModule{
                .name = self.mod_name,
                .ports = try alloc.dupe(hir.HirPort, self.ports.items),
                .registers = try alloc.dupe(hir.HirRegister, self.registers.items),
                .local_signals = try alloc.dupe(hir.HirSignal, self.local_signals.items),
                .comb_stmts = try alloc.dupe(hir.HirStatement, self.comb_stmts.items),
                .instances = try alloc.dupe(hir.HirSubmoduleInstance, self.instances.items),
            },
        };
    }
};

fn sanitizeModuleName(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var buf = try allocator.alloc(u8, raw.len);
    for (raw, 0..) |c, i| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            buf[i] = c;
        } else {
            buf[i] = '_';
        }
    }
    return std.mem.trimEnd(u8, buf, "_");
}

/// Elaborate any pure Zig module struct into an ElaboratedModule
pub fn elaborate(comptime Mod: type, allocator: std.mem.Allocator) !ElaboratedModule {
    const raw_name = @typeName(Mod);
    // Find base name (after last dot)
    const base_name = if (std.mem.lastIndexOfScalar(u8, raw_name, '.')) |dot_idx|
        raw_name[dot_idx + 1 ..]
    else
        raw_name;

    var b = try Builder.init(allocator, base_name);
    errdefer b.deinit();

    const mod_name = try sanitizeModuleName(b.arenaAlloc(), base_name);
    b.mod_name = mod_name;

    const info = @typeInfo(Mod);
    if (info != .@"struct") {
        @compileError("Only struct types can be elaborated into ZHdl modules: " ++ raw_name);
    }

    const s = info.@"struct";

    // 1. First pass: find default Clock and Reset ports
    inline for (s.field_names, s.field_types) |fname, ftype| {
        if (comptime types.isPort(ftype)) {
            const DataT = ftype.DataType;
            if (comptime types.isClock(DataT)) {
                if (b.clk_name == null) b.clk_name = fname;
            } else if (comptime types.isReset(DataT)) {
                if (b.rst_name == null) {
                    b.rst_name = fname;
                    b.rst_active_low = (DataT.polarity == .active_low);
                    b.rst_is_sync = (DataT.reset_mode == .sync);
                }
            }
        }
    }

    // 2. Second pass: extract Ports
    inline for (s.field_names, s.field_types) |fname, ftype| {
        if (comptime types.isPort(ftype)) {
            const dir: hir.HirPortDir = switch (ftype.direction) {
                .in => .in,
                .out => .out,
                .inout => .inout,
            };

            const is_async_port = comptime types.isAsync(ftype.DataType);
            const hir_t = try types.toHirType(b.arenaAlloc(), ftype.DataType);

            try b.ports.append(.{
                .name = fname,
                .dir = dir,
                .hir_type = hir_t,
                .is_async = is_async_port,
            });
        }
    }

    // 3. Third pass: extract Registers
    inline for (s.field_names, s.field_types) |fname, ftype| {
        if (comptime types.isReg(ftype)) {
            const hir_t = try types.toHirType(b.arenaAlloc(), ftype.DataType);
            const clk = b.clk_name orelse return error.MissingClockForRegister;
            const d_name = try std.fmt.allocPrint(b.arenaAlloc(), "{s}_d", .{fname});

            try b.registers.append(.{
                .name = fname,
                .q_name = fname,
                .d_name = d_name,
                .hir_type = hir_t,
                .clk_name = clk,
                .rst_name = b.rst_name,
                .rst_active_low = b.rst_active_low,
                .rst_is_sync = b.rst_is_sync,
                .init_val = 0,
                .is_sync_stage = false,
            });
        }
    }

    // 4. Fourth pass: invoke custom build() method if defined on Mod
    if (@hasDecl(Mod, "build")) {
        try Mod.build(&b);
    }

    return b.finish();
}
