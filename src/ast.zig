const std = @import("std");
const token = @import("token.zig");
const TokenType = token.TokenType;
const SourceLoc = token.SourceLoc;

pub const PortDir = enum {
    in,
    out,
    inout,
};

pub const TypeTag = enum {
    named,
    int, // u8, u1, u(W), i16
    enum_type,
    packed_struct,
    array,
    optional,
    tagged_union,
    reset,
    struct_type,
};

pub const EnumField = struct {
    name: []const u8,
    value: ?*Expr,
    loc: SourceLoc,
};

pub const StructField = struct {
    name: []const u8,
    type_expr: *Type,
    loc: SourceLoc,
};

pub const UnionField = struct {
    name: []const u8,
    type_expr: ?*Type, // null if void or empty payload
    loc: SourceLoc,
};

pub const Type = struct {
    tag: TypeTag,
    loc: SourceLoc,
    data: union {
        named: []const u8,
        int: struct {
            is_signed: bool,
            width: *Expr,
        },
        enum_type: struct {
            tag_type: ?*Type,
            fields: []EnumField,
            methods: []FnDecl = &.{},
            constants: []Decl = &.{},
        },
        packed_struct: struct {
            fields: []StructField,
            methods: []FnDecl = &.{},
            constants: []Decl = &.{},
        },
        array: struct {
            len: *Expr,
            elem_type: *Type,
        },
        optional: *Type,
        tagged_union: struct {
            tag_type: ?*Type,
            fields: []UnionField,
            methods: []FnDecl = &.{},
            constants: []Decl = &.{},
        },
        reset: struct {
            is_active_low: bool,
        },
        struct_type: struct {
            decls: []Decl,
        },
    },
};

pub const NamedExpr = struct {
    name: []const u8,
    value: *Expr,
    loc: SourceLoc,
};

pub const TimeUnit = enum {
    ps,
    ns,
    us,
    ms,
    s,
};

pub const TimeLiteral = struct {
    val: u64,
    unit: TimeUnit,
    raw: []const u8,
};

pub const FreqUnit = enum {
    hz,
    khz,
    mhz,
    ghz,
};

pub const FreqLiteral = struct {
    val: u64,
    unit: FreqUnit,
    raw: []const u8,
};

pub const ExprTag = enum {
    number,
    time_literal,
    freq_literal,
    boolean,
    string,
    identifier,
    enum_literal, // e.g. .idle
    null_lit,
    unary,
    binary,
    index,
    slice,
    member_access,
    call,
    builtin_call,
    struct_init,
    array_init,
    part_select,
    if_expr,
    type_expr,
    module_literal,
};

pub const Expr = struct {
    tag: ExprTag,
    loc: SourceLoc,
    data: union {
        number: struct {
            val: u64,
            raw: []const u8,
        },
        time_literal: TimeLiteral,
        freq_literal: FreqLiteral,
        boolean: bool,
        string: []const u8,
        identifier: []const u8,
        enum_literal: []const u8,
        null_lit: void,
        unary: struct {
            op: TokenType,
            operand: *Expr,
        },
        binary: struct {
            op: TokenType,
            left: *Expr,
            right: *Expr,
        },
        index: struct {
            target: *Expr,
            index: *Expr,
        },
        slice: struct {
            target: *Expr,
            start: *Expr,
            end: *Expr,
            is_downward: bool, // true for sugar like x[4..0]
        },
        member_access: struct {
            target: *Expr,
            field: []const u8,
        },
        call: struct {
            callee: *Expr,
            args: []*Expr,
        },
        builtin_call: struct {
            tag: TokenType,
            args: []*Expr,
        },
        struct_init: struct {
            type_expr: ?*Type,
            fields: []NamedExpr,
        },
        array_init: struct {
            type_expr: ?*Type,
            elements: []*Expr,
        },
        part_select: struct {
            target: *Expr,
            base: *Expr,
            width: *Expr,
            is_up: bool,
        },
        if_expr: struct {
            cond: *Expr,
            then_branch: *Expr,
            else_branch: *Expr,
        },
        type_expr: *Type,
        module_literal: struct {
            params: []FnParam = &.{},
            items: []ModuleItem,
            is_extern: bool = false,
            foreign_name: ?[]const u8 = null,
            include_path: ?[]const u8 = null,
        },
    },
};

pub const SwitchCase = struct {
    patterns: []*Expr, // empty if is_else is true
    capture: ?[]const u8 = null,
    is_else: bool,
    body: []Statement,
    loc: SourceLoc,
};

pub const StatementTag = enum {
    assign,
    var_decl,
    if_stmt,
    switch_stmt,
    inline_for,
    expr_stmt,
};

pub const Statement = struct {
    tag: StatementTag,
    loc: SourceLoc,
    data: union {
        assign: struct {
            target: *Expr,
            value: *Expr,
            is_reg_assign: bool = false,
        },
        var_decl: struct {
            name: []const u8,
            type_annot: ?*Type,
            init_val: *Expr,
        },
        if_stmt: struct {
            cond: *Expr,
            capture: ?[]const u8 = null,
            then_stmts: []Statement,
            else_stmts: ?[]Statement,
        },
        switch_stmt: struct {
            expr: *Expr,
            cases: []SwitchCase,
        },
        inline_for: struct {
            var_name: []const u8,
            start: *Expr,
            end: *Expr,
            body: []Statement,
        },
        expr_stmt: *Expr,
    },
};

pub const PortBinding = struct {
    port_name: []const u8,
    expr: *Expr,
    loc: SourceLoc,
};

pub const ModuleItemTag = enum {
    port,
    reg_decl,
    instance,
    comb_block,
    const_decl,
    sim_block,
    stmt,
};

pub const ModuleItem = struct {
    tag: ModuleItemTag,
    loc: SourceLoc,
    data: union {
        port: struct {
            dir: PortDir,
            name: []const u8,
            type_expr: *Type,
        },
        reg_decl: struct {
            name: []const u8,
            type_expr: *Type,
            clk: ?*Expr,
            rst: ?*Expr,
            rst_polarity: ?bool = null,
            init_val: *Expr,
        },
        instance: struct {
            name: []const u8,
            module_expr: *Expr,
            parameters: []PortBinding = &.{},
            bindings: []PortBinding,
        },
        comb_block: struct {
            stmts: []Statement,
        },
        const_decl: struct {
            name: []const u8,
            type_annot: ?*Type,
            val: *Expr,
        },
        sim_block: struct {
            stmts: []Statement,
        },
        stmt: Statement,
    },
};

pub const FnParam = struct {
    name: []const u8,
    type_expr: *Type,
    is_comptime: bool,
    loc: SourceLoc,
};

pub const FnDecl = struct {
    name: []const u8,
    is_pub: bool = false,
    params: []FnParam,
    return_type: ?*Type,
    body_expr: *Expr,
    loc: SourceLoc,
};

pub const DeclTag = enum {
    const_decl,
    fn_decl,
    module_decl,
    test_decl,
};

pub const Decl = struct {
    tag: DeclTag,
    is_pub: bool,
    loc: SourceLoc,
    data: union {
        const_decl: struct {
            name: []const u8,
            type_annot: ?*Type,
            val: *Expr,
        },
        fn_decl: FnDecl,
        module_decl: struct {
            name: []const u8,
            params: []FnParam = &.{},
            items: []ModuleItem,
            is_extern: bool = false,
            foreign_name: ?[]const u8 = null,
            include_path: ?[]const u8 = null,
        },
        test_decl: struct {
            name: []const u8,
            items: []ModuleItem,
        },
    },
};

pub const AST = struct {
    arena: std.heap.ArenaAllocator,
    decls: []Decl,

    pub fn deinit(self: *AST) void {
        self.arena.deinit();
    }
};
