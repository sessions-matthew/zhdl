const std = @import("std");
const ArrayList = std.array_list.Managed;
const ast = @import("ast.zig");
const hir = @import("hir.zig");
const TokenType = @import("token.zig").TokenType;

pub const ElaborateError = error{
    ModuleNotFound,
    PortNotFound,
    SymbolNotFound,
    TypeMismatch,
    InvalidComptimeExpr,
    SignalAlreadyDeclared,
    CannotAssignInputPort,
    MultipleDrivers,
    CombinationalLoop,
    ClockDomainCrossing,
    MissingClockSignal,
    OutOfMemory,
};

pub const Elaborator = struct {
    allocator: std.mem.Allocator,
    ast_tree: *const ast.AST,
    types: std.StringHashMap(hir.HirType),
    constants: std.StringHashMap(u64),
    allocated_struct_fields: ArrayList([]hir.HirStructField),
    allocated_union_fields: ArrayList([]hir.HirUnionField),
    allocated_enum_variants: ArrayList([]hir.HirEnumVariant),
    enum_variants: std.StringHashMap(u64),
    fn_decls: std.StringHashMap(ast.FnDecl),
    type_methods: std.StringHashMap(std.StringHashMap(ast.FnDecl)),
    param_env: ?*std.StringHashMap(*hir.HirExpr) = null,
    specialized_modules: std.StringHashMap(void),

    // Active elaboration state for dynamic register/signal injection (e.g. @sync2ff)
    active_registers: ?*ArrayList(hir.HirRegister) = null,
    active_local_signals: ?*ArrayList(hir.HirSignal) = null,
    active_comb_stmts: ?*ArrayList(hir.HirStatement) = null,
    active_reg_map: ?*std.StringHashMap(hir.HirRegister) = null,
    active_signal_types: ?*std.StringHashMap(hir.HirType) = null,
    next_sync_id: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, ast_tree: *const ast.AST) Elaborator {
        return .{
            .allocator = allocator,
            .ast_tree = ast_tree,
            .types = std.StringHashMap(hir.HirType).init(allocator),
            .constants = std.StringHashMap(u64).init(allocator),
            .allocated_struct_fields = ArrayList([]hir.HirStructField).init(allocator),
            .allocated_union_fields = ArrayList([]hir.HirUnionField).init(allocator),
            .allocated_enum_variants = ArrayList([]hir.HirEnumVariant).init(allocator),
            .enum_variants = std.StringHashMap(u64).init(allocator),
            .fn_decls = std.StringHashMap(ast.FnDecl).init(allocator),
            .type_methods = std.StringHashMap(std.StringHashMap(ast.FnDecl)).init(allocator),
            .specialized_modules = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Elaborator) void {
        for (self.allocated_struct_fields.items) |sf| {
            self.allocator.free(sf);
        }
        self.allocated_struct_fields.deinit();
        for (self.allocated_union_fields.items) |uf| {
            self.allocator.free(uf);
        }
        self.allocated_union_fields.deinit();
        for (self.allocated_enum_variants.items) |ev| {
            self.allocator.free(ev);
        }
        self.allocated_enum_variants.deinit();
        self.enum_variants.deinit();
        var tit = self.type_methods.valueIterator();
        while (tit.next()) |m_map| {
            m_map.deinit();
        }
        self.type_methods.deinit();
        self.specialized_modules.deinit();
        self.fn_decls.deinit();
        self.types.deinit();
        self.constants.deinit();
    }

    fn registerTypeMethods(self: *Elaborator, type_name: []const u8, te: *ast.Type) !void {
        if (te.tag == .packed_struct) {
            var m_map = std.StringHashMap(ast.FnDecl).init(self.allocator);
            for (te.data.packed_struct.methods) |m| {
                try m_map.put(m.name, m);
            }
            try self.type_methods.put(type_name, m_map);
        } else if (te.tag == .tagged_union) {
            var m_map = std.StringHashMap(ast.FnDecl).init(self.allocator);
            for (te.data.tagged_union.methods) |m| {
                try m_map.put(m.name, m);
            }
            try self.type_methods.put(type_name, m_map);
        }
    }

    const ParamValue = union(enum) {
        int_val: u64,
        type_val: *ast.Type,
        expr_val: *ast.Expr,
    };

    const ParamSubst = struct {
        name: []const u8,
        value: ParamValue,
    };

    fn cloneModuleItems(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        items: []const ast.ModuleItem,
        substs: []const ParamSubst,
    ) std.mem.Allocator.Error![]ast.ModuleItem {
        var cloned = try alloc.alloc(ast.ModuleItem, items.len);
        for (items, 0..) |item, i| {
            cloned[i] = try self.cloneModuleItem(alloc, item, substs);
        }
        return cloned;
    }

    fn cloneModuleItem(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        item: ast.ModuleItem,
        substs: []const ParamSubst,
    ) std.mem.Allocator.Error!ast.ModuleItem {
        switch (item.tag) {
            .port => {
                const p = item.data.port;
                return .{
                    .tag = .port,
                    .loc = item.loc,
                    .data = .{
                        .port = .{
                            .dir = p.dir,
                            .name = try alloc.dupe(u8, p.name),
                            .type_expr = try self.cloneType(alloc, p.type_expr, substs),
                        },
                    },
                };
            },
            .reg_decl => {
                const r = item.data.reg_decl;
                return .{
                    .tag = .reg_decl,
                    .loc = item.loc,
                    .data = .{
                        .reg_decl = .{
                            .name = try alloc.dupe(u8, r.name),
                            .type_expr = try self.cloneType(alloc, r.type_expr, substs),
                            .clk = if (r.clk) |c| try self.cloneExpr(alloc, c, substs) else null,
                            .rst = if (r.rst) |rst| try self.cloneExpr(alloc, rst, substs) else null,
                            .rst_polarity = r.rst_polarity,
                            .init_val = try self.cloneExpr(alloc, r.init_val, substs),
                        },
                    },
                };
            },
            .instance => {
                const inst = item.data.instance;
                var bindings = try alloc.alloc(ast.PortBinding, inst.bindings.len);
                for (inst.bindings, 0..) |b, i| {
                    bindings[i] = .{
                        .port_name = try alloc.dupe(u8, b.port_name),
                        .expr = try self.cloneExpr(alloc, b.expr, substs),
                        .loc = b.loc,
                    };
                }
                return .{
                    .tag = .instance,
                    .loc = item.loc,
                    .data = .{
                        .instance = .{
                            .name = try alloc.dupe(u8, inst.name),
                            .module_expr = try self.cloneExpr(alloc, inst.module_expr, substs),
                            .bindings = bindings,
                        },
                    },
                };
            },
            .comb_block => {
                return .{
                    .tag = .comb_block,
                    .loc = item.loc,
                    .data = .{
                        .comb_block = .{
                            .stmts = try self.cloneStatements(alloc, item.data.comb_block.stmts, substs),
                        },
                    },
                };
            },
            .sync_block => {
                const s = item.data.sync_block;
                return .{
                    .tag = .sync_block,
                    .loc = item.loc,
                    .data = .{
                        .sync_block = .{
                            .clk = try self.cloneExpr(alloc, s.clk, substs),
                            .rst = if (s.rst) |rst| try self.cloneExpr(alloc, rst, substs) else null,
                            .stmts = try self.cloneStatements(alloc, s.stmts, substs),
                        },
                    },
                };
            },
            .const_decl => {
                const c = item.data.const_decl;
                return .{
                    .tag = .const_decl,
                    .loc = item.loc,
                    .data = .{
                        .const_decl = .{
                            .name = try alloc.dupe(u8, c.name),
                            .type_annot = if (c.type_annot) |t| try self.cloneType(alloc, t, substs) else null,
                            .val = try self.cloneExpr(alloc, c.val, substs),
                        },
                    },
                };
            },
            .sim_block => {
                return .{
                    .tag = .sim_block,
                    .loc = item.loc,
                    .data = .{
                        .sim_block = .{
                            .stmts = try self.cloneStatements(alloc, item.data.sim_block.stmts, substs),
                        },
                    },
                };
            },
        }
    }

    fn cloneStatements(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        stmts: []const ast.Statement,
        substs: []const ParamSubst,
    ) std.mem.Allocator.Error![]ast.Statement {
        var cloned = try alloc.alloc(ast.Statement, stmts.len);
        for (stmts, 0..) |s, i| {
            cloned[i] = try self.cloneStatement(alloc, s, substs);
        }
        return cloned;
    }

    fn cloneStatement(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        stmt: ast.Statement,
        substs: []const ParamSubst,
    ) std.mem.Allocator.Error!ast.Statement {
        switch (stmt.tag) {
            .assign => {
                const a = stmt.data.assign;
                return .{
                    .tag = .assign,
                    .loc = stmt.loc,
                    .data = .{
                        .assign = .{
                            .target = try self.cloneExpr(alloc, a.target, substs),
                            .value = try self.cloneExpr(alloc, a.value, substs),
                            .is_reg_assign = a.is_reg_assign,
                        },
                    },
                };
            },
            .var_decl => {
                const v = stmt.data.var_decl;
                return .{
                    .tag = .var_decl,
                    .loc = stmt.loc,
                    .data = .{
                        .var_decl = .{
                            .name = try alloc.dupe(u8, v.name),
                            .type_annot = if (v.type_annot) |t| try self.cloneType(alloc, t, substs) else null,
                            .init_val = try self.cloneExpr(alloc, v.init_val, substs),
                        },
                    },
                };
            },
            .if_stmt => {
                const ifs = stmt.data.if_stmt;
                return .{
                    .tag = .if_stmt,
                    .loc = stmt.loc,
                    .data = .{
                        .if_stmt = .{
                            .cond = try self.cloneExpr(alloc, ifs.cond, substs),
                            .capture = if (ifs.capture) |cap| try alloc.dupe(u8, cap) else null,
                            .then_stmts = try self.cloneStatements(alloc, ifs.then_stmts, substs),
                            .else_stmts = if (ifs.else_stmts) |es| try self.cloneStatements(alloc, es, substs) else null,
                        },
                    },
                };
            },
            .switch_stmt => {
                const ss = stmt.data.switch_stmt;
                var cases = try alloc.alloc(ast.SwitchCase, ss.cases.len);
                for (ss.cases, 0..) |c, i| {
                    var patterns = try alloc.alloc(*ast.Expr, c.patterns.len);
                    for (c.patterns, 0..) |p, pi| {
                        patterns[pi] = try self.cloneExpr(alloc, p, substs);
                    }
                    cases[i] = .{
                        .patterns = patterns,
                        .capture = if (c.capture) |cap| try alloc.dupe(u8, cap) else null,
                        .is_else = c.is_else,
                        .body = try self.cloneStatements(alloc, c.body, substs),
                        .loc = c.loc,
                    };
                }
                return .{
                    .tag = .switch_stmt,
                    .loc = stmt.loc,
                    .data = .{
                        .switch_stmt = .{
                            .expr = try self.cloneExpr(alloc, ss.expr, substs),
                            .cases = cases,
                        },
                    },
                };
            },
            .inline_for => {
                const inf = stmt.data.inline_for;
                return .{
                    .tag = .inline_for,
                    .loc = stmt.loc,
                    .data = .{
                        .inline_for = .{
                            .var_name = try alloc.dupe(u8, inf.var_name),
                            .start = try self.cloneExpr(alloc, inf.start, substs),
                            .end = try self.cloneExpr(alloc, inf.end, substs),
                            .body = try self.cloneStatements(alloc, inf.body, substs),
                        },
                    },
                };
            },
            .expr_stmt => {
                return .{
                    .tag = .expr_stmt,
                    .loc = stmt.loc,
                    .data = .{
                        .expr_stmt = try self.cloneExpr(alloc, stmt.data.expr_stmt, substs),
                    },
                };
            },
        }
    }

    fn cloneType(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        t: *ast.Type,
        substs: []const ParamSubst,
    ) std.mem.Allocator.Error!*ast.Type {
        const new_t = try alloc.create(ast.Type);
        switch (t.tag) {
            .named => {
                for (substs) |s| {
                    if (std.mem.eql(u8, s.name, t.data.named)) {
                        switch (s.value) {
                            .type_val => |tv| return try self.cloneType(alloc, tv, substs),
                            .int_val => {},
                            .expr_val => {},
                        }
                    }
                }
                new_t.* = .{
                    .tag = .named,
                    .loc = t.loc,
                    .data = .{
                        .named = try alloc.dupe(u8, t.data.named),
                    },
                };
                return new_t;
            },
            .int => {
                new_t.* = .{
                    .tag = .int,
                    .loc = t.loc,
                    .data = .{
                        .int = .{
                            .is_signed = t.data.int.is_signed,
                            .width = try self.cloneExpr(alloc, t.data.int.width, substs),
                        },
                    },
                };
                return new_t;
            },
            .array => {
                new_t.* = .{
                    .tag = .array,
                    .loc = t.loc,
                    .data = .{
                        .array = .{
                            .len = try self.cloneExpr(alloc, t.data.array.len, substs),
                            .elem_type = try self.cloneType(alloc, t.data.array.elem_type, substs),
                        },
                    },
                };
                return new_t;
            },
            .optional => {
                new_t.* = .{
                    .tag = .optional,
                    .loc = t.loc,
                    .data = .{
                        .optional = try self.cloneType(alloc, t.data.optional, substs),
                    },
                };
                return new_t;
            },
            .enum_type => {
                var fields = try alloc.alloc(ast.EnumField, t.data.enum_type.fields.len);
                for (t.data.enum_type.fields, 0..) |f, i| {
                    fields[i] = .{
                        .name = try alloc.dupe(u8, f.name),
                        .value = if (f.value) |v| try self.cloneExpr(alloc, v, substs) else null,
                        .loc = f.loc,
                    };
                }
                new_t.* = .{
                    .tag = .enum_type,
                    .loc = t.loc,
                    .data = .{
                        .enum_type = .{
                            .tag_type = if (t.data.enum_type.tag_type) |tt| try self.cloneType(alloc, tt, substs) else null,
                            .fields = fields,
                        },
                    },
                };
                return new_t;
            },
            .packed_struct => {
                var fields = try alloc.alloc(ast.StructField, t.data.packed_struct.fields.len);
                for (t.data.packed_struct.fields, 0..) |f, i| {
                    fields[i] = .{
                        .name = try alloc.dupe(u8, f.name),
                        .type_expr = try self.cloneType(alloc, f.type_expr, substs),
                        .loc = f.loc,
                    };
                }
                new_t.* = .{
                    .tag = .packed_struct,
                    .loc = t.loc,
                    .data = .{
                        .packed_struct = .{
                            .fields = fields,
                            .methods = t.data.packed_struct.methods,
                        },
                    },
                };
                return new_t;
            },
            .tagged_union => {
                var fields = try alloc.alloc(ast.UnionField, t.data.tagged_union.fields.len);
                for (t.data.tagged_union.fields, 0..) |f, i| {
                    fields[i] = .{
                        .name = try alloc.dupe(u8, f.name),
                        .type_expr = if (f.type_expr) |te| try self.cloneType(alloc, te, substs) else null,
                        .loc = f.loc,
                    };
                }
                new_t.* = .{
                    .tag = .tagged_union,
                    .loc = t.loc,
                    .data = .{
                        .tagged_union = .{
                            .tag_type = if (t.data.tagged_union.tag_type) |tt| try self.cloneType(alloc, tt, substs) else null,
                            .fields = fields,
                            .methods = t.data.tagged_union.methods,
                        },
                    },
                };
                return new_t;
            },
            .reset => {
                new_t.* = .{
                    .tag = .reset,
                    .loc = t.loc,
                    .data = .{
                        .reset = .{
                            .is_active_low = t.data.reset.is_active_low,
                        },
                    },
                };
                return new_t;
            },
        }
    }

    fn cloneExpr(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        expr: *ast.Expr,
        substs: []const ParamSubst,
    ) std.mem.Allocator.Error!*ast.Expr {
        const new_e = try alloc.create(ast.Expr);
        switch (expr.tag) {
            .number => {
                new_e.* = .{
                    .tag = .number,
                    .loc = expr.loc,
                    .data = .{
                        .number = .{
                            .val = expr.data.number.val,
                            .raw = try alloc.dupe(u8, expr.data.number.raw),
                        },
                    },
                };
                return new_e;
            },
            .time_literal => {
                new_e.* = .{
                    .tag = .time_literal,
                    .loc = expr.loc,
                    .data = .{
                        .time_literal = .{
                            .val = expr.data.time_literal.val,
                            .unit = expr.data.time_literal.unit,
                            .raw = try alloc.dupe(u8, expr.data.time_literal.raw),
                        },
                    },
                };
                return new_e;
            },
            .freq_literal => {
                new_e.* = .{
                    .tag = .freq_literal,
                    .loc = expr.loc,
                    .data = .{
                        .freq_literal = .{
                            .val = expr.data.freq_literal.val,
                            .unit = expr.data.freq_literal.unit,
                            .raw = try alloc.dupe(u8, expr.data.freq_literal.raw),
                        },
                    },
                };
                return new_e;
            },
            .boolean => {
                new_e.* = .{
                    .tag = .boolean,
                    .loc = expr.loc,
                    .data = .{ .boolean = expr.data.boolean },
                };
                return new_e;
            },
            .string => {
                new_e.* = .{
                    .tag = .string,
                    .loc = expr.loc,
                    .data = .{ .string = try alloc.dupe(u8, expr.data.string) },
                };
                return new_e;
            },
            .identifier => {
                for (substs) |s| {
                    if (std.mem.eql(u8, s.name, expr.data.identifier)) {
                        switch (s.value) {
                            .int_val => |iv| {
                                new_e.* = .{
                                    .tag = .number,
                                    .loc = expr.loc,
                                    .data = .{
                                        .number = .{
                                            .val = iv,
                                            .raw = try std.fmt.allocPrint(alloc, "{d}", .{iv}),
                                        },
                                    },
                                };
                                return new_e;
                            },
                            .type_val => |tv| {
                                if (tv.tag == .named) {
                                    new_e.* = .{
                                        .tag = .identifier,
                                        .loc = expr.loc,
                                        .data = .{
                                            .identifier = try alloc.dupe(u8, tv.data.named),
                                        },
                                    };
                                    return new_e;
                                } else if (tv.tag == .int) {
                                    const w = self.evalConst(tv.data.int.width);
                                    new_e.* = .{
                                        .tag = .identifier,
                                        .loc = expr.loc,
                                        .data = .{
                                            .identifier = if (tv.data.int.is_signed)
                                                try std.fmt.allocPrint(alloc, "i{d}", .{w})
                                            else
                                                try std.fmt.allocPrint(alloc, "u{d}", .{w}),
                                        },
                                    };
                                    return new_e;
                                } else {
                                    const cloned_tv = try self.cloneType(alloc, tv, substs);
                                    new_e.* = .{
                                        .tag = .type_expr,
                                        .loc = expr.loc,
                                        .data = .{
                                            .type_expr = cloned_tv,
                                        },
                                    };
                                    return new_e;
                                }
                            },
                            .expr_val => |ev| {
                                return try self.cloneExpr(alloc, ev, substs);
                            },
                        }
                    }
                }
                new_e.* = .{
                    .tag = .identifier,
                    .loc = expr.loc,
                    .data = .{
                        .identifier = try alloc.dupe(u8, expr.data.identifier),
                    },
                };
                return new_e;
            },
            .enum_literal => {
                new_e.* = .{
                    .tag = .enum_literal,
                    .loc = expr.loc,
                    .data = .{ .enum_literal = try alloc.dupe(u8, expr.data.enum_literal) },
                };
                return new_e;
            },
            .null_lit => {
                new_e.* = .{
                    .tag = .null_lit,
                    .loc = expr.loc,
                    .data = .{ .null_lit = {} },
                };
                return new_e;
            },
            .unary => {
                new_e.* = .{
                    .tag = .unary,
                    .loc = expr.loc,
                    .data = .{
                        .unary = .{
                            .op = expr.data.unary.op,
                            .operand = try self.cloneExpr(alloc, expr.data.unary.operand, substs),
                        },
                    },
                };
                return new_e;
            },
            .binary => {
                new_e.* = .{
                    .tag = .binary,
                    .loc = expr.loc,
                    .data = .{
                        .binary = .{
                            .op = expr.data.binary.op,
                            .left = try self.cloneExpr(alloc, expr.data.binary.left, substs),
                            .right = try self.cloneExpr(alloc, expr.data.binary.right, substs),
                        },
                    },
                };
                return new_e;
            },
            .index => {
                new_e.* = .{
                    .tag = .index,
                    .loc = expr.loc,
                    .data = .{
                        .index = .{
                            .target = try self.cloneExpr(alloc, expr.data.index.target, substs),
                            .index = try self.cloneExpr(alloc, expr.data.index.index, substs),
                        },
                    },
                };
                return new_e;
            },
            .slice => {
                const sl = expr.data.slice;
                new_e.* = .{
                    .tag = .slice,
                    .loc = expr.loc,
                    .data = .{
                        .slice = .{
                            .target = try self.cloneExpr(alloc, sl.target, substs),
                            .start = try self.cloneExpr(alloc, sl.start, substs),
                            .end = try self.cloneExpr(alloc, sl.end, substs),
                            .is_downward = sl.is_downward,
                        },
                    },
                };
                return new_e;
            },
            .member_access => {
                const ma = expr.data.member_access;
                new_e.* = .{
                    .tag = .member_access,
                    .loc = expr.loc,
                    .data = .{
                        .member_access = .{
                            .target = try self.cloneExpr(alloc, ma.target, substs),
                            .field = try alloc.dupe(u8, ma.field),
                        },
                    },
                };
                return new_e;
            },
            .call => {
                const c = expr.data.call;
                var args = try alloc.alloc(*ast.Expr, c.args.len);
                for (c.args, 0..) |arg, i| {
                    args[i] = try self.cloneExpr(alloc, arg, substs);
                }
                new_e.* = .{
                    .tag = .call,
                    .loc = expr.loc,
                    .data = .{
                        .call = .{
                            .callee = try self.cloneExpr(alloc, c.callee, substs),
                            .args = args,
                        },
                    },
                };
                return new_e;
            },
            .builtin_call => {
                const bc = expr.data.builtin_call;
                var args = try alloc.alloc(*ast.Expr, bc.args.len);
                for (bc.args, 0..) |arg, i| {
                    args[i] = try self.cloneExpr(alloc, arg, substs);
                }
                new_e.* = .{
                    .tag = .builtin_call,
                    .loc = expr.loc,
                    .data = .{
                        .builtin_call = .{
                            .tag = bc.tag,
                            .args = args,
                        },
                    },
                };
                return new_e;
            },
            .struct_init => {
                const si = expr.data.struct_init;
                var fields = try alloc.alloc(ast.NamedExpr, si.fields.len);
                for (si.fields, 0..) |f, i| {
                    fields[i] = .{
                        .name = try alloc.dupe(u8, f.name),
                        .value = try self.cloneExpr(alloc, f.value, substs),
                        .loc = f.loc,
                    };
                }
                new_e.* = .{
                    .tag = .struct_init,
                    .loc = expr.loc,
                    .data = .{
                        .struct_init = .{
                            .type_expr = if (si.type_expr) |te| try self.cloneType(alloc, te, substs) else null,
                            .fields = fields,
                        },
                    },
                };
                return new_e;
            },
            .if_expr => {
                const ife = expr.data.if_expr;
                new_e.* = .{
                    .tag = .if_expr,
                    .loc = expr.loc,
                    .data = .{
                        .if_expr = .{
                            .cond = try self.cloneExpr(alloc, ife.cond, substs),
                            .then_branch = try self.cloneExpr(alloc, ife.then_branch, substs),
                            .else_branch = try self.cloneExpr(alloc, ife.else_branch, substs),
                        },
                    },
                };
                return new_e;
            },
            .type_expr => {
                new_e.* = .{
                    .tag = .type_expr,
                    .loc = expr.loc,
                    .data = .{
                        .type_expr = try self.cloneType(alloc, expr.data.type_expr, substs),
                    },
                };
                return new_e;
            },
            .module_literal => {
                new_e.* = .{
                    .tag = .module_literal,
                    .loc = expr.loc,
                    .data = .{
                        .module_literal = try self.cloneModuleItems(alloc, expr.data.module_literal, substs),
                    },
                };
                return new_e;
            },
        }
    }

    fn resolveGenericCall(
        self: *Elaborator,
        expr: *ast.Expr,
        local_items: ?[]const ast.ModuleItem,
    ) ?*ast.Expr {
        if (expr.tag == .call) {
            if (expr.data.call.callee.tag == .identifier) {
                if (self.fn_decls.get(expr.data.call.callee.data.identifier)) |fd| {
                    if (fd.body_expr.tag == .module_literal) {
                        return expr;
                    }
                }
            }
            return null;
        }
        if (expr.tag == .identifier) {
            const id_name = expr.data.identifier;
            if (local_items) |items| {
                for (items) |item| {
                    if (item.tag == .const_decl and std.mem.eql(u8, item.data.const_decl.name, id_name)) {
                        return self.resolveGenericCall(item.data.const_decl.val, local_items);
                    }
                }
            }
            for (self.ast_tree.decls) |decl| {
                if (decl.tag == .const_decl and std.mem.eql(u8, decl.data.const_decl.name, id_name)) {
                    return self.resolveGenericCall(decl.data.const_decl.val, local_items);
                }
            }
        }
        return null;
    }

    fn isTypeExprOrName(self: *Elaborator, expr: *ast.Expr) bool {
        if (expr.tag == .type_expr) return true;
        if (expr.tag == .call and expr.data.call.callee.tag == .identifier) {
            const cname = expr.data.call.callee.data.identifier;
            if ((std.mem.eql(u8, cname, "u") or std.mem.eql(u8, cname, "i")) and expr.data.call.args.len == 1) {
                return true;
            }
            if (std.mem.eql(u8, cname, "reset") and expr.data.call.args.len <= 1) {
                return true;
            }
        }
        if (expr.tag == .identifier) {
            const name = expr.data.identifier;
            if (std.mem.eql(u8, name, "clock") or std.mem.eql(u8, name, "reset") or std.mem.eql(u8, name, "reset_n") or std.mem.eql(u8, name, "reset_low")) return true;
            if (self.types.contains(name)) return true;
            if ((name[0] == 'u' or name[0] == 'i') and name.len > 1) {
                var all_digits = true;
                for (name[1..]) |ch| {
                    if (!std.ascii.isDigit(ch)) {
                        all_digits = false;
                        break;
                    }
                }
                if (all_digits) return true;
            }
        }
        return false;
    }

    fn exprToType(self: *Elaborator, alloc: std.mem.Allocator, expr: *ast.Expr) !*ast.Type {
        _ = self;
        if (expr.tag == .type_expr) {
            return expr.data.type_expr;
        }
        if (expr.tag == .call and expr.data.call.callee.tag == .identifier) {
            const cname = expr.data.call.callee.data.identifier;
            if ((std.mem.eql(u8, cname, "u") or std.mem.eql(u8, cname, "i")) and expr.data.call.args.len == 1) {
                const t = try alloc.create(ast.Type);
                t.* = .{
                    .tag = .int,
                    .loc = expr.loc,
                    .data = .{
                        .int = .{
                            .is_signed = std.mem.eql(u8, cname, "i"),
                            .width = expr.data.call.args[0],
                        },
                    },
                };
                return t;
            }
            if (std.mem.eql(u8, cname, "reset")) {
                var is_low = false;
                if (expr.data.call.args.len > 0) {
                    const arg0 = expr.data.call.args[0];
                    if (arg0.tag == .enum_literal) {
                        const lit = arg0.data.enum_literal;
                        if (std.mem.eql(u8, lit, "low") or std.mem.eql(u8, lit, "active_low")) {
                            is_low = true;
                        }
                    } else if (arg0.tag == .identifier) {
                        const id = arg0.data.identifier;
                        if (std.mem.eql(u8, id, "low") or std.mem.eql(u8, id, "active_low")) {
                            is_low = true;
                        }
                    }
                }
                const t = try alloc.create(ast.Type);
                t.* = .{
                    .tag = .reset,
                    .loc = expr.loc,
                    .data = .{
                        .reset = .{
                            .is_active_low = is_low,
                        },
                    },
                };
                return t;
            }
        }
        if (expr.tag == .identifier) {
            const name = expr.data.identifier;
            if (std.mem.eql(u8, name, "reset")) {
                const t = try alloc.create(ast.Type);
                t.* = .{
                    .tag = .reset,
                    .loc = expr.loc,
                    .data = .{
                        .reset = .{
                            .is_active_low = false,
                        },
                    },
                };
                return t;
            }
            if (std.mem.eql(u8, name, "reset_n") or std.mem.eql(u8, name, "reset_low")) {
                const t = try alloc.create(ast.Type);
                t.* = .{
                    .tag = .reset,
                    .loc = expr.loc,
                    .data = .{
                        .reset = .{
                            .is_active_low = true,
                        },
                    },
                };
                return t;
            }
            if ((name[0] == 'u' or name[0] == 'i') and name.len > 1) {
                var all_digits = true;
                for (name[1..]) |ch| {
                    if (!std.ascii.isDigit(ch)) {
                        all_digits = false;
                        break;
                    }
                }
                if (all_digits) {
                    const width_val = try std.fmt.parseInt(u64, name[1..], 10);
                    const w_expr = try alloc.create(ast.Expr);
                    w_expr.* = .{
                        .tag = .number,
                        .loc = expr.loc,
                        .data = .{
                            .number = .{
                                .val = width_val,
                                .raw = try alloc.dupe(u8, name[1..]),
                            },
                        },
                    };
                    const t = try alloc.create(ast.Type);
                    t.* = .{
                        .tag = .int,
                        .loc = expr.loc,
                        .data = .{
                            .int = .{
                                .is_signed = (name[0] == 'i'),
                                .width = w_expr,
                            },
                        },
                    };
                    return t;
                }
            }
            const t = try alloc.create(ast.Type);
            t.* = .{
                .tag = .named,
                .loc = expr.loc,
                .data = .{
                    .named = try alloc.dupe(u8, name),
                },
            };
            return t;
        }
        return error.TypeMismatch;
    }

    fn getOrMonomorphizeModule(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        call_expr: *ast.Expr,
        modules: *ArrayList(hir.HirModule),
        module_ports: *std.StringHashMap([]hir.HirPort),
        local_consts: ?*const std.StringHashMap(u64),
    ) anyerror![]const u8 {
        const callee = call_expr.data.call.callee;
        if (callee.tag != .identifier) return error.ModuleNotFound;
        const fn_name = callee.data.identifier;
        const fn_decl = self.fn_decls.get(fn_name) orelse return error.ModuleNotFound;
        if (fn_decl.body_expr.tag != .module_literal) return error.ModuleNotFound;

        const args = call_expr.data.call.args;
        var substs = ArrayList(ParamSubst).init(alloc);

        for (fn_decl.params, 0..) |param, i| {
            if (i >= args.len) break;
            const arg = args[i];
            const is_type_param = (param.type_expr.tag == .named and std.mem.eql(u8, param.type_expr.data.named, "type")) or
                self.isTypeExprOrName(arg);

            if (is_type_param) {
                const t = self.exprToType(alloc, arg) catch return error.TypeMismatch;
                substs.append(.{
                    .name = param.name,
                    .value = .{ .type_val = t },
                }) catch return error.OutOfMemory;
            } else {
                const v = self.evalConstEx(arg, local_consts);
                substs.append(.{
                    .name = param.name,
                    .value = .{ .int_val = v },
                }) catch return error.OutOfMemory;
            }
        }

        var name_buf = ArrayList(u8).init(alloc);
        name_buf.appendSlice(fn_name) catch return error.OutOfMemory;
        for (substs.items) |subst| {
            switch (subst.value) {
                .int_val => |iv| {
                    const s = std.fmt.allocPrint(alloc, "_{d}", .{iv}) catch return error.OutOfMemory;
                    name_buf.appendSlice(s) catch return error.OutOfMemory;
                },
                .type_val => |tv| {
                    if (tv.tag == .int) {
                        const w = self.evalConst(tv.data.int.width);
                        const sign_char: u8 = if (tv.data.int.is_signed) 'i' else 'u';
                        const s = std.fmt.allocPrint(alloc, "_{c}{d}", .{ sign_char, w }) catch return error.OutOfMemory;
                        name_buf.appendSlice(s) catch return error.OutOfMemory;
                    } else if (tv.tag == .named) {
                        const s = std.fmt.allocPrint(alloc, "_{s}", .{tv.data.named}) catch return error.OutOfMemory;
                        name_buf.appendSlice(s) catch return error.OutOfMemory;
                    } else {
                        name_buf.appendSlice("_type") catch return error.OutOfMemory;
                    }
                },
                .expr_val => |ev| {
                    const iv = self.evalConstEx(ev, local_consts);
                    const s = std.fmt.allocPrint(alloc, "_{d}", .{iv}) catch return error.OutOfMemory;
                    name_buf.appendSlice(s) catch return error.OutOfMemory;
                },
            }
        }
        const mono_name = name_buf.toOwnedSlice() catch return error.OutOfMemory;

        if (self.specialized_modules.contains(mono_name)) {
            return mono_name;
        }
        self.specialized_modules.put(mono_name, {}) catch return error.OutOfMemory;

        // Clone template items
        const template_items = fn_decl.body_expr.data.module_literal;
        const specialized_items = self.cloneModuleItems(alloc, template_items, substs.items) catch return error.OutOfMemory;

        // Register ports of this specialized module
        var mod_ports = ArrayList(hir.HirPort).init(alloc);
        for (specialized_items) |item| {
            if (item.tag == .port) {
                const p = item.data.port;
                const h_type = try self.lowerType(p.type_expr);
                mod_ports.append(.{
                    .name = p.name,
                    .dir = switch (p.dir) {
                        .in => .in,
                        .out => .out,
                        .inout => .inout,
                    },
                    .hir_type = h_type,
                }) catch return error.OutOfMemory;
            }
        }
        const owned_ports = mod_ports.toOwnedSlice() catch return error.OutOfMemory;
        module_ports.put(mono_name, owned_ports) catch return error.OutOfMemory;

        // Elaborate the specialized module!
        const hir_mod = try self.elaborateModule(alloc, mono_name, specialized_items, module_ports, modules);
        modules.append(hir_mod) catch return error.OutOfMemory;

        return mono_name;
    }

    pub fn elaborate(self: *Elaborator, top_module_name: ?[]const u8) !hir.HirDesign {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // 1. Collect top-level types, constants, and functions
        for (self.ast_tree.decls) |decl| {
            if (decl.tag == .fn_decl) {
                try self.fn_decls.put(decl.data.fn_decl.name, decl.data.fn_decl);
            } else if (decl.tag == .const_decl) {
                const c = decl.data.const_decl;
                if (c.val.tag == .number) {
                    try self.constants.put(c.name, c.val.data.number.val);
                } else if (c.val.tag == .type_expr) {
                    var h_type = try self.lowerType(c.val.data.type_expr);
                    h_type.name = c.name;
                    try self.types.put(c.name, h_type);
                    try self.registerTypeMethods(c.name, c.val.data.type_expr);
                }
            }
        }

        var modules = ArrayList(hir.HirModule).init(alloc);
        var testbenches = ArrayList(hir.HirTestbench).init(alloc);
        var module_ports = std.StringHashMap([]hir.HirPort).init(alloc);

        for (self.ast_tree.decls) |decl| {
            if (decl.tag == .module_decl) {
                var mod_ports = ArrayList(hir.HirPort).init(alloc);
                for (decl.data.module_decl.items) |item| {
                    if (item.tag == .port) {
                        const p = item.data.port;
                        const h_type = try self.lowerType(p.type_expr);
                        try mod_ports.append(.{
                            .name = p.name,
                            .dir = switch (p.dir) {
                                .in => .in,
                                .out => .out,
                                .inout => .inout,
                            },
                            .hir_type = h_type,
                        });
                    }
                }
                try module_ports.put(decl.data.module_decl.name, try mod_ports.toOwnedSlice());
            }
        }

        // 2. Find target module
        var target_mod_name = top_module_name;
        if (target_mod_name == null) {
            for (self.ast_tree.decls) |decl| {
                if (decl.tag == .module_decl) {
                    target_mod_name = decl.data.module_decl.name;
                    break;
                }
            }
            if (target_mod_name == null) {
                for (self.ast_tree.decls) |decl| {
                    if (decl.tag == .const_decl and self.resolveGenericCall(decl.data.const_decl.val, null) != null) {
                        target_mod_name = decl.data.const_decl.name;
                        break;
                    }
                }
            }
        }

        // If target_mod_name matches a top-level generic const_decl, monomorphize it now
        if (target_mod_name != null) {
            for (self.ast_tree.decls) |decl| {
                if (decl.tag == .const_decl and std.mem.eql(u8, decl.data.const_decl.name, target_mod_name.?)) {
                    if (self.resolveGenericCall(decl.data.const_decl.val, null)) |call_expr| {
                        target_mod_name = try self.getOrMonomorphizeModule(alloc, call_expr, &modules, &module_ports, null);
                        break;
                    }
                }
            }
        }

        // If target_mod_name is still null, check if any testbench has an instance of a module
        if (target_mod_name == null) {
            for (self.ast_tree.decls) |decl| {
                if (decl.tag == .test_decl) {
                    for (decl.data.test_decl.items) |item| {
                        if (item.tag == .instance) {
                            if (self.resolveGenericCall(item.data.instance.module_expr, decl.data.test_decl.items)) |call_expr| {
                                target_mod_name = try self.getOrMonomorphizeModule(alloc, call_expr, &modules, &module_ports, null);
                                break;
                            } else if (item.data.instance.module_expr.tag == .identifier) {
                                target_mod_name = item.data.instance.module_expr.data.identifier;
                                break;
                            }
                        }
                    }
                    if (target_mod_name != null) break;
                }
            }
        }

        if (target_mod_name == null) {
            return error.ModuleNotFound;
        }

        for (self.ast_tree.decls) |decl| {
            if (decl.tag == .module_decl) {
                const mod_name = decl.data.module_decl.name;
                const hir_mod = try self.elaborateModule(alloc, mod_name, decl.data.module_decl.items, &module_ports, &modules);
                try modules.append(hir_mod);
            } else if (decl.tag == .test_decl) {
                const td = decl.data.test_decl;
                const tb = try self.elaborateTestbench(alloc, td.name, td.items, &module_ports, &modules);
                try testbenches.append(tb);
            }
        }

        return .{
            .arena = arena,
            .modules = try modules.toOwnedSlice(),
            .testbenches = try testbenches.toOwnedSlice(),
            .top_module = target_mod_name.?,
        };
    }

    fn elaborateModule(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        mod_name: []const u8,
        items: []ast.ModuleItem,
        module_ports: *std.StringHashMap([]hir.HirPort),
        modules: *ArrayList(hir.HirModule),
    ) !hir.HirModule {
        var ports = ArrayList(hir.HirPort).init(alloc);
        var registers = ArrayList(hir.HirRegister).init(alloc);
        var local_signals = ArrayList(hir.HirSignal).init(alloc);
        var comb_stmts = ArrayList(hir.HirStatement).init(alloc);
        var instances = ArrayList(hir.HirSubmoduleInstance).init(alloc);

        var reg_map = std.StringHashMap(hir.HirRegister).init(alloc);
        var signal_types = std.StringHashMap(hir.HirType).init(alloc);

        var default_clk_name: ?[]const u8 = null;
        var default_rst_name: ?[]const u8 = null;
        var default_rst_active_low = false;
        var local_consts = std.StringHashMap(u64).init(alloc);

        for (items) |item| {
            if (item.tag == .port) {
                const p = item.data.port;
                const h_type = self.lowerType(p.type_expr) catch null;
                if (h_type) |ht| {
                    if (ht.tag == .clock) {
                        if (default_clk_name == null) default_clk_name = p.name;
                    }
                    if (ht.tag == .reset) {
                        if (default_rst_name == null) {
                            default_rst_name = p.name;
                            default_rst_active_low = ht.is_active_low;
                        }
                    }
                    try signal_types.put(p.name, ht);
                }
            } else if (item.tag == .const_decl) {
                const c = item.data.const_decl;
                if (c.type_annot) |ta| {
                    const h_type = self.lowerType(ta) catch null;
                    if (h_type) |ht| {
                        try signal_types.put(c.name, ht);
                    }
                }
            }
        }

        // First pass: Ports, Registers, Instances, Constants
        for (items) |item| {
            switch (item.tag) {
                .port => {
                    const p = item.data.port;
                    const h_type = try self.lowerType(p.type_expr);
                    try ports.append(.{
                        .name = p.name,
                        .dir = switch (p.dir) {
                            .in => .in,
                            .out => .out,
                            .inout => .inout,
                        },
                        .hir_type = h_type,
                    });
                    try signal_types.put(p.name, h_type);
                },
                .reg_decl => {
                    const r = item.data.reg_decl;
                    const h_type = try self.lowerType(r.type_expr);
                    const q_name = try std.fmt.allocPrint(alloc, "{s}_q", .{r.name});
                    const d_name = try std.fmt.allocPrint(alloc, "{s}_d", .{r.name});

                    const clk_str = if (r.clk != null and r.clk.?.tag == .identifier)
                        r.clk.?.data.identifier
                    else blk: {
                        if (default_clk_name) |dcn| {
                            break :blk dcn;
                        } else {
                            std.debug.print(
                                \\
                                \\======================================================================
                                \\COMPILE ERROR: Missing Clock Signal for Register '{s}' in module '{s}'
                                \\======================================================================
                                \\Register '{s}' does not specify an explicit clock, and the module
                                \\does not declare any input port with type 'clock'.
                                \\
                                \\Fix:
                                \\  1. Declare a clock port in the module:
                                \\       in clk: clock,
                                \\  2. Or specify the clock explicitly on the register:
                                \\       reg(clk) {s}: ... = 0;
                                \\======================================================================
                                \\
                                , .{ r.name, mod_name, r.name, r.name });
                            return error.MissingClockSignal;
                        }
                    };

                    const rst_str: ?[]const u8 = if (r.rst != null) blk: {
                        if (r.rst.?.tag == .identifier) {
                            break :blk r.rst.?.data.identifier;
                        } else if (r.rst.?.tag == .enum_literal and std.mem.eql(u8, r.rst.?.data.enum_literal, "none")) {
                            break :blk null;
                        } else {
                            break :blk default_rst_name;
                        }
                    } else default_rst_name;

                    var rst_active_low = false;
                    if (r.rst_polarity) |pol| {
                        rst_active_low = pol;
                    } else if (rst_str) |s| {
                        if (signal_types.get(s)) |st| {
                            rst_active_low = st.is_active_low;
                        } else if (std.mem.eql(u8, s, default_rst_name orelse "")) {
                            rst_active_low = default_rst_active_low;
                        }
                    }
                    var init_val: u64 = if (r.init_val.tag == .number) r.init_val.data.number.val else 0;
                    if (h_type.tag == .tagged_union and r.init_val.tag == .struct_init) {
                        const si = r.init_val.data.struct_init;
                        if (si.fields.len > 0) {
                            if (h_type.getUnionField(si.fields[0].name)) |uf| {
                                var v: u64 = if (h_type.elem_width < 64) uf.tag_value << @intCast(h_type.elem_width) else 0;
                                if (uf.payload_width > 0) {
                                    const pv = self.evalConst(si.fields[0].value);
                                    const mask = if (uf.payload_width >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(uf.payload_width)) - 1;
                                    v |= (pv & mask);
                                }
                                init_val = v;
                            }
                        }
                    }

                    const hir_reg: hir.HirRegister = .{
                        .name = r.name,
                        .q_name = q_name,
                        .d_name = d_name,
                        .hir_type = h_type,
                        .clk_name = clk_str,
                        .rst_name = rst_str,
                        .rst_active_low = rst_active_low,
                        .init_val = init_val,
                    };

                    try registers.append(hir_reg);
                    try reg_map.put(r.name, hir_reg);
                    try signal_types.put(r.name, h_type);
                    try signal_types.put(q_name, h_type);
                    try signal_types.put(d_name, h_type);

                    // Add Q and D to local signals
                    try local_signals.append(.{ .name = q_name, .hir_type = h_type });
                    try local_signals.append(.{ .name = d_name, .hir_type = h_type });
                },
                .const_decl => {
                    const c = item.data.const_decl;
                    if (self.resolveGenericCall(c.val, items) != null) {
                        // generic module alias - skip creating hardware wire
                    } else if (c.val.tag == .type_expr) {
                        var h_type = try self.lowerType(c.val.data.type_expr);
                        h_type.name = c.name;
                        try self.types.put(c.name, h_type);
                        try signal_types.put(c.name, h_type);
                        try self.registerTypeMethods(c.name, c.val.data.type_expr);
                    } else if (c.type_annot) |ta| {
                        const h_type = try self.lowerType(ta);
                        try local_signals.append(.{ .name = c.name, .hir_type = h_type });
                        try signal_types.put(c.name, h_type);
                    } else if (c.val.tag == .number) {
                        try local_consts.put(c.name, c.val.data.number.val);
                        try self.constants.put(c.name, c.val.data.number.val);
                    } else {
                        const const_v = self.evalConstEx(c.val, &local_consts);
                        if (const_v > 0) {
                            try local_consts.put(c.name, const_v);
                        }
                        const val = try self.lowerExpr(alloc, c.val, &reg_map, &signal_types);
                        const h_type = if (val.hir_type.width > 0) val.hir_type else hir.HirType{ .tag = .bits, .width = 32 };
                        try local_signals.append(.{ .name = c.name, .hir_type = h_type });
                        try signal_types.put(c.name, h_type);
                    }
                },
                else => {},
            }
        }

        // Activate dynamic elaboration state for submodules, synchronizers, and blocks
        self.active_registers = &registers;
        self.active_local_signals = &local_signals;
        self.active_comb_stmts = &comb_stmts;
        self.active_reg_map = &reg_map;
        self.active_signal_types = &signal_types;
        defer {
            self.active_registers = null;
            self.active_local_signals = null;
            self.active_comb_stmts = null;
            self.active_reg_map = null;
            self.active_signal_types = null;
        }

        // Second pass: Instances (now all ports, registers and local signals are known)
        for (items) |item| {
            if (item.tag == .instance) {
                const inst = item.data.instance;
                var target_mod: []const u8 = undefined;

                if (self.resolveGenericCall(inst.module_expr, items)) |call_expr| {
                    target_mod = try self.getOrMonomorphizeModule(alloc, call_expr, modules, module_ports, &local_consts);
                } else if (inst.module_expr.tag == .identifier) {
                    target_mod = inst.module_expr.data.identifier;
                } else {
                    target_mod = "Submodule";
                }

                var conns = ArrayList(hir.HirPortConnection).init(alloc);
                for (inst.bindings) |b| {
                    const h_expr = try self.lowerExpr(alloc, b.expr, &reg_map, &signal_types);
                    try conns.append(.{
                        .port_name = b.port_name,
                        .expr = h_expr,
                    });
                }

                try instances.append(.{
                    .instance_name = inst.name,
                    .module_name = target_mod,
                    .connections = try conns.toOwnedSlice(),
                });
            }
        }

        // Automatic default-hold for registers: count_d = count_q;
        // This guarantees 100% latch-free synthesizable logic!
        for (registers.items) |r| {
            if (r.is_sync_stage) continue;
            const target = try alloc.create(hir.HirExpr);
            target.* = .{
                .tag = .signal_ref,
                .hir_type = r.hir_type,
                .data = .{ .signal_ref = .{ .name = r.d_name } },
            };

            const src = try alloc.create(hir.HirExpr);
            src.* = .{
                .tag = .signal_ref,
                .hir_type = r.hir_type,
                .data = .{ .signal_ref = .{ .name = r.q_name } },
            };

            try comb_stmts.append(.{
                .tag = .assign,
                .data = .{
                    .assign = .{
                        .target = target,
                        .value = src,
                    },
                },
            });
        }

        // Second pass: comb and sync blocks
        for (items) |item| {
            switch (item.tag) {
                .const_decl => {
                    const c = item.data.const_decl;
                    if (c.val.tag != .number and c.val.tag != .type_expr and self.resolveGenericCall(c.val, items) == null) {
                        const target = try alloc.create(hir.HirExpr);
                        const h_type = signal_types.get(c.name) orelse hir.HirType{ .tag = .bits, .width = 32 };
                        target.* = .{
                            .tag = .signal_ref,
                            .hir_type = h_type,
                            .data = .{ .signal_ref = .{ .name = c.name } },
                        };
                        const val = try self.lowerExpr(alloc, c.val, &reg_map, &signal_types);
                        if (val.tag == .lit and h_type.width > 0) {
                            val.hir_type.width = h_type.width;
                        }
                        try comb_stmts.append(.{
                            .tag = .assign,
                            .data = .{
                                .assign = .{
                                    .target = target,
                                    .value = val,
                                },
                            },
                        });
                    }
                },
                .comb_block => {
                    for (item.data.comb_block.stmts) |stmt| {
                        try self.lowerStatement(alloc, stmt, &comb_stmts, &local_signals, &reg_map, &signal_types);
                    }
                },
                .sync_block => {
                    const sb = item.data.sync_block;
                    const clk_str = if (sb.clk.tag == .identifier) sb.clk.data.identifier else "clk";
                    const rst_str: ?[]const u8 = if (sb.rst != null and sb.rst.?.tag == .identifier)
                        sb.rst.?.data.identifier
                    else
                        null;

                    // Statements in sync block lower to register assignments
                    for (sb.stmts) |stmt| {
                        if (stmt.tag == .assign) {
                            const a = stmt.data.assign;
                            if (a.target.tag == .identifier) {
                                const var_name = a.target.data.identifier;
                                // If not already a register, promote it to one
                                if (reg_map.get(var_name) == null) {
                                    const h_type: hir.HirType = .{ .tag = .bits, .width = 32 };
                                    const q_name = try std.fmt.allocPrint(alloc, "{s}_q", .{var_name});
                                    const d_name = try std.fmt.allocPrint(alloc, "{s}_d", .{var_name});
                                    var rst_active_low = false;
                                    if (rst_str) |s| {
                                        if (signal_types.get(s)) |st| {
                                            rst_active_low = st.is_active_low;
                                        }
                                    }
                                    const hir_reg: hir.HirRegister = .{
                                        .name = var_name,
                                        .q_name = q_name,
                                        .d_name = d_name,
                                        .hir_type = h_type,
                                        .clk_name = clk_str,
                                        .rst_name = rst_str,
                                        .rst_active_low = rst_active_low,
                                        .init_val = 0,
                                    };
                                    try registers.append(hir_reg);
                                    try reg_map.put(var_name, hir_reg);
                                    try signal_types.put(var_name, h_type);
                                    try signal_types.put(q_name, h_type);
                                    try signal_types.put(d_name, h_type);
                                    try local_signals.append(.{ .name = q_name, .hir_type = h_type });
                                    try local_signals.append(.{ .name = d_name, .hir_type = h_type });
                                }
                            }
                        }
                        try self.lowerStatement(alloc, stmt, &comb_stmts, &local_signals, &reg_map, &signal_types);
                    }
                },
                else => {},
            }
        }

        // Race condition prevention:
        // 1. Single-writer rule (no multi-driven nets, no writes to input ports)
        try self.checkMultiDrivers(alloc, mod_name, items, ports.items, instances.items, &reg_map, module_ports);

        // 2. Combinational cycle detection (no zero-delay feedback loops or ring oscillators)
        try self.checkCombinationalLoops(alloc, mod_name, ports.items, local_signals.items, comb_stmts.items, &reg_map);

        // 3. Clock Domain Crossing (CDC) verification (no unsynchronized multi-clock domain sampling)
        try self.checkClockDomainCrossing(alloc, mod_name, registers.items, comb_stmts.items, &reg_map);

        return .{
            .name = mod_name,
            .ports = try ports.toOwnedSlice(),
            .registers = try registers.toOwnedSlice(),
            .local_signals = try local_signals.toOwnedSlice(),
            .comb_stmts = try comb_stmts.toOwnedSlice(),
            .instances = try instances.toOwnedSlice(),
        };
    }

    fn elaborateTestbench(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        tb_name: []const u8,
        items: []ast.ModuleItem,
        module_ports: *std.StringHashMap([]hir.HirPort),
        modules: *ArrayList(hir.HirModule),
    ) !hir.HirTestbench {
        var signals = ArrayList(hir.HirSignal).init(alloc);
        var clock_gens = ArrayList(hir.HirClockGen).init(alloc);
        var instances = ArrayList(hir.HirSubmoduleInstance).init(alloc);
        var sim_stmts = ArrayList(hir.HirSimStmt).init(alloc);
        var signal_types = std.StringHashMap(hir.HirType).init(alloc);
        defer signal_types.deinit();
        var reg_map = std.StringHashMap(hir.HirRegister).init(alloc);
        defer reg_map.deinit();

        // 1. Collect signals (wires, registers, ports)
        for (items) |item| {
            switch (item.tag) {
                .port => {
                    const p = item.data.port;
                    const h_type = try self.lowerType(p.type_expr);
                    try signals.append(.{ .name = p.name, .hir_type = h_type });
                    try signal_types.put(p.name, h_type);
                },
                .const_decl => {
                    const c = item.data.const_decl;
                    if (self.resolveGenericCall(c.val, items) != null) {
                        // generic module alias - skip
                    } else if (c.val.tag == .type_expr) {
                        const h_type = try self.lowerType(c.val.data.type_expr);
                        try self.types.put(c.name, h_type);
                        try signal_types.put(c.name, h_type);
                    } else if (c.type_annot) |ta| {
                        const h_type = try self.lowerType(ta);
                        try signals.append(.{ .name = c.name, .hir_type = h_type });
                        try signal_types.put(c.name, h_type);
                    } else if (c.val.tag == .number) {
                        try self.constants.put(c.name, c.val.data.number.val);
                    } else {
                        const h_type: hir.HirType = .{ .tag = .bits, .width = 32 };
                        try signals.append(.{ .name = c.name, .hir_type = h_type });
                        try signal_types.put(c.name, h_type);
                    }
                },
                .reg_decl => {
                    const r = item.data.reg_decl;
                    const h_type = try self.lowerType(r.type_expr);
                    try signals.append(.{ .name = r.name, .hir_type = h_type });
                    try signal_types.put(r.name, h_type);
                },
                else => {},
            }
        }

        // 2. Instances (DUT instantiation)
        for (items) |item| {
            if (item.tag == .instance) {
                const inst = item.data.instance;
                var target_mod: []const u8 = undefined;

                if (self.resolveGenericCall(inst.module_expr, items)) |call_expr| {
                    target_mod = try self.getOrMonomorphizeModule(alloc, call_expr, modules, module_ports, null);
                } else if (inst.module_expr.tag == .identifier) {
                    target_mod = inst.module_expr.data.identifier;
                } else {
                    target_mod = "DUT";
                }

                var conns = ArrayList(hir.HirPortConnection).init(alloc);
                for (inst.bindings) |b| {
                    const h_expr = try self.lowerExpr(alloc, b.expr, &reg_map, &signal_types);
                    try conns.append(.{
                        .port_name = b.port_name,
                        .expr = h_expr,
                    });
                }

                try instances.append(.{
                    .instance_name = inst.name,
                    .module_name = target_mod,
                    .connections = try conns.toOwnedSlice(),
                });
            }
        }

        // 3. Process sim blocks
        for (items) |item| {
            if (item.tag == .sim_block) {
                for (item.data.sim_block.stmts) |stmt| {
                    try self.lowerSimStatement(alloc, stmt, &sim_stmts, &clock_gens, &reg_map, &signal_types);
                }
            }
        }

        return .{
            .name = tb_name,
            .signals = try signals.toOwnedSlice(),
            .clock_gens = try clock_gens.toOwnedSlice(),
            .instances = try instances.toOwnedSlice(),
            .sim_stmts = try sim_stmts.toOwnedSlice(),
        };
    }

    fn convertToNs(lit: ast.TimeLiteral) u64 {
        return switch (lit.unit) {
            .ps => if (lit.val > 0 and lit.val < 1000) 1 else lit.val / 1000,
            .ns => lit.val,
            .us => lit.val * 1_000,
            .ms => lit.val * 1_000_000,
            .s => lit.val * 1_000_000_000,
        };
    }

    fn convertFreqToNs(fl: ast.FreqLiteral) u64 {
        const val: u64 = if (fl.val == 0) 1 else fl.val;
        const freq_hz: u64 = switch (fl.unit) {
            .hz => val,
            .khz => val * 1_000,
            .mhz => val * 1_000_000,
            .ghz => val * 1_000_000_000,
        };
        const one_billion: u64 = 1_000_000_000;
        if (freq_hz >= one_billion) return 1;
        return one_billion / freq_hz;
    }

    const FreqConversion = struct {
        period_ns: u64,
        half_period_str: []const u8,
    };

    fn convertFreqToPeriod(alloc: std.mem.Allocator, fl: ast.FreqLiteral) !FreqConversion {
        const val: u64 = if (fl.val == 0) 1 else fl.val;
        const freq_hz: u64 = switch (fl.unit) {
            .hz => val,
            .khz => val * 1_000,
            .mhz => val * 1_000_000,
            .ghz => val * 1_000_000_000,
        };

        const one_trillion: u128 = 1_000_000_000_000;
        const period_ps: u64 = @intCast(one_trillion / freq_hz);
        const half_ps: u64 = if (period_ps >= 2) period_ps / 2 else 1;
        const period_ns: u64 = if (period_ps >= 1000) period_ps / 1000 else 1;

        var half_str: []const u8 = undefined;
        if (half_ps >= 1000 and (half_ps % 1000) == 0) {
            half_str = try std.fmt.allocPrint(alloc, "{d}ns", .{half_ps / 1000});
        } else {
            half_str = try std.fmt.allocPrint(alloc, "{d}ps", .{half_ps});
        }

        return .{
            .period_ns = period_ns,
            .half_period_str = half_str,
        };
    }

    fn convertTimeToHalfPeriodStr(alloc: std.mem.Allocator, tl: ast.TimeLiteral) !struct { period_ns: u64, half_str: []const u8 } {
        const val = tl.val;
        const period_ps: u64 = switch (tl.unit) {
            .ps => val,
            .ns => val * 1000,
            .us => val * 1000000,
            .ms => val * 1000000000,
            .s => val * 1000000000000,
        };
        const half_ps: u64 = if (period_ps >= 2) period_ps / 2 else 1;
        const period_ns: u64 = if (period_ps >= 1000) period_ps / 1000 else 1;

        var half_str: []const u8 = undefined;
        if (half_ps >= 1000 and (half_ps % 1000) == 0) {
            half_str = try std.fmt.allocPrint(alloc, "{d}ns", .{half_ps / 1000});
        } else {
            half_str = try std.fmt.allocPrint(alloc, "{d}ps", .{half_ps});
        }
        return .{ .period_ns = period_ns, .half_str = half_str };
    }

    fn lowerSimStatement(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        stmt: ast.Statement,
        sim_stmts: *ArrayList(hir.HirSimStmt),
        clock_gens: *ArrayList(hir.HirClockGen),
        reg_map: *const std.StringHashMap(hir.HirRegister),
        signal_types: *std.StringHashMap(hir.HirType),
    ) !void {
        switch (stmt.tag) {
            .assign => {
                const a = stmt.data.assign;
                const target = try self.lowerExpr(alloc, a.target, reg_map, signal_types);
                const value = try self.lowerExpr(alloc, a.value, reg_map, signal_types);
                if (value.tag == .lit and target.hir_type.width > 0) {
                    value.hir_type.width = target.hir_type.width;
                }
                try sim_stmts.append(.{
                    .tag = .assign,
                    .data = .{
                        .assign = .{
                            .target = target,
                            .value = value,
                        },
                    },
                });
            },
            .expr_stmt => {
                const expr = stmt.data.expr_stmt;
                if (expr.tag == .call) {
                    const c = expr.data.call;
                    if (c.callee.tag == .member_access) {
                        const ma = c.callee.data.member_access;
                        if (ma.target.tag == .identifier) {
                            const obj_name = ma.target.data.identifier;
                            if (std.mem.eql(u8, ma.field, "generate")) {
                                var period: u64 = 10;
                                var raw_str: []const u8 = "10ns";
                                var half_str: []const u8 = "5ns";
                                if (c.args.len > 0) {
                                    const p = c.args[0];
                                    if (p.tag == .freq_literal) {
                                        const fc = try convertFreqToPeriod(alloc, p.data.freq_literal);
                                        period = fc.period_ns;
                                        half_str = fc.half_period_str;
                                        raw_str = p.data.freq_literal.raw;
                                    } else if (p.tag == .time_literal) {
                                        const tc = try convertTimeToHalfPeriodStr(alloc, p.data.time_literal);
                                        period = tc.period_ns;
                                        half_str = tc.half_str;
                                        raw_str = p.data.time_literal.raw;
                                    } else if (p.tag == .number) {
                                        period = p.data.number.val;
                                        const half = if (period >= 2) period / 2 else 1;
                                        half_str = try std.fmt.allocPrint(alloc, "{d}ns", .{half});
                                        raw_str = try std.fmt.allocPrint(alloc, "{d}ns", .{period});
                                    }
                                }
                                try clock_gens.append(.{
                                    .clk_name = obj_name,
                                    .period_ns = period,
                                    .half_period_str = half_str,
                                    .raw = raw_str,
                                });
                                try sim_stmts.append(.{
                                    .tag = .clk_generate,
                                    .data = .{
                                        .clk_generate = .{
                                            .clk_name = obj_name,
                                            .period_ns = period,
                                            .half_period_str = half_str,
                                            .raw = raw_str,
                                        },
                                    },
                                });
                                return;
                            } else if (std.mem.eql(u8, ma.field, "step")) {
                                var cycles: u64 = 1;
                                if (c.args.len > 0 and c.args[0].tag == .number) {
                                    cycles = c.args[0].data.number.val;
                                }
                                try sim_stmts.append(.{
                                    .tag = .step,
                                    .data = .{
                                        .step = .{
                                            .clk_name = obj_name,
                                            .cycles = cycles,
                                            .edge = .posedge,
                                        },
                                    },
                                });
                                return;
                            } else if (std.mem.eql(u8, ma.field, "posedge")) {
                                var cycles: u64 = 1;
                                if (c.args.len > 0 and c.args[0].tag == .number) {
                                    cycles = c.args[0].data.number.val;
                                }
                                try sim_stmts.append(.{
                                    .tag = .step,
                                    .data = .{
                                        .step = .{
                                            .clk_name = obj_name,
                                            .cycles = cycles,
                                            .edge = .posedge,
                                        },
                                    },
                                });
                                return;
                            } else if (std.mem.eql(u8, ma.field, "negedge")) {
                                var cycles: u64 = 1;
                                if (c.args.len > 0 and c.args[0].tag == .number) {
                                    cycles = c.args[0].data.number.val;
                                }
                                try sim_stmts.append(.{
                                    .tag = .step,
                                    .data = .{
                                        .step = .{
                                            .clk_name = obj_name,
                                            .cycles = cycles,
                                            .edge = .negedge,
                                        },
                                    },
                                });
                                return;
                            } else if (std.mem.eql(u8, ma.field, "pulse")) {
                                var cycles: ?u64 = null;
                                var duration_raw: ?[]const u8 = null;
                                if (c.args.len > 0) {
                                    if (c.args[0].tag == .time_literal) {
                                        duration_raw = c.args[0].data.time_literal.raw;
                                    } else if (c.args[0].tag == .number) {
                                        cycles = c.args[0].data.number.val;
                                    }
                                }
                                if (cycles == null and duration_raw == null) {
                                    cycles = 1;
                                }
                                var active_low = false;
                                if (signal_types.get(obj_name)) |st| {
                                    active_low = st.is_active_low;
                                }
                                if (c.args.len > 1) {
                                    if (c.args[1].tag == .enum_literal) {
                                        const lit = c.args[1].data.enum_literal;
                                        if (std.mem.eql(u8, lit, "low") or std.mem.eql(u8, lit, "active_low")) {
                                            active_low = true;
                                        } else if (std.mem.eql(u8, lit, "high") or std.mem.eql(u8, lit, "active_high")) {
                                            active_low = false;
                                        }
                                    }
                                }
                                try sim_stmts.append(.{
                                    .tag = .rst_pulse,
                                    .data = .{
                                        .rst_pulse = .{
                                            .rst_name = obj_name,
                                            .cycles = cycles,
                                            .duration_raw = duration_raw,
                                            .active_low = active_low,
                                        },
                                    },
                                });
                                return;
                            } else if (std.mem.eql(u8, ma.field, "assert_signal") or std.mem.eql(u8, ma.field, "assert")) {
                                var active_low = false;
                                if (signal_types.get(obj_name)) |st| {
                                    active_low = st.is_active_low;
                                }
                                const active_val: u64 = if (active_low) 0 else 1;
                                const target = try alloc.create(hir.HirExpr);
                                target.* = .{
                                    .tag = .signal_ref,
                                    .hir_type = .{ .tag = .bits, .width = 1 },
                                    .data = .{ .signal_ref = .{ .name = obj_name } },
                                };
                                const val_expr = try alloc.create(hir.HirExpr);
                                val_expr.* = .{
                                    .tag = .lit,
                                    .hir_type = .{ .tag = .bits, .width = 1 },
                                    .data = .{
                                        .lit = .{
                                            .val = active_val,
                                            .raw = if (active_low) "0" else "1",
                                        },
                                    },
                                };
                                try sim_stmts.append(.{
                                    .tag = .assign,
                                    .data = .{
                                        .assign = .{
                                            .target = target,
                                            .value = val_expr,
                                        },
                                    },
                                });
                                return;
                            } else if (std.mem.eql(u8, ma.field, "deassert")) {
                                var active_low = false;
                                if (signal_types.get(obj_name)) |st| {
                                    active_low = st.is_active_low;
                                }
                                const inactive_val: u64 = if (active_low) 1 else 0;
                                const target = try alloc.create(hir.HirExpr);
                                target.* = .{
                                    .tag = .signal_ref,
                                    .hir_type = .{ .tag = .bits, .width = 1 },
                                    .data = .{ .signal_ref = .{ .name = obj_name } },
                                };
                                const val_expr = try alloc.create(hir.HirExpr);
                                val_expr.* = .{
                                    .tag = .lit,
                                    .hir_type = .{ .tag = .bits, .width = 1 },
                                    .data = .{
                                        .lit = .{
                                            .val = inactive_val,
                                            .raw = if (active_low) "1" else "0",
                                        },
                                    },
                                };
                                try sim_stmts.append(.{
                                    .tag = .assign,
                                    .data = .{
                                        .assign = .{
                                            .target = target,
                                            .value = val_expr,
                                        },
                                    },
                                });
                                return;
                            }
                        }
                    } else if (c.callee.tag == .identifier) {
                        const fn_name = c.callee.data.identifier;
                        if (std.mem.eql(u8, fn_name, "step")) {
                            var clk_name: ?[]const u8 = null;
                            var cycles: u64 = 1;
                            if (c.args.len == 1) {
                                if (c.args[0].tag == .number) {
                                    cycles = c.args[0].data.number.val;
                                } else if (c.args[0].tag == .identifier) {
                                    clk_name = c.args[0].data.identifier;
                                    cycles = 1;
                                }
                            } else if (c.args.len >= 2) {
                                if (c.args[0].tag == .identifier) {
                                    clk_name = c.args[0].data.identifier;
                                }
                                if (c.args[1].tag == .number) {
                                    cycles = c.args[1].data.number.val;
                                }
                            }
                            try sim_stmts.append(.{
                                .tag = .step,
                                .data = .{
                                    .step = .{
                                        .clk_name = clk_name,
                                        .cycles = cycles,
                                        .edge = .posedge,
                                    },
                                },
                            });
                            return;
                        } else if (std.mem.eql(u8, fn_name, "posedge")) {
                            const clk_name: ?[]const u8 = if (c.args.len > 0 and c.args[0].tag == .identifier)
                                c.args[0].data.identifier
                            else
                                null;
                            try sim_stmts.append(.{
                                .tag = .step,
                                .data = .{
                                    .step = .{
                                        .clk_name = clk_name,
                                        .cycles = 1,
                                        .edge = .posedge,
                                    },
                                },
                            });
                            return;
                        } else if (std.mem.eql(u8, fn_name, "negedge")) {
                            const clk_name: ?[]const u8 = if (c.args.len > 0 and c.args[0].tag == .identifier)
                                c.args[0].data.identifier
                            else
                                null;
                            try sim_stmts.append(.{
                                .tag = .step,
                                .data = .{
                                    .step = .{
                                        .clk_name = clk_name,
                                        .cycles = 1,
                                        .edge = .negedge,
                                    },
                                },
                            });
                            return;
                        } else if (std.mem.eql(u8, fn_name, "assert")) {
                            if (c.args.len > 0) {
                                const cond = try self.lowerExpr(alloc, c.args[0], reg_map, signal_types);
                                const msg: ?[]const u8 = if (c.args.len >= 2 and c.args[1].tag == .string)
                                    c.args[1].data.string
                                else
                                    null;
                                try sim_stmts.append(.{
                                    .tag = .assert_stmt,
                                    .data = .{
                                        .assert_stmt = .{
                                            .cond = cond,
                                            .msg = msg,
                                        },
                                    },
                                });
                                return;
                            }
                        } else if (std.mem.eql(u8, fn_name, "assert_within")) {
                            if (c.args.len >= 2) {
                                const cond = try self.lowerExpr(alloc, c.args[0], reg_map, signal_types);
                                var max_cycles: ?u64 = null;
                                var timeout_raw: ?[]const u8 = null;
                                const timeout = c.args[1];
                                if (timeout.tag == .time_literal) {
                                    timeout_raw = timeout.data.time_literal.raw;
                                    max_cycles = null;
                                } else if (timeout.tag == .number) {
                                    max_cycles = timeout.data.number.val;
                                    timeout_raw = null;
                                }
                                try sim_stmts.append(.{
                                    .tag = .wait_for,
                                    .data = .{
                                        .wait_for = .{
                                            .cond = cond,
                                            .max_cycles = max_cycles,
                                            .timeout_raw = timeout_raw,
                                        },
                                    },
                                });
                                return;
                            }
                        } else if (std.mem.eql(u8, fn_name, "wait_for")) {
                            if (c.args.len > 0) {
                                const cond = try self.lowerExpr(alloc, c.args[0], reg_map, signal_types);
                                var max_cycles: ?u64 = null;
                                var timeout_raw: ?[]const u8 = null;
                                if (c.args.len >= 2) {
                                    const timeout = c.args[1];
                                    if (timeout.tag == .time_literal) {
                                        timeout_raw = timeout.data.time_literal.raw;
                                        max_cycles = null;
                                    } else if (timeout.tag == .number) {
                                        max_cycles = timeout.data.number.val;
                                        timeout_raw = null;
                                    }
                                }
                                try sim_stmts.append(.{
                                    .tag = .wait_for,
                                    .data = .{
                                        .wait_for = .{
                                            .cond = cond,
                                            .max_cycles = max_cycles,
                                            .timeout_raw = timeout_raw,
                                        },
                                    },
                                });
                                return;
                            }
                        } else if (std.mem.eql(u8, fn_name, "trace")) {
                            const vcd_path: []const u8 = if (c.args.len > 0 and c.args[0].tag == .string)
                                c.args[0].data.string
                            else
                                "dump.vcd";
                            try sim_stmts.append(.{
                                .tag = .trace,
                                .data = .{
                                    .trace = .{
                                        .vcd_path = vcd_path,
                                    },
                                },
                            });
                            return;
                        } else if (std.mem.eql(u8, fn_name, "delay")) {
                            var ns: u64 = 10;
                            var raw_str: []const u8 = "10ns";
                            if (c.args.len > 0) {
                                const t = c.args[0];
                                if (t.tag == .time_literal) {
                                    raw_str = t.data.time_literal.raw;
                                    ns = convertToNs(t.data.time_literal);
                                } else if (t.tag == .number) {
                                    ns = t.data.number.val;
                                    raw_str = t.data.number.raw;
                                }
                            }
                            try sim_stmts.append(.{
                                .tag = .delay,
                                .data = .{
                                    .delay = .{
                                        .ns = ns,
                                        .raw = raw_str,
                                    },
                                },
                            });
                            return;
                        } else if (std.mem.eql(u8, fn_name, "finish")) {
                            try sim_stmts.append(.{
                                .tag = .finish,
                                .data = .{ .finish = {} },
                            });
                            return;
                        }
                    }
                }
            },
            else => {},
        }
    }

    fn lowerTaggedUnionInit(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        ut: hir.HirType,
        field_init: ast.NamedExpr,
        reg_map: *const std.StringHashMap(hir.HirRegister),
        signal_types: *const std.StringHashMap(hir.HirType),
    ) anyerror!*hir.HirExpr {
        const uf = ut.getUnionField(field_init.name) orelse return error.SymbolNotFound;
        const tag_expr = try alloc.create(hir.HirExpr);
        tag_expr.* = .{
            .tag = .lit,
            .hir_type = .{ .tag = .bits, .width = ut.tag_width },
            .data = .{
                .lit = .{
                    .val = uf.tag_value,
                    .raw = try std.fmt.allocPrint(alloc, "{d}'d{d}", .{ ut.tag_width, uf.tag_value }),
                },
            },
        };

        const max_payload_w = ut.elem_width;
        if (max_payload_w == 0) {
            const res = try alloc.create(hir.HirExpr);
            res.* = tag_expr.*;
            res.hir_type = ut;
            return res;
        }

        var concat_args = ArrayList(*hir.HirExpr).init(alloc);
        try concat_args.append(tag_expr);

        if (uf.payload_width > 0) {
            const lowered_p = try self.lowerExpr(alloc, field_init.value, reg_map, signal_types);
            if (lowered_p.tag == .lit and uf.payload_width > 0) {
                lowered_p.hir_type.width = uf.payload_width;
            }

            if (uf.payload_width < max_payload_w) {
                const pad_w = max_payload_w - uf.payload_width;
                const pad_expr = try alloc.create(hir.HirExpr);
                pad_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = pad_w },
                    .data = .{
                        .lit = .{
                            .val = 0,
                            .raw = try std.fmt.allocPrint(alloc, "{d}'d0", .{pad_w}),
                        },
                    },
                };
                try concat_args.append(pad_expr);
            }
            try concat_args.append(lowered_p);
        } else {
            const pad_expr = try alloc.create(hir.HirExpr);
            pad_expr.* = .{
                .tag = .lit,
                .hir_type = .{ .tag = .bits, .width = max_payload_w },
                .data = .{
                    .lit = .{
                        .val = 0,
                        .raw = try std.fmt.allocPrint(alloc, "{d}'d0", .{max_payload_w}),
                    },
                },
            };
            try concat_args.append(pad_expr);
        }

        const res = try alloc.create(hir.HirExpr);
        res.* = .{
            .tag = .concat,
            .hir_type = ut,
            .data = .{
                .concat = .{
                    .args = try concat_args.toOwnedSlice(),
                },
            },
        };
        return res;
    }

    fn lowerUnionFieldAssign(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        out_stmts: *ArrayList(hir.HirStatement),
        ut: hir.HirType,
        uf: hir.HirUnionField,
        target_sig_name: []const u8,
        value_ast: *ast.Expr,
        reg_map: *const std.StringHashMap(hir.HirRegister),
        signal_types: *const std.StringHashMap(hir.HirType),
    ) anyerror!void {
        const sub_target = try alloc.create(hir.HirExpr);
        sub_target.* = .{
            .tag = .signal_ref,
            .hir_type = ut,
            .data = .{ .signal_ref = .{ .name = target_sig_name } },
        };

        if (uf.payload_width > 0) {
            const payload_target = try alloc.create(hir.HirExpr);
            payload_target.* = .{
                .tag = .slice,
                .hir_type = .{ .tag = .bits, .width = uf.payload_width },
                .data = .{
                    .slice = .{
                        .target = sub_target,
                        .start = 0,
                        .end = uf.payload_width,
                        .is_downward = false,
                    },
                },
            };
            const lowered_val = try self.lowerExpr(alloc, value_ast, reg_map, signal_types);
            if (lowered_val.tag == .lit and uf.payload_width > 0) {
                lowered_val.hir_type.width = uf.payload_width;
            }
            try out_stmts.append(.{
                .tag = .assign,
                .data = .{
                    .assign = .{
                        .target = payload_target,
                        .value = lowered_val,
                    },
                },
            });
        }

        const tag_target = try alloc.create(hir.HirExpr);
        tag_target.* = .{
            .tag = .slice,
            .hir_type = .{ .tag = .bits, .width = ut.tag_width },
            .data = .{
                .slice = .{
                    .target = sub_target,
                    .start = ut.elem_width,
                    .end = ut.elem_width + ut.tag_width,
                    .is_downward = false,
                },
            },
        };
        const tag_val_expr = try alloc.create(hir.HirExpr);
        tag_val_expr.* = .{
            .tag = .lit,
            .hir_type = .{ .tag = .bits, .width = ut.tag_width },
            .data = .{
                .lit = .{
                    .val = uf.tag_value,
                    .raw = try std.fmt.allocPrint(alloc, "{d}'d{d}", .{ ut.tag_width, uf.tag_value }),
                },
            },
        };
        try out_stmts.append(.{
            .tag = .assign,
            .data = .{
                .assign = .{
                    .target = tag_target,
                    .value = tag_val_expr,
                },
            },
        });
    }

    fn lowerStatement(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        stmt: ast.Statement,
        out_stmts: *ArrayList(hir.HirStatement),
        local_signals: *ArrayList(hir.HirSignal),
        reg_map: *const std.StringHashMap(hir.HirRegister),
        signal_types: *std.StringHashMap(hir.HirType),
    ) !void {
        switch (stmt.tag) {
            .assign => {
                const a = stmt.data.assign;

                if (a.is_reg_assign) {
                    if (getAstTargetBaseName(a.target)) |bn| {
                        if (reg_map.get(bn) == null) {
                            std.debug.print(
                                \\
                                \\======================================================================
                                \\COMPILE ERROR: Invalid Register Assignment (':=') on Signal '{s}'
                                \\======================================================================
                                \\The operator ':=' is reserved for clocked registers ('reg').
                                \\Signal '{s}' is a combinational wire.
                                \\
                                \\Fix:
                                \\  Use '=' for combinational wires:
                                \\    {s} = ...;
                                \\======================================================================
                                \\
                                , .{ bn, bn, bn });
                            return error.TypeMismatch;
                        }
                    }
                }

                // Handle reg.next = val, reg.next[idx] = val, reg[idx].next = val, reg[idx] = val, reg := val
                var target_expr: *hir.HirExpr = undefined;
                if (a.target.tag == .member_access and
                    std.mem.eql(u8, a.target.data.member_access.field, "next"))
                {
                    const base = a.target.data.member_access.target;
                    if (base.tag == .identifier) {
                        const reg_name = base.data.identifier;
                        if (reg_map.get(reg_name)) |r| {
                            target_expr = try alloc.create(hir.HirExpr);
                            target_expr.* = .{
                                .tag = .signal_ref,
                                .hir_type = r.hir_type,
                                .data = .{ .signal_ref = .{ .name = r.d_name } },
                            };
                        } else {
                            target_expr = try self.lowerExpr(alloc, a.target, reg_map, signal_types);
                        }
                    } else if (base.tag == .index) {
                        const arr_target = base.data.index.target;
                        const idx_e = try self.lowerExpr(alloc, base.data.index.index, reg_map, signal_types);
                        if (arr_target.tag == .identifier and reg_map.get(arr_target.data.identifier) != null) {
                            const r = reg_map.get(arr_target.data.identifier).?;
                            const sub_target = try alloc.create(hir.HirExpr);
                            sub_target.* = .{
                                .tag = .signal_ref,
                                .hir_type = r.hir_type,
                                .data = .{ .signal_ref = .{ .name = r.d_name } },
                            };
                            target_expr = try alloc.create(hir.HirExpr);
                            target_expr.* = .{
                                .tag = .index,
                                .hir_type = .{ .tag = .bits, .width = r.hir_type.elem_width },
                                .data = .{ .index = .{ .target = sub_target, .index = idx_e } },
                            };
                        } else {
                            target_expr = try self.lowerExpr(alloc, a.target, reg_map, signal_types);
                        }
                    } else if (base.tag == .member_access) {
                        const sub_base = base.data.member_access.target;
                        const field_name = base.data.member_access.field;
                        if (sub_base.tag == .identifier and reg_map.get(sub_base.data.identifier) != null) {
                            const r = reg_map.get(sub_base.data.identifier).?;
                            if (r.hir_type.tag == .tagged_union) {
                                if (r.hir_type.getUnionField(field_name)) |uf| {
                                    try self.lowerUnionFieldAssign(alloc, out_stmts, r.hir_type, uf, r.d_name, a.value, reg_map, signal_types);
                                    return;
                                }
                            }
                            if (r.hir_type.getStructField(field_name)) |f| {
                                const sub_target = try alloc.create(hir.HirExpr);
                                sub_target.* = .{
                                    .tag = .signal_ref,
                                    .hir_type = r.hir_type,
                                    .data = .{ .signal_ref = .{ .name = r.d_name } },
                                };
                                target_expr = try alloc.create(hir.HirExpr);
                                target_expr.* = .{
                                    .tag = .slice,
                                    .hir_type = .{ .tag = .bits, .width = f.width },
                                    .data = .{
                                        .slice = .{
                                            .target = sub_target,
                                            .start = f.offset,
                                            .end = f.offset + f.width,
                                            .is_downward = false,
                                        },
                                    },
                                };
                            } else {
                                target_expr = try self.lowerExpr(alloc, a.target, reg_map, signal_types);
                            }
                        } else {
                            target_expr = try self.lowerExpr(alloc, a.target, reg_map, signal_types);
                        }
                    } else {
                        target_expr = try self.lowerExpr(alloc, a.target, reg_map, signal_types);
                    }
                } else if (a.target.tag == .member_access) {
                    const ma = a.target.data.member_access;
                    const field_name = ma.field;
                    var base_id: ?[]const u8 = null;
                    if (ma.target.tag == .identifier) {
                        base_id = ma.target.data.identifier;
                    } else if (ma.target.tag == .member_access and std.mem.eql(u8, ma.target.data.member_access.field, "next")) {
                        if (ma.target.data.member_access.target.tag == .identifier) {
                            base_id = ma.target.data.member_access.target.data.identifier;
                        }
                    }

                    if (base_id != null and reg_map.get(base_id.?) != null) {
                        const r = reg_map.get(base_id.?).?;
                        if (r.hir_type.tag == .tagged_union) {
                            if (r.hir_type.getUnionField(field_name)) |uf| {
                                try self.lowerUnionFieldAssign(alloc, out_stmts, r.hir_type, uf, r.d_name, a.value, reg_map, signal_types);
                                return;
                            }
                        }
                        if (r.hir_type.getStructField(field_name)) |f| {
                            const sub_target = try alloc.create(hir.HirExpr);
                            sub_target.* = .{
                                .tag = .signal_ref,
                                .hir_type = r.hir_type,
                                .data = .{ .signal_ref = .{ .name = r.d_name } },
                            };
                            target_expr = try alloc.create(hir.HirExpr);
                            target_expr.* = .{
                                .tag = .slice,
                                .hir_type = .{ .tag = .bits, .width = f.width },
                                .data = .{
                                    .slice = .{
                                        .target = sub_target,
                                        .start = f.offset,
                                        .end = f.offset + f.width,
                                        .is_downward = false,
                                    },
                                },
                            };
                        } else {
                            target_expr = try self.lowerExpr(alloc, a.target, reg_map, signal_types);
                        }
                    } else if (base_id != null and signal_types.get(base_id.?) != null) {
                        const sig_t = signal_types.get(base_id.?).?;
                        if (sig_t.tag == .tagged_union) {
                            if (sig_t.getUnionField(field_name)) |uf| {
                                try self.lowerUnionFieldAssign(alloc, out_stmts, sig_t, uf, base_id.?, a.value, reg_map, signal_types);
                                return;
                            }
                        }
                        if (sig_t.getStructField(field_name)) |f| {
                            const sub_target = try alloc.create(hir.HirExpr);
                            sub_target.* = .{
                                .tag = .signal_ref,
                                .hir_type = sig_t,
                                .data = .{ .signal_ref = .{ .name = base_id.? } },
                            };
                            target_expr = try alloc.create(hir.HirExpr);
                            target_expr.* = .{
                                .tag = .slice,
                                .hir_type = .{ .tag = .bits, .width = f.width },
                                .data = .{
                                    .slice = .{
                                        .target = sub_target,
                                        .start = f.offset,
                                        .end = f.offset + f.width,
                                        .is_downward = false,
                                    },
                                },
                            };
                        } else {
                            target_expr = try self.lowerExpr(alloc, a.target, reg_map, signal_types);
                        }
                    } else {
                        target_expr = try self.lowerExpr(alloc, a.target, reg_map, signal_types);
                    }
                } else if (a.target.tag == .index) {
                    const base = a.target.data.index.target;
                    const idx_e = try self.lowerExpr(alloc, a.target.data.index.index, reg_map, signal_types);
                    if (base.tag == .member_access and std.mem.eql(u8, base.data.member_access.field, "next")) {
                        const sub_base = base.data.member_access.target;
                        if (sub_base.tag == .identifier and reg_map.get(sub_base.data.identifier) != null) {
                            const r = reg_map.get(sub_base.data.identifier).?;
                            const sub_target = try alloc.create(hir.HirExpr);
                            sub_target.* = .{
                                .tag = .signal_ref,
                                .hir_type = r.hir_type,
                                .data = .{ .signal_ref = .{ .name = r.d_name } },
                            };
                            target_expr = try alloc.create(hir.HirExpr);
                            target_expr.* = .{
                                .tag = .index,
                                .hir_type = .{ .tag = .bits, .width = r.hir_type.elem_width },
                                .data = .{ .index = .{ .target = sub_target, .index = idx_e } },
                            };
                        } else {
                            target_expr = try self.lowerExpr(alloc, a.target, reg_map, signal_types);
                        }
                    } else if (base.tag == .identifier and reg_map.get(base.data.identifier) != null) {
                        const r = reg_map.get(base.data.identifier).?;
                        const sub_target = try alloc.create(hir.HirExpr);
                        sub_target.* = .{
                            .tag = .signal_ref,
                            .hir_type = r.hir_type,
                            .data = .{ .signal_ref = .{ .name = r.d_name } },
                        };
                        target_expr = try alloc.create(hir.HirExpr);
                        target_expr.* = .{
                            .tag = .index,
                            .hir_type = .{ .tag = .bits, .width = r.hir_type.elem_width },
                            .data = .{ .index = .{ .target = sub_target, .index = idx_e } },
                        };
                    } else {
                        target_expr = try self.lowerExpr(alloc, a.target, reg_map, signal_types);
                    }
                } else if (a.target.tag == .identifier and reg_map.get(a.target.data.identifier) != null) {
                    const r = reg_map.get(a.target.data.identifier).?;
                    target_expr = try alloc.create(hir.HirExpr);
                    target_expr.* = .{
                        .tag = .signal_ref,
                        .hir_type = r.hir_type,
                        .data = .{ .signal_ref = .{ .name = r.d_name } },
                    };
                } else {
                    target_expr = try self.lowerExpr(alloc, a.target, reg_map, signal_types);
                }

                var val_expr: *hir.HirExpr = undefined;
                if (target_expr.hir_type.tag == .optional) {
                    if (a.value.tag == .null_lit) {
                        val_expr = try alloc.create(hir.HirExpr);
                        val_expr.* = .{
                            .tag = .lit,
                            .hir_type = target_expr.hir_type,
                            .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                        };
                    } else {
                        val_expr = try self.lowerExpr(alloc, a.value, reg_map, signal_types);
                        if (val_expr.hir_type.tag != .optional) {
                            const one_lit = try alloc.create(hir.HirExpr);
                            one_lit.* = .{
                                .tag = .lit,
                                .hir_type = .{ .tag = .bits, .width = 1 },
                                .data = .{ .lit = .{ .val = 1, .raw = "1'b1" } },
                            };
                            if (val_expr.tag == .lit and target_expr.hir_type.elem_width > 0) {
                                val_expr.hir_type.width = target_expr.hir_type.elem_width;
                            }
                            var cat_args = try alloc.alloc(*hir.HirExpr, 2);
                            cat_args[0] = one_lit;
                            cat_args[1] = val_expr;
                            const wrapped = try alloc.create(hir.HirExpr);
                            wrapped.* = .{
                                .tag = .concat,
                                .hir_type = target_expr.hir_type,
                                .data = .{ .concat = .{ .args = cat_args } },
                            };
                            val_expr = wrapped;
                        }
                    }
                } else if (target_expr.hir_type.tag == .tagged_union and a.value.tag == .struct_init) {
                    const si = a.value.data.struct_init;
                    if (si.fields.len > 0) {
                        val_expr = try self.lowerTaggedUnionInit(alloc, target_expr.hir_type, si.fields[0], reg_map, signal_types);
                    } else {
                        val_expr = try alloc.create(hir.HirExpr);
                        val_expr.* = .{
                            .tag = .lit,
                            .hir_type = target_expr.hir_type,
                            .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                        };
                    }
                } else if (a.value.tag == .struct_init and a.value.data.struct_init.type_expr == null and target_expr.hir_type.struct_fields.len > 0) {
                    const st = target_expr.hir_type;
                    const si = a.value.data.struct_init;
                    var concat_args = ArrayList(*hir.HirExpr).init(alloc);
                    var idx = st.struct_fields.len;
                    while (idx > 0) {
                        idx -= 1;
                        const sf = st.struct_fields[idx];
                        var found_val: ?*ast.Expr = null;
                        for (si.fields) |f| {
                            if (std.mem.eql(u8, f.name, sf.name)) {
                                found_val = f.value;
                                break;
                            }
                        }
                        if (found_val) |fv| {
                            const lowered_f = try self.lowerExpr(alloc, fv, reg_map, signal_types);
                            if (lowered_f.tag == .lit and sf.width > 0) {
                                lowered_f.hir_type.width = sf.width;
                            }
                            try concat_args.append(lowered_f);
                        } else {
                            const zero_expr = try alloc.create(hir.HirExpr);
                            zero_expr.* = .{
                                .tag = .lit,
                                .hir_type = .{ .tag = .bits, .width = sf.width },
                                .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                            };
                            try concat_args.append(zero_expr);
                        }
                    }
                    val_expr = try alloc.create(hir.HirExpr);
                    val_expr.* = .{
                        .tag = .concat,
                        .hir_type = st,
                        .data = .{ .concat = .{ .args = try concat_args.toOwnedSlice() } },
                    };
                } else {
                    val_expr = try self.lowerExpr(alloc, a.value, reg_map, signal_types);
                }
                if (val_expr.tag == .lit and target_expr.hir_type.width > 0) {
                    val_expr.hir_type.width = target_expr.hir_type.width;
                }
                try out_stmts.append(.{
                    .tag = .assign,
                    .data = .{
                        .assign = .{
                            .target = target_expr,
                            .value = val_expr,
                        },
                    },
                });
            },
            .var_decl => {
                const vd = stmt.data.var_decl;
                var val = try self.lowerExpr(alloc, vd.init_val, reg_map, signal_types);
                const h_type = if (vd.type_annot) |t|
                    try self.lowerType(t)
                else if (val.hir_type.width > 0)
                    val.hir_type
                else
                    hir.HirType{ .tag = .bits, .width = 32 };

                if (h_type.tag == .optional) {
                    if (vd.init_val.tag == .null_lit) {
                        val.hir_type = h_type;
                        val.data.lit.val = 0;
                    } else if (val.hir_type.tag != .optional) {
                        const one_lit = try alloc.create(hir.HirExpr);
                        one_lit.* = .{
                            .tag = .lit,
                            .hir_type = .{ .tag = .bits, .width = 1 },
                            .data = .{ .lit = .{ .val = 1, .raw = "1'b1" } },
                        };
                        if (val.tag == .lit and h_type.elem_width > 0) {
                            val.hir_type.width = h_type.elem_width;
                        }
                        var cat_args = try alloc.alloc(*hir.HirExpr, 2);
                        cat_args[0] = one_lit;
                        cat_args[1] = val;
                        const wrapped = try alloc.create(hir.HirExpr);
                        wrapped.* = .{
                            .tag = .concat,
                            .hir_type = h_type,
                            .data = .{ .concat = .{ .args = cat_args } },
                        };
                        val = wrapped;
                    }
                }

                if (h_type.tag == .tagged_union and vd.init_val.tag == .struct_init) {
                    const si = vd.init_val.data.struct_init;
                    if (si.fields.len > 0) {
                        val = try self.lowerTaggedUnionInit(alloc, h_type, si.fields[0], reg_map, signal_types);
                    }
                }

                try local_signals.append(.{
                    .name = vd.name,
                    .hir_type = h_type,
                });
                try signal_types.put(vd.name, h_type);

                const target = try alloc.create(hir.HirExpr);
                target.* = .{
                    .tag = .signal_ref,
                    .hir_type = h_type,
                    .data = .{ .signal_ref = .{ .name = vd.name } },
                };
                if (val.tag == .lit and h_type.width > 0) {
                    val.hir_type.width = h_type.width;
                }

                try out_stmts.append(.{
                    .tag = .assign,
                    .data = .{
                        .assign = .{
                            .target = target,
                            .value = val,
                        },
                    },
                });
            },
            .if_stmt => {
                const ifs = stmt.data.if_stmt;
                const cond = try self.lowerExpr(alloc, ifs.cond, reg_map, signal_types);

                var if_cond = cond;
                if (cond.hir_type.tag == .optional) {
                    const valid_slice = try alloc.create(hir.HirExpr);
                    valid_slice.* = .{
                        .tag = .slice,
                        .hir_type = .{ .tag = .bits, .width = 1 },
                        .data = .{
                            .slice = .{
                                .target = cond,
                                .start = cond.hir_type.width - 1,
                                .end = cond.hir_type.width,
                                .is_downward = false,
                            },
                        },
                    };
                    if_cond = valid_slice;
                }

                var then_list = ArrayList(hir.HirStatement).init(alloc);

                var had_cap_in_sig_types = false;
                var old_cap_sig_type: ?hir.HirType = null;
                if (ifs.capture) |cap_name| {
                    const payload_w = if (cond.hir_type.elem_width > 0)
                        cond.hir_type.elem_width
                    else if (cond.hir_type.width > 1)
                        cond.hir_type.width - 1
                    else
                        1;
                    const cap_type = hir.HirType{ .tag = .bits, .width = payload_w };

                    var found = false;
                    for (local_signals.items) |sig| {
                        if (std.mem.eql(u8, sig.name, cap_name)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try local_signals.append(.{
                            .name = cap_name,
                            .hir_type = cap_type,
                        });
                    }

                    if (signal_types.get(cap_name)) |existing_t| {
                        had_cap_in_sig_types = true;
                        old_cap_sig_type = existing_t;
                    }
                    try signal_types.put(cap_name, cap_type);

                    const cap_target = try alloc.create(hir.HirExpr);
                    cap_target.* = .{
                        .tag = .signal_ref,
                        .hir_type = cap_type,
                        .data = .{ .signal_ref = .{ .name = cap_name } },
                    };

                    const payload_slice = try alloc.create(hir.HirExpr);
                    payload_slice.* = .{
                        .tag = .slice,
                        .hir_type = cap_type,
                        .data = .{
                            .slice = .{
                                .target = cond,
                                .start = 0,
                                .end = payload_w,
                                .is_downward = false,
                            },
                        },
                    };

                    try then_list.append(.{
                        .tag = .assign,
                        .data = .{
                            .assign = .{
                                .target = cap_target,
                                .value = payload_slice,
                            },
                        },
                    });
                }

                for (ifs.then_stmts) |s| {
                    try self.lowerStatement(alloc, s, &then_list, local_signals, reg_map, signal_types);
                }

                if (ifs.capture) |cap_name| {
                    if (had_cap_in_sig_types) {
                        try signal_types.put(cap_name, old_cap_sig_type.?);
                    } else {
                        _ = signal_types.remove(cap_name);
                    }
                }

                var else_list: ?[]hir.HirStatement = null;
                if (ifs.else_stmts) |es| {
                    var el = ArrayList(hir.HirStatement).init(alloc);
                    for (es) |s| {
                        try self.lowerStatement(alloc, s, &el, local_signals, reg_map, signal_types);
                    }
                    else_list = try el.toOwnedSlice();
                }

                try out_stmts.append(.{
                    .tag = .if_stmt,
                    .data = .{
                        .if_stmt = .{
                            .cond = if_cond,
                            .then_body = try then_list.toOwnedSlice(),
                            .else_body = else_list,
                        },
                    },
                });
            },
            .switch_stmt => {
                const sw = stmt.data.switch_stmt;
                const target = try self.lowerExpr(alloc, sw.expr, reg_map, signal_types);

                if (target.hir_type.tag == .tagged_union) {
                    const tag_slice = try alloc.create(hir.HirExpr);
                    tag_slice.* = .{
                        .tag = .slice,
                        .hir_type = .{ .tag = .bits, .width = target.hir_type.tag_width },
                        .data = .{
                            .slice = .{
                                .target = target,
                                .start = target.hir_type.elem_width,
                                .end = target.hir_type.width,
                                .is_downward = false,
                            },
                        },
                    };

                    var branches = ArrayList(hir.HirCaseBranch).init(alloc);
                    for (sw.cases) |c| {
                        var vals = ArrayList(u64).init(alloc);
                        if (!c.is_else) {
                            for (c.patterns) |p| {
                                if (p.tag == .enum_literal) {
                                    if (target.hir_type.getUnionField(p.data.enum_literal)) |uf| {
                                        try vals.append(uf.tag_value);
                                    } else {
                                        try vals.append(self.getEnumVal(p.data.enum_literal));
                                    }
                                } else if (p.tag == .number) {
                                    try vals.append(p.data.number.val);
                                }
                            }
                        }

                        var body_stmts = ArrayList(hir.HirStatement).init(alloc);
                        var had_cap_in_sig_types = false;
                        var old_cap_sig_type: ?hir.HirType = null;

                        if (c.capture) |cap_name| {
                            var payload_w: u32 = 0;
                            if (c.patterns.len > 0 and c.patterns[0].tag == .enum_literal) {
                                if (target.hir_type.getUnionField(c.patterns[0].data.enum_literal)) |uf| {
                                    payload_w = uf.payload_width;
                                }
                            }

                            if (payload_w > 0) {
                                var cap_type = hir.HirType{ .tag = .bits, .width = payload_w };
                                if (c.patterns.len > 0 and c.patterns[0].tag == .enum_literal) {
                                    if (target.hir_type.getUnionField(c.patterns[0].data.enum_literal)) |uf| {
                                        if (uf.payload_type_name.len > 0) {
                                            if (self.types.get(uf.payload_type_name)) |found_t| {
                                                cap_type = found_t;
                                            }
                                        }
                                    }
                                }

                                var found = false;
                                for (local_signals.items) |*sig| {
                                    if (std.mem.eql(u8, sig.name, cap_name)) {
                                        found = true;
                                        if (cap_type.width > sig.hir_type.width) {
                                            sig.hir_type.width = cap_type.width;
                                        }
                                        break;
                                    }
                                }
                                if (!found) {
                                    try local_signals.append(.{
                                        .name = cap_name,
                                        .hir_type = cap_type,
                                    });
                                }

                                if (signal_types.get(cap_name)) |existing_t| {
                                    had_cap_in_sig_types = true;
                                    old_cap_sig_type = existing_t;
                                }
                                try signal_types.put(cap_name, cap_type);

                                const cap_target = try alloc.create(hir.HirExpr);
                                cap_target.* = .{
                                    .tag = .signal_ref,
                                    .hir_type = cap_type,
                                    .data = .{ .signal_ref = .{ .name = cap_name } },
                                };

                                const cap_slice = try alloc.create(hir.HirExpr);
                                cap_slice.* = .{
                                    .tag = .slice,
                                    .hir_type = cap_type,
                                    .data = .{
                                        .slice = .{
                                            .target = target,
                                            .start = 0,
                                            .end = payload_w,
                                            .is_downward = false,
                                        },
                                    },
                                };

                                try body_stmts.append(.{
                                    .tag = .assign,
                                    .data = .{
                                        .assign = .{
                                            .target = cap_target,
                                            .value = cap_slice,
                                        },
                                    },
                                });
                            }
                        }

                        for (c.body) |s| {
                            try self.lowerStatement(alloc, s, &body_stmts, local_signals, reg_map, signal_types);
                        }

                        if (c.capture) |cap_name| {
                            if (had_cap_in_sig_types) {
                                try signal_types.put(cap_name, old_cap_sig_type.?);
                            } else {
                                _ = signal_types.remove(cap_name);
                            }
                        }

                        try branches.append(.{
                            .pattern_values = try vals.toOwnedSlice(),
                            .is_default = c.is_else,
                            .body = try body_stmts.toOwnedSlice(),
                        });
                    }

                    try out_stmts.append(.{
                        .tag = .case_stmt,
                        .data = .{
                            .case_stmt = .{
                                .expr = tag_slice,
                                .branches = try branches.toOwnedSlice(),
                            },
                        },
                    });
                } else {
                    var branches = ArrayList(hir.HirCaseBranch).init(alloc);
                    for (sw.cases) |c| {
                        var vals = ArrayList(u64).init(alloc);
                        for (c.patterns) |p| {
                            if (p.tag == .number) {
                                try vals.append(p.data.number.val);
                            } else if (p.tag == .enum_literal) {
                                // Enum literal: find value or assign index
                                try vals.append(self.getEnumVal(p.data.enum_literal));
                            }
                        }

                        var body_stmts = ArrayList(hir.HirStatement).init(alloc);
                        for (c.body) |s| {
                            try self.lowerStatement(alloc, s, &body_stmts, local_signals, reg_map, signal_types);
                        }

                        try branches.append(.{
                            .pattern_values = try vals.toOwnedSlice(),
                            .is_default = c.is_else,
                            .body = try body_stmts.toOwnedSlice(),
                        });
                    }

                    try out_stmts.append(.{
                        .tag = .case_stmt,
                        .data = .{
                            .case_stmt = .{
                                .expr = target,
                                .branches = try branches.toOwnedSlice(),
                            },
                        },
                    });
                }
            },
            .inline_for => {
                // Comptime unrolling of loop
                const loop = stmt.data.inline_for;
                const start_val = if (loop.start.tag == .number) loop.start.data.number.val else 0;
                const end_val = if (loop.end.tag == .number) loop.end.data.number.val else 0;

                var idx = start_val;
                while (idx < end_val) : (idx += 1) {
                    try self.constants.put(loop.var_name, idx);
                    for (loop.body) |s| {
                        try self.lowerStatement(alloc, s, out_stmts, local_signals, reg_map, signal_types);
                    }
                }
                _ = self.constants.remove(loop.var_name);
            },
            .expr_stmt => {},
        }
    }

    fn lowerExpr(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        expr: *ast.Expr,
        reg_map: *const std.StringHashMap(hir.HirRegister),
        signal_types: *const std.StringHashMap(hir.HirType),
    ) !*hir.HirExpr {
        const h_expr = try alloc.create(hir.HirExpr);

        switch (expr.tag) {
            .number => {
                h_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = 32 },
                    .data = .{
                        .lit = .{
                            .val = expr.data.number.val,
                            .raw = expr.data.number.raw,
                        },
                    },
                };
            },
            .time_literal => {
                h_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = 64 },
                    .data = .{
                        .lit = .{
                            .val = convertToNs(expr.data.time_literal),
                            .raw = expr.data.time_literal.raw,
                        },
                    },
                };
            },
            .freq_literal => {
                h_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = 64 },
                    .data = .{
                        .lit = .{
                            .val = convertFreqToNs(expr.data.freq_literal),
                            .raw = expr.data.freq_literal.raw,
                        },
                    },
                };
            },
            .boolean => {
                h_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = 1 },
                    .data = .{
                        .lit = .{
                            .val = if (expr.data.boolean) 1 else 0,
                            .raw = if (expr.data.boolean) "1" else "0",
                        },
                    },
                };
            },
            .null_lit => {
                h_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = 1 },
                    .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                };
            },
            .identifier => {
                const name = expr.data.identifier;
                if (self.param_env) |pe| {
                    if (pe.get(name)) |bound_expr| {
                        return bound_expr;
                    }
                }
                // If it's a register name, reading it maps to Q output (e.g. count_q)
                if (reg_map.get(name)) |r| {
                    h_expr.* = .{
                        .tag = .signal_ref,
                        .hir_type = r.hir_type,
                        .data = .{ .signal_ref = .{ .name = r.q_name } },
                    };
                } else if (self.constants.get(name)) |c_val| {
                    h_expr.* = .{
                        .tag = .lit,
                        .hir_type = .{ .tag = .bits, .width = 32 },
                        .data = .{ .lit = .{ .val = c_val, .raw = "" } },
                    };
                } else if (signal_types.get(name)) |st| {
                    h_expr.* = .{
                        .tag = .signal_ref,
                        .hir_type = st,
                        .data = .{ .signal_ref = .{ .name = name } },
                    };
                } else {
                    h_expr.* = .{
                        .tag = .signal_ref,
                        .hir_type = .{ .tag = .bits, .width = 32 },
                        .data = .{ .signal_ref = .{ .name = name } },
                    };
                }
            },
            .enum_literal => {
                const val = self.getEnumVal(expr.data.enum_literal);
                h_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = 8 },
                    .data = .{
                        .lit = .{
                            .val = val,
                            .raw = expr.data.enum_literal,
                        },
                    },
                };
            },
            .member_access => {
                const ma = expr.data.member_access;
                const target = try self.lowerExpr(alloc, ma.target, reg_map, signal_types);
                if (target.hir_type.getStructField(ma.field)) |f| {
                    h_expr.* = .{
                        .tag = .slice,
                        .hir_type = .{ .tag = .bits, .width = f.width },
                        .data = .{
                            .slice = .{
                                .target = target,
                                .start = f.offset,
                                .end = f.offset + f.width,
                                .is_downward = false,
                            },
                        },
                    };
                } else {
                    h_expr.* = .{
                        .tag = .member,
                        .hir_type = .{ .tag = .bits, .width = 32 },
                        .data = .{
                            .member = .{
                                .target = target,
                                .field = ma.field,
                            },
                        },
                    };
                }
            },
            .binary => {
                const b = expr.data.binary;
                const left = try self.lowerExpr(alloc, b.left, reg_map, signal_types);
                const right = try self.lowerExpr(alloc, b.right, reg_map, signal_types);

                if (b.op != .shl and b.op != .shr) {
                    if (left.hir_type.width > 0 and right.tag == .lit) {
                        right.hir_type.width = left.hir_type.width;
                    } else if (right.hir_type.width > 0 and left.tag == .lit) {
                        left.hir_type.width = right.hir_type.width;
                    }
                }

                const is_compare = switch (b.op) {
                    .equal_equal, .bang_equal, .less_than, .less_than_equal, .greater_than, .greater_than_equal, .ampersand_ampersand, .pipe_pipe => true,
                    else => false,
                };

                h_expr.* = .{
                    .tag = .binary,
                    .hir_type = if (is_compare) hir.HirType{ .tag = .bits, .width = 1 } else left.hir_type,
                    .data = .{
                        .binary = .{
                            .op = b.op,
                            .left = left,
                            .right = right,
                        },
                    },
                };
            },
            .unary => {
                const u = expr.data.unary;
                const operand = try self.lowerExpr(alloc, u.operand, reg_map, signal_types);
                h_expr.* = .{
                    .tag = .unary,
                    .hir_type = operand.hir_type,
                    .data = .{
                        .unary = .{
                            .op = u.op,
                            .operand = operand,
                        },
                    },
                };
            },
            .slice => {
                const sl = expr.data.slice;
                const target = try self.lowerExpr(alloc, sl.target, reg_map, signal_types);
                const start_val: u32 = @intCast(self.evalConst(sl.start));
                const end_val: u32 = @intCast(self.evalConst(sl.end));

                var is_downward = sl.is_downward;
                var s = start_val;
                var e = end_val;
                if (start_val > end_val) {
                    is_downward = true;
                    s = end_val;
                    e = start_val;
                }

                const width = if (e >= s) e - s else 1;
                h_expr.* = .{
                    .tag = .slice,
                    .hir_type = .{ .tag = .bits, .width = width },
                    .data = .{
                        .slice = .{
                            .target = target,
                            .start = s,
                            .end = e,
                            .is_downward = is_downward,
                        },
                    },
                };
            },
            .index => {
                const idx = expr.data.index;
                const target = try self.lowerExpr(alloc, idx.target, reg_map, signal_types);
                const index_e = try self.lowerExpr(alloc, idx.index, reg_map, signal_types);
                const w: u32 = if (target.hir_type.tag == .array) target.hir_type.elem_width else 1;
                h_expr.* = .{
                    .tag = .index,
                    .hir_type = .{ .tag = .bits, .width = w },
                    .data = .{
                        .index = .{
                            .target = target,
                            .index = index_e,
                        },
                    },
                };
            },
            .builtin_call => {
                const bc = expr.data.builtin_call;
                switch (bc.tag) {
                    .builtin_bit_reverse => {
                        const target = try self.lowerExpr(alloc, bc.args[0], reg_map, signal_types);
                        h_expr.* = .{
                            .tag = .bit_reverse,
                            .hir_type = target.hir_type,
                            .data = .{ .bit_reverse = .{ .target = target } },
                        };
                    },
                    .builtin_byte_swap => {
                        const target = try self.lowerExpr(alloc, bc.args[0], reg_map, signal_types);
                        h_expr.* = .{
                            .tag = .byte_swap,
                            .hir_type = target.hir_type,
                            .data = .{ .byte_swap = .{ .target = target } },
                        };
                    },
                    .builtin_concat => {
                        var args = ArrayList(*hir.HirExpr).init(alloc);
                        var total_w: u32 = 0;
                        for (bc.args) |a| {
                            const sub = try self.lowerExpr(alloc, a, reg_map, signal_types);
                            try args.append(sub);
                            total_w += sub.hir_type.width;
                        }
                        h_expr.* = .{
                            .tag = .concat,
                            .hir_type = .{ .tag = .bits, .width = total_w },
                            .data = .{ .concat = .{ .args = try args.toOwnedSlice() } },
                        };
                    },
                    .builtin_as, .builtin_truncate, .builtin_bit_cast => {
                        var target_w: u32 = 32;
                        var target_type: ?hir.HirType = null;
                        if (bc.args.len > 1) {
                            const type_arg = bc.args[0];
                            if (type_arg.tag == .identifier) {
                                const id_name = type_arg.data.identifier;
                                if ((id_name[0] == 'u' or id_name[0] == 'i') and id_name.len > 1) {
                                    target_w = std.fmt.parseInt(u32, id_name[1..], 10) catch 32;
                                } else if (self.types.get(id_name)) |found_t| {
                                    target_type = found_t;
                                    target_w = found_t.width;
                                }
                            } else if (type_arg.tag == .type_expr) {
                                const found_t = try self.lowerType(type_arg.data.type_expr);
                                target_type = found_t;
                                target_w = found_t.width;
                            }
                            const val_arg = bc.args[1];
                            const sub = try self.lowerExpr(alloc, val_arg, reg_map, signal_types);

                            if (bc.tag == .builtin_truncate and sub.tag != .lit and sub.hir_type.width > target_w) {
                                h_expr.* = .{
                                    .tag = .slice,
                                    .hir_type = if (target_type) |tt| tt else hir.HirType{ .tag = .bits, .width = target_w },
                                    .data = .{
                                        .slice = .{
                                            .target = sub,
                                            .start = 0,
                                            .end = target_w,
                                            .is_downward = false,
                                        },
                                    },
                                };
                            } else {
                                if (sub.tag == .lit and target_w < 64) {
                                    sub.data.lit.val = sub.data.lit.val & ((@as(u64, 1) << @intCast(target_w)) - 1);
                                }
                                if (target_type) |tt| {
                                    sub.hir_type = tt;
                                } else {
                                    sub.hir_type.width = target_w;
                                }
                                h_expr.* = sub.*;
                            }
                        } else {
                            const sub = try self.lowerExpr(alloc, bc.args[0], reg_map, signal_types);
                            h_expr.* = sub.*;
                        }
                    },
                    .builtin_sync2ff => {
                        if (bc.args.len < 2) {
                            return error.InvalidComptimeExpr;
                        }
                        const dest_clk_name = switch (bc.args[0].tag) {
                            .identifier => bc.args[0].data.identifier,
                            .member_access => bc.args[0].data.member_access.field,
                            else => "clk",
                        };

                        const sub = try self.lowerExpr(alloc, bc.args[1], reg_map, signal_types);
                        const h_type: hir.HirType = if (sub.hir_type.width > 0) sub.hir_type else .{ .tag = .bits, .width = 1 };

                        // If active_registers is null (e.g. during pass 1 type deduction), return dummy signal_ref
                        if (self.active_registers == null or self.active_comb_stmts == null) {
                            h_expr.* = .{
                                .tag = .signal_ref,
                                .hir_type = h_type,
                                .data = .{ .signal_ref = .{ .name = "_sync2ff_dummy" } },
                            };
                        } else {
                            const sync_id = self.next_sync_id;
                            self.next_sync_id += 1;

                            const ff1_name = try std.fmt.allocPrint(alloc, "_sync2ff_{d}_stage1", .{sync_id});
                            const ff1_q = try std.fmt.allocPrint(alloc, "{s}_q", .{ff1_name});
                            const ff1_d = try std.fmt.allocPrint(alloc, "{s}_d", .{ff1_name});

                            const ff2_name = try std.fmt.allocPrint(alloc, "_sync2ff_{d}_stage2", .{sync_id});
                            const ff2_q = try std.fmt.allocPrint(alloc, "{s}_q", .{ff2_name});
                            const ff2_d = try std.fmt.allocPrint(alloc, "{s}_d", .{ff2_name});

                            const reg1: hir.HirRegister = .{
                                .name = ff1_name,
                                .q_name = ff1_q,
                                .d_name = ff1_d,
                                .hir_type = h_type,
                                .clk_name = dest_clk_name,
                                .rst_name = null,
                                .rst_active_low = false,
                                .init_val = 0,
                                .is_sync_stage = true,
                            };
                            const reg2: hir.HirRegister = .{
                                .name = ff2_name,
                                .q_name = ff2_q,
                                .d_name = ff2_d,
                                .hir_type = h_type,
                                .clk_name = dest_clk_name,
                                .rst_name = null,
                                .rst_active_low = false,
                                .init_val = 0,
                                .is_sync_stage = true,
                            };

                            try self.active_registers.?.append(reg1);
                            try self.active_registers.?.append(reg2);
                            if (self.active_reg_map) |rm| {
                                try rm.put(ff1_name, reg1);
                                try rm.put(ff2_name, reg2);
                            }

                            if (self.active_local_signals) |ls| {
                                try ls.append(.{ .name = ff1_q, .hir_type = h_type });
                                try ls.append(.{ .name = ff1_d, .hir_type = h_type });
                                try ls.append(.{ .name = ff2_q, .hir_type = h_type });
                                try ls.append(.{ .name = ff2_d, .hir_type = h_type });
                            }
                            if (self.active_signal_types) |st| {
                                try st.put(ff1_name, h_type);
                                try st.put(ff1_q, h_type);
                                try st.put(ff1_d, h_type);
                                try st.put(ff2_name, h_type);
                                try st.put(ff2_q, h_type);
                                try st.put(ff2_d, h_type);
                            }

                            // Wire ff1_d = sub
                            const target1 = try alloc.create(hir.HirExpr);
                            target1.* = .{
                                .tag = .signal_ref,
                                .hir_type = h_type,
                                .data = .{ .signal_ref = .{ .name = ff1_d } },
                            };
                            try self.active_comb_stmts.?.append(.{
                                .tag = .assign,
                                .data = .{ .assign = .{ .target = target1, .value = sub } },
                            });

                            // Wire ff2_d = ff1_q
                            const target2 = try alloc.create(hir.HirExpr);
                            target2.* = .{
                                .tag = .signal_ref,
                                .hir_type = h_type,
                                .data = .{ .signal_ref = .{ .name = ff2_d } },
                            };
                            const src2 = try alloc.create(hir.HirExpr);
                            src2.* = .{
                                .tag = .signal_ref,
                                .hir_type = h_type,
                                .data = .{ .signal_ref = .{ .name = ff1_q } },
                            };
                            try self.active_comb_stmts.?.append(.{
                                .tag = .assign,
                                .data = .{ .assign = .{ .target = target2, .value = src2 } },
                            });

                            // Return reference to ff2_q
                            h_expr.* = .{
                                .tag = .signal_ref,
                                .hir_type = h_type,
                                .data = .{ .signal_ref = .{ .name = ff2_q } },
                            };
                        }
                    },
                    else => {
                        h_expr.* = .{
                            .tag = .lit,
                            .hir_type = .{ .tag = .bits, .width = 32 },
                            .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                        };
                    },
                }
            },
            .if_expr => {
                const ife = expr.data.if_expr;
                const cond = try self.lowerExpr(alloc, ife.cond, reg_map, signal_types);
                const then_e = try self.lowerExpr(alloc, ife.then_branch, reg_map, signal_types);
                const else_e = try self.lowerExpr(alloc, ife.else_branch, reg_map, signal_types);

                if (then_e.hir_type.width > 0 and else_e.tag == .lit) {
                    else_e.hir_type.width = then_e.hir_type.width;
                } else if (else_e.hir_type.width > 0 and then_e.tag == .lit) {
                    then_e.hir_type.width = else_e.hir_type.width;
                }

                const mux_type = if (then_e.tag != .lit and then_e.hir_type.width > 0) then_e.hir_type else else_e.hir_type;

                h_expr.* = .{
                    .tag = .mux,
                    .hir_type = mux_type,
                    .data = .{
                        .mux = .{
                            .cond = cond,
                            .then_expr = then_e,
                            .else_expr = else_e,
                        },
                    },
                };
            },
            .struct_init => {
                const si = expr.data.struct_init;
                var resolved_type: ?hir.HirType = null;
                if (si.type_expr) |te| {
                    resolved_type = try self.lowerType(te);
                }

                if (resolved_type != null and resolved_type.?.tag == .tagged_union) {
                    if (si.fields.len > 0) {
                        return try self.lowerTaggedUnionInit(alloc, resolved_type.?, si.fields[0], reg_map, signal_types);
                    }
                }

                if (resolved_type != null and resolved_type.?.struct_fields.len > 0) {
                    const st = resolved_type.?;
                    var concat_args = ArrayList(*hir.HirExpr).init(alloc);
                    var idx = st.struct_fields.len;
                    while (idx > 0) {
                        idx -= 1;
                        const sf = st.struct_fields[idx];
                        var found_val: ?*ast.Expr = null;
                        for (si.fields) |f| {
                            if (std.mem.eql(u8, f.name, sf.name)) {
                                found_val = f.value;
                                break;
                            }
                        }
                        if (found_val) |fv| {
                            const lowered_f = try self.lowerExpr(alloc, fv, reg_map, signal_types);
                            if (lowered_f.tag == .lit and sf.width > 0) {
                                lowered_f.hir_type.width = sf.width;
                            }
                            try concat_args.append(lowered_f);
                        } else {
                            const zero_expr = try alloc.create(hir.HirExpr);
                            zero_expr.* = .{
                                .tag = .lit,
                                .hir_type = .{ .tag = .bits, .width = sf.width },
                                .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                            };
                            try concat_args.append(zero_expr);
                        }
                    }
                    h_expr.* = .{
                        .tag = .concat,
                        .hir_type = st,
                        .data = .{ .concat = .{ .args = try concat_args.toOwnedSlice() } },
                    };
                } else {
                    var concat_args = ArrayList(*hir.HirExpr).init(alloc);
                    var total_w: u32 = 0;
                    var idx = si.fields.len;
                    while (idx > 0) {
                        idx -= 1;
                        const f = si.fields[idx];
                        const lowered_f = try self.lowerExpr(alloc, f.value, reg_map, signal_types);
                        total_w += lowered_f.hir_type.width;
                        try concat_args.append(lowered_f);
                    }
                    h_expr.* = .{
                        .tag = .concat,
                        .hir_type = .{ .tag = .bits, .width = total_w },
                        .data = .{ .concat = .{ .args = try concat_args.toOwnedSlice() } },
                    };
                }
            },
            .call => {
                const c = expr.data.call;
                const callee = c.callee;

                if (callee.tag == .member_access) {
                    const ma = callee.data.member_access;
                    // Check if ma.target is an identifier referring to a type name (e.g. MyType.method(arg0, ...))
                    if (ma.target.tag == .identifier and self.type_methods.contains(ma.target.data.identifier)) {
                        const type_name = ma.target.data.identifier;
                        const methods = self.type_methods.get(type_name).?;
                        if (methods.get(ma.field)) |fn_decl| {
                            var new_env = std.StringHashMap(*hir.HirExpr).init(alloc);
                            for (fn_decl.params, 0..) |param, i| {
                                if (i < c.args.len) {
                                    const arg_val = try self.lowerExpr(alloc, c.args[i], reg_map, signal_types);
                                    try new_env.put(param.name, arg_val);
                                }
                            }
                            const prev_env = self.param_env;
                            self.param_env = &new_env;
                            defer self.param_env = prev_env;

                            var inlined_res = try self.lowerExpr(alloc, fn_decl.body_expr, reg_map, signal_types);
                            if (fn_decl.return_type) |rt| {
                                const ret_h = try self.lowerType(rt);
                                if (ret_h.width > 0) inlined_res.hir_type.width = ret_h.width;
                                if (ret_h.name.len > 0) inlined_res.hir_type.name = ret_h.name;
                                if (ret_h.tag != .bits) inlined_res.hir_type = ret_h;
                            }
                            h_expr.* = inlined_res.*;
                            return h_expr;
                        }
                    } else {
                        // Otherwise, lower target = try self.lowerExpr(...)
                        const target = try self.lowerExpr(alloc, ma.target, reg_map, signal_types);
                        var type_name = target.hir_type.name;
                        if (type_name.len == 0) {
                            var tit = self.types.iterator();
                            while (tit.next()) |entry| {
                                if (entry.value_ptr.tag == target.hir_type.tag and entry.value_ptr.width == target.hir_type.width) {
                                    if (self.type_methods.contains(entry.key_ptr.*)) {
                                        type_name = entry.key_ptr.*;
                                        break;
                                    }
                                }
                            }
                        }
                        if (type_name.len > 0) {
                            if (self.type_methods.get(type_name)) |methods| {
                                if (methods.get(ma.field)) |fn_decl| {
                                    var new_env = std.StringHashMap(*hir.HirExpr).init(alloc);
                                    if (fn_decl.params.len > 0) {
                                        try new_env.put(fn_decl.params[0].name, target);
                                        for (fn_decl.params[1..], 0..) |param, i| {
                                            if (i < c.args.len) {
                                                const arg_val = try self.lowerExpr(alloc, c.args[i], reg_map, signal_types);
                                                try new_env.put(param.name, arg_val);
                                            }
                                        }
                                    }
                                    const prev_env = self.param_env;
                                    self.param_env = &new_env;
                                    defer self.param_env = prev_env;

                                    var inlined_res = try self.lowerExpr(alloc, fn_decl.body_expr, reg_map, signal_types);
                                    if (fn_decl.return_type) |rt| {
                                        const ret_h = try self.lowerType(rt);
                                        if (ret_h.width > 0) inlined_res.hir_type.width = ret_h.width;
                                        if (ret_h.name.len > 0) inlined_res.hir_type.name = ret_h.name;
                                        if (ret_h.tag != .bits) inlined_res.hir_type = ret_h;
                                    }
                                    h_expr.* = inlined_res.*;
                                    return h_expr;
                                }
                            }
                        }
                    }
                } else if (callee.tag == .identifier and self.fn_decls.contains(callee.data.identifier)) {
                    const fn_decl = self.fn_decls.get(callee.data.identifier).?;
                    if (fn_decl.body_expr.tag == .module_literal) {
                        return error.TypeMismatch;
                    }
                    var new_env = std.StringHashMap(*hir.HirExpr).init(alloc);
                    for (fn_decl.params, 0..) |param, i| {
                        if (i < c.args.len) {
                            const arg_val = try self.lowerExpr(alloc, c.args[i], reg_map, signal_types);
                            try new_env.put(param.name, arg_val);
                        }
                    }
                    const prev_env = self.param_env;
                    self.param_env = &new_env;
                    defer self.param_env = prev_env;

                    var inlined_res = try self.lowerExpr(alloc, fn_decl.body_expr, reg_map, signal_types);
                    if (fn_decl.return_type) |rt| {
                        const ret_h = try self.lowerType(rt);
                        if (ret_h.width > 0) inlined_res.hir_type.width = ret_h.width;
                        if (ret_h.name.len > 0) inlined_res.hir_type.name = ret_h.name;
                        if (ret_h.tag != .bits) inlined_res.hir_type = ret_h;
                    }
                    h_expr.* = inlined_res.*;
                    return h_expr;
                }

                h_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = 32 },
                    .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                };
            },
            else => {
                h_expr.* = .{
                    .tag = .lit,
                    .hir_type = .{ .tag = .bits, .width = 32 },
                    .data = .{ .lit = .{ .val = 0, .raw = "0" } },
                };
            },
        }

        return h_expr;
    }

    fn lowerType(self: *Elaborator, t: *ast.Type) !hir.HirType {
        switch (t.tag) {
            .int => {
                const w = self.evalConst(t.data.int.width);
                return .{
                    .tag = .bits,
                    .width = @intCast(w),
                    .is_signed = t.data.int.is_signed,
                };
            },
            .array => {
                const len = self.evalConst(t.data.array.len);
                const elem_t = try self.lowerType(t.data.array.elem_type);
                return .{
                    .tag = .array,
                    .width = elem_t.width * @as(u32, @intCast(len)),
                    .elem_width = elem_t.width,
                    .array_len = @intCast(len),
                };
            },
            .named => {
                const name = t.data.named;
                if (std.mem.eql(u8, name, "clock")) {
                    return .{ .tag = .clock, .width = 1 };
                }
                if (std.mem.eql(u8, name, "reset")) {
                    return .{ .tag = .reset, .width = 1, .is_active_low = false };
                }
                if (std.mem.eql(u8, name, "reset_n") or std.mem.eql(u8, name, "reset_low")) {
                    return .{ .tag = .reset, .width = 1, .is_active_low = true };
                }
                if (self.types.get(name)) |found| {
                    return found;
                }
                return .{ .tag = .bits, .width = 1, .name = name };
            },
            .reset => {
                return .{
                    .tag = .reset,
                    .width = 1,
                    .is_active_low = t.data.reset.is_active_low,
                };
            },
            .enum_type => {
                const N = t.data.enum_type.fields.len;
                const tag_w: u32 = if (t.data.enum_type.tag_type != null)
                    (try self.lowerType(t.data.enum_type.tag_type.?)).width
                else if (N <= 1)
                    1
                else
                    @intCast(std.math.log2_int_ceil(usize, N));

                var variants = try self.allocator.alloc(hir.HirEnumVariant, N);
                try self.allocated_enum_variants.append(variants);

                var cur_val: u64 = 0;
                for (t.data.enum_type.fields, 0..) |f, i| {
                    if (f.value) |v| {
                        cur_val = self.evalConst(v);
                    }
                    variants[i] = .{
                        .name = f.name,
                        .value = cur_val,
                    };
                    try self.enum_variants.put(f.name, cur_val);
                    cur_val += 1;
                }

                return .{
                    .tag = .enum_type,
                    .width = tag_w,
                    .enum_variants = variants,
                };
            },
            .packed_struct => {
                const f_count = t.data.packed_struct.fields.len;
                var struct_fields = try self.allocator.alloc(hir.HirStructField, f_count);
                try self.allocated_struct_fields.append(struct_fields);
                var offset: u32 = 0;
                for (t.data.packed_struct.fields, 0..) |f, i| {
                    const f_type = try self.lowerType(f.type_expr);
                    struct_fields[i] = .{
                        .name = f.name,
                        .width = f_type.width,
                        .offset = offset,
                    };
                    offset += f_type.width;
                }
                return .{
                    .tag = .packed_struct,
                    .width = offset,
                    .struct_fields = struct_fields,
                };
            },
            .optional => {
                const child_t = try self.lowerType(t.data.optional);
                const total_w = child_t.width + 1;
                var struct_fields = try self.allocator.alloc(hir.HirStructField, 2);
                try self.allocated_struct_fields.append(struct_fields);
                struct_fields[0] = .{
                    .name = "data",
                    .width = child_t.width,
                    .offset = 0,
                };
                struct_fields[1] = .{
                    .name = "valid",
                    .width = 1,
                    .offset = child_t.width,
                };
                return .{
                    .tag = .optional,
                    .width = total_w,
                    .elem_width = child_t.width,
                    .struct_fields = struct_fields,
                };
            },
            .tagged_union => {
                const u_data = t.data.tagged_union;
                const N = u_data.fields.len;
                const tag_w: u32 = if (u_data.tag_type != null)
                    (try self.lowerType(u_data.tag_type.?)).width
                else if (N <= 1)
                    1
                else
                    @intCast(std.math.log2_int_ceil(usize, N));

                var max_payload_w: u32 = 0;
                for (u_data.fields) |f| {
                    if (f.type_expr) |te| {
                        const ft = try self.lowerType(te);
                        max_payload_w = @max(max_payload_w, ft.width);
                    }
                }

                const total_w = tag_w + max_payload_w;

                var union_fields = try self.allocator.alloc(hir.HirUnionField, N);
                try self.allocated_union_fields.append(union_fields);

                for (u_data.fields, 0..) |f, i| {
                    var f_payload_w: u32 = 0;
                    var f_type_name: []const u8 = "";
                    if (f.type_expr) |te| {
                        const ft = try self.lowerType(te);
                        f_payload_w = ft.width;
                        if (te.tag == .named) {
                            f_type_name = te.data.named;
                        } else if (ft.name.len > 0) {
                            f_type_name = ft.name;
                        }
                    }
                    union_fields[i] = .{
                        .name = f.name,
                        .tag_value = @intCast(i),
                        .payload_width = f_payload_w,
                        .payload_type_name = f_type_name,
                    };
                    try self.enum_variants.put(f.name, @intCast(i));
                }

                var struct_fields = try self.allocator.alloc(hir.HirStructField, 1 + N);
                try self.allocated_struct_fields.append(struct_fields);

                struct_fields[0] = .{
                    .name = "tag",
                    .width = tag_w,
                    .offset = max_payload_w,
                };
                for (union_fields, 0..) |uf, i| {
                    struct_fields[1 + i] = .{
                        .name = uf.name,
                        .width = uf.payload_width,
                        .offset = 0,
                    };
                }

                return .{
                    .tag = .tagged_union,
                    .width = total_w,
                    .elem_width = max_payload_w,
                    .tag_width = tag_w,
                    .union_fields = union_fields,
                    .struct_fields = struct_fields,
                };
            },
        }
    }

    // =========================================================================
    // Race Condition Prevention & Static Verification Checks
    // =========================================================================

    const DriverKind = enum {
        input_port,
        submodule_output,
        continuous_wire,
        comb_block,
    };

    const DriverInfo = struct {
        kind: DriverKind,
        desc: []const u8,
        comb_block_idx: ?usize = null,
    };

    fn getHirTargetBaseName(target: *const hir.HirExpr) ?[]const u8 {
        switch (target.tag) {
            .signal_ref => return target.data.signal_ref.name,
            .index => return getHirTargetBaseName(target.data.index.target),
            .slice => return getHirTargetBaseName(target.data.slice.target),
            .member => return getHirTargetBaseName(target.data.member.target),
            else => return null,
        }
    }

    fn getAstTargetBaseName(target: *const ast.Expr) ?[]const u8 {
        switch (target.tag) {
            .identifier => return target.data.identifier,
            .member_access => {
                if (std.mem.eql(u8, target.data.member_access.field, "next")) {
                    return getAstTargetBaseName(target.data.member_access.target);
                }
                return getAstTargetBaseName(target.data.member_access.target);
            },
            .index => return getAstTargetBaseName(target.data.index.target),
            .slice => return getAstTargetBaseName(target.data.slice.target),
            else => return null,
        }
    }

    fn collectTargetsFromAstStatements(stmts: []const ast.Statement, out_targets: *std.StringHashMap(void)) !void {
        for (stmts) |stmt| {
            switch (stmt.tag) {
                .assign => {
                    if (getAstTargetBaseName(stmt.data.assign.target)) |name| {
                        try out_targets.put(name, {});
                    }
                },
                .var_decl => {
                    try out_targets.put(stmt.data.var_decl.name, {});
                },
                .if_stmt => {
                    try collectTargetsFromAstStatements(stmt.data.if_stmt.then_stmts, out_targets);
                    if (stmt.data.if_stmt.else_stmts) |es| {
                        try collectTargetsFromAstStatements(es, out_targets);
                    }
                },
                .switch_stmt => {
                    for (stmt.data.switch_stmt.cases) |c| {
                        try collectTargetsFromAstStatements(c.body, out_targets);
                    }
                },
                .inline_for => {
                    try collectTargetsFromAstStatements(stmt.data.inline_for.body, out_targets);
                },
                .expr_stmt => {},
            }
        }
    }

    fn checkMultiDrivers(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        mod_name: []const u8,
        items: []ast.ModuleItem,
        ports: []const hir.HirPort,
        instances: []const hir.HirSubmoduleInstance,
        reg_map: *const std.StringHashMap(hir.HirRegister),
        module_ports: *const std.StringHashMap([]hir.HirPort),
    ) !void {
        var drivers = std.StringHashMap(DriverInfo).init(alloc);
        var input_ports = std.StringHashMap(void).init(alloc);

        // 1. Register input ports
        for (ports) |p| {
            if (p.dir == .in) {
                try drivers.put(p.name, .{ .kind = .input_port, .desc = "module input port" });
                try input_ports.put(p.name, {});
            }
        }

        // 2. Register submodule instance outputs
        for (instances) |inst| {
            if (module_ports.get(inst.module_name)) |sub_ports| {
                for (inst.connections) |conn| {
                    for (sub_ports) |sp| {
                        if (std.mem.eql(u8, sp.name, conn.port_name)) {
                            if (sp.dir == .out) {
                                if (getHirTargetBaseName(conn.expr)) |target_name| {
                                    if (drivers.get(target_name)) |existing| {
                                        std.debug.print(
                                            \\
                                            \\======================================================================
                                            \\COMPILE ERROR: Multiple Drivers Detected on Signal '{s}' in module '{s}'
                                            \\======================================================================
                                            \\The signal '{s}' is driven by multiple concurrent sources:
                                            \\  1. {s}
                                            \\  2. submodule instance 'u_{s}' output port '.{s}'
                                            \\
                                            \\Reason:
                                            \\  In hardware, driving a wire or net from two concurrent drivers creates
                                            \\  electrical contention (short circuit in physical silicon, 1'bx in simulation).
                                            \\  Every wire and output port must have exactly one concurrent driver.
                                            \\======================================================================
                                            \\
                                            , .{ target_name, mod_name, target_name, existing.desc, inst.instance_name, conn.port_name });
                                        return error.MultipleDrivers;
                                    }
                                    const desc = try std.fmt.allocPrint(alloc, "submodule instance 'u_{s}' output port '.{s}'", .{ inst.instance_name, conn.port_name });
                                    try drivers.put(target_name, .{ .kind = .submodule_output, .desc = desc });
                                }
                            }
                            break;
                        }
                    }
                }
            }
        }

        // 3. Register continuous wire declarations
        for (items) |item| {
            if (item.tag == .const_decl) {
                const c = item.data.const_decl;
                if (c.val.tag != .number and c.val.tag != .type_expr and self.resolveGenericCall(c.val, items) == null) {
                    if (drivers.get(c.name)) |existing| {
                        std.debug.print(
                            \\
                            \\======================================================================
                            \\COMPILE ERROR: Multiple Drivers Detected on Signal '{s}' in module '{s}'
                            \\======================================================================
                            \\The signal '{s}' is driven by multiple concurrent sources:
                            \\  1. {s}
                            \\  2. continuous wire declaration '{s}'
                            \\
                            \\Reason:
                            \\  Every wire must have exactly one concurrent driver.
                            \\======================================================================
                            \\
                            , .{ c.name, mod_name, c.name, existing.desc, c.name });
                        return error.MultipleDrivers;
                    }
                    const desc = try std.fmt.allocPrint(alloc, "continuous wire declaration '{s}'", .{c.name});
                    try drivers.put(c.name, .{ .kind = .continuous_wire, .desc = desc });
                }
            }
        }

        // 4. Check comb blocks
        var comb_block_count: usize = 0;
        for (items) |item| {
            if (item.tag == .comb_block) {
                comb_block_count += 1;
                const current_idx = comb_block_count;

                var comb_written = std.StringHashMap(void).init(alloc);
                try collectTargetsFromAstStatements(item.data.comb_block.stmts, &comb_written);

                var it = comb_written.keyIterator();
                while (it.next()) |k| {
                    const target_name = k.*;
                    const is_reg = (reg_map.get(target_name) != null);

                    if (input_ports.contains(target_name)) {
                        std.debug.print(
                            \\
                            \\======================================================================
                            \\COMPILE ERROR: Cannot Assign to Input Port '{s}' in module '{s}'
                            \\======================================================================
                            \\The signal '{s}' is declared as an input port and cannot be driven internally.
                            \\
                            \\Reason:
                            \\  Input ports are driven externally by the parent module or testbench.
                            \\  Driving an input port from within the module causes illegal contention.
                            \\======================================================================
                            \\
                            , .{ target_name, mod_name, target_name });
                        return error.CannotAssignInputPort;
                    }

                    if (drivers.get(target_name)) |existing| {
                        if (existing.kind == .submodule_output or existing.kind == .continuous_wire or
                            (existing.kind == .comb_block and existing.comb_block_idx != null and existing.comb_block_idx.? != current_idx))
                        {
                            const target_label = if (is_reg)
                                try std.fmt.allocPrint(alloc, "{s}.next", .{target_name})
                            else
                                target_name;

                            std.debug.print(
                                \\
                                \\======================================================================
                                \\COMPILE ERROR: Multiple Drivers Detected on Signal '{s}' in module '{s}'
                                \\======================================================================
                                \\The signal '{s}' is driven by multiple concurrent sources:
                                \\  1. {s}
                                \\  2. procedural assignment in comb block #{d}
                                \\
                                \\Reason:
                                \\  In hardware, concurrent blocks cannot drive the same net without creating contention.
                                \\======================================================================
                                \\
                                , .{ target_label, mod_name, target_label, existing.desc, current_idx });
                            return error.MultipleDrivers;
                        }
                    } else {
                        const target_label = if (is_reg)
                            try std.fmt.allocPrint(alloc, "{s}.next", .{target_name})
                        else
                            target_name;
                        const desc = try std.fmt.allocPrint(alloc, "procedural assignment to '{s}' in comb block #{d}", .{ target_label, current_idx });
                        try drivers.put(target_name, .{
                            .kind = .comb_block,
                            .desc = desc,
                            .comb_block_idx = current_idx,
                        });
                    }
                }
            }
        }
    }

    fn collectExprSignals(expr: *const hir.HirExpr, out_signals: *ArrayList([]const u8)) anyerror!void {
        switch (expr.tag) {
            .lit => {},
            .signal_ref => {
                try out_signals.append(expr.data.signal_ref.name);
            },
            .member => {
                try collectExprSignals(expr.data.member.target, out_signals);
            },
            .slice => {
                try collectExprSignals(expr.data.slice.target, out_signals);
            },
            .index => {
                try collectExprSignals(expr.data.index.target, out_signals);
                try collectExprSignals(expr.data.index.index, out_signals);
            },
            .concat => {
                for (expr.data.concat.args) |a| {
                    try collectExprSignals(a, out_signals);
                }
            },
            .bit_reverse => {
                try collectExprSignals(expr.data.bit_reverse.target, out_signals);
            },
            .byte_swap => {
                try collectExprSignals(expr.data.byte_swap.target, out_signals);
            },
            .unary => {
                try collectExprSignals(expr.data.unary.operand, out_signals);
            },
            .binary => {
                try collectExprSignals(expr.data.binary.left, out_signals);
                try collectExprSignals(expr.data.binary.right, out_signals);
            },
            .mux => {
                try collectExprSignals(expr.data.mux.cond, out_signals);
                try collectExprSignals(expr.data.mux.then_expr, out_signals);
                try collectExprSignals(expr.data.mux.else_expr, out_signals);
            },
        }
    }

    fn walkStmtForDependencies(
        stmt: hir.HirStatement,
        cond_sources: *ArrayList([]const u8),
        graph: *std.StringHashMap(ArrayList([]const u8)),
        comb_signals: *const std.StringHashMap(void),
        alloc: std.mem.Allocator,
    ) anyerror!void {
        switch (stmt.tag) {
            .assign => {
                const target_name = getHirTargetBaseName(stmt.data.assign.target) orelse return;
                if (!comb_signals.contains(target_name)) return;

                var sources = ArrayList([]const u8).init(alloc);
                try collectExprSignals(stmt.data.assign.value, &sources);

                var adj = graph.getPtr(target_name) orelse return;

                for (sources.items) |s| {
                    if (comb_signals.contains(s)) {
                        var already = false;
                        for (adj.items) |existing| {
                            if (std.mem.eql(u8, existing, s)) {
                                already = true;
                                break;
                            }
                        }
                        if (!already) {
                            try adj.append(s);
                        }
                    }
                }

                for (cond_sources.items) |cs| {
                    if (comb_signals.contains(cs)) {
                        var already = false;
                        for (adj.items) |existing| {
                            if (std.mem.eql(u8, existing, cs)) {
                                already = true;
                                break;
                            }
                        }
                        if (!already) {
                            try adj.append(cs);
                        }
                    }
                }
            },
            .if_stmt => {
                const ifs = stmt.data.if_stmt;
                var cond_sigs = ArrayList([]const u8).init(alloc);
                try collectExprSignals(ifs.cond, &cond_sigs);

                const old_len = cond_sources.items.len;
                for (cond_sigs.items) |cs| {
                    if (comb_signals.contains(cs)) {
                        try cond_sources.append(cs);
                    }
                }

                for (ifs.then_body) |s| {
                    try walkStmtForDependencies(s, cond_sources, graph, comb_signals, alloc);
                }
                if (ifs.else_body) |eb| {
                    for (eb) |s| {
                        try walkStmtForDependencies(s, cond_sources, graph, comb_signals, alloc);
                    }
                }

                cond_sources.shrinkRetainingCapacity(old_len);
            },
            .case_stmt => {
                const cs = stmt.data.case_stmt;
                var expr_sigs = ArrayList([]const u8).init(alloc);
                try collectExprSignals(cs.expr, &expr_sigs);

                const old_len = cond_sources.items.len;
                for (expr_sigs.items) |es| {
                    if (comb_signals.contains(es)) {
                        try cond_sources.append(es);
                    }
                }

                for (cs.branches) |b| {
                    for (b.body) |s| {
                        try walkStmtForDependencies(s, cond_sources, graph, comb_signals, alloc);
                    }
                }

                cond_sources.shrinkRetainingCapacity(old_len);
            },
        }
    }

    fn dfsCycleCheck(
        self: *Elaborator,
        u: []const u8,
        graph: *std.StringHashMap(ArrayList([]const u8)),
        color: *std.StringHashMap(u8),
        cycle_path: *ArrayList([]const u8),
        mod_name: []const u8,
        alloc: std.mem.Allocator,
    ) anyerror!void {
        try color.put(u, 1); // Gray (visiting)
        try cycle_path.append(u);

        if (graph.get(u)) |neighbors| {
            for (neighbors.items) |v| {
                const v_color = color.get(v) orelse 0;
                if (v_color == 1) {
                    // Cycle detected!
                    var cycle_start: usize = 0;
                    for (cycle_path.items, 0..) |p, i| {
                        if (std.mem.eql(u8, p, v)) {
                            cycle_start = i;
                            break;
                        }
                    }

                    var cycle_str = ArrayList(u8).init(alloc);
                    for (cycle_path.items[cycle_start..]) |node| {
                        try cycle_str.appendSlice(node);
                        try cycle_str.appendSlice(" -> ");
                    }
                    try cycle_str.appendSlice(v);

                    std.debug.print(
                        \\
                        \\======================================================================
                        \\COMPILE ERROR: Combinational Loop Detected in module '{s}'
                        \\======================================================================
                        \\A cyclic dependency exists among purely combinational signals:
                        \\  {s}
                        \\
                        \\Reason:
                        \\  Combinational logic cannot form a closed loop without an intervening
                        \\  clocked register (D-flip-flop). This creates an unstable analog ring
                        \\  oscillator in physical silicon and hangs event-driven simulators in
                        \\  infinite zero-delay delta-cycle loops.
                        \\
                        \\Solution:
                        \\  Break the combinational cycle by declaring a clocked register:
                        \\    reg {s}: ... = 0;
                        \\    comb {{
                        \\        {s}.next = ...;
                        \\    }}
                        \\======================================================================
                        \\
                        , .{ mod_name, cycle_str.items, v, v });

                    return error.CombinationalLoop;
                } else if (v_color == 0) {
                    try self.dfsCycleCheck(v, graph, color, cycle_path, mod_name, alloc);
                }
            }
        }

        _ = cycle_path.pop();
        try color.put(u, 2); // Black (visited)
    }

    fn checkCombinationalLoops(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        mod_name: []const u8,
        ports: []const hir.HirPort,
        local_signals: []const hir.HirSignal,
        comb_stmts: []const hir.HirStatement,
        reg_map: *const std.StringHashMap(hir.HirRegister),
    ) !void {
        var comb_signals = std.StringHashMap(void).init(alloc);

        // 1. Output and inout ports are combinational signals
        for (ports) |p| {
            if (p.dir == .out or p.dir == .inout) {
                try comb_signals.put(p.name, {});
            }
        }

        var reg_state_signals = std.StringHashMap(void).init(alloc);
        defer reg_state_signals.deinit();
        var reg_it = reg_map.valueIterator();
        while (reg_it.next()) |r| {
            try reg_state_signals.put(r.q_name, {});
            try reg_state_signals.put(r.d_name, {});
        }

        // 2. Local signals that are not registers or internal register nets are combinational wires
        for (local_signals) |s| {
            if (reg_map.get(s.name) != null) continue;
            if (reg_state_signals.contains(s.name)) continue;
            try comb_signals.put(s.name, {});
        }

        // 3. Build graph
        var graph = std.StringHashMap(ArrayList([]const u8)).init(alloc);
        var it = comb_signals.keyIterator();
        while (it.next()) |k| {
            try graph.put(k.*, ArrayList([]const u8).init(alloc));
        }

        // 4. Populate edges
        var cond_sources = ArrayList([]const u8).init(alloc);
        for (comb_stmts) |stmt| {
            try walkStmtForDependencies(stmt, &cond_sources, &graph, &comb_signals, alloc);
        }

        // 5. DFS cycle detection
        var color = std.StringHashMap(u8).init(alloc);
        var cycle_path = ArrayList([]const u8).init(alloc);

        var node_it = comb_signals.keyIterator();
        while (node_it.next()) |k| {
            const u = k.*;
            const c = color.get(u) orelse 0;
            if (c == 0) {
                try self.dfsCycleCheck(u, &graph, &color, &cycle_path, mod_name, alloc);
            }
        }
    }

    fn walkStmtForCdcDependencies(
        stmt: hir.HirStatement,
        cond_sources: *ArrayList([]const u8),
        dep_graph: *std.StringHashMap(ArrayList([]const u8)),
        alloc: std.mem.Allocator,
    ) anyerror!void {
        switch (stmt.tag) {
            .assign => {
                const target_name = getHirTargetBaseName(stmt.data.assign.target) orelse return;

                var sources = ArrayList([]const u8).init(alloc);
                try collectExprSignals(stmt.data.assign.value, &sources);

                const gop = try dep_graph.getOrPut(target_name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = ArrayList([]const u8).init(alloc);
                }
                var adj = gop.value_ptr;

                for (sources.items) |s| {
                    var already = false;
                    for (adj.items) |existing| {
                        if (std.mem.eql(u8, existing, s)) {
                            already = true;
                            break;
                        }
                    }
                    if (!already) {
                        try adj.append(s);
                    }
                }

                for (cond_sources.items) |cs| {
                    var already = false;
                    for (adj.items) |existing| {
                        if (std.mem.eql(u8, existing, cs)) {
                            already = true;
                            break;
                        }
                    }
                    if (!already) {
                        try adj.append(cs);
                    }
                }
            },
            .if_stmt => {
                const ifs = stmt.data.if_stmt;
                var cond_sigs = ArrayList([]const u8).init(alloc);
                try collectExprSignals(ifs.cond, &cond_sigs);

                const old_len = cond_sources.items.len;
                for (cond_sigs.items) |cs| {
                    try cond_sources.append(cs);
                }

                for (ifs.then_body) |s| {
                    try walkStmtForCdcDependencies(s, cond_sources, dep_graph, alloc);
                }
                if (ifs.else_body) |eb| {
                    for (eb) |s| {
                        try walkStmtForCdcDependencies(s, cond_sources, dep_graph, alloc);
                    }
                }

                cond_sources.shrinkRetainingCapacity(old_len);
            },
            .case_stmt => {
                const cs = stmt.data.case_stmt;
                var expr_sigs = ArrayList([]const u8).init(alloc);
                try collectExprSignals(cs.expr, &expr_sigs);

                const old_len = cond_sources.items.len;
                for (expr_sigs.items) |es| {
                    try cond_sources.append(es);
                }

                for (cs.branches) |b| {
                    for (b.body) |s| {
                        try walkStmtForCdcDependencies(s, cond_sources, dep_graph, alloc);
                    }
                }

                cond_sources.shrinkRetainingCapacity(old_len);
            },
        }
    }

    fn checkCdcPathDfs(
        current_signal: []const u8,
        dest_reg: *const hir.HirRegister,
        reg_by_q: *const std.StringHashMap(hir.HirRegister),
        dep_graph: *const std.StringHashMap(ArrayList([]const u8)),
        visited: *std.StringHashMap(void),
        path: *ArrayList([]const u8),
        mod_name: []const u8,
        alloc: std.mem.Allocator,
    ) anyerror!void {
        if (visited.contains(current_signal)) return;
        try visited.put(current_signal, {});
        try path.append(current_signal);
        defer _ = path.pop();

        // Check if current_signal is a register output
        if (reg_by_q.get(current_signal)) |src_reg| {
            if (!std.mem.eql(u8, src_reg.clk_name, dest_reg.clk_name)) {
                // Illegal Clock Domain Crossing detected!
                var path_str = ArrayList(u8).init(alloc);
                try path_str.appendSlice(src_reg.name);

                if (path.items.len > 2) {
                    var idx = path.items.len - 2;
                    while (idx >= 1) : (idx -= 1) {
                        const node = path.items[idx];
                        if (!std.mem.eql(u8, node, src_reg.q_name) and
                            !std.mem.eql(u8, node, src_reg.name) and
                            !std.mem.eql(u8, node, dest_reg.d_name) and
                            !std.mem.eql(u8, node, dest_reg.name))
                        {
                            try path_str.appendSlice(" -> ");
                            try path_str.appendSlice(node);
                        }
                    }
                }
                try path_str.appendSlice(" -> ");
                try path_str.appendSlice(dest_reg.name);

                std.debug.print(
                    \\
                    \\======================================================================
                    \\COMPILE ERROR: Unsafe Clock Domain Crossing in module '{s}'
                    \\======================================================================
                    \\Illegal asynchronous transfer from clock domain '{s}' to '{s}':
                    \\  Source register:      '{s}' (clock: {s})
                    \\  Destination register: '{s}' (clock: {s})
                    \\  Dataflow path:        {s}
                    \\
                    \\Reason:
                    \\  Sampling registers across asynchronous clock domains without synchronization
                    \\  causes metastability and non-deterministic race conditions.
                    \\
                    \\Fix:
                    \\  Synchronize the cross-domain signal using a 2-stage flip-flop synchronizer:
                    \\    wire {s}_sync = @sync2ff({s}, {s});
                    \\======================================================================
                    \\
                    , .{
                        mod_name,
                        src_reg.clk_name,
                        dest_reg.clk_name,
                        src_reg.name,
                        src_reg.clk_name,
                        dest_reg.name,
                        dest_reg.clk_name,
                        path_str.items,
                        src_reg.name,
                        dest_reg.clk_name,
                        src_reg.name,
                    },
                );

                return error.ClockDomainCrossing;
            }
            // Same clock domain: sequential boundary reached, stop search
            return;
        }

        // Combinational wire: recurse to its sources
        if (dep_graph.get(current_signal)) |sources| {
            for (sources.items) |src| {
                try checkCdcPathDfs(
                    src,
                    dest_reg,
                    reg_by_q,
                    dep_graph,
                    visited,
                    path,
                    mod_name,
                    alloc,
                );
            }
        }
    }

    fn checkClockDomainCrossing(
        self: *Elaborator,
        alloc: std.mem.Allocator,
        mod_name: []const u8,
        registers: []const hir.HirRegister,
        comb_stmts: []const hir.HirStatement,
        reg_map: *const std.StringHashMap(hir.HirRegister),
    ) !void {
        _ = self;
        _ = reg_map;

        // 1. Collect distinct clock domains
        var clk_domains = std.StringHashMap(void).init(alloc);
        for (registers) |r| {
            try clk_domains.put(r.clk_name, {});
        }

        // Fast path: single-clock designs have 0 overhead
        if (clk_domains.count() <= 1) {
            return;
        }

        // 2. Map register Q outputs and base names to register definitions
        var reg_by_q = std.StringHashMap(hir.HirRegister).init(alloc);
        for (registers) |r| {
            try reg_by_q.put(r.q_name, r);
            try reg_by_q.put(r.name, r);
        }

        // 3. Build combinational dependency graph: target -> [sources]
        var dep_graph = std.StringHashMap(ArrayList([]const u8)).init(alloc);
        var cond_sources = ArrayList([]const u8).init(alloc);
        for (comb_stmts) |stmt| {
            try walkStmtForCdcDependencies(stmt, &cond_sources, &dep_graph, alloc);
        }

        // 4. Trace backward from each non-synchronizer destination register's D-input
        for (registers) |dest_reg| {
            if (dest_reg.is_sync_stage) continue;

            if (dep_graph.get(dest_reg.d_name)) |sources| {
                var visited = std.StringHashMap(void).init(alloc);
                var path = ArrayList([]const u8).init(alloc);
                try path.append(dest_reg.d_name);

                for (sources.items) |src| {
                    try checkCdcPathDfs(
                        src,
                        &dest_reg,
                        &reg_by_q,
                        &dep_graph,
                        &visited,
                        &path,
                        mod_name,
                        alloc,
                    );
                }
            }
        }
    }

    fn evalConstEx(self: *Elaborator, expr: *ast.Expr, local_consts: ?*const std.StringHashMap(u64)) u64 {
        switch (expr.tag) {
            .number => return expr.data.number.val,
            .time_literal => return convertToNs(expr.data.time_literal),
            .freq_literal => return convertFreqToNs(expr.data.freq_literal),
            .boolean => return if (expr.data.boolean) 1 else 0,
            .identifier => {
                if (local_consts) |lc| {
                    if (lc.get(expr.data.identifier)) |v| return v;
                }
                return self.constants.get(expr.data.identifier) orelse 1;
            },
            .binary => {
                const l = self.evalConstEx(expr.data.binary.left, local_consts);
                const r = self.evalConstEx(expr.data.binary.right, local_consts);
                return switch (expr.data.binary.op) {
                    .plus, .plus_percent => l + r,
                    .minus, .minus_percent => if (l >= r) l - r else 0,
                    .asterisk, .asterisk_percent => l * r,
                    .shl => l << @intCast(r),
                    .shr => l >> @intCast(r),
                    else => 0,
                };
            },
            .unary => {
                const u = expr.data.unary;
                const op_val = self.evalConstEx(u.operand, local_consts);
                return switch (u.op) {
                    .tilde, .bang => ~op_val,
                    .minus => (~op_val) +% 1,
                    else => op_val,
                };
            },
            .builtin_call => {
                const bc = expr.data.builtin_call;
                if (bc.tag == .builtin_clog2 and bc.args.len > 0) {
                    const arg_val = self.evalConstEx(bc.args[0], local_consts);
                    if (arg_val <= 1) return 1;
                    return 64 - @clz(arg_val - 1);
                }
                return 0;
            },
            else => return 0,
        }
    }

    fn evalConst(self: *Elaborator, expr: *ast.Expr) u64 {
        return self.evalConstEx(expr, null);
    }

    fn getEnumVal(self: *Elaborator, name: []const u8) u64 {
        if (self.enum_variants.get(name)) |v| {
            return v;
        }
        return 0;
    }
};
