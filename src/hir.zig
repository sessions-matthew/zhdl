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
    is_active_low: bool = false,
    name: []const u8 = "",
    enum_variants: []HirEnumVariant = &.{},
    struct_fields: []HirStructField = &.{},
    union_fields: []HirUnionField = &.{},
    elem_width: u32 = 0,
    tag_width: u32 = 0,
    array_len: u32 = 0,

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
    array_init,
    replicate,
    part_select,
    signed_cast,
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
        array_init: struct {
            elements: []*HirExpr,
        },
        replicate: struct {
            count: u32,
            val: *HirExpr,
        },
        part_select: struct {
            target: *HirExpr,
            base: *HirExpr,
            width: u32,
            is_up: bool,
        },
        signed_cast: struct {
            target: *HirExpr,
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

pub const HirParameterBinding = struct {
    name: []const u8,
    expr: *HirExpr,
};

pub const HirSubmoduleInstance = struct {
    instance_name: []const u8,
    module_name: []const u8,
    parameters: []HirParameterBinding = &.{},
    connections: []HirPortConnection,
};

pub const HirModule = struct {
    name: []const u8,
    is_extern: bool = false,
    foreign_name: ?[]const u8 = null,
    include_path: ?[]const u8 = null,
    parameters: []HirParameterBinding = &.{},
    ports: []HirPort,
    registers: []HirRegister,
    local_signals: []HirSignal,
    comb_stmts: []HirStatement,
    instances: []HirSubmoduleInstance,
};

pub const HirClockEdge = enum {
    posedge,
    negedge,
};

pub const HirSimStmtTag = enum {
    assign,
    step,
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
            edge: HirClockEdge = .posedge,
        },
        rst_pulse: struct {
            rst_name: []const u8,
            clk_name: ?[]const u8 = null,
            cycles: ?u64 = null,
            duration_raw: ?[]const u8 = null,
            active_low: bool,
        },
        delay: struct {
            ns: u64,
            raw: []const u8 = "",
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
            timeout_raw: ?[]const u8 = null,
            clk_name: ?[]const u8 = null,
        },
        finish: void,
    },
};

pub const HirClockGen = struct {
    clk_name: []const u8,
    period_ns: u64,
    half_period_str: []const u8 = "",
    raw: []const u8 = "",
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
    external_sources: [][]const u8 = &.{},

    pub fn deinit(self: *HirDesign) void {
        self.arena.deinit();
    }
};
