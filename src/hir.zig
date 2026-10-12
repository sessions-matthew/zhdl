const std = @import("std");
const ast = @import("ast.zig");
const TokenType = @import("token.zig").TokenType;

pub const HirPortDir = enum {
    in,
    out,
    inout,
};

pub const HirTypeTag = enum {
    bits,
    clock,
    reset,
    enum_type,
    packed_struct,
    array,
    optional,
    tagged_union,
};

pub const HirEnumVariant = struct {
    name: []const u8,
    value: u64,
};

pub const HirStructField = struct {
    name: []const u8,
    width: u32,
    offset: u32, // bit offset from LSB
};

pub const HirUnionField = struct {
    name: []const u8,
    tag_value: u64,
    payload_width: u32,
    payload_type_name: []const u8 = "",
};

pub const HirType = struct {
    tag: HirTypeTag,
    width: u32, // total bit width
    is_signed: bool = false,
    name: []const u8 = "",
    enum_variants: []HirEnumVariant = &.{},
    struct_fields: []HirStructField = &.{},
    union_fields: []HirUnionField = &.{},
    elem_width: u32 = 0,
    tag_width: u32 = 0,
    array_len: u32 = 0,

    pub fn isClock(self: HirType) bool {
        return self.tag == .clock;
    }

    pub fn isReset(self: HirType) bool {
        return self.tag == .reset;
    }

    pub fn getStructField(self: HirType, field_name: []const u8) ?HirStructField {
        for (self.struct_fields) |f| {
            if (std.mem.eql(u8, f.name, field_name)) return f;
        }
        return null;
    }

    pub fn getUnionField(self: HirType, field_name: []const u8) ?HirUnionField {
        for (self.union_fields) |f| {
            if (std.mem.eql(u8, f.name, field_name)) return f;
        }
        return null;
    }

    pub fn getUnionFieldByTag(self: HirType, tag_val: u64) ?HirUnionField {
        for (self.union_fields) |f| {
            if (f.tag_value == tag_val) return f;
        }
        return null;
    }
};

pub const HirExprTag = enum {
    lit,
    signal_ref,
    member,
    slice,
    index,
    concat,
    bit_reverse,
    byte_swap,
    unary,
    binary,
    mux,
};

pub const HirExpr = struct {
    tag: HirExprTag,
    hir_type: HirType,
    data: union {
        lit: struct {
            val: u64,
            raw: []const u8,
        },
        signal_ref: struct {
            name: []const u8,
        },
        member: struct {
            target: *HirExpr,
            field: []const u8,
        },
        slice: struct {
            target: *HirExpr,
            start: u32,
            end: u32,
            is_downward: bool,
        },
        index: struct {
            target: *HirExpr,
            index: *HirExpr,
        },
        concat: struct {
            args: []*HirExpr,
        },
        bit_reverse: struct {
            target: *HirExpr,
        },
        byte_swap: struct {
            target: *HirExpr,
        },
        unary: struct {
            op: TokenType,
            operand: *HirExpr,
        },
        binary: struct {
            op: TokenType,
            left: *HirExpr,
            right: *HirExpr,
        },
        mux: struct {
            cond: *HirExpr,
            then_expr: *HirExpr,
            else_expr: *HirExpr,
        },
    },
};

pub const HirCaseBranch = struct {
    pattern_values: []u64,
    is_default: bool,
    body: []HirStatement,
};

pub const HirStatementTag = enum {
    assign,
    if_stmt,
    case_stmt,
};

pub const HirStatement = struct {
    tag: HirStatementTag,
    data: union {
        assign: struct {
            target: *HirExpr,
            value: *HirExpr,
        },
        if_stmt: struct {
            cond: *HirExpr,
            then_body: []HirStatement,
            else_body: ?[]HirStatement,
        },
        case_stmt: struct {
            expr: *HirExpr,
            branches: []HirCaseBranch,
        },
    },
};

pub const HirPort = struct {
    name: []const u8,
    dir: HirPortDir,
    hir_type: HirType,
};

pub const HirRegister = struct {
    name: []const u8, // e.g. count
    q_name: []const u8, // e.g. count_q (or count)
    d_name: []const u8, // e.g. count_d
    hir_type: HirType,
    clk_name: []const u8,
    rst_name: ?[]const u8,
    rst_active_low: bool = false,
    init_val: u64,
    is_sync_stage: bool = false,
};

pub const HirSignal = struct {
    name: []const u8,
    hir_type: HirType,
};

pub const HirPortConnection = struct {
    port_name: []const u8,
    expr: *HirExpr,
};

pub const HirSubmoduleInstance = struct {
    instance_name: []const u8,
    module_name: []const u8,
    connections: []HirPortConnection,
};

pub const HirModule = struct {
    name: []const u8,
    ports: []HirPort,
    registers: []HirRegister,
    local_signals: []HirSignal,
    comb_stmts: []HirStatement,
    instances: []HirSubmoduleInstance,
};

pub const HirSimStmtTag = enum {
    assign,
    step,
    clk_generate,
    rst_pulse,
    delay,
    assert_stmt,
    trace,
    print,
    wait_for,
    finish,
};

pub const HirSimStmt = struct {
    tag: HirSimStmtTag,
    data: union {
        assign: struct {
            target: *HirExpr,
            value: *HirExpr,
        },
        step: struct {
            clk_name: ?[]const u8,
            cycles: u64,
        },
        clk_generate: struct {
            clk_name: []const u8,
            period_ns: u64,
        },
        rst_pulse: struct {
            rst_name: []const u8,
            cycles: u64,
            active_low: bool,
        },
        delay: struct {
            ns: u64,
        },
        assert_stmt: struct {
            cond: *HirExpr,
            msg: ?[]const u8,
        },
        trace: struct {
            vcd_path: []const u8,
        },
        print: struct {
            fmt: []const u8,
            args: []*HirExpr,
        },
        wait_for: struct {
            cond: *HirExpr,
            max_cycles: ?u64,
        },
        finish: void,
    },
};

pub const HirClockGen = struct {
    clk_name: []const u8,
    period_ns: u64,
};

pub const HirTestbench = struct {
    name: []const u8,
    signals: []HirSignal,
    clock_gens: []HirClockGen,
    instances: []HirSubmoduleInstance,
    sim_stmts: []HirSimStmt,
};

pub const HirDesign = struct {
    arena: std.heap.ArenaAllocator,
    modules: []HirModule,
    testbenches: []HirTestbench,
    top_module: []const u8,

    pub fn deinit(self: *HirDesign) void {
        self.arena.deinit();
    }
};
