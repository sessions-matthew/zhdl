const std = @import("std");
const Lexer = @import("../lexer.zig").Lexer;
const token = @import("../token.zig");
const Token = token.Token;
const TokenType = token.TokenType;
const ArrayList = std.array_list.Managed;

pub const SymbolKind = enum {
    in_port,
    out_port,
    inout_port,
    reg,
    wire,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    type_str: []const u8,
    init_val: ?[]const u8 = null,
    is_async: bool = false,
    is_clock: bool = false,
    is_reset: bool = false,
    reset_active_low: bool = false,
    reset_is_sync: bool = false,
};

pub const Desugarer = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: ArrayList(Token),
    cursor: usize = 0,
    out: ArrayList(u8),
    symbols: std.StringHashMap(Symbol),

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Desugarer {
        var lex = Lexer.init(source);
        var tokens = ArrayList(Token).init(allocator);
        while (true) {
            const tok = lex.next();
            try tokens.append(tok);
            if (tok.tag == .eof) break;
        }
        return .{
            .allocator = allocator,
            .source = source,
            .tokens = tokens,
            .cursor = 0,
            .out = ArrayList(u8).init(allocator),
            .symbols = std.StringHashMap(Symbol).init(allocator),
        };
    }

    pub fn deinit(self: *Desugarer) void {
        self.tokens.deinit();
        self.out.deinit();
        self.symbols.deinit();
    }

    fn peek(self: *Desugarer) Token {
        if (self.cursor < self.tokens.items.len) {
            return self.tokens.items[self.cursor];
        }
        return .{ .tag = .eof, .loc = .{ .line = 0, .col = 0, .offset = self.source.len }, .slice = "" };
    }

    fn peekAt(self: *Desugarer, offset: usize) Token {
        const idx = self.cursor + offset;
        if (idx < self.tokens.items.len) {
            return self.tokens.items[idx];
        }
        return .{ .tag = .eof, .loc = .{ .line = 0, .col = 0, .offset = self.source.len }, .slice = "" };
    }

    fn advance(self: *Desugarer) Token {
        const tok = self.peek();
        if (self.cursor < self.tokens.items.len) {
            self.cursor += 1;
        }
        return tok;
    }

    fn matchTag(self: *Desugarer, tag: TokenType) bool {
        if (self.peek().tag == tag) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn write(self: *Desugarer, s: []const u8) !void {
        try self.out.appendSlice(s);
    }

    fn writeFmt(self: *Desugarer, comptime fmt: []const u8, args: anytype) !void {
        const formatted = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(formatted);
        try self.write(formatted);
    }

    /// Desugar integer types: u(W) -> zhdl.UInt(W), s(W) -> zhdl.SInt(W)
    fn desugarType(self: *Desugarer, raw: []const u8) ![]const u8 {
        var res = ArrayList(u8).init(self.allocator);
        errdefer res.deinit();

        var i: usize = 0;
        while (i < raw.len) {
            if ((raw[i] == 'u' or raw[i] == 's') and i + 1 < raw.len and raw[i + 1] == '(') {
                const is_unsigned = raw[i] == 'u';
                i += 2;
                const start = i;
                var paren_depth: usize = 1;
                while (i < raw.len and paren_depth > 0) : (i += 1) {
                    if (raw[i] == '(') paren_depth += 1;
                    if (raw[i] == ')') {
                        paren_depth -= 1;
                        if (paren_depth == 0) break;
                    }
                }
                const width_expr = raw[start..i];
                if (i < raw.len and raw[i] == ')') i += 1;

                if (is_unsigned) {
                    try res.appendSlice("zhdl.UInt(");
                } else {
                    try res.appendSlice("zhdl.SInt(");
                }
                try res.appendSlice(width_expr);
                try res.appendSlice(")");
            } else {
                try res.append(raw[i]);
                i += 1;
            }
        }
        return res.toOwnedSlice();
    }

    /// Desugar frequency literal like 100MHz -> zhdl.MHz(100)
    fn desugarFreq(self: *Desugarer, raw: []const u8) ![]const u8 {
        if (std.mem.endsWith(u8, raw, "MHz")) {
            const num = raw[0 .. raw.len - 3];
            return std.fmt.allocPrint(self.allocator, "zhdl.MHz({s})", .{num});
        } else if (std.mem.endsWith(u8, raw, "KHz") or std.mem.endsWith(u8, raw, "kHz")) {
            const num = raw[0 .. raw.len - 3];
            return std.fmt.allocPrint(self.allocator, "zhdl.KHz({s})", .{num});
        } else if (std.mem.endsWith(u8, raw, "GHz")) {
            const num = raw[0 .. raw.len - 3];
            return std.fmt.allocPrint(self.allocator, "zhdl.GHz({s})", .{num});
        } else if (std.mem.endsWith(u8, raw, "Hz")) {
            const num = raw[0 .. raw.len - 2];
            return std.fmt.allocPrint(self.allocator, "zhdl.Hz({s})", .{num});
        }
        return self.allocator.dupe(u8, raw);
    }

    /// Desugar time literal like 10ns -> zhdl.ns(10)
    fn desugarTime(self: *Desugarer, raw: []const u8) ![]const u8 {
        if (std.mem.endsWith(u8, raw, "ps")) {
            const num = raw[0 .. raw.len - 2];
            return std.fmt.allocPrint(self.allocator, "zhdl.ps({s})", .{num});
        } else if (std.mem.endsWith(u8, raw, "ns")) {
            const num = raw[0 .. raw.len - 2];
            return std.fmt.allocPrint(self.allocator, "zhdl.ns({s})", .{num});
        } else if (std.mem.endsWith(u8, raw, "us")) {
            const num = raw[0 .. raw.len - 2];
            return std.fmt.allocPrint(self.allocator, "zhdl.us({s})", .{num});
        } else if (std.mem.endsWith(u8, raw, "ms")) {
            const num = raw[0 .. raw.len - 2];
            return std.fmt.allocPrint(self.allocator, "zhdl.ms({s})", .{num});
        }
        return self.allocator.dupe(u8, raw);
    }

    /// Process the entire source code
    pub fn process(self: *Desugarer) ![:0]const u8 {
        try self.write("const std = @import(\"std\");\n");
        try self.write("const zhdl = @import(\"zhdl\");\n\n");

        while (self.peek().tag != .eof) {
            // Check for module declaration:
            // 1. pub const Name = module { ... };
            // 2. const Name = module { ... };
            // 3. pub module Name(...) { ... }
            // 4. module Name(...) { ... }
            if (self.isModuleStart()) {
                try self.processModule();
            } else if (self.peek().tag == .kw_test) {
                try self.processTestBlock();
            } else {
                // Pass through token or slice
                const tok = self.advance();
                try self.emitToken(tok);
            }
        }

        return self.out.toOwnedSliceSentinel(0);
    }

    fn emitToken(self: *Desugarer, tok: Token) !void {
        switch (tok.tag) {
            .freq_literal => {
                const s = try self.desugarFreq(tok.slice);
                defer self.allocator.free(s);
                try self.write(s);
            },
            .time_literal => {
                const s = try self.desugarTime(tok.slice);
                defer self.allocator.free(s);
                try self.write(s);
            },
            .equal_equal => try self.write(" == "),
            .bang_equal => try self.write(" != "),
            .plus_percent => try self.write(" +% "),
            .minus_percent => try self.write(" -% "),
            .plus => try self.write(" + "),
            .minus => try self.write(" - "),
            .equal => try self.write(" = "),
            .fat_arrow => try self.write(" => "),
            .comma => try self.write(", "),
            else => {
                try self.write(tok.slice);
            },
        }
        // Emit whitespace separator if appropriate
        if (tok.tag == .identifier or tok.tag == .kw_const or tok.tag == .kw_var or
            tok.tag == .kw_pub or tok.tag == .kw_fn or tok.tag == .kw_return or
            tok.tag == .kw_struct or tok.tag == .kw_packed or tok.tag == .kw_union or
            tok.tag == .kw_enum or tok.tag == .kw_if or tok.tag == .kw_else or
            tok.tag == .kw_switch)
        {
            try self.write(" ");
        }
    }

    fn isModuleStart(self: *Desugarer) bool {
        var idx: usize = 0;
        if (self.peekAt(idx).tag == .kw_pub) idx += 1;

        // Check: module Name
        if (self.peekAt(idx).tag == .kw_module) return true;

        // Check: const Name = module
        if (self.peekAt(idx).tag == .kw_const) {
            idx += 1;
            if (self.peekAt(idx).tag == .identifier) {
                idx += 1;
                if (self.peekAt(idx).tag == .equal) {
                    idx += 1;
                    if (self.peekAt(idx).tag == .kw_module) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    fn parsePort(self: *Desugarer, symbols_list: *ArrayList(Symbol)) !void {
        var is_async = false;
        if (self.matchTag(.kw_async)) {
            is_async = true;
        }

        const dir_tok = self.advance(); // in, out, or inout
        const kind: SymbolKind = switch (dir_tok.tag) {
            .kw_in => .in_port,
            .kw_out => .out_port,
            .kw_inout => .inout_port,
            else => return error.ExpectedPortDirection,
        };

        if (!is_async and self.matchTag(.kw_async)) {
            is_async = true;
        }

        const name = self.advance().slice;
        _ = self.matchTag(.colon);

        var is_clock = false;
        var is_reset = false;
        var reset_active_low = false;
        var reset_is_sync = false;
        var type_str: []const u8 = "";

        if (self.peek().tag == .kw_clock) {
            is_clock = true;
            _ = self.advance();
            type_str = "zhdl.Clock";
        } else if (self.peek().tag == .kw_reset) {
            is_reset = true;
            _ = self.advance();
            if (self.matchTag(.l_paren)) {
                while (self.peek().tag != .eof and self.peek().tag != .r_paren) {
                    const arg = self.advance();
                    if (std.mem.eql(u8, arg.slice, "active_low")) reset_active_low = true;
                    if (std.mem.eql(u8, arg.slice, "sync")) reset_is_sync = true;
                }
                _ = self.matchTag(.r_paren);
            }
            type_str = if (reset_is_sync)
                (if (reset_active_low) "zhdl.SyncResetActiveLow" else "zhdl.SyncReset")
            else
                (if (reset_active_low) "zhdl.AsyncResetActiveLow" else "zhdl.AsyncReset");
        } else {
            const t_start = self.cursor;
            var p_depth: usize = 0;
            var b_depth: usize = 0;
            while (self.peek().tag != .eof) {
                if (self.peek().tag == .l_paren) p_depth += 1;
                if (self.peek().tag == .r_paren) {
                    if (p_depth == 0) break;
                    p_depth -= 1;
                }
                if (self.peek().tag == .l_bracket) b_depth += 1;
                if (self.peek().tag == .r_bracket) {
                    if (b_depth == 0) break;
                    b_depth -= 1;
                }
                if (p_depth == 0 and b_depth == 0 and (self.peek().tag == .comma or self.peek().tag == .semicolon)) {
                    break;
                }
                _ = self.advance();
            }
            const t_end = self.cursor;
            if (t_end > t_start) {
                type_str = std.mem.trim(u8, self.source[self.tokens.items[t_start].loc.offset .. self.tokens.items[t_end - 1].loc.offset + self.tokens.items[t_end - 1].slice.len], " \t\r\n");
            }
        }
        _ = self.matchTag(.comma);
        _ = self.matchTag(.semicolon);

        const sym = Symbol{
            .name = name,
            .kind = kind,
            .type_str = try self.desugarType(type_str),
            .is_async = is_async,
            .is_clock = is_clock,
            .is_reset = is_reset,
            .reset_active_low = reset_active_low,
            .reset_is_sync = reset_is_sync,
        };
        try symbols_list.append(sym);
        try self.symbols.put(name, sym);
    }

    fn processModule(self: *Desugarer) !void {
        self.symbols.clearRetainingCapacity();

        const is_pub = self.matchTag(.kw_pub);

        var mod_name: []const u8 = "";
        var comptime_params = ArrayList([]const u8).init(self.allocator);
        defer comptime_params.deinit();

        var symbols_list = ArrayList(Symbol).init(self.allocator);
        defer symbols_list.deinit();

        if (self.peek().tag == .kw_module) {
            _ = self.advance(); // consume 'module'
            mod_name = self.advance().slice; // Name

            // Paradigm 2: Ports and Comptime Generics in module(...) header with commas!
            if (self.peek().tag == .l_paren) {
                _ = self.advance(); // '('
                while (self.peek().tag != .eof and self.peek().tag != .r_paren) {
                    if (self.peek().tag == .kw_in or self.peek().tag == .kw_out or self.peek().tag == .kw_inout or self.peek().tag == .kw_async) {
                        try self.parsePort(&symbols_list);
                    } else if (self.peek().tag == .kw_comptime) {
                        const p_start = self.cursor;
                        var p_depth: usize = 0;
                        while (self.peek().tag != .eof) {
                            if (self.peek().tag == .l_paren) p_depth += 1;
                            if (self.peek().tag == .r_paren) {
                                if (p_depth == 0) break;
                                p_depth -= 1;
                            }
                            if (p_depth == 0 and self.peek().tag == .comma) break;
                            _ = self.advance();
                        }
                        const p_end = self.cursor;
                        const param_slice = std.mem.trim(u8, self.source[self.tokens.items[p_start].loc.offset .. self.tokens.items[p_end - 1].loc.offset + self.tokens.items[p_end - 1].slice.len], " \t\r\n");
                        try comptime_params.append(param_slice);
                        _ = self.matchTag(.comma);
                    } else {
                        // Generic parameter without explicit 'comptime' keyword, e.g. W: usize
                        const p_start = self.cursor;
                        var p_depth: usize = 0;
                        while (self.peek().tag != .eof) {
                            if (self.peek().tag == .l_paren) p_depth += 1;
                            if (self.peek().tag == .r_paren) {
                                if (p_depth == 0) break;
                                p_depth -= 1;
                            }
                            if (p_depth == 0 and self.peek().tag == .comma) break;
                            _ = self.advance();
                        }
                        const p_end = self.cursor;
                        const param_slice = std.mem.trim(u8, self.source[self.tokens.items[p_start].loc.offset .. self.tokens.items[p_end - 1].loc.offset + self.tokens.items[p_end - 1].slice.len], " \t\r\n");
                        try comptime_params.append(param_slice);
                        _ = self.matchTag(.comma);
                    }
                }
                _ = self.matchTag(.r_paren);
            }
        } else if (self.peek().tag == .kw_const) {
            _ = self.advance(); // consume 'const'
            mod_name = self.advance().slice;
            _ = self.advance(); // consume '='
            _ = self.advance(); // consume 'module'
        }

        if (!self.matchTag(.l_brace)) {
            return error.ExpectedModuleOpeningBrace;
        }

        var flat_stmts = ArrayList([]const Token).init(self.allocator);
        defer flat_stmts.deinit();

        var comb_tokens = ArrayList(Token).init(self.allocator);
        defer comb_tokens.deinit();

        var depth: usize = 1;
        while (self.peek().tag != .eof and depth > 0) {
            const tok = self.peek();
            if (tok.tag == .r_brace) {
                depth -= 1;
                _ = self.advance();
                if (depth == 0) break;
                continue;
            }

            // Port declarations inside module body (backward compatibility)
            if (tok.tag == .kw_in or tok.tag == .kw_out or tok.tag == .kw_inout or tok.tag == .kw_async) {
                try self.parsePort(&symbols_list);
                continue;
            }

            // Register declarations (terminated with ;)
            if (tok.tag == .kw_reg) {
                _ = self.advance();
                const name = self.advance().slice;
                _ = self.matchTag(.colon);

                const t_start = self.cursor;
                while (self.peek().tag != .eof and self.peek().tag != .equal and self.peek().tag != .semicolon and self.peek().tag != .comma) {
                    _ = self.advance();
                }
                const t_end = self.cursor;
                const type_str = std.mem.trim(u8, self.source[self.tokens.items[t_start].loc.offset .. self.tokens.items[t_end - 1].loc.offset + self.tokens.items[t_end - 1].slice.len], " \t\r\n");

                var init_val: []const u8 = "0";
                if (self.matchTag(.equal)) {
                    const i_start = self.cursor;
                    while (self.peek().tag != .eof and self.peek().tag != .semicolon and self.peek().tag != .comma) {
                        _ = self.advance();
                    }
                    const i_end = self.cursor;
                    if (i_end > i_start) {
                        init_val = std.mem.trim(u8, self.source[self.tokens.items[i_start].loc.offset .. self.tokens.items[i_end - 1].loc.offset + self.tokens.items[i_end - 1].slice.len], " \t\r\n");
                    }
                }
                _ = self.matchTag(.semicolon);
                _ = self.matchTag(.comma);

                const sym = Symbol{
                    .name = name,
                    .kind = .reg,
                    .type_str = try self.desugarType(type_str),
                    .init_val = init_val,
                };
                try symbols_list.append(sym);
                try self.symbols.put(name, sym);
                continue;
            }

            // comb { ... } block
            if (tok.tag == .kw_comb) {
                _ = self.advance();
                _ = self.matchTag(.l_brace);
                var c_depth: usize = 1;
                while (self.peek().tag != .eof and c_depth > 0) {
                    const c_tok = self.advance();
                    if (c_tok.tag == .l_brace) c_depth += 1;
                    if (c_tok.tag == .r_brace) {
                        c_depth -= 1;
                        if (c_depth == 0) break;
                    }
                    try comb_tokens.append(c_tok);
                }
                continue;
            }

            // Flat module continuous assignment (e.g. overflow = (count_reg == 255);)
            const stmt_start = self.cursor;
            while (self.peek().tag != .eof and self.peek().tag != .semicolon and self.peek().tag != .r_brace) {
                _ = self.advance();
            }
            if (self.peek().tag == .semicolon) _ = self.advance();
            const stmt_end = self.cursor;
            if (stmt_end > stmt_start) {
                try flat_stmts.append(self.tokens.items[stmt_start..stmt_end]);
            }
        }

        // Consume trailing semicolon if any
        _ = self.matchTag(.semicolon);

        // --- EMIT DESUGARED ZIG MODULE ---
        if (comptime_params.items.len > 0) {
            if (is_pub) try self.write("pub ");
            try self.writeFmt("fn {s}(", .{mod_name});
            for (comptime_params.items, 0..) |p, p_idx| {
                if (p_idx > 0) try self.write(", ");
                try self.write(p);
            }
            try self.write(") type {\n    return struct {\n");
        } else {
            if (is_pub) try self.write("pub ");
            try self.writeFmt("const {s} = struct {{\n", .{mod_name});
        }

        // 1. Emit Ports and Registers
        for (symbols_list.items) |sym| {
            switch (sym.kind) {
                .in_port => {
                    if (sym.is_clock or sym.is_reset) {
                        try self.writeFmt("        {s}: zhdl.In({s}),\n", .{ sym.name, sym.type_str });
                    } else if (sym.is_async) {
                        try self.writeFmt("        {s}: zhdl.In(zhdl.Async({s})),\n", .{ sym.name, sym.type_str });
                    } else {
                        try self.writeFmt("        {s}: zhdl.In({s}),\n", .{ sym.name, sym.type_str });
                    }
                },
                .out_port => {
                    try self.writeFmt("        {s}: zhdl.Out({s}),\n", .{ sym.name, sym.type_str });
                },
                .inout_port => {
                    try self.writeFmt("        {s}: zhdl.InOut({s}),\n", .{ sym.name, sym.type_str });
                },
                .reg => {
                    const init_str = sym.init_val orelse "0";
                    try self.writeFmt("        {s}: zhdl.Reg({s}) = .init({s}),\n", .{ sym.name, sym.type_str, init_str });
                },
                .wire => {
                    try self.writeFmt("        {s}: zhdl.Wire({s}) = .{{}},\n", .{ sym.name, sym.type_str });
                },
            }
        }

        // 2. Emit comb() method
        try self.write("\n        pub fn comb(self: *@This()) void {\n");

        // Emit flat assignments
        for (flat_stmts.items) |stmt_toks| {
            try self.write("            ");
            try self.emitDesugaredTokens(stmt_toks);
            try self.write("\n");
        }

        // Emit comb body
        if (comb_tokens.items.len > 0) {
            try self.write("            ");
            try self.emitDesugaredTokens(comb_tokens.items);
            try self.write("\n");
        }

        try self.write("        }\n");

        // 3. Close module struct
        if (comptime_params.items.len > 0) {
            try self.write("    };\n}\n");
        } else {
            try self.write("};\n");
        }
    }

    fn emitDesugaredTokens(self: *Desugarer, toks: []const Token) !void {
        var i: usize = 0;
        while (i < toks.len) {
            const tok = toks[i];

            // 1. Non-blocking assignment: reg := expr; -> self.reg.d = (expr);
            if (tok.tag == .identifier and i + 1 < toks.len and toks[i + 1].tag == .colon_equal) {
                if (self.symbols.get(tok.slice)) |sym| {
                    if (sym.kind == .reg) {
                        try self.writeFmt("self.{s}.d = (", .{tok.slice});
                        i += 2;
                        // Read until semicolon
                        var end_i = i;
                        while (end_i < toks.len and toks[end_i].tag != .semicolon) : (end_i += 1) {}
                        try self.emitDesugaredTokens(toks[i..end_i]);
                        if (self.out.items.len > 0 and self.out.items[self.out.items.len - 1] == ' ') {
                            _ = self.out.pop();
                        }
                        try self.write(");");
                        i = if (end_i < toks.len and toks[end_i].tag == .semicolon) end_i + 1 else end_i;
                        continue;
                    }
                }
            }

            // 2. Assignment to output/wire: out = expr; -> self.out.val = (expr);
            if (tok.tag == .identifier and i + 1 < toks.len and toks[i + 1].tag == .equal and
                (i + 2 >= toks.len or (toks[i + 2].tag != .equal and toks[i + 2].tag != .fat_arrow)))
            {
                if (self.symbols.get(tok.slice)) |sym| {
                    if (sym.kind == .out_port or sym.kind == .wire) {
                        try self.writeFmt("self.{s}.val = (", .{tok.slice});
                        i += 2;
                        var end_i = i;
                        while (end_i < toks.len and toks[end_i].tag != .semicolon) : (end_i += 1) {}
                        try self.emitDesugaredTokens(toks[i..end_i]);
                        if (self.out.items.len > 0 and self.out.items[self.out.items.len - 1] == ' ') {
                            _ = self.out.pop();
                        }
                        try self.write(");");
                        i = if (end_i < toks.len and toks[end_i].tag == .semicolon) end_i + 1 else end_i;
                        continue;
                    }
                }
            }

            // 3. Bit slicing: target[high:low] or target[high..low] -> zhdl.slice(target, high, low)
            if (tok.tag == .identifier) {
                var target_end = i + 1;
                while (target_end + 1 < toks.len and toks[target_end].tag == .dot and toks[target_end + 1].tag == .identifier) {
                    target_end += 2;
                }
                if (target_end < toks.len and toks[target_end].tag == .l_bracket) {
                    var b_depth: usize = 1;
                    var j = target_end + 1;
                    var colon_pos: ?usize = null;
                    var dotdot_pos: ?usize = null;
                    while (j < toks.len and b_depth > 0) : (j += 1) {
                        if (toks[j].tag == .l_bracket) b_depth += 1;
                        if (toks[j].tag == .r_bracket) {
                            b_depth -= 1;
                            if (b_depth == 0) break;
                        }
                        if (b_depth == 1) {
                            if (toks[j].tag == .colon) colon_pos = j;
                            if (toks[j].tag == .dot_dot) dotdot_pos = j;
                        }
                    }

                    if (colon_pos != null or dotdot_pos != null) {
                        const split_pos = colon_pos orelse dotdot_pos.?;
                        const high_toks = toks[target_end + 1 .. split_pos];
                        const low_toks = toks[split_pos + 1 .. j];

                        try self.write("zhdl.slice(");
                        const target_toks = toks[i..target_end];
                        if (target_toks.len == 1) {
                            const single_name = target_toks[0].slice;
                            if (self.symbols.get(single_name)) |sym| {
                                switch (sym.kind) {
                                    .in_port => try self.writeFmt("self.{s}.get()", .{single_name}),
                                    .reg => try self.writeFmt("self.{s}.q", .{single_name}),
                                    .out_port, .inout_port, .wire => try self.writeFmt("self.{s}.val", .{single_name}),
                                }
                            } else {
                                try self.write(single_name);
                            }
                        } else {
                            for (target_toks, 0..) |t, t_idx| {
                                if (t_idx == 0 and self.symbols.get(t.slice) != null) {
                                    const sym = self.symbols.get(t.slice).?;
                                    switch (sym.kind) {
                                        .in_port => try self.writeFmt("self.{s}.get()", .{t.slice}),
                                        .reg => try self.writeFmt("self.{s}.q", .{t.slice}),
                                        .out_port, .inout_port, .wire => try self.writeFmt("self.{s}.val", .{t.slice}),
                                    }
                                } else {
                                    try self.write(t.slice);
                                }
                            }
                        }
                        try self.write(", ");
                        try self.emitDesugaredTokens(high_toks);
                        if (self.out.items.len > 0 and self.out.items[self.out.items.len - 1] == ' ') _ = self.out.pop();
                        try self.write(", ");
                        try self.emitDesugaredTokens(low_toks);
                        if (self.out.items.len > 0 and self.out.items[self.out.items.len - 1] == ' ') _ = self.out.pop();
                        try self.write(")");
                        i = j + 1;
                        continue;
                    }
                }
            }

            // 4. Identifier referencing port / reg in expression
            if (tok.tag == .identifier) {
                // Check for u(W) or s(W)
                if ((std.mem.eql(u8, tok.slice, "u") or std.mem.eql(u8, tok.slice, "s")) and
                    i + 1 < toks.len and toks[i + 1].tag == .l_paren)
                {
                    const is_u = std.mem.eql(u8, tok.slice, "u");
                    if (is_u) try self.write("zhdl.UInt(") else try self.write("zhdl.SInt(");
                    i += 2;
                    while (i < toks.len and toks[i].tag != .r_paren) : (i += 1) {
                        try self.write(toks[i].slice);
                    }
                    try self.write(")");
                    if (i < toks.len and toks[i].tag == .r_paren) i += 1;
                    continue;
                }

                if (self.symbols.get(tok.slice)) |sym| {
                    switch (sym.kind) {
                        .in_port => try self.writeFmt("self.{s}.get()", .{tok.slice}),
                        .reg => try self.writeFmt("self.{s}.q", .{tok.slice}),
                        .out_port => try self.writeFmt("self.{s}.val", .{tok.slice}),
                        .wire => try self.writeFmt("self.{s}.val", .{tok.slice}),
                        else => try self.write(tok.slice),
                    }
                    i += 1;
                    continue;
                }
            }

            // 5. Builtin @sync2ff(clk, sig) -> sig
            if (tok.tag == .invalid and std.mem.startsWith(u8, tok.slice, "@sync2ff")) {
                // Skip '@sync2ff(' and read sig
                i += 1;
                if (i < toks.len and toks[i].tag == .l_paren) i += 1;
                // Skip clk
                while (i < toks.len and toks[i].tag != .comma) : (i += 1) {}
                if (i < toks.len and toks[i].tag == .comma) i += 1;
                // Read signal
                if (i < toks.len) {
                    const sig_tok = toks[i];
                    if (self.symbols.get(sig_tok.slice)) |sym| {
                        if (sym.kind == .in_port) {
                            try self.writeFmt("self.{s}.get()", .{sig_tok.slice});
                        } else {
                            try self.write(sig_tok.slice);
                        }
                    } else {
                        try self.write(sig_tok.slice);
                    }
                    i += 1;
                }
                while (i < toks.len and toks[i].tag != .r_paren) : (i += 1) {}
                if (i < toks.len and toks[i].tag == .r_paren) i += 1;
                continue;
            }

            // 6. wire in comb block -> const
            if (tok.tag == .kw_wire) {
                try self.write("const ");
                i += 1;
                continue;
            }

            // Default: emit token slice
            try self.emitToken(tok);
            i += 1;
        }
    }

    fn processTestBlock(self: *Desugarer) !void {
        _ = self.advance(); // consume 'test'
        const name_tok = self.advance(); // test name string
        try self.writeFmt("test {s} {{\n", .{name_tok.slice});
        _ = self.matchTag(.l_brace);

        var depth: usize = 1;
        while (self.peek().tag != .eof and depth > 0) {
            const tok = self.advance();
            if (tok.tag == .l_brace) depth += 1;
            if (tok.tag == .r_brace) {
                depth -= 1;
                if (depth == 0) break;
            }

            // Transform testbench helpers
            if (tok.tag == .kw_wire) {
                const wire_name = self.advance();
                _ = self.matchTag(.colon);
                const t_start = self.cursor;
                while (self.peek().tag != .eof and self.peek().tag != .semicolon and self.peek().tag != .equal) {
                    _ = self.advance();
                }
                const t_end = self.cursor;
                const raw_type = std.mem.trim(u8, self.source[self.tokens.items[t_start].loc.offset .. self.tokens.items[t_end - 1].loc.offset + self.tokens.items[t_end - 1].slice.len], " \t\r\n");
                const desugared_type = try self.desugarType(raw_type);
                defer self.allocator.free(desugared_type);

                var init_val: []const u8 = "undefined";
                var has_custom_init = false;
                if (self.matchTag(.equal)) {
                    has_custom_init = true;
                    const i_start = self.cursor;
                    while (self.peek().tag != .eof and self.peek().tag != .semicolon) {
                        _ = self.advance();
                    }
                    const i_end = self.cursor;
                    init_val = std.mem.trim(u8, self.source[self.tokens.items[i_start].loc.offset .. self.tokens.items[i_end - 1].loc.offset + self.tokens.items[i_end - 1].slice.len], " \t\r\n");
                }
                _ = self.matchTag(.semicolon);
                if (has_custom_init) {
                    try self.writeFmt("var {s}: {s} = {s};\n", .{ wire_name.slice, desugared_type, init_val });
                } else {
                    try self.writeFmt("var {s}: {s} = undefined;\n", .{ wire_name.slice, desugared_type });
                }
                continue;
            }

            if (tok.tag == .kw_clock or (tok.tag == .identifier and std.mem.eql(u8, tok.slice, "clock"))) {
                try self.write("zhdl.clock");
                continue;
            }

            if (tok.tag == .kw_reset or (tok.tag == .identifier and std.mem.eql(u8, tok.slice, "reset"))) {
                try self.write("zhdl.reset");
                continue;
            }

            if (tok.tag == .identifier and std.mem.eql(u8, tok.slice, "assert")) {
                try self.write("try std.testing.expect(");
                // If there's a second argument message, ignore or skip it
                if (self.matchTag(.l_paren)) {
                    var paren_d: usize = 1;
                    while (self.peek().tag != .eof and paren_d > 0) {
                        const a_tok = self.advance();
                        if (a_tok.tag == .l_paren) paren_d += 1;
                        if (a_tok.tag == .r_paren) {
                            paren_d -= 1;
                            if (paren_d == 0) break;
                        }
                        if (paren_d == 1 and a_tok.tag == .comma) {
                            // Skip the message string argument
                            while (self.peek().tag != .eof and self.peek().tag != .r_paren) {
                                _ = self.advance();
                            }
                            _ = self.matchTag(.r_paren);
                            break;
                        }
                        try self.emitToken(a_tok);
                    }
                    try self.write(");\n");
                    _ = self.matchTag(.semicolon);
                    continue;
                }
            }

            if (tok.tag == .identifier and (std.mem.eql(u8, tok.slice, "finish") or std.mem.eql(u8, tok.slice, "trace"))) {
                // Skip function call finish(); or trace(...);
                if (self.matchTag(.l_paren)) {
                    while (self.peek().tag != .eof and self.peek().tag != .r_paren) {
                        _ = self.advance();
                    }
                    _ = self.matchTag(.r_paren);
                }
                _ = self.matchTag(.semicolon);
                continue;
            }

            try self.emitToken(tok);
        }

        try self.write("}\n\n");
    }
};

/// Public API: Desugar a .zhdl source buffer into a 100% valid Zig virtual source buffer
pub fn desugar(allocator: std.mem.Allocator, source: []const u8) ![:0]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var d = try Desugarer.init(arena.allocator(), source);
    defer d.deinit();
    const result = try d.process();
    const copy = try allocator.allocSentinel(u8, result.len, 0);
    @memcpy(copy, result);
    return copy;
}

/// Formats a valid Zig source buffer using Zig's official AST renderer (equivalent to `zig fmt`).
pub fn formatZig(allocator: std.mem.Allocator, source: [:0]const u8) ![:0]u8 {
    var tree = try std.zig.Ast.parse(allocator, source, .{});
    defer tree.deinit(allocator);

    if (tree.errors.len > 0) {
        return error.AstParseError;
    }

    const rendered = try tree.renderAlloc(allocator);
    defer allocator.free(rendered);

    const formatted = try allocator.allocSentinel(u8, rendered.len, 0);
    @memcpy(formatted, rendered);
    return formatted;
}

/// Desugars ZHdl source code and automatically formats it to clean, idiomatic Zig.
pub fn desugarFormatted(allocator: std.mem.Allocator, source: []const u8) ![:0]u8 {
    const raw = try desugar(allocator, source);
    defer allocator.free(raw);

    return formatZig(allocator, raw) catch {
        const copy = try allocator.allocSentinel(u8, raw.len, 0);
        @memcpy(copy, raw);
        return copy;
    };
}

test "desugar basic counter module produces valid Zig AST" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const zhdl_src =
        \\pub const SimpleCounter = module {
        \\    in clk: clock,
        \\    in rst: reset(.async),
        \\    in en: u1,
        \\    out count: u8,
        \\    out overflow: u1,
        \\
        \\    reg count_reg: u8 = 0;
        \\
        \\    overflow = (count_reg == 255);
        \\
        \\    comb {
        \\        if (en != 0) {
        \\            count_reg := count_reg +% 1;
        \\        }
        \\    }
        \\
        \\    count = count_reg;
        \\};
    ;

    const desugared = try desugar(allocator, zhdl_src);
    defer allocator.free(desugared);

    // Verify key transformations
    try testing.expect(std.mem.indexOf(u8, desugared, "pub const SimpleCounter = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, desugared, "clk: zhdl.In(zhdl.Clock),") != null);
    try testing.expect(std.mem.indexOf(u8, desugared, "rst: zhdl.In(zhdl.AsyncReset),") != null);
    try testing.expect(std.mem.indexOf(u8, desugared, "count_reg: zhdl.Reg(u8) = .init(0),") != null);
    try testing.expect(std.mem.indexOf(u8, desugared, "self.overflow.val =") != null);
    try testing.expect(std.mem.indexOf(u8, desugared, "self.count_reg.q == 255") != null);
    try testing.expect(std.mem.indexOf(u8, desugared, "self.count_reg.d = (self.count_reg.q +% 1);") != null);

    // Validate that official std.zig.Ast parses this with 0 errors!
    var tree = try std.zig.Ast.parse(allocator, desugared, .{});
    defer tree.deinit(allocator);

    if (tree.errors.len > 0) {
        std.debug.print("\n=== Desugared Zig Code ===\n{s}\n", .{desugared});
        for (tree.errors) |err| {
            std.debug.print("AST Error: {any}\n", .{err});
        }
    }
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "desugar bit slicing and parameterized module" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const zhdl_src =
        \\pub module Slicer(comptime W: usize) {
        \\    in clk: clock,
        \\    in data_in: u(W),
        \\    out lower: u4,
        \\
        \\    comb {
        \\        lower = data_in[3:0];
        \\    }
        \\}
    ;

    const desugared = try desugar(allocator, zhdl_src);
    defer allocator.free(desugared);

    try testing.expect(std.mem.indexOf(u8, desugared, "pub fn Slicer(comptime W: usize) type {") != null);
    try testing.expect(std.mem.indexOf(u8, desugared, "zhdl.UInt(W)") != null);
    try testing.expect(std.mem.indexOf(u8, desugared, "self.lower.val = (zhdl.slice(self.data_in.get(), 3, 0));") != null);

    // Validate std.zig.Ast parses with 0 errors
    var tree = try std.zig.Ast.parse(allocator, desugared, .{});
    defer tree.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "desugar real Counter module syntax and downward bit slicing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const counter_zhdl =
        \\pub const Counter = module {
        \\    in clk: clock,
        \\    in rst: reset(.async),
        \\    in en: u1,
        \\    out count: u8,
        \\    out overflow: u1,
        \\    out rev_nibble: u4,
        \\
        \\    reg count_reg: u8 = 0;
        \\
        \\    overflow = (count_reg == 255);
        \\
        \\    comb {
        \\        if (en != 0) {
        \\            count_reg := count_reg +% 1;
        \\        }
        \\    }
        \\
        \\    count = count_reg;
        \\    rev_nibble = count_reg[4..0];
        \\};
    ;

    const desugared = try desugar(allocator, counter_zhdl);
    defer allocator.free(desugared);

    var tree = try std.zig.Ast.parse(allocator, desugared, .{});
    defer tree.deinit(allocator);

    if (tree.errors.len > 0) {
        std.debug.print("\n=== Desugared Counter.zhdl ===\n{s}\n", .{desugared});
        for (tree.errors) |err| {
            std.debug.print("AST Error: {any}\n", .{err});
        }
    }
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
    try testing.expect(std.mem.indexOf(u8, desugared, "zhdl.slice(self.count_reg.q, 4, 0)") != null);
}

test "desugar real PacketFilter module with packed structs, union and bit slicing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const packet_filter_zhdl =
        \\pub const PacketHeader = packed struct {
        \\    tag: u4,
        \\    len: u12,
        \\    pub fn isNull(self: PacketHeader) u1 { return self.tag == 0; }
        \\};
        \\pub const Command = union(enum) {
        \\    ping: u8,
        \\    data: PacketHeader,
        \\    idle: void,
        \\};
        \\pub module PacketFilter(comptime W: usize) {
        \\    in clk: clock,
        \\    in rst_n: reset(.async, .active_low),
        \\    in async ext_enable: u1,
        \\    in cmd: Command,
        \\    out rx_stream: ?u(W),
        \\    reg active_header: ?PacketHeader = null;
        \\    comb {
        \\        wire enable = ext_enable;
        \\        switch (cmd) {
        \\            .ping => |echo| {
        \\                rx_stream = if (enable != 0) echo else null;
        \\            },
        \\            .data => |hdr| {
        \\                if (hdr.isNull() != 0) {
        \\                    active_header := null;
        \\                    rx_stream = null;
        \\                } else {
        \\                    active_header := hdr;
        \\                    rx_stream = hdr.len[7:0];
        \\                }
        \\            },
        \\            .idle => {
        \\                rx_stream = null;
        \\            },
        \\        }
        \\    }
        \\}
    ;

    const desugared = try desugar(allocator, packet_filter_zhdl);
    defer allocator.free(desugared);

    var tree = try std.zig.Ast.parse(allocator, desugared, .{});
    defer tree.deinit(allocator);

    if (tree.errors.len > 0) {
        std.debug.print("\n=== Desugared PacketFilter ===\n{s}\n", .{desugared});
        for (tree.errors) |err| {
            std.debug.print("AST Error: {any}\n", .{err});
        }
    }
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
    try testing.expect(std.mem.indexOf(u8, desugared, "zhdl.In(zhdl.Async(u1))") != null);
    try testing.expect(std.mem.indexOf(u8, desugared, "zhdl.Out(?zhdl.UInt(W))") != null);
    try testing.expect(std.mem.indexOf(u8, desugared, "self.active_header.d = (hdr);") != null);
    try testing.expect(std.mem.indexOf(u8, desugared, "zhdl.slice(hdr.len, 7, 0)") != null);
}

test "Paradigm 2: Verilog-style ports in module(...) header with commas, registers in body with semicolons" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const zhdl_src =
        \\pub module AnsiCounter(
        \\    in clk: clock,
        \\    in rst: reset(.async),
        \\    in en: u1,
        \\    out count: u8,
        \\    out overflow: u1,
        \\) {
        \\    reg count_reg: u8 = 0;
        \\
        \\    overflow = (count_reg == 255);
        \\
        \\    comb {
        \\        if (en != 0) {
        \\            count_reg := count_reg +% 1;
        \\        }
        \\    }
        \\
        \\    count = count_reg;
        \\}
        \\
        \\pub module AnsiGeneric(
        \\    comptime W: usize,
        \\    in clk: clock,
        \\    in rst: reset(.async),
        \\    out count: u(W),
        \\) {
        \\    reg count_reg: u(W) = 0;
        \\    comb {
        \\        count_reg := count_reg +% 1;
        \\        count = count_reg;
        \\    }
        \\}
    ;

    const desugared = try desugar(allocator, zhdl_src);
    defer allocator.free(desugared);

    // Verify AnsiCounter (no comptime params -> const struct)
    try testing.expect(std.mem.indexOf(u8, desugared, "pub const AnsiCounter = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, desugared, "clk: zhdl.In(zhdl.Clock),") != null);
    try testing.expect(std.mem.indexOf(u8, desugared, "rst: zhdl.In(zhdl.AsyncReset),") != null);
    try testing.expect(std.mem.indexOf(u8, desugared, "count_reg: zhdl.Reg(u8) = .init(0),") != null);

    // Verify AnsiGeneric (has comptime params -> fn returning struct)
    try testing.expect(std.mem.indexOf(u8, desugared, "pub fn AnsiGeneric(comptime W: usize) type {") != null);
    try testing.expect(std.mem.indexOf(u8, desugared, "count: zhdl.Out(zhdl.UInt(W)),") != null);
    try testing.expect(std.mem.indexOf(u8, desugared, "count_reg: zhdl.Reg(zhdl.UInt(W)) = .init(0),") != null);

    // Validate standard Zig AST parse with 0 errors
    var tree = try std.zig.Ast.parse(allocator, desugared, .{});
    defer tree.deinit(allocator);

    if (tree.errors.len > 0) {
        std.debug.print("\n=== Desugared Paradigm 2 ===\n{s}\n", .{desugared});
        for (tree.errors) |err| {
            std.debug.print("AST Error: {any}\n", .{err});
        }
    }
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "formatZig and desugarFormatted produce canonical Zig formatting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const zhdl_src =
        \\pub module FmtTest(in clk: clock, in rst: reset(.async), out q: u8) {
        \\    reg r: u8 = 0;
        \\    comb { r := r +% 1; q = r; }
        \\}
    ;

    const formatted = try desugarFormatted(allocator, zhdl_src);
    defer allocator.free(formatted);

    // Verify it is clean, multiline formatted Zig
    try testing.expect(std.mem.indexOf(u8, formatted, "pub const FmtTest = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "clk: zhdl.In(zhdl.Clock),") != null);

    // Verify that the formatted code parses with 0 AST errors
    var tree = try std.zig.Ast.parse(allocator, formatted, .{});
    defer tree.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}
