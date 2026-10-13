const std = @import("std");

pub const SourceLoc = struct {
    line: u32,
    col: u32,
    offset: usize,
};

pub const TokenType = enum {
    // End of file / error
    eof,
    invalid,

    // Identifiers and literals
    identifier,
    number,
    string_literal,
    time_literal,
    freq_literal,

    // Hardware Keywords
    kw_module,
    kw_in,
    kw_out,
    kw_inout,
    kw_comb,
    kw_sync,
    kw_reg,
    kw_wire,
    kw_clock,
    kw_reset,
    kw_test,
    kw_sim,
    kw_async,
    kw_spawn,

    // Zig Standard Keywords
    kw_const,
    kw_var,
    kw_fn,
    kw_pub,
    kw_return,
    kw_comptime,
    kw_inline,
    kw_for,
    kw_struct,
    kw_packed,
    kw_enum,
    kw_union,
    kw_switch,
    kw_if,
    kw_else,
    kw_true,
    kw_false,
    kw_null,
    kw_and,
    kw_or,
    kw_extern,

    // Builtins (starting with '@')
    builtin_import,
    builtin_concat,
    builtin_replicate,
    builtin_reduce_or,
    builtin_reduce_and,
    builtin_reduce_xor,
    builtin_part_select,
    builtin_bit_reverse,
    builtin_byte_swap,
    builtin_truncate,
    builtin_bit_cast,
    builtin_as,
    builtin_clog2,
    builtin_sync2ff,

    // Operators
    equal, // =
    colon_equal, // := (register non-blocking assignment)
    fat_arrow, // =>
    dot, // .
    dot_dot, // ..
    question_mark, // ?
    colon, // :
    plus_colon, // +:
    minus_colon, // -:
    semicolon, // ;
    comma, // ,

    // Delimiters
    l_paren, // (
    r_paren, // )
    l_bracket, // [
    r_bracket, // ]
    l_brace, // {
    r_brace, // }

    // Arithmetic
    plus, // +
    plus_percent, // +% (wrapping add)
    minus, // -
    minus_percent, // -% (wrapping sub)
    asterisk, // *
    asterisk_percent, // *% (wrapping mul)
    slash, // /
    percent, // %

    // Bitwise
    ampersand, // &
    pipe, // |
    caret, // ^
    tilde, // ~
    shl, // <<
    shr, // >>

    // Logical & Comparison
    bang, // !
    ampersand_ampersand, // &&
    pipe_pipe, // ||
    equal_equal, // ==
    bang_equal, // !=
    less_than, // <
    less_than_equal, // <=
    greater_than, // >
    greater_than_equal, // >=
};

pub const Token = struct {
    tag: TokenType,
    loc: SourceLoc,
    slice: []const u8,
};

pub const keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "module", .kw_module },
    .{ "in", .kw_in },
    .{ "out", .kw_out },
    .{ "inout", .kw_inout },
    .{ "comb", .kw_comb },
    .{ "sync", .kw_sync },
    .{ "reg", .kw_reg },
    .{ "wire", .kw_wire },
    .{ "clock", .kw_clock },
    .{ "reset", .kw_reset },
    .{ "test", .kw_test },
    .{ "sim", .kw_sim },
    .{ "const", .kw_const },
    .{ "var", .kw_var },
    .{ "fn", .kw_fn },
    .{ "pub", .kw_pub },
    .{ "return", .kw_return },
    .{ "comptime", .kw_comptime },
    .{ "inline", .kw_inline },
    .{ "for", .kw_for },
    .{ "struct", .kw_struct },
    .{ "packed", .kw_packed },
    .{ "enum", .kw_enum },
    .{ "union", .kw_union },
    .{ "switch", .kw_switch },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "null", .kw_null },
    .{ "and", .kw_and },
    .{ "or", .kw_or },
    .{ "extern", .kw_extern },
    .{ "async", .kw_async },
    .{ "spawn", .kw_spawn },
});

pub const builtins = std.StaticStringMap(TokenType).initComptime(.{
    .{ "@import", .builtin_import },
    .{ "@concat", .builtin_concat },
    .{ "@replicate", .builtin_replicate },
    .{ "@reduceOr", .builtin_reduce_or },
    .{ "@reduceAnd", .builtin_reduce_and },
    .{ "@reduceXor", .builtin_reduce_xor },
    .{ "@partSelect", .builtin_part_select },
    .{ "@bitReverse", .builtin_bit_reverse },
    .{ "@byteSwap", .builtin_byte_swap },
    .{ "@truncate", .builtin_truncate },
    .{ "@bitCast", .builtin_bit_cast },
    .{ "@as", .builtin_as },
    .{ "@clog2", .builtin_clog2 },
    .{ "@sync2ff", .builtin_sync2ff },
});
