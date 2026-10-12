const std = @import("std");
const ArrayList = std.array_list.Managed;
const token = @import("token.zig");
const Token = token.Token;
const TokenType = token.TokenType;
const SourceLoc = token.SourceLoc;
const Lexer = @import("lexer.zig").Lexer;
const ast = @import("ast.zig");

pub const ParseError = error{
    UnexpectedToken,
    ExpectedIdentifier,
    ExpectedType,
    ExpectedExpression,
    ExpectedSemicolon,
    ExpectedBrace,
    ExpectedParen,
    ExpectedComma,
    OutOfMemory,
};

pub const Parser = struct {
    lexer: Lexer,
    current: Token,
    peek_token: Token,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        var l = Lexer.init(source);
        const cur = l.next();
        const peek = l.next();
        return .{
            .lexer = l,
            .current = cur,
            .peek_token = peek,
            .allocator = allocator,
        };
    }

    fn advance(self: *Parser) void {
        self.current = self.peek_token;
        self.peek_token = self.lexer.next();
    }

    fn check(self: *Parser, tag: TokenType) bool {
        return self.current.tag == tag;
    }

    fn match(self: *Parser, tag: TokenType) bool {
        if (self.check(tag)) {
            self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, tag: TokenType) !Token {
        if (self.check(tag)) {
            const tok = self.current;
            self.advance();
            return tok;
        }
        std.debug.print("Parse error at {d}:{d}: expected {s}, got {s} ('{s}')\n", .{
            self.current.loc.line,
            self.current.loc.col,
            @tagName(tag),
            @tagName(self.current.tag),
            self.current.slice,
        });
        return error.UnexpectedToken;
    }

    const ExternMetadata = struct {
        foreign_name: ?[]const u8 = null,
        include_path: ?[]const u8 = null,
    };

    fn parseExternMetadata(self: *Parser, alloc: std.mem.Allocator) ParseError!ExternMetadata {
        var meta = ExternMetadata{};
        if (self.match(.l_paren)) {
            if (self.check(.string_literal)) {
                const str_tok = self.expect(.string_literal) catch return error.UnexpectedToken;
                var s = str_tok.slice;
                if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
                    s = s[1 .. s.len - 1];
                }
                meta.foreign_name = s;
                if (self.match(.comma)) {
                    if (self.match(.dot)) {
                        _ = self.expect(.l_brace) catch return error.UnexpectedToken;
                        while (!self.check(.r_brace) and !self.check(.eof)) {
                            _ = self.expect(.dot) catch return error.UnexpectedToken;
                            const opt_name = self.expect(.identifier) catch return error.UnexpectedToken;
                            _ = self.expect(.equal) catch return error.UnexpectedToken;
                            if (std.mem.eql(u8, opt_name.slice, "include")) {
                                const inc_tok = self.expect(.string_literal) catch return error.UnexpectedToken;
                                var inc = inc_tok.slice;
                                if (inc.len >= 2 and inc[0] == '"' and inc[inc.len - 1] == '"') {
                                    inc = inc[1 .. inc.len - 1];
                                }
                                meta.include_path = inc;
                            } else {
                                _ = try self.parseExpr(alloc);
                            }
                            if (!self.match(.comma)) break;
                        }
                        _ = self.expect(.r_brace) catch return error.UnexpectedToken;
                    }
                }
            } else if (self.match(.dot)) {
                _ = self.expect(.l_brace) catch return error.UnexpectedToken;
                while (!self.check(.r_brace) and !self.check(.eof)) {
                    _ = self.expect(.dot) catch return error.UnexpectedToken;
                    const opt_name = self.expect(.identifier) catch return error.UnexpectedToken;
                    _ = self.expect(.equal) catch return error.UnexpectedToken;
                    if (std.mem.eql(u8, opt_name.slice, "include")) {
                        const inc_tok = self.expect(.string_literal) catch return error.UnexpectedToken;
                        var inc = inc_tok.slice;
                        if (inc.len >= 2 and inc[0] == '"' and inc[inc.len - 1] == '"') {
                            inc = inc[1 .. inc.len - 1];
                        }
                        meta.include_path = inc;
                    } else {
                        _ = try self.parseExpr(alloc);
                    }
                    if (!self.match(.comma)) break;
                }
                _ = self.expect(.r_brace) catch return error.UnexpectedToken;
            }
            _ = self.expect(.r_paren) catch return error.UnexpectedToken;
        }
        return meta;
    }

    pub fn parseConstDecl(self: *Parser, alloc: std.mem.Allocator, is_pub: bool) ParseError!ast.Decl {
        const name_tok = try self.expect(.identifier);
        var type_annot: ?*ast.Type = null;
        if (self.match(.colon)) {
            type_annot = try self.parseType(alloc);
        }
        _ = try self.expect(.equal);

        // Check if this is a module or extern module definition: pub const Name = [extern(...)] module { ... };
        var is_extern = false;
        var foreign_name: ?[]const u8 = null;
        var include_path: ?[]const u8 = null;

        if (self.match(.kw_extern)) {
            is_extern = true;
            const meta = try self.parseExternMetadata(alloc);
            foreign_name = meta.foreign_name;
            include_path = meta.include_path;
        }

        if (is_extern or self.match(.kw_module)) {
            if (is_extern) {
                _ = try self.expect(.kw_module);
            }
            var params: []ast.FnParam = &.{};
            if (self.match(.l_paren)) {
                params = try self.parseFnParams(alloc, true);
                _ = try self.expect(.r_paren);
            }
            const mod_items = try self.parseModuleBody(alloc);
            _ = self.match(.semicolon);
            if (params.len > 0) {
                const mod_expr = try alloc.create(ast.Expr);
                mod_expr.* = .{
                    .tag = .module_literal,
                    .loc = name_tok.loc,
                    .data = .{
                        .module_literal = .{
                            .params = params,
                            .items = mod_items,
                            .is_extern = is_extern,
                            .foreign_name = foreign_name,
                            .include_path = include_path,
                        },
                    },
                };
                return .{
                    .tag = .fn_decl,
                    .is_pub = is_pub,
                    .loc = name_tok.loc,
                    .data = .{
                        .fn_decl = .{
                            .name = name_tok.slice,
                            .is_pub = is_pub,
                            .params = params,
                            .return_type = null,
                            .body_expr = mod_expr,
                            .loc = name_tok.loc,
                        },
                    },
                };
            } else {
                return .{
                    .tag = .module_decl,
                    .is_pub = is_pub,
                    .loc = name_tok.loc,
                    .data = .{
                        .module_decl = .{
                            .name = name_tok.slice,
                            .params = params,
                            .items = mod_items,
                            .is_extern = is_extern,
                            .foreign_name = foreign_name,
                            .include_path = include_path,
                        },
                    },
                };
            }
        } else {
            const val_expr = try self.parseExpr(alloc);
            _ = try self.expect(.semicolon);
            return .{
                .tag = .const_decl,
                .is_pub = is_pub,
                .loc = name_tok.loc,
                .data = .{
                    .const_decl = .{
                        .name = name_tok.slice,
                        .type_annot = type_annot,
                        .val = val_expr,
                    },
                },
            };
        }
    }

    pub fn parseDecl(self: *Parser, alloc: std.mem.Allocator) ParseError!?ast.Decl {
        if (self.check(.eof)) return null;
        const is_pub = self.match(.kw_pub);

        if (self.match(.kw_const)) {
            return try self.parseConstDecl(alloc, is_pub);
        } else if (self.match(.kw_fn)) {
            return try self.parseFnDecl(alloc, is_pub);
        } else if (self.match(.kw_module)) {
            const name_tok = try self.expect(.identifier);
            var params: []ast.FnParam = &.{};
            if (self.match(.l_paren)) {
                params = try self.parseFnParams(alloc, true);
                _ = try self.expect(.r_paren);
            }
            const mod_items = try self.parseModuleBody(alloc);
            _ = self.match(.semicolon);
            if (params.len > 0) {
                const mod_expr = try alloc.create(ast.Expr);
                mod_expr.* = .{
                    .tag = .module_literal,
                    .loc = name_tok.loc,
                    .data = .{
                        .module_literal = .{
                            .params = params,
                            .items = mod_items,
                            .is_extern = false,
                            .foreign_name = null,
                            .include_path = null,
                        },
                    },
                };
                return .{
                    .tag = .fn_decl,
                    .is_pub = is_pub,
                    .loc = name_tok.loc,
                    .data = .{
                        .fn_decl = .{
                            .name = name_tok.slice,
                            .is_pub = is_pub,
                            .params = params,
                            .return_type = null,
                            .body_expr = mod_expr,
                            .loc = name_tok.loc,
                        },
                    },
                };
            } else {
                return .{
                    .tag = .module_decl,
                    .is_pub = is_pub,
                    .loc = name_tok.loc,
                    .data = .{
                        .module_decl = .{
                            .name = name_tok.slice,
                            .params = params,
                            .items = mod_items,
                            .is_extern = false,
                            .foreign_name = null,
                            .include_path = null,
                        },
                    },
                };
            }
        } else if (self.match(.kw_test)) {
            const test_name_tok = if (self.check(.string_literal))
                try self.expect(.string_literal)
            else
                try self.expect(.identifier);

            var name_str = test_name_tok.slice;
            if (test_name_tok.tag == .string_literal and name_str.len >= 2 and name_str[0] == '"' and name_str[name_str.len - 1] == '"') {
                name_str = name_str[1 .. name_str.len - 1];
            }

            const test_items = try self.parseTestBody(alloc);
            _ = self.match(.semicolon);
            return .{
                .tag = .test_decl,
                .is_pub = is_pub,
                .loc = test_name_tok.loc,
                .data = .{
                    .test_decl = .{
                        .name = name_str,
                        .items = test_items,
                    },
                },
            };
        } else {
            return null;
        }
    }

    pub fn parse(self: *Parser) !ast.AST {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        var decls = ArrayList(ast.Decl).init(alloc);

        while (!self.check(.eof)) {
            if (try self.parseDecl(alloc)) |decl| {
                try decls.append(decl);
            } else {
                std.debug.print("Unexpected top-level token: {s} ('{s}') at {d}:{d}\n", .{
                    @tagName(self.current.tag),
                    self.current.slice,
                    self.current.loc.line,
                    self.current.loc.col,
                });
                return error.UnexpectedToken;
            }
        }

        return .{
            .arena = arena,
            .decls = try decls.toOwnedSlice(),
        };
    }

    fn parseFnParams(self: *Parser, alloc: std.mem.Allocator, default_comptime: bool) ![]ast.FnParam {
        var params = ArrayList(ast.FnParam).init(alloc);
        while (!self.check(.r_paren) and !self.check(.eof)) {
            const is_comptime = self.match(.kw_comptime);
            const param_name = try self.expect(.identifier);
            _ = try self.expect(.colon);
            const param_type = try self.parseType(alloc);

            try params.append(.{
                .name = param_name.slice,
                .type_expr = param_type,
                .is_comptime = is_comptime or default_comptime,
                .loc = param_name.loc,
            });

            if (!self.match(.comma)) break;
        }
        return try params.toOwnedSlice();
    }

    fn parseFnDecl(self: *Parser, alloc: std.mem.Allocator, is_pub: bool) !ast.Decl {
        const name_tok = try self.expect(.identifier);
        _ = try self.expect(.l_paren);
        const params = try self.parseFnParams(alloc, false);
        _ = try self.expect(.r_paren);

        var ret_type: ?*ast.Type = null;
        var is_module_ret = false;
        if (self.match(.kw_module)) {
            is_module_ret = true;
        } else if (!self.check(.l_brace)) {
            ret_type = try self.parseType(alloc);
        }

        if (is_module_ret) {
            const mod_items = try self.parseModuleBody(alloc);
            const mod_expr = try alloc.create(ast.Expr);
            mod_expr.* = .{
                .tag = .module_literal,
                .loc = name_tok.loc,
                .data = .{
                    .module_literal = .{
                        .params = params,
                        .items = mod_items,
                        .is_extern = false,
                        .foreign_name = null,
                        .include_path = null,
                    },
                },
            };
            return .{
                .tag = .fn_decl,
                .is_pub = is_pub,
                .loc = name_tok.loc,
                .data = .{
                    .fn_decl = .{
                        .name = name_tok.slice,
                        .is_pub = is_pub,
                        .params = params,
                        .return_type = null,
                        .body_expr = mod_expr,
                        .loc = name_tok.loc,
                    },
                },
            };
        }

        _ = try self.expect(.l_brace);

        // Body could be: return module { ... };
        var body_expr: *ast.Expr = undefined;
        if (self.match(.kw_return)) {
            body_expr = try self.parseExpr(alloc);
            _ = try self.expect(.semicolon);
        } else {
            body_expr = try self.parseExpr(alloc);
            _ = self.match(.semicolon);
        }
        _ = try self.expect(.r_brace);

        return .{
            .tag = .fn_decl,
            .is_pub = is_pub,
            .loc = name_tok.loc,
            .data = .{
                .fn_decl = .{
                    .name = name_tok.slice,
                    .is_pub = is_pub,
                    .params = params,
                    .return_type = ret_type,
                    .body_expr = body_expr,
                    .loc = name_tok.loc,
                },
            },
        };
    }

    fn parseModuleBody(self: *Parser, alloc: std.mem.Allocator) ![]ast.ModuleItem {
        return self.parseModuleBodyInternal(alloc, false);
    }

    fn parseTestBody(self: *Parser, alloc: std.mem.Allocator) ![]ast.ModuleItem {
        return self.parseModuleBodyInternal(alloc, true);
    }

    fn parseModuleBodyInternal(self: *Parser, alloc: std.mem.Allocator, is_test: bool) ![]ast.ModuleItem {
        _ = try self.expect(.l_brace);
        var items = ArrayList(ast.ModuleItem).init(alloc);

        while (!self.check(.r_brace) and !self.check(.eof)) {
            const item_loc = self.current.loc;

            // Ports: in, out, inout
            if (self.check(.kw_in) or self.check(.kw_out) or self.check(.kw_inout)) {
                const dir: ast.PortDir = if (self.match(.kw_in)) .in else if (self.match(.kw_out)) .out else blk: {
                    _ = try self.expect(.kw_inout);
                    break :blk .inout;
                };
                const port_name = try self.expect(.identifier);
                _ = try self.expect(.colon);
                const port_type = try self.parseType(alloc);
                _ = self.match(.comma);
                _ = self.match(.semicolon);

                try items.append(.{
                    .tag = .port,
                    .loc = item_loc,
                    .data = .{
                        .port = .{
                            .dir = dir,
                            .name = port_name.slice,
                            .type_expr = port_type,
                        },
                    },
                });
            } else if (self.match(.kw_var) or self.match(.kw_wire)) {
                const var_name = try self.expect(.identifier);
                if (self.match(.colon)) {
                    // Local signal: wire wr_ptr: u4 = 0; or wire wr_ptr: u4;
                    const sig_type = try self.parseType(alloc);
                    var init_val: *ast.Expr = try self.createZeroLit(alloc, item_loc);
                    if (self.match(.equal)) {
                        init_val = try self.parseExpr(alloc);
                    }
                    _ = self.match(.semicolon);

                    try items.append(.{
                        .tag = .const_decl,
                        .loc = item_loc,
                        .data = .{
                            .const_decl = .{
                                .name = var_name.slice,
                                .type_annot = sig_type,
                                .val = init_val,
                            },
                        },
                    });
                } else if (self.match(.equal)) {
                    if (self.match(.kw_reg)) {
                        _ = try self.expect(.l_paren);
                        const reg_type = try self.parseType(alloc);
                        _ = try self.expect(.comma);

                        // Parse config struct literal: .{ .clk = clk, .rst = rst, .init = 0 }
                        _ = try self.expect(.dot);
                        _ = try self.expect(.l_brace);

                        var clk_expr: ?*ast.Expr = null;
                        var rst_expr: ?*ast.Expr = null;
                        var rst_polarity: ?bool = null;
                        var init_expr: ?*ast.Expr = null;

                        while (!self.check(.r_brace) and !self.check(.eof)) {
                            _ = try self.expect(.dot);
                            const field_name = try self.expect(.identifier);
                            _ = try self.expect(.equal);
                            const val = try self.parseExpr(alloc);

                            if (std.mem.eql(u8, field_name.slice, "clk")) {
                                clk_expr = val;
                            } else if (std.mem.eql(u8, field_name.slice, "rst")) {
                                rst_expr = val;
                            } else if (std.mem.eql(u8, field_name.slice, "init")) {
                                init_expr = val;
                            } else if (std.mem.eql(u8, field_name.slice, "active_low") or std.mem.eql(u8, field_name.slice, "is_active_low")) {
                                if (val.tag == .boolean) {
                                    rst_polarity = val.data.boolean;
                                }
                            } else if (std.mem.eql(u8, field_name.slice, "polarity")) {
                                if (val.tag == .enum_literal) {
                                    const lit = val.data.enum_literal;
                                    if (std.mem.eql(u8, lit, "low") or std.mem.eql(u8, lit, "active_low")) {
                                        rst_polarity = true;
                                    } else if (std.mem.eql(u8, lit, "high") or std.mem.eql(u8, lit, "active_high")) {
                                        rst_polarity = false;
                                    }
                                }
                            }

                            if (!self.match(.comma)) break;
                        }
                        _ = try self.expect(.r_brace);
                        _ = try self.expect(.r_paren);
                        _ = self.match(.semicolon);

                        if (clk_expr == null) return error.UnexpectedToken;
                        const rst = rst_expr orelse try self.createZeroLit(alloc, item_loc);
                        const init_val = init_expr orelse try self.createZeroLit(alloc, item_loc);

                        try items.append(.{
                            .tag = .reg_decl,
                            .loc = item_loc,
                            .data = .{
                                .reg_decl = .{
                                    .name = var_name.slice,
                                    .type_expr = reg_type,
                                    .clk = clk_expr.?,
                                    .rst = rst,
                                    .rst_polarity = rst_polarity,
                                    .init_val = init_val,
                                },
                            },
                        });
                    } else {
                        // wire wr_ptr = expr; (type inferred)
                        const init_val = try self.parseExpr(alloc);
                        _ = self.match(.semicolon);

                        try items.append(.{
                            .tag = .const_decl,
                            .loc = item_loc,
                            .data = .{
                                .const_decl = .{
                                    .name = var_name.slice,
                                    .type_annot = null,
                                    .val = init_val,
                                },
                            },
                        });
                    }
                } else {
                    return error.UnexpectedToken;
                }
            } else if (self.match(.kw_reg)) {
                // Option 1 syntax: reg count: u8 = 0; OR reg(clk, rst) count: u8 = 0; OR reg(clk, rst, .low) count: u8 = 0;
                var clk_expr: ?*ast.Expr = null;
                var rst_expr: ?*ast.Expr = null;
                var rst_polarity: ?bool = null;

                if (self.match(.l_paren)) {
                    clk_expr = try self.parseExpr(alloc);
                    if (self.match(.comma)) {
                        rst_expr = try self.parseExpr(alloc);
                        if (self.match(.comma)) {
                            const pol_expr = try self.parseExpr(alloc);
                            if (pol_expr.tag == .enum_literal) {
                                const lit = pol_expr.data.enum_literal;
                                if (std.mem.eql(u8, lit, "low") or std.mem.eql(u8, lit, "active_low")) {
                                    rst_polarity = true;
                                } else if (std.mem.eql(u8, lit, "high") or std.mem.eql(u8, lit, "active_high")) {
                                    rst_polarity = false;
                                }
                            }
                        }
                    }
                    _ = try self.expect(.r_paren);
                }

                const reg_name = try self.expect(.identifier);
                _ = try self.expect(.colon);
                const reg_type = try self.parseType(alloc);

                var init_val: *ast.Expr = try self.createZeroLit(alloc, item_loc);
                if (self.match(.equal)) {
                    init_val = try self.parseExpr(alloc);
                }
                _ = try self.expect(.semicolon);

                try items.append(.{
                    .tag = .reg_decl,
                    .loc = item_loc,
                    .data = .{
                        .reg_decl = .{
                            .name = reg_name.slice,
                            .type_expr = reg_type,
                            .clk = clk_expr,
                            .rst = rst_expr,
                            .rst_polarity = rst_polarity,
                            .init_val = init_val,
                        },
                    },
                });
        } else if (self.match(.kw_const)) {
                // const rx = uart.Rx(...).instantiate(.{ ... }); OR const W = 8;
                const const_name = try self.expect(.identifier);
                var const_type: ?*ast.Type = null;
                if (self.match(.colon)) {
                    const_type = try self.parseType(alloc);
                }
                _ = try self.expect(.equal);
                const expr = try self.parseExpr(alloc);
                _ = try self.expect(.semicolon);

                // Check if this is an instantiation call: expr.instantiate(.{ ... })
                if (expr.tag == .call and expr.data.call.callee.tag == .member_access and
                    std.mem.eql(u8, expr.data.call.callee.data.member_access.field, "instantiate"))
                {
                    const mod_expr = expr.data.call.callee.data.member_access.target;
                    var bindings = ArrayList(ast.PortBinding).init(alloc);
                    var parameters = ArrayList(ast.PortBinding).init(alloc);

                    if (expr.data.call.args.len == 1) {
                        const arg0 = expr.data.call.args[0];
                        if (arg0.tag == .struct_init) {
                            var has_ports_or_params = false;
                            for (arg0.data.struct_init.fields) |f| {
                                if (std.mem.eql(u8, f.name, "ports") and f.value.tag == .struct_init) {
                                    has_ports_or_params = true;
                                    for (f.value.data.struct_init.fields) |pf| {
                                        try bindings.append(.{
                                            .port_name = pf.name,
                                            .expr = pf.value,
                                            .loc = pf.loc,
                                        });
                                    }
                                } else if (std.mem.eql(u8, f.name, "parameters") and f.value.tag == .struct_init) {
                                    has_ports_or_params = true;
                                    for (f.value.data.struct_init.fields) |pmf| {
                                        try parameters.append(.{
                                            .port_name = pmf.name,
                                            .expr = pmf.value,
                                            .loc = pmf.loc,
                                        });
                                    }
                                }
                            }
                            if (!has_ports_or_params) {
                                for (arg0.data.struct_init.fields) |f| {
                                    try bindings.append(.{
                                        .port_name = f.name,
                                        .expr = f.value,
                                        .loc = f.loc,
                                    });
                                }
                            }
                        }
                    } else if (expr.data.call.args.len >= 2) {
                        const arg0 = expr.data.call.args[0];
                        const arg1 = expr.data.call.args[1];
                        if (arg0.tag == .struct_init) {
                            for (arg0.data.struct_init.fields) |f| {
                                try parameters.append(.{
                                    .port_name = f.name,
                                    .expr = f.value,
                                    .loc = f.loc,
                                });
                            }
                        }
                        if (arg1.tag == .struct_init) {
                            for (arg1.data.struct_init.fields) |f| {
                                try bindings.append(.{
                                    .port_name = f.name,
                                    .expr = f.value,
                                    .loc = f.loc,
                                });
                            }
                        }
                    }

                    try items.append(.{
                        .tag = .instance,
                        .loc = item_loc,
                        .data = .{
                            .instance = .{
                                .name = const_name.slice,
                                .module_expr = mod_expr,
                                .parameters = try parameters.toOwnedSlice(),
                                .bindings = try bindings.toOwnedSlice(),
                            },
                        },
                    });
                } else {
                    try items.append(.{
                        .tag = .const_decl,
                        .loc = item_loc,
                        .data = .{
                            .const_decl = .{
                                .name = const_name.slice,
                                .type_annot = const_type,
                                .val = expr,
                            },
                        },
                    });
                }
            } else if (self.match(.kw_comb)) {
                _ = try self.expect(.l_brace);
                var stmts = ArrayList(ast.Statement).init(alloc);
                while (!self.check(.r_brace) and !self.check(.eof)) {
                    try stmts.append(try self.parseStatement(alloc));
                }
                _ = try self.expect(.r_brace);
                try items.append(.{
                    .tag = .comb_block,
                    .loc = item_loc,
                    .data = .{
                        .comb_block = .{
                            .stmts = try stmts.toOwnedSlice(),
                        },
                    },
                });
            } else if (self.match(.kw_sync)) {
                std.debug.print(
                    \\
                    \\======================================================================
                    \\COMPILE ERROR: Deprecated 'sync' Block
                    \\======================================================================
                    \\'sync' blocks are deprecated.
                    \\In ZHdl, clocks and resets are bound exclusively at the register declaration:
                    \\    reg(clk, rst) count: u8 = 0;
                    \\
                    \\All next-state logic is computed inside 'comb' using ':=':
                    \\    comb {{
                    \\        count := count +% 1;
                    \\    }}
                    \\======================================================================
                    \\
                    , .{});
                return error.UnexpectedToken;
            } else if (self.match(.kw_sim)) {
                _ = try self.expect(.l_brace);
                var stmts = ArrayList(ast.Statement).init(alloc);
                while (!self.check(.r_brace) and !self.check(.eof)) {
                    try stmts.append(try self.parseStatement(alloc));
                }
                _ = try self.expect(.r_brace);
                _ = self.match(.semicolon);

                try items.append(.{
                    .tag = .sim_block,
                    .loc = item_loc,
                    .data = .{
                        .sim_block = .{
                            .stmts = try stmts.toOwnedSlice(),
                        },
                    },
                });
            } else if (!is_test and self.check(.l_brace)) {
                std.debug.print(
                    \\
                    \\======================================================================
                    \\COMPILE ERROR: Anonymous Block at Module Scope
                    \\======================================================================
                    \\Bare anonymous '{{ ... }}' blocks are not permitted at module scope.
                    \\All procedural combinational logic must be enclosed in an explicit 'comb' block:
                    \\
                    \\Fix:
                    \\  comb {{
                    \\      ...
                    \\  }}
                    \\======================================================================
                    \\
                    , .{});
                return error.UnexpectedToken;
            } else if (!is_test and (self.check(.kw_if) or self.check(.kw_switch) or self.check(.kw_for) or self.check(.kw_inline))) {
                std.debug.print(
                    \\
                    \\======================================================================
                    \\COMPILE ERROR: Procedural Statement at Module Scope
                    \\======================================================================
                    \\Control-flow statements ('{s}') are not permitted at module scope.
                    \\Module root is strictly declarative.
                    \\
                    \\Fix:
                    \\  Enclose procedural combinational logic in an explicit 'comb' block:
                    \\    comb {{
                    \\        {s} ...
                    \\    }}
                    \\======================================================================
                    \\
                    , .{ self.current.slice, self.current.slice });
                return error.UnexpectedToken;
            } else {
                const stmt = try self.parseStatement(alloc);
                if (!is_test and stmt.tag == .assign and stmt.data.assign.is_reg_assign) {
                    std.debug.print(
                        \\
                        \\======================================================================
                        \\COMPILE ERROR: Procedural Register Assignment at Module Scope
                        \\======================================================================
                        \\Register assignment (':=') is not permitted at module scope.
                        \\Module root is strictly declarative.
                        \\
                        \\Fix:
                        \\  Enclose register updates in an explicit 'comb' block:
                        \\    comb {{
                        \\        ... := ...;
                        \\    }}
                        \\======================================================================
                        \\
                        , .{});
                    return error.UnexpectedToken;
                }
                try items.append(.{
                    .tag = .stmt,
                    .loc = item_loc,
                    .data = .{
                        .stmt = stmt,
                    },
                });
            }
        }
        _ = try self.expect(.r_brace);
        return try items.toOwnedSlice();
    }

    fn createZeroLit(self: *Parser, alloc: std.mem.Allocator, loc: SourceLoc) !*ast.Expr {
        _ = self;
        const e = try alloc.create(ast.Expr);
        e.* = .{
            .tag = .number,
            .loc = loc,
            .data = .{
                .number = .{
                    .val = 0,
                    .raw = "0",
                },
            },
        };
        return e;
    }

    fn parseStatement(self: *Parser, alloc: std.mem.Allocator) ParseError!ast.Statement {
        const stmt_loc = self.current.loc;

        if (self.match(.kw_var) or self.match(.kw_wire) or self.match(.kw_const)) {
            const name_tok = try self.expect(.identifier);
            var type_annot: ?*ast.Type = null;
            if (self.match(.colon)) {
                type_annot = try self.parseType(alloc);
            }
            var init_val: ?*ast.Expr = null;
            if (self.match(.equal)) {
                init_val = try self.parseExpr(alloc);
            } else if (type_annot != null) {
                init_val = try self.createZeroLit(alloc, stmt_loc);
            } else {
                return error.UnexpectedToken;
            }
            _ = try self.expect(.semicolon);

            return .{
                .tag = .var_decl,
                .loc = stmt_loc,
                .data = .{
                    .var_decl = .{
                        .name = name_tok.slice,
                        .type_annot = type_annot,
                        .init_val = init_val.?,
                    },
                },
            };
        }

        if (self.match(.kw_if)) {
            _ = try self.expect(.l_paren);
            const cond = try self.parseExpr(alloc);
            _ = try self.expect(.r_paren);

            var capture: ?[]const u8 = null;
            if (self.match(.pipe)) {
                const cap = try self.expect(.identifier);
                _ = try self.expect(.pipe);
                capture = cap.slice;
            }

            _ = try self.expect(.l_brace);
            var then_stmts = ArrayList(ast.Statement).init(alloc);
            while (!self.check(.r_brace) and !self.check(.eof)) {
                try then_stmts.append(try self.parseStatement(alloc));
            }
            _ = try self.expect(.r_brace);

            var else_stmts: ?[]ast.Statement = null;
            if (self.match(.kw_else)) {
                if (self.check(.kw_if)) {
                    const nested_if = try self.parseStatement(alloc);
                    var s = try alloc.alloc(ast.Statement, 1);
                    s[0] = nested_if;
                    else_stmts = s;
                } else {
                    _ = try self.expect(.l_brace);
                    var else_list = ArrayList(ast.Statement).init(alloc);
                    while (!self.check(.r_brace) and !self.check(.eof)) {
                        try else_list.append(try self.parseStatement(alloc));
                    }
                    _ = try self.expect(.r_brace);
                    else_stmts = try else_list.toOwnedSlice();
                }
            }

            return .{
                .tag = .if_stmt,
                .loc = stmt_loc,
                .data = .{
                    .if_stmt = .{
                        .cond = cond,
                        .capture = capture,
                        .then_stmts = try then_stmts.toOwnedSlice(),
                        .else_stmts = else_stmts,
                    },
                },
            };
        }

        if (self.match(.kw_switch)) {
            _ = try self.expect(.l_paren);
            const target_expr = try self.parseExpr(alloc);
            _ = try self.expect(.r_paren);

            _ = try self.expect(.l_brace);
            var cases = ArrayList(ast.SwitchCase).init(alloc);

            while (!self.check(.r_brace) and !self.check(.eof)) {
                const case_loc = self.current.loc;
                var patterns = ArrayList(*ast.Expr).init(alloc);
                var is_else = false;

                if (self.match(.kw_else)) {
                    is_else = true;
                } else {
                    while (true) {
                        try patterns.append(try self.parseExpr(alloc));
                        if (!self.match(.comma)) break;
                    }
                }

                _ = try self.expect(.fat_arrow);

                var capture: ?[]const u8 = null;
                if (self.match(.pipe)) {
                    const cap = try self.expect(.identifier);
                    _ = try self.expect(.pipe);
                    capture = cap.slice;
                }

                // Case body: either single statement or { statements }
                var body_stmts = ArrayList(ast.Statement).init(alloc);
                if (self.match(.l_brace)) {
                    while (!self.check(.r_brace) and !self.check(.eof)) {
                        try body_stmts.append(try self.parseStatement(alloc));
                    }
                    _ = try self.expect(.r_brace);
                    _ = self.match(.comma);
                } else {
                    try body_stmts.append(try self.parseStatement(alloc));
                    _ = self.match(.comma);
                }

                try cases.append(.{
                    .patterns = try patterns.toOwnedSlice(),
                    .capture = capture,
                    .is_else = is_else,
                    .body = try body_stmts.toOwnedSlice(),
                    .loc = case_loc,
                });
            }
            _ = try self.expect(.r_brace);

            return .{
                .tag = .switch_stmt,
                .loc = stmt_loc,
                .data = .{
                    .switch_stmt = .{
                        .expr = target_expr,
                        .cases = try cases.toOwnedSlice(),
                    },
                },
            };
        }

        if (self.match(.kw_inline)) {
            _ = try self.expect(.kw_for);
            _ = try self.expect(.l_paren);
            const start_expr = try self.parseExpr(alloc);
            _ = try self.expect(.dot_dot);
            const end_expr = try self.parseExpr(alloc);
            _ = try self.expect(.r_paren);

            _ = try self.expect(.pipe);
            const var_name = try self.expect(.identifier);
            _ = try self.expect(.pipe);

            _ = try self.expect(.l_brace);
            var body_stmts = ArrayList(ast.Statement).init(alloc);
            while (!self.check(.r_brace) and !self.check(.eof)) {
                try body_stmts.append(try self.parseStatement(alloc));
            }
            _ = try self.expect(.r_brace);

            return .{
                .tag = .inline_for,
                .loc = stmt_loc,
                .data = .{
                    .inline_for = .{
                        .var_name = var_name.slice,
                        .start = start_expr,
                        .end = end_expr,
                        .body = try body_stmts.toOwnedSlice(),
                    },
                },
            };
        }

        // Assignment: target = value; OR target := value; OR Expr statement: call(...);
        const target = try self.parseExpr(alloc);
        const is_equal = self.match(.equal);
        const is_colon_equal = if (!is_equal) self.match(.colon_equal) else false;

        if (is_equal or is_colon_equal) {
            const value = try self.parseExpr(alloc);
            _ = self.match(.semicolon);

            return .{
                .tag = .assign,
                .loc = stmt_loc,
                .data = .{
                    .assign = .{
                        .target = target,
                        .value = value,
                        .is_reg_assign = is_colon_equal,
                    },
                },
            };
        } else {
            _ = self.match(.semicolon);
            return .{
                .tag = .expr_stmt,
                .loc = stmt_loc,
                .data = .{
                    .expr_stmt = target,
                },
            };
        }
    }

    pub fn parseType(self: *Parser, alloc: std.mem.Allocator) ParseError!*ast.Type {
        const type_loc = self.current.loc;

        if (self.match(.question_mark)) {
            const child_type = try self.parseType(alloc);
            const t = try alloc.create(ast.Type);
            t.* = .{
                .tag = .optional,
                .loc = type_loc,
                .data = .{
                    .optional = child_type,
                },
            };
            return t;
        }

        if (self.match(.l_bracket)) {
            const len_expr = try self.parseExpr(alloc);
            _ = try self.expect(.r_bracket);
            const elem_type = try self.parseType(alloc);

            const t = try alloc.create(ast.Type);
            t.* = .{
                .tag = .array,
                .loc = type_loc,
                .data = .{
                    .array = .{
                        .len = len_expr,
                        .elem_type = elem_type,
                    },
                },
            };
            return t;
        }

        if (self.match(.kw_struct)) {
            _ = try self.expect(.l_brace);
            var struct_decls = ArrayList(ast.Decl).init(alloc);
            while (!self.check(.r_brace) and !self.check(.eof)) {
                if (try self.parseDecl(alloc)) |decl| {
                    try struct_decls.append(decl);
                } else {
                    return error.UnexpectedToken;
                }
            }
            _ = try self.expect(.r_brace);

            const t = try alloc.create(ast.Type);
            t.* = .{
                .tag = .struct_type,
                .loc = type_loc,
                .data = .{
                    .struct_type = .{
                        .decls = try struct_decls.toOwnedSlice(),
                    },
                },
            };
            return t;
        }

        if (self.match(.kw_packed)) {
            _ = try self.expect(.kw_struct);
            _ = try self.expect(.l_brace);
            var fields = ArrayList(ast.StructField).init(alloc);
            var methods = ArrayList(ast.FnDecl).init(alloc);
            var constants = ArrayList(ast.Decl).init(alloc);
            while (!self.check(.r_brace) and !self.check(.eof)) {
                if (self.check(.kw_pub) or self.check(.kw_fn) or self.check(.kw_const)) {
                    const is_pub = self.match(.kw_pub);
                    if (self.match(.kw_fn)) {
                        const m = try self.parseFnDecl(alloc, is_pub);
                        try methods.append(m.data.fn_decl);
                        _ = self.match(.semicolon);
                        _ = self.match(.comma);
                    } else if (self.match(.kw_const)) {
                        const c = try self.parseConstDecl(alloc, is_pub);
                        try constants.append(c);
                        _ = self.match(.semicolon);
                        _ = self.match(.comma);
                    } else {
                        return error.UnexpectedToken;
                    }
                } else {
                    const f_loc = self.current.loc;
                    const f_name = try self.expect(.identifier);
                    _ = try self.expect(.colon);
                    const f_type = try self.parseType(alloc);
                    _ = self.match(.comma);
                    _ = self.match(.semicolon);
                    try fields.append(.{
                        .name = f_name.slice,
                        .type_expr = f_type,
                        .loc = f_loc,
                    });
                }
            }
            _ = try self.expect(.r_brace);

            const t = try alloc.create(ast.Type);
            t.* = .{
                .tag = .packed_struct,
                .loc = type_loc,
                .data = .{
                    .packed_struct = .{
                        .fields = try fields.toOwnedSlice(),
                        .methods = try methods.toOwnedSlice(),
                        .constants = try constants.toOwnedSlice(),
                    },
                },
            };
            return t;
        }

        if (self.match(.kw_enum)) {
            var tag_type: ?*ast.Type = null;
            if (self.match(.l_paren)) {
                tag_type = try self.parseType(alloc);
                _ = try self.expect(.r_paren);
            }
            _ = try self.expect(.l_brace);
            var fields = ArrayList(ast.EnumField).init(alloc);
            var methods = ArrayList(ast.FnDecl).init(alloc);
            var constants = ArrayList(ast.Decl).init(alloc);
            while (!self.check(.r_brace) and !self.check(.eof)) {
                if (self.check(.kw_pub) or self.check(.kw_fn) or self.check(.kw_const)) {
                    const is_pub = self.match(.kw_pub);
                    if (self.match(.kw_fn)) {
                        const m = try self.parseFnDecl(alloc, is_pub);
                        try methods.append(m.data.fn_decl);
                        _ = self.match(.semicolon);
                        _ = self.match(.comma);
                    } else if (self.match(.kw_const)) {
                        const c = try self.parseConstDecl(alloc, is_pub);
                        try constants.append(c);
                        _ = self.match(.semicolon);
                        _ = self.match(.comma);
                    } else {
                        return error.UnexpectedToken;
                    }
                } else {
                    const f_loc = self.current.loc;
                    const f_name = try self.expect(.identifier);
                    var f_val: ?*ast.Expr = null;
                    if (self.match(.equal)) {
                        f_val = try self.parseExpr(alloc);
                    }
                    _ = self.match(.comma);
                    _ = self.match(.semicolon);
                    try fields.append(.{
                        .name = f_name.slice,
                        .value = f_val,
                        .loc = f_loc,
                    });
                }
            }
            _ = try self.expect(.r_brace);

            const t = try alloc.create(ast.Type);
            t.* = .{
                .tag = .enum_type,
                .loc = type_loc,
                .data = .{
                    .enum_type = .{
                        .tag_type = tag_type,
                        .fields = try fields.toOwnedSlice(),
                        .methods = try methods.toOwnedSlice(),
                        .constants = try constants.toOwnedSlice(),
                    },
                },
            };
            return t;
        }

        if (self.match(.kw_union)) {
            _ = try self.expect(.l_paren);
            var tag_type: ?*ast.Type = null;
            if (self.match(.kw_enum)) {
                if (self.match(.l_paren)) {
                    tag_type = try self.parseType(alloc);
                    _ = try self.expect(.r_paren);
                }
            } else {
                tag_type = try self.parseType(alloc);
            }
            _ = try self.expect(.r_paren);
            _ = try self.expect(.l_brace);

            var fields = ArrayList(ast.UnionField).init(alloc);
            var methods = ArrayList(ast.FnDecl).init(alloc);
            var constants = ArrayList(ast.Decl).init(alloc);
            while (!self.check(.r_brace) and !self.check(.eof)) {
                if (self.check(.kw_pub) or self.check(.kw_fn) or self.check(.kw_const)) {
                    const is_pub = self.match(.kw_pub);
                    if (self.match(.kw_fn)) {
                        const m = try self.parseFnDecl(alloc, is_pub);
                        try methods.append(m.data.fn_decl);
                        _ = self.match(.semicolon);
                        _ = self.match(.comma);
                    } else if (self.match(.kw_const)) {
                        const c = try self.parseConstDecl(alloc, is_pub);
                        try constants.append(c);
                        _ = self.match(.semicolon);
                        _ = self.match(.comma);
                    } else {
                        return error.UnexpectedToken;
                    }
                } else {
                    const f_loc = self.current.loc;
                    const f_name = try self.expect(.identifier);
                    var f_type: ?*ast.Type = null;
                    if (self.match(.colon)) {
                        if (self.check(.identifier) and std.mem.eql(u8, self.current.slice, "void")) {
                            self.advance();
                            f_type = null;
                        } else {
                            f_type = try self.parseType(alloc);
                        }
                    }
                    _ = self.match(.comma);
                    _ = self.match(.semicolon);
                    try fields.append(.{
                        .name = f_name.slice,
                        .type_expr = f_type,
                        .loc = f_loc,
                    });
                }
            }
            _ = try self.expect(.r_brace);

            const t = try alloc.create(ast.Type);
            t.* = .{
                .tag = .tagged_union,
                .loc = type_loc,
                .data = .{
                    .tagged_union = .{
                        .tag_type = tag_type,
                        .fields = try fields.toOwnedSlice(),
                        .methods = try methods.toOwnedSlice(),
                        .constants = try constants.toOwnedSlice(),
                    },
                },
            };
            return t;
        }

        if (self.check(.identifier) or self.check(.kw_clock) or self.check(.kw_reset)) {
            const name = self.current.slice;
            self.advance();

            // Check if it's an integer type like u8, u1, u32, i16
            if ((name[0] == 'u' or name[0] == 'i') and name.len > 1) {
                var all_digits = true;
                for (name[1..]) |ch| {
                    if (!std.ascii.isDigit(ch)) {
                        all_digits = false;
                        break;
                    }
                }
                if (all_digits) {
                    const width_val = std.fmt.parseInt(u64, name[1..], 10) catch return error.UnexpectedToken;
                    const w_expr = try alloc.create(ast.Expr);
                    w_expr.* = .{
                        .tag = .number,
                        .loc = type_loc,
                        .data = .{
                            .number = .{
                                .val = width_val,
                                .raw = name[1..],
                            },
                        },
                    };
                    const t = try alloc.create(ast.Type);
                    t.* = .{
                        .tag = .int,
                        .loc = type_loc,
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

            // Check if it's parametric u(W)
            if ((std.mem.eql(u8, name, "u") or std.mem.eql(u8, name, "i")) and self.match(.l_paren)) {
                const width_expr = try self.parseExpr(alloc);
                _ = try self.expect(.r_paren);

                const t = try alloc.create(ast.Type);
                t.* = .{
                    .tag = .int,
                    .loc = type_loc,
                    .data = .{
                        .int = .{
                            .is_signed = (name[0] == 'i'),
                            .width = width_expr,
                        },
                    },
                };
                return t;
            }

            // Check for reset or reset(...)
            if (std.mem.eql(u8, name, "reset")) {
                var is_active_low = false;
                if (self.match(.l_paren)) {
                    if (self.match(.dot)) {
                        const pol_tok = try self.expect(.identifier);
                        if (std.mem.eql(u8, pol_tok.slice, "low") or std.mem.eql(u8, pol_tok.slice, "active_low")) {
                            is_active_low = true;
                        } else if (std.mem.eql(u8, pol_tok.slice, "high") or std.mem.eql(u8, pol_tok.slice, "active_high")) {
                            is_active_low = false;
                        } else {
                            return error.UnexpectedToken;
                        }
                    } else if (self.check(.identifier)) {
                        const pol_tok = self.current;
                        self.advance();
                        if (std.mem.eql(u8, pol_tok.slice, "low") or std.mem.eql(u8, pol_tok.slice, "active_low")) {
                            is_active_low = true;
                        } else if (std.mem.eql(u8, pol_tok.slice, "high") or std.mem.eql(u8, pol_tok.slice, "active_high")) {
                            is_active_low = false;
                        } else {
                            return error.UnexpectedToken;
                        }
                    } else {
                        return error.UnexpectedToken;
                    }
                    _ = try self.expect(.r_paren);
                }
                const t = try alloc.create(ast.Type);
                t.* = .{
                    .tag = .reset,
                    .loc = type_loc,
                    .data = .{
                        .reset = .{
                            .is_active_low = is_active_low,
                        },
                    },
                };
                return t;
            }

            if (std.mem.eql(u8, name, "reset_n") or std.mem.eql(u8, name, "reset_low")) {
                const t = try alloc.create(ast.Type);
                t.* = .{
                    .tag = .reset,
                    .loc = type_loc,
                    .data = .{
                        .reset = .{
                            .is_active_low = true,
                        },
                    },
                };
                return t;
            }

            // Named type like clock, or custom type (including dotted pkg.Type)
            var final_name = name;
            if (self.check(.dot) and self.peek_token.tag == .identifier) {
                var name_buf = ArrayList(u8).init(alloc);
                try name_buf.appendSlice(name);
                while (self.check(.dot) and self.peek_token.tag == .identifier) {
                    _ = self.match(.dot);
                    const sub_tok = try self.expect(.identifier);
                    try name_buf.append('.');
                    try name_buf.appendSlice(sub_tok.slice);
                }
                final_name = try name_buf.toOwnedSlice();
            }

            const t = try alloc.create(ast.Type);
            t.* = .{
                .tag = .named,
                .loc = type_loc,
                .data = .{
                    .named = final_name,
                },
            };
            return t;
        }

        return error.ExpectedType;
    }

    pub fn parseExpr(self: *Parser, alloc: std.mem.Allocator) ParseError!*ast.Expr {
        return self.parseLogicalOr(alloc);
    }

    fn parseLogicalOr(self: *Parser, alloc: std.mem.Allocator) ParseError!*ast.Expr {
        var left = try self.parseLogicalAnd(alloc);
        while (self.match(.pipe_pipe) or self.match(.kw_or)) {
            const right = try self.parseLogicalAnd(alloc);
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .binary,
                .loc = left.loc,
                .data = .{
                    .binary = .{
                        .op = .pipe_pipe,
                        .left = left,
                        .right = right,
                    },
                },
            };
            left = e;
        }
        return left;
    }

    fn parseLogicalAnd(self: *Parser, alloc: std.mem.Allocator) ParseError!*ast.Expr {
        var left = try self.parseBitwiseOr(alloc);
        while (self.match(.ampersand_ampersand) or self.match(.kw_and)) {
            const right = try self.parseBitwiseOr(alloc);
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .binary,
                .loc = left.loc,
                .data = .{
                    .binary = .{
                        .op = .ampersand_ampersand,
                        .left = left,
                        .right = right,
                    },
                },
            };
            left = e;
        }
        return left;
    }

    fn parseBitwiseOr(self: *Parser, alloc: std.mem.Allocator) ParseError!*ast.Expr {
        var left = try self.parseBitwiseXor(alloc);
        while (self.match(.pipe)) {
            const right = try self.parseBitwiseXor(alloc);
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .binary,
                .loc = left.loc,
                .data = .{
                    .binary = .{
                        .op = .pipe,
                        .left = left,
                        .right = right,
                    },
                },
            };
            left = e;
        }
        return left;
    }

    fn parseBitwiseXor(self: *Parser, alloc: std.mem.Allocator) ParseError!*ast.Expr {
        var left = try self.parseBitwiseAnd(alloc);
        while (self.match(.caret)) {
            const right = try self.parseBitwiseAnd(alloc);
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .binary,
                .loc = left.loc,
                .data = .{
                    .binary = .{
                        .op = .caret,
                        .left = left,
                        .right = right,
                    },
                },
            };
            left = e;
        }
        return left;
    }

    fn parseBitwiseAnd(self: *Parser, alloc: std.mem.Allocator) ParseError!*ast.Expr {
        var left = try self.parseEquality(alloc);
        while (self.match(.ampersand)) {
            const right = try self.parseEquality(alloc);
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .binary,
                .loc = left.loc,
                .data = .{
                    .binary = .{
                        .op = .ampersand,
                        .left = left,
                        .right = right,
                    },
                },
            };
            left = e;
        }
        return left;
    }

    fn parseEquality(self: *Parser, alloc: std.mem.Allocator) ParseError!*ast.Expr {
        var left = try self.parseRelational(alloc);
        while (self.check(.equal_equal) or self.check(.bang_equal)) {
            const op = self.current.tag;
            self.advance();
            const right = try self.parseRelational(alloc);
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .binary,
                .loc = left.loc,
                .data = .{
                    .binary = .{
                        .op = op,
                        .left = left,
                        .right = right,
                    },
                },
            };
            left = e;
        }
        return left;
    }

    fn parseRelational(self: *Parser, alloc: std.mem.Allocator) ParseError!*ast.Expr {
        var left = try self.parseShift(alloc);
        while (self.check(.less_than) or self.check(.less_than_equal) or
            self.check(.greater_than) or self.check(.greater_than_equal))
        {
            const op = self.current.tag;
            self.advance();
            const right = try self.parseShift(alloc);
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .binary,
                .loc = left.loc,
                .data = .{
                    .binary = .{
                        .op = op,
                        .left = left,
                        .right = right,
                    },
                },
            };
            left = e;
        }
        return left;
    }

    fn parseShift(self: *Parser, alloc: std.mem.Allocator) ParseError!*ast.Expr {
        var left = try self.parseAdditive(alloc);
        while (self.check(.shl) or self.check(.shr)) {
            const op = self.current.tag;
            self.advance();
            const right = try self.parseAdditive(alloc);
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .binary,
                .loc = left.loc,
                .data = .{
                    .binary = .{
                        .op = op,
                        .left = left,
                        .right = right,
                    },
                },
            };
            left = e;
        }
        return left;
    }

    fn parseAdditive(self: *Parser, alloc: std.mem.Allocator) ParseError!*ast.Expr {
        var left = try self.parseMultiplicative(alloc);
        while (self.check(.plus) or self.check(.plus_percent) or
            self.check(.minus) or self.check(.minus_percent))
        {
            const op = self.current.tag;
            self.advance();
            const right = try self.parseMultiplicative(alloc);
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .binary,
                .loc = left.loc,
                .data = .{
                    .binary = .{
                        .op = op,
                        .left = left,
                        .right = right,
                    },
                },
            };
            left = e;
        }
        return left;
    }

    fn parseMultiplicative(self: *Parser, alloc: std.mem.Allocator) ParseError!*ast.Expr {
        var left = try self.parseUnary(alloc);
        while (self.check(.asterisk) or self.check(.asterisk_percent) or
            self.check(.slash) or self.check(.percent))
        {
            const op = self.current.tag;
            self.advance();
            const right = try self.parseUnary(alloc);
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .binary,
                .loc = left.loc,
                .data = .{
                    .binary = .{
                        .op = op,
                        .left = left,
                        .right = right,
                    },
                },
            };
            left = e;
        }
        return left;
    }

    fn parseUnary(self: *Parser, alloc: std.mem.Allocator) ParseError!*ast.Expr {
        if (self.check(.bang) or self.check(.tilde) or self.check(.minus) or self.check(.pipe) or self.check(.ampersand) or self.check(.caret)) {
            const op = self.current.tag;
            const op_loc = self.current.loc;
            self.advance();
            const operand = try self.parseUnary(alloc);
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .unary,
                .loc = op_loc,
                .data = .{
                    .unary = .{
                        .op = op,
                        .operand = operand,
                    },
                },
            };
            return e;
        }
        return self.parsePostfix(alloc);
    }

    fn parsePostfix(self: *Parser, alloc: std.mem.Allocator) ParseError!*ast.Expr {
        var expr = try self.parsePrimary(alloc);

        while (true) {
            if (self.match(.dot)) {
                const member_name = try self.expect(.identifier);
                const e = try alloc.create(ast.Expr);
                e.* = .{
                    .tag = .member_access,
                    .loc = member_name.loc,
                    .data = .{
                        .member_access = .{
                            .target = expr,
                            .field = member_name.slice,
                        },
                    },
                };
                expr = e;
            } else if (self.match(.l_bracket)) {
                // Slicing: [start..end], [base +: width], [base -: width], or indexing: [i]
                const start_expr = try self.parseExpr(alloc);
                if (self.match(.plus_colon)) {
                    const width_expr = try self.parseExpr(alloc);
                    _ = try self.expect(.r_bracket);
                    const e = try alloc.create(ast.Expr);
                    e.* = .{
                        .tag = .part_select,
                        .loc = start_expr.loc,
                        .data = .{
                            .part_select = .{
                                .target = expr,
                                .base = start_expr,
                                .width = width_expr,
                                .is_up = true,
                            },
                        },
                    };
                    expr = e;
                } else if (self.match(.minus_colon)) {
                    const width_expr = try self.parseExpr(alloc);
                    _ = try self.expect(.r_bracket);
                    const e = try alloc.create(ast.Expr);
                    e.* = .{
                        .tag = .part_select,
                        .loc = start_expr.loc,
                        .data = .{
                            .part_select = .{
                                .target = expr,
                                .base = start_expr,
                                .width = width_expr,
                                .is_up = false,
                            },
                        },
                    };
                    expr = e;
                } else if (self.match(.dot_dot)) {
                    const end_expr = try self.parseExpr(alloc);
                    _ = try self.expect(.r_bracket);

                    // Determine downward slice sugar: if start and end are literals and start > end
                    var is_downward = false;
                    if (start_expr.tag == .number and end_expr.tag == .number) {
                        if (start_expr.data.number.val > end_expr.data.number.val) {
                            is_downward = true;
                        }
                    }

                    const e = try alloc.create(ast.Expr);
                    e.* = .{
                        .tag = .slice,
                        .loc = start_expr.loc,
                        .data = .{
                            .slice = .{
                                .target = expr,
                                .start = start_expr,
                                .end = end_expr,
                                .is_downward = is_downward,
                            },
                        },
                    };
                    expr = e;
                } else if (self.match(.colon)) {
                    // Verilog-style slice: [msb:lsb], e.g. [7:0]
                    const lsb_expr = try self.parseExpr(alloc);
                    _ = try self.expect(.r_bracket);

                    var start_e = lsb_expr;
                    var end_e = lsb_expr;
                    if (start_expr.tag == .number and lsb_expr.tag == .number) {
                        const hi = start_expr.data.number.val;
                        const lo = lsb_expr.data.number.val;
                        const s_node = try alloc.create(ast.Expr);
                        s_node.* = .{
                            .tag = .number,
                            .loc = lsb_expr.loc,
                            .data = .{ .number = .{ .val = lo, .raw = try std.fmt.allocPrint(alloc, "{d}", .{lo}) } },
                        };
                        const e_node = try alloc.create(ast.Expr);
                        e_node.* = .{
                            .tag = .number,
                            .loc = start_expr.loc,
                            .data = .{ .number = .{ .val = hi + 1, .raw = try std.fmt.allocPrint(alloc, "{d}", .{hi + 1}) } },
                        };
                        start_e = s_node;
                        end_e = e_node;
                    }

                    const e = try alloc.create(ast.Expr);
                    e.* = .{
                        .tag = .slice,
                        .loc = start_expr.loc,
                        .data = .{
                            .slice = .{
                                .target = expr,
                                .start = start_e,
                                .end = end_e,
                                .is_downward = false,
                            },
                        },
                    };
                    expr = e;
                } else {
                    _ = try self.expect(.r_bracket);
                    const e = try alloc.create(ast.Expr);
                    e.* = .{
                        .tag = .index,
                        .loc = start_expr.loc,
                        .data = .{
                            .index = .{
                                .target = expr,
                                .index = start_expr,
                            },
                        },
                    };
                    expr = e;
                }
            } else if (self.match(.l_paren)) {
                var args = ArrayList(*ast.Expr).init(alloc);
                while (!self.check(.r_paren) and !self.check(.eof)) {
                    try args.append(try self.parseExpr(alloc));
                    if (!self.match(.comma)) break;
                }
                _ = try self.expect(.r_paren);

                const e = try alloc.create(ast.Expr);
                e.* = .{
                    .tag = .call,
                    .loc = expr.loc,
                    .data = .{
                        .call = .{
                            .callee = expr,
                            .args = try args.toOwnedSlice(),
                        },
                    },
                };
                expr = e;
            } else {
                break;
            }
        }

        return expr;
    }

    fn parseStructInitFields(self: *Parser, alloc: std.mem.Allocator) ParseError![]ast.NamedExpr {
        var fields = ArrayList(ast.NamedExpr).init(alloc);
        while (!self.check(.r_brace) and !self.check(.eof)) {
            _ = try self.expect(.dot);
            const f_name = try self.expect(.identifier);
            _ = try self.expect(.equal);
            const f_val = try self.parseExpr(alloc);
            try fields.append(.{
                .name = f_name.slice,
                .value = f_val,
                .loc = f_name.loc,
            });
            if (!self.match(.comma)) break;
        }
        _ = try self.expect(.r_brace);
        return try fields.toOwnedSlice();
    }

    fn parsePrimary(self: *Parser, alloc: std.mem.Allocator) ParseError!*ast.Expr {
        const loc = self.current.loc;

        // Number literal
        if (self.check(.number)) {
            const raw = self.current.slice;
            self.advance();
            var val: u64 = 0;
            if (std.mem.indexOfScalar(u8, raw, '\'')) |quote_pos| {
                if (quote_pos + 1 < raw.len) {
                    const base_ch = raw[quote_pos + 1];
                    const digits = raw[quote_pos + 2 ..];
                    if (base_ch == 'h' or base_ch == 'H') {
                        val = parseHex(digits) catch 0;
                    } else if (base_ch == 'b' or base_ch == 'B') {
                        val = parseBin(digits) catch 0;
                    } else if (base_ch == 'd' or base_ch == 'D') {
                        val = parseDec(digits) catch 0;
                    }
                }
            } else if (raw.len > 2 and raw[0] == '0' and (raw[1] == 'x' or raw[1] == 'X')) {
                val = parseHex(raw[2..]) catch 0;
            } else if (raw.len > 2 and raw[0] == '0' and (raw[1] == 'b' or raw[1] == 'B')) {
                val = parseBin(raw[2..]) catch 0;
            } else {
                val = parseDec(raw) catch 0;
            }

            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .number,
                .loc = loc,
                .data = .{
                    .number = .{
                        .val = val,
                        .raw = raw,
                    },
                },
            };
            return e;
        }

        // Time literal
        if (self.check(.time_literal)) {
            const raw = self.current.slice;
            var unit: ast.TimeUnit = .ns;
            var num_part: []const u8 = raw;
            if (std.mem.endsWith(u8, raw, "ps")) {
                unit = .ps;
                num_part = raw[0 .. raw.len - 2];
            } else if (std.mem.endsWith(u8, raw, "ns")) {
                unit = .ns;
                num_part = raw[0 .. raw.len - 2];
            } else if (std.mem.endsWith(u8, raw, "us")) {
                unit = .us;
                num_part = raw[0 .. raw.len - 2];
            } else if (std.mem.endsWith(u8, raw, "ms")) {
                unit = .ms;
                num_part = raw[0 .. raw.len - 2];
            } else if (std.mem.endsWith(u8, raw, "s")) {
                unit = .s;
                num_part = raw[0 .. raw.len - 1];
            }
            const val = parseDec(num_part) catch 0;
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .time_literal,
                .loc = loc,
                .data = .{
                    .time_literal = .{
                        .val = val,
                        .unit = unit,
                        .raw = raw,
                    },
                },
            };
            self.advance();
            return e;
        }

        // Frequency literal
        if (self.check(.freq_literal)) {
            const raw = self.current.slice;
            var unit: ast.FreqUnit = .mhz;
            var num_part: []const u8 = raw;
            if (std.ascii.endsWithIgnoreCase(raw, "ghz")) {
                unit = .ghz;
                num_part = raw[0 .. raw.len - 3];
            } else if (std.ascii.endsWithIgnoreCase(raw, "mhz")) {
                unit = .mhz;
                num_part = raw[0 .. raw.len - 3];
            } else if (std.ascii.endsWithIgnoreCase(raw, "khz")) {
                unit = .khz;
                num_part = raw[0 .. raw.len - 3];
            } else if (std.ascii.endsWithIgnoreCase(raw, "hz")) {
                unit = .hz;
                num_part = raw[0 .. raw.len - 2];
            }
            const val = parseDec(num_part) catch 0;
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .freq_literal,
                .loc = loc,
                .data = .{
                    .freq_literal = .{
                        .val = val,
                        .unit = unit,
                        .raw = raw,
                    },
                },
            };
            self.advance();
            return e;
        }

        // Boolean
        if (self.match(.kw_true)) {
            const e = try alloc.create(ast.Expr);
            e.* = .{ .tag = .boolean, .loc = loc, .data = .{ .boolean = true } };
            return e;
        }
        if (self.match(.kw_false)) {
            const e = try alloc.create(ast.Expr);
            e.* = .{ .tag = .boolean, .loc = loc, .data = .{ .boolean = false } };
            return e;
        }

        // Null literal
        if (self.match(.kw_null)) {
            const e = try alloc.create(ast.Expr);
            e.* = .{ .tag = .null_lit, .loc = loc, .data = .{ .null_lit = {} } };
            return e;
        }

        // String literal
        if (self.check(.string_literal)) {
            const s = self.current.slice;
            self.advance();
            const e = try alloc.create(ast.Expr);
            // strip quotes
            const content = if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s[1 .. s.len - 1] else s;
            e.* = .{ .tag = .string, .loc = loc, .data = .{ .string = content } };
            return e;
        }

        // Enum literal: .idle, .read, etc. or Anonymous struct/array init: .{ ... }
        if (self.match(.dot)) {
            if (self.check(.l_brace)) {
                // Anonymous struct init: .{ .a = 1, .b = 2 } or array init: .{ 1, 2, 3 }
                self.advance();
                if (self.check(.r_brace)) {
                    _ = try self.expect(.r_brace);
                    const e = try alloc.create(ast.Expr);
                    e.* = .{
                        .tag = .array_init,
                        .loc = loc,
                        .data = .{
                            .array_init = .{
                                .type_expr = null,
                                .elements = &.{},
                            },
                        },
                    };
                    return e;
                } else if (self.check(.dot)) {
                    const fields = try self.parseStructInitFields(alloc);
                    const e = try alloc.create(ast.Expr);
                    e.* = .{
                        .tag = .struct_init,
                        .loc = loc,
                        .data = .{
                            .struct_init = .{
                                .type_expr = null,
                                .fields = fields,
                            },
                        },
                    };
                    return e;
                } else {
                    var elements = ArrayList(*ast.Expr).init(alloc);
                    while (!self.check(.r_brace) and !self.check(.eof)) {
                        try elements.append(try self.parseExpr(alloc));
                        if (!self.match(.comma)) break;
                    }
                    _ = try self.expect(.r_brace);
                    const e = try alloc.create(ast.Expr);
                    e.* = .{
                        .tag = .array_init,
                        .loc = loc,
                        .data = .{
                            .array_init = .{
                                .type_expr = null,
                                .elements = try elements.toOwnedSlice(),
                            },
                        },
                    };
                    return e;
                }
            }

            const field = try self.expect(.identifier);
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .enum_literal,
                .loc = loc,
                .data = .{
                    .enum_literal = field.slice,
                },
            };
            return e;
        }

        // Builtins: @concat, @bitReverse, @byteSwap, @truncate, @bitCast, @clog2, @import
        if (isBuiltin(self.current.tag)) {
            const b_tag = self.current.tag;
            self.advance();
            _ = try self.expect(.l_paren);
            var args = ArrayList(*ast.Expr).init(alloc);
            while (!self.check(.r_paren) and !self.check(.eof)) {
                try args.append(try self.parseExpr(alloc));
                if (!self.match(.comma)) break;
            }
            _ = try self.expect(.r_paren);

            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .builtin_call,
                .loc = loc,
                .data = .{
                    .builtin_call = .{
                        .tag = b_tag,
                        .args = try args.toOwnedSlice(),
                    },
                },
            };
            return e;
        }

        // Extern module literal: extern(...) module { ... } or extern(...) module(...) { ... }
        if (self.match(.kw_extern)) {
            const meta = try self.parseExternMetadata(alloc);
            _ = try self.expect(.kw_module);
            var params: []ast.FnParam = &.{};
            if (self.match(.l_paren)) {
                params = try self.parseFnParams(alloc, true);
                _ = try self.expect(.r_paren);
            }
            const items = try self.parseModuleBody(alloc);
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .module_literal,
                .loc = loc,
                .data = .{
                    .module_literal = .{
                        .params = params,
                        .items = items,
                        .is_extern = true,
                        .foreign_name = meta.foreign_name,
                        .include_path = meta.include_path,
                    },
                },
            };
            return e;
        }

        // Module literal: module { ... } or module(...) { ... } (used in generic module functions)
        if (self.match(.kw_module)) {
            var params: []ast.FnParam = &.{};
            if (self.match(.l_paren)) {
                params = try self.parseFnParams(alloc, true);
                _ = try self.expect(.r_paren);
            }
            const items = try self.parseModuleBody(alloc);
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .module_literal,
                .loc = loc,
                .data = .{
                    .module_literal = .{
                        .params = params,
                        .items = items,
                        .is_extern = false,
                        .foreign_name = null,
                        .include_path = null,
                    },
                },
            };
            return e;
        }

        // If expression: if (cond) a else b
        if (self.match(.kw_if)) {
            _ = try self.expect(.l_paren);
            const cond = try self.parseExpr(alloc);
            _ = try self.expect(.r_paren);
            const then_branch = try self.parseExpr(alloc);
            _ = try self.expect(.kw_else);
            const else_branch = try self.parseExpr(alloc);

            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .if_expr,
                .loc = loc,
                .data = .{
                    .if_expr = .{
                        .cond = cond,
                        .then_branch = then_branch,
                        .else_branch = else_branch,
                    },
                },
            };
            return e;
        }

        // Parentheses: (expr)
        if (self.match(.l_paren)) {
            const e = try self.parseExpr(alloc);
            _ = try self.expect(.r_paren);
            return e;
        }

        // Array type or typed array init: [4]u8{ 1, 2, 3, 4 } or [4]u8
        if (self.check(.l_bracket)) {
            const t = try self.parseType(alloc);
            if (self.match(.l_brace)) {
                var elements = ArrayList(*ast.Expr).init(alloc);
                while (!self.check(.r_brace) and !self.check(.eof)) {
                    try elements.append(try self.parseExpr(alloc));
                    if (!self.match(.comma)) break;
                }
                _ = try self.expect(.r_brace);
                const e = try alloc.create(ast.Expr);
                e.* = .{
                    .tag = .array_init,
                    .loc = loc,
                    .data = .{
                        .array_init = .{
                            .type_expr = t,
                            .elements = try elements.toOwnedSlice(),
                        },
                    },
                };
                return e;
            } else {
                const e = try alloc.create(ast.Expr);
                e.* = .{
                    .tag = .type_expr,
                    .loc = loc,
                    .data = .{
                        .type_expr = t,
                    },
                };
                return e;
            }
        }

        // Type expressions: ?T, packed struct { ... } or enum { ... } or union(...) { ... } or struct { ... }
        if (self.check(.question_mark) or self.check(.kw_packed) or self.check(.kw_enum) or self.check(.kw_union) or self.check(.kw_struct)) {
            const t = try self.parseType(alloc);
            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .type_expr,
                .loc = loc,
                .data = .{
                    .type_expr = t,
                },
            };
            return e;
        }

        // Identifier or Named struct init: MyStruct{ .field1 = val1, ... }
        if (self.check(.identifier)) {
            const name = self.current.slice;
            const id_loc = self.current.loc;
            self.advance();

            if (self.check(.l_brace) and (self.peek_token.tag == .dot or self.peek_token.tag == .r_brace)) {
                self.advance(); // consume '{'
                const fields = try self.parseStructInitFields(alloc);
                const t = try alloc.create(ast.Type);
                t.* = .{
                    .tag = .named,
                    .loc = id_loc,
                    .data = .{
                        .named = name,
                    },
                };
                const e = try alloc.create(ast.Expr);
                e.* = .{
                    .tag = .struct_init,
                    .loc = id_loc,
                    .data = .{
                        .struct_init = .{
                            .type_expr = t,
                            .fields = fields,
                        },
                    },
                };
                return e;
            }

            const e = try alloc.create(ast.Expr);
            e.* = .{
                .tag = .identifier,
                .loc = id_loc,
                .data = .{
                    .identifier = name,
                },
            };
            return e;
        }

        std.debug.print("Expected expression, found {s} ('{s}') at {d}:{d}\n", .{
            @tagName(self.current.tag),
            self.current.slice,
            self.current.loc.line,
            self.current.loc.col,
        });
        return error.ExpectedExpression;
    }

    fn isBuiltin(tag: TokenType) bool {
        return switch (tag) {
            .builtin_import,
            .builtin_concat,
            .builtin_replicate,
            .builtin_reduce_or,
            .builtin_reduce_and,
            .builtin_reduce_xor,
            .builtin_part_select,
            .builtin_bit_reverse,
            .builtin_byte_swap,
            .builtin_truncate,
            .builtin_bit_cast,
            .builtin_as,
            .builtin_clog2,
            .builtin_sync2ff,
            => true,
            else => false,
        };
    }

    fn parseHex(slice: []const u8) !u64 {
        var res: u64 = 0;
        for (slice) |ch| {
            if (ch == '_') continue;
            const digit = try std.fmt.charToDigit(ch, 16);
            res = (res << 4) | digit;
        }
        return res;
    }

    fn parseBin(slice: []const u8) !u64 {
        var res: u64 = 0;
        for (slice) |ch| {
            if (ch == '_') continue;
            const digit = try std.fmt.charToDigit(ch, 2);
            res = (res << 1) | digit;
        }
        return res;
    }

    fn parseDec(slice: []const u8) !u64 {
        var res: u64 = 0;
        for (slice) |ch| {
            if (ch == '_') continue;
            const digit = try std.fmt.charToDigit(ch, 10);
            res = res * 10 + digit;
        }
        return res;
    }
};
