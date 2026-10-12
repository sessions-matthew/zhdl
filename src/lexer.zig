const std = @import("std");
const token = @import("token.zig");
const Token = token.Token;
const TokenType = token.TokenType;
const SourceLoc = token.SourceLoc;

pub const Lexer = struct {
    source: []const u8,
    index: usize = 0,
    line: u32 = 1,
    col: u32 = 1,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
        };
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespaceAndComments();

        if (self.index >= self.source.len) {
            return .{
                .tag = .eof,
                .loc = self.currentLoc(),
                .slice = "",
            };
        }

        const start_idx = self.index;
        const start_loc = self.currentLoc();
        const c = self.peek();

        // Builtins starting with '@'
        if (c == '@') {
            self.advance();
            while (self.index < self.source.len and isIdentifierChar(self.peek())) {
                self.advance();
            }
            const slice = self.source[start_idx..self.index];
            if (token.builtins.get(slice)) |tag| {
                return .{ .tag = tag, .loc = start_loc, .slice = slice };
            } else {
                return .{ .tag = .invalid, .loc = start_loc, .slice = slice };
            }
        }

        // Identifiers and keywords
        if (isIdentifierStart(c)) {
            while (self.index < self.source.len and isIdentifierChar(self.peek())) {
                self.advance();
            }
            const slice = self.source[start_idx..self.index];
            const tag = token.keywords.get(slice) orelse .identifier;
            return .{ .tag = tag, .loc = start_loc, .slice = slice };
        }

        // Numbers (decimal, hex, binary)
        if (std.ascii.isDigit(c)) {
            return self.lexNumber(start_loc, start_idx);
        }

        // String literals
        if (c == '"') {
            return self.lexString(start_loc, start_idx);
        }

        // Punctuation and operators
        self.advance();
        switch (c) {
            '(' => return .{ .tag = .l_paren, .loc = start_loc, .slice = "(" },
            ')' => return .{ .tag = .r_paren, .loc = start_loc, .slice = ")" },
            '[' => return .{ .tag = .l_bracket, .loc = start_loc, .slice = "[" },
            ']' => return .{ .tag = .r_bracket, .loc = start_loc, .slice = "]" },
            '{' => return .{ .tag = .l_brace, .loc = start_loc, .slice = "{" },
            '}' => return .{ .tag = .r_brace, .loc = start_loc, .slice = "}" },
            ',' => return .{ .tag = .comma, .loc = start_loc, .slice = "," },
            ':' => {
                if (self.match('=')) {
                    return .{ .tag = .colon_equal, .loc = start_loc, .slice = ":=" };
                }
                return .{ .tag = .colon, .loc = start_loc, .slice = ":" };
            },
            ';' => return .{ .tag = .semicolon, .loc = start_loc, .slice = ";" },
            '~' => return .{ .tag = .tilde, .loc = start_loc, .slice = "~" },
            '^' => return .{ .tag = .caret, .loc = start_loc, .slice = "^" },

            '.' => {
                if (self.match('.')) {
                    return .{ .tag = .dot_dot, .loc = start_loc, .slice = ".." };
                }
                return .{ .tag = .dot, .loc = start_loc, .slice = "." };
            },

            '=' => {
                if (self.match('=')) {
                    return .{ .tag = .equal_equal, .loc = start_loc, .slice = "==" };
                }
                if (self.match('>')) {
                    return .{ .tag = .fat_arrow, .loc = start_loc, .slice = "=>" };
                }
                return .{ .tag = .equal, .loc = start_loc, .slice = "=" };
            },

            '!' => {
                if (self.match('=')) {
                    return .{ .tag = .bang_equal, .loc = start_loc, .slice = "!=" };
                }
                return .{ .tag = .bang, .loc = start_loc, .slice = "!" };
            },

            '?' => return .{ .tag = .question_mark, .loc = start_loc, .slice = "?" },

            '+' => {
                if (self.match('%')) {
                    return .{ .tag = .plus_percent, .loc = start_loc, .slice = "+%" };
                }
                return .{ .tag = .plus, .loc = start_loc, .slice = "+" };
            },

            '-' => {
                if (self.match('%')) {
                    return .{ .tag = .minus_percent, .loc = start_loc, .slice = "-%" };
                }
                return .{ .tag = .minus, .loc = start_loc, .slice = "-" };
            },

            '*' => {
                if (self.match('%')) {
                    return .{ .tag = .asterisk_percent, .loc = start_loc, .slice = "*%" };
                }
                return .{ .tag = .asterisk, .loc = start_loc, .slice = "*" };
            },

            '/' => return .{ .tag = .slash, .loc = start_loc, .slice = "/" },
            '%' => return .{ .tag = .percent, .loc = start_loc, .slice = "%" },

            '&' => {
                if (self.match('&')) {
                    return .{ .tag = .ampersand_ampersand, .loc = start_loc, .slice = "&&" };
                }
                return .{ .tag = .ampersand, .loc = start_loc, .slice = "&" };
            },

            '|' => {
                if (self.match('|')) {
                    return .{ .tag = .pipe_pipe, .loc = start_loc, .slice = "||" };
                }
                return .{ .tag = .pipe, .loc = start_loc, .slice = "|" };
            },

            '<' => {
                if (self.match('<')) {
                    return .{ .tag = .shl, .loc = start_loc, .slice = "<<" };
                }
                if (self.match('=')) {
                    return .{ .tag = .less_than_equal, .loc = start_loc, .slice = "<=" };
                }
                return .{ .tag = .less_than, .loc = start_loc, .slice = "<" };
            },

            '>' => {
                if (self.match('>')) {
                    return .{ .tag = .shr, .loc = start_loc, .slice = ">>" };
                }
                if (self.match('=')) {
                    return .{ .tag = .greater_than_equal, .loc = start_loc, .slice = ">=" };
                }
                return .{ .tag = .greater_than, .loc = start_loc, .slice = ">" };
            },

            else => {
                return .{
                    .tag = .invalid,
                    .loc = start_loc,
                    .slice = self.source[start_idx..self.index],
                };
            },
        }
    }

    fn lexNumber(self: *Lexer, loc: SourceLoc, start_idx: usize) Token {
        self.advance(); // consume first digit
        if (self.source[start_idx] == '0' and self.index < self.source.len) {
            const next_char = self.peek();
            if (next_char == 'x' or next_char == 'X') {
                self.advance(); // consume 'x'
                while (self.index < self.source.len and (std.ascii.isHex(self.peek()) or self.peek() == '_')) {
                    self.advance();
                }
                return .{ .tag = .number, .loc = loc, .slice = self.source[start_idx..self.index] };
            } else if (next_char == 'b' or next_char == 'B') {
                self.advance(); // consume 'b'
                while (self.index < self.source.len and (self.peek() == '0' or self.peek() == '1' or self.peek() == '_')) {
                    self.advance();
                }
                return .{ .tag = .number, .loc = loc, .slice = self.source[start_idx..self.index] };
            }
        }

        while (self.index < self.source.len and (std.ascii.isDigit(self.peek()) or self.peek() == '_')) {
            self.advance();
        }

        if (self.index < self.source.len and self.peek() == '\'') {
            self.advance(); // consume '\''
            if (self.index < self.source.len) {
                const base_ch = self.peek();
                if (base_ch == 'h' or base_ch == 'H') {
                    self.advance();
                    while (self.index < self.source.len and (std.ascii.isHex(self.peek()) or self.peek() == '_')) {
                        self.advance();
                    }
                } else if (base_ch == 'b' or base_ch == 'B') {
                    self.advance();
                    while (self.index < self.source.len and (self.peek() == '0' or self.peek() == '1' or self.peek() == '_')) {
                        self.advance();
                    }
                } else if (base_ch == 'd' or base_ch == 'D') {
                    self.advance();
                    while (self.index < self.source.len and (std.ascii.isDigit(self.peek()) or self.peek() == '_')) {
                        self.advance();
                    }
                }
            }
        }

        // Check if followed immediately by a time unit suffix: ps, ns, us, ms, s
        const rem = self.source[self.index..];
        const suffixes = [_][]const u8{ "ps", "ns", "us", "ms", "s" };
        for (suffixes) |suffix| {
            if (std.mem.startsWith(u8, rem, suffix)) {
                const next_idx = self.index + suffix.len;
                if (next_idx >= self.source.len or !isIdentifierChar(self.source[next_idx])) {
                    for (suffix) |_| {
                        self.advance();
                    }
                    return .{
                        .tag = .time_literal,
                        .loc = loc,
                        .slice = self.source[start_idx..self.index],
                    };
                }
            }
        }

        return .{
            .tag = .number,
            .loc = loc,
            .slice = self.source[start_idx..self.index],
        };
    }

    fn lexString(self: *Lexer, loc: SourceLoc, start_idx: usize) Token {
        self.advance(); // consume opening quote '"'
        while (self.index < self.source.len) {
            const ch = self.peek();
            self.advance();
            if (ch == '"') {
                return .{
                    .tag = .string_literal,
                    .loc = loc,
                    .slice = self.source[start_idx..self.index],
                };
            }
            if (ch == '\\' and self.index < self.source.len) {
                self.advance(); // skip escaped character
            }
        }
        return .{
            .tag = .invalid,
            .loc = loc,
            .slice = self.source[start_idx..self.index],
        };
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.index < self.source.len) {
            const c = self.peek();
            switch (c) {
                ' ', '\t', '\r' => {
                    self.advance();
                },
                '\n' => {
                    self.advance();
                    self.line += 1;
                    self.col = 1;
                },
                '/' => {
                    if (self.index + 1 < self.source.len and self.source[self.index + 1] == '/') {
                        // Single-line or doc comment '//' or '///' or '//!': skip until newline
                        self.advance();
                        self.advance();
                        while (self.index < self.source.len and self.peek() != '\n') {
                            self.advance();
                        }
                    } else {
                        break;
                    }
                },
                else => break,
            }
        }
    }

    fn peek(self: *Lexer) u8 {
        if (self.index >= self.source.len) return 0;
        return self.source[self.index];
    }

    fn advance(self: *Lexer) void {
        if (self.index < self.source.len) {
            self.index += 1;
            self.col += 1;
        }
    }

    fn match(self: *Lexer, expected: u8) bool {
        if (self.index >= self.source.len) return false;
        if (self.source[self.index] == expected) {
            self.advance();
            return true;
        }
        return false;
    }

    fn currentLoc(self: *Lexer) SourceLoc {
        return .{
            .line = self.line,
            .col = self.col,
            .offset = self.index,
        };
    }

    fn isIdentifierStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }

    fn isIdentifierChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }
};
