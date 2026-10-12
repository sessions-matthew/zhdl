const std = @import("std");
const ArrayList = std.array_list.Managed;
const Lexer = @import("lexer.zig").Lexer;
const TokenType = @import("token.zig").TokenType;

test "lexer basic tokens" {
    const src =
        \\const uart = @import("uart.zhdl");
        \\pub const Counter = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in en: u1,
        \\    out count: u8,
        \\    var count_reg = reg(u8, .{ .clk = clk, .rst = rst, .init = 0 });
        \\    comb {
        \\        if (en) {
        \\            count_reg.next = count_reg +% 1;
        \\        }
        \\        count = count_reg;
        \\    }
        \\};
    ;

    var lexer = Lexer.init(src);
    var token_count: usize = 0;
    while (true) {
        const tok = lexer.next();
        if (tok.tag == .eof) break;
        try std.testing.expect(tok.tag != .invalid);
        token_count += 1;
    }
    try std.testing.expect(token_count > 20);
}

test "lexer operators, numbers, and builtins" {
    const src = "0x1F 0b1010 42 @bitReverse @byteSwap @concat +% -% *% .. => == != <= >= << >>";
    var lexer = Lexer.init(src);

    try std.testing.expectEqual(TokenType.number, lexer.next().tag);
    try std.testing.expectEqual(TokenType.number, lexer.next().tag);
    try std.testing.expectEqual(TokenType.number, lexer.next().tag);
    try std.testing.expectEqual(TokenType.builtin_bit_reverse, lexer.next().tag);
    try std.testing.expectEqual(TokenType.builtin_byte_swap, lexer.next().tag);
    try std.testing.expectEqual(TokenType.builtin_concat, lexer.next().tag);
    try std.testing.expectEqual(TokenType.plus_percent, lexer.next().tag);
    try std.testing.expectEqual(TokenType.minus_percent, lexer.next().tag);
    try std.testing.expectEqual(TokenType.asterisk_percent, lexer.next().tag);
    try std.testing.expectEqual(TokenType.dot_dot, lexer.next().tag);
    try std.testing.expectEqual(TokenType.fat_arrow, lexer.next().tag);
    try std.testing.expectEqual(TokenType.equal_equal, lexer.next().tag);
    try std.testing.expectEqual(TokenType.bang_equal, lexer.next().tag);
    try std.testing.expectEqual(TokenType.less_than_equal, lexer.next().tag);
    try std.testing.expectEqual(TokenType.greater_than_equal, lexer.next().tag);
    try std.testing.expectEqual(TokenType.shl, lexer.next().tag);
    try std.testing.expectEqual(TokenType.shr, lexer.next().tag);
    try std.testing.expectEqual(TokenType.eof, lexer.next().tag);
}

test "parser module and downward slicing sugar" {
    const src =
        \\pub const Counter = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in din: u8,
        \\    out dout: u4,
        \\    out rev: u4,
        \\    var count = reg(u8, .{ .clk = clk, .rst = rst, .init = 0 });
        \\    comb {
        \\        count.next = count +% 1;
        \\        dout = count[0..4];
        \\        rev = count[4..0]; // downward slicing syntactic sugar!
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    try std.testing.expectEqual(@as(usize, 1), ast_tree.decls.len);
    const decl = ast_tree.decls[0];
    try std.testing.expectEqual(true, decl.is_pub);
    try std.testing.expect(decl.tag == .module_decl);
    try std.testing.expectEqualStrings("Counter", decl.data.module_decl.name);
    try std.testing.expectEqual(@as(usize, 7), decl.data.module_decl.items.len);
}

test "end-to-end elaboration and SystemVerilog emission" {
    const src =
        \\pub const Counter = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in en: u1,
        \\    out count: u8,
        \\    out rev: u4,
        \\    var count_reg = reg(u8, .{ .clk = clk, .rst = rst, .init = 0 });
        \\    comb {
        \\        if (en) {
        \\            count_reg.next = count_reg +% 1;
        \\        }
        \\        count = count_reg;
        \\        rev = count_reg[4..0]; // downward slicing
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    var hir_design = try elaborator.elaborate(null);
    defer hir_design.deinit();

    try std.testing.expectEqual(@as(usize, 1), hir_design.modules.len);
    const mod = hir_design.modules[0];
    try std.testing.expectEqualStrings("Counter", mod.name);
    try std.testing.expectEqual(@as(usize, 5), mod.ports.len);
    try std.testing.expectEqual(@as(usize, 1), mod.registers.len);

    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();

    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try emitter.emitDesign(&hir_design, &sw);

    const sv_output = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "module Counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "always_ff @(posedge clk or posedge rst)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "always_comb begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "{<<{count_reg_q[3:0]}}") != null);
}

test "option 1 reg syntax with implicit clock/reset binding" {
    const src =
        \\pub const StreamReg = module {
        \\    in clk: clock,
        \\    in rst_n: reset,
        \\    in d_in: u8,
        \\    out d_out: u8,
        \\
        \\    // Concise Option 1 syntax
        \\    reg state: u2 = 0;
        \\    reg buffer: u8 = 0xFF;
        \\    reg(clk, .none) unreset_pipe: u8 = 0;
        \\
        \\    comb {
        \\        buffer.next = d_in;
        \\        unreset_pipe.next = buffer;
        \\        d_out = unreset_pipe;
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    var hir_design = try elaborator.elaborate(null);
    defer hir_design.deinit();

    try std.testing.expectEqual(@as(usize, 1), hir_design.modules.len);
    const mod = hir_design.modules[0];
    try std.testing.expectEqual(@as(usize, 3), mod.registers.len);

    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();

    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try emitter.emitDesign(&hir_design, &sw);

    const sv_output = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "always_ff @(posedge clk or negedge rst_n)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "always_ff @(posedge clk) begin") != null);
}

test "wire keyword combinational logic and interconnect" {
    const src =
        \\pub const WireTest = module {
        \\    in a: u8,
        \\    in b: u8,
        \\    out sum: u8,
        \\    out diff: u8,
        \\    out result: u8,
        \\
        \\    // Module-level wires
        \\    wire mid_sum: u8 = a +% b;
        \\    wire mid_diff: u8;
        \\
        \\    comb {
        \\        // Inside comb wires (both typed and type-inferred)
        \\        wire local_xor: u8 = a ^ b;
        \\        wire local_and = a & b;
        \\
        \\        mid_diff = a -% b;
        \\        sum = mid_sum;
        \\        diff = mid_diff;
        \\        result = local_xor | local_and;
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    var hir_design = try elaborator.elaborate(null);
    defer hir_design.deinit();

    try std.testing.expectEqual(@as(usize, 1), hir_design.modules.len);
    const mod = hir_design.modules[0];
    try std.testing.expectEqualStrings("WireTest", mod.name);
    try std.testing.expectEqual(@as(usize, 5), mod.ports.len);

    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();

    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try emitter.emitDesign(&hir_design, &sw);

    const sv_output = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "logic [7:0] mid_sum;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "logic [7:0] mid_diff;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "logic [7:0] local_xor;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "logic [7:0] local_and;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "mid_sum = (a + b);") != null);
}

test "testbench parsing elaboration and testbench emission" {
    const src =
        \\pub const Inverter = module {
        \\    in a: u1,
        \\    out y: u1,
        \\    comb {
        \\        y = !a;
        \\    }
        \\};
        \\
        \\test "Inverter verifies inverted output" {
        \\    wire a: u1;
        \\    wire y: u1;
        \\
        \\    const dut = Inverter.instantiate(.{
        \\        .a = a,
        \\        .y = y,
        \\    });
        \\
        \\    sim {
        \\        trace("inverter.vcd");
        \\        a = 0;
        \\        delay(5);
        \\        assert(y == 1, "Expected y to be 1 when a is 0");
        \\
        \\        a = 1;
        \\        delay(5);
        \\        assert(y == 0, "Expected y to be 0 when a is 1");
        \\        finish();
        \\    }
        \\}
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    try std.testing.expectEqual(@as(usize, 2), ast_tree.decls.len);
    try std.testing.expect(ast_tree.decls[0].tag == .module_decl);
    try std.testing.expect(ast_tree.decls[1].tag == .test_decl);
    try std.testing.expectEqualStrings("Inverter verifies inverted output", ast_tree.decls[1].data.test_decl.name);

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    var hir_design = try elaborator.elaborate(null);
    defer hir_design.deinit();

    try std.testing.expectEqual(@as(usize, 1), hir_design.modules.len);
    try std.testing.expectEqual(@as(usize, 1), hir_design.testbenches.len);
    const tb = hir_design.testbenches[0];
    try std.testing.expectEqualStrings("Inverter verifies inverted output", tb.name);
    try std.testing.expectEqual(@as(usize, 2), tb.signals.len);
    try std.testing.expectEqual(@as(usize, 1), tb.instances.len);

    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();

    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try emitter.emitDesign(&hir_design, &sw);

    const sv_output = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "module Inverter") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "module tb_Inverter_verifies_inverted_output;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "$dumpfile(\"inverter.vcd\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "a = 1'd0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "#5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "$error(\"[FAIL] Expected y to be 1 when a is 0\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_output, "$finish;") != null);
}

test "race condition: detect and reject combinational self-loop" {
    const src =
        \\pub const LoopSelf = module {
        \\    wire a: u8;
        \\    comb {
        \\        a = a + 1;
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    const res = elaborator.elaborate(null);
    try std.testing.expectError(error.CombinationalLoop, res);
}

test "race condition: detect and reject mutual combinational loop" {
    const src =
        \\pub const MutualLoop = module {
        \\    wire a: u8;
        \\    wire b: u8;
        \\    comb {
        \\        a = b + 1;
        \\        b = a + 1;
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    const res = elaborator.elaborate(null);
    try std.testing.expectError(error.CombinationalLoop, res);
}

test "race condition: detect and reject input port assignment" {
    const src =
        \\pub const InputAssign = module {
        \\    in clk: clock,
        \\    comb {
        \\        clk = 1;
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    const res = elaborator.elaborate(null);
    try std.testing.expectError(error.CannotAssignInputPort, res);
}

test "race condition: detect and reject multi-driver comb blocks" {
    const src =
        \\pub const MultiComb = module {
        \\    out y: u8,
        \\    comb {
        \\        y = 1;
        \\    }
        \\    comb {
        \\        y = 2;
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    const res = elaborator.elaborate(null);
    try std.testing.expectError(error.MultipleDrivers, res);
}

test "race condition: clocked registers safely break combinational loops" {
    const src =
        \\pub const SafeCounter = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    out count: u8,
        \\    reg count_reg: u8 = 0;
        \\    comb {
        \\        count_reg.next = count_reg +% 1;
        \\        count = count_reg;
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    var hir_design = try elaborator.elaborate(null);
    defer hir_design.deinit();

    try std.testing.expectEqual(@as(usize, 1), hir_design.modules.len);
}

test "race condition: detect and reject 10-element combinational loop" {
    const src =
        \\pub const DeepLoop = module {
        \\    wire w0: u8;
        \\    wire w1: u8;
        \\    wire w2: u8;
        \\    wire w3: u8;
        \\    wire w4: u8;
        \\    wire w5: u8;
        \\    wire w6: u8;
        \\    wire w7: u8;
        \\    wire w8: u8;
        \\    wire w9: u8;
        \\
        \\    comb {
        \\        w0 = w1 + 1;
        \\        w1 = w2 + 1;
        \\        w2 = w3 + 1;
        \\        w3 = w4 + 1;
        \\        w4 = w5 + 1;
        \\        w5 = w6 + 1;
        \\        w6 = w7 + 1;
        \\        w7 = w8 + 1;
        \\        w8 = w9 + 1;
        \\        w9 = w0 + 1;
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    const res = elaborator.elaborate(null);
    try std.testing.expectError(error.CombinationalLoop, res);
}

test "cdc: detect and reject unsynchronized direct cross-domain register transfer" {
    const src =
        \\pub const UnsafeCdcDirect = module {
        \\    in clk_a: clock,
        \\    in clk_b: clock,
        \\    var reg_a = reg(u8, .{ .clk = clk_a, .init = 0 });
        \\    var reg_b = reg(u8, .{ .clk = clk_b, .init = 0 });
        \\    comb {
        \\        reg_b.next = reg_a;
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    const res = elaborator.elaborate(null);
    try std.testing.expectError(error.ClockDomainCrossing, res);
}

test "cdc: detect and reject multi-hop combinational cross-domain path" {
    const src =
        \\pub const UnsafeCdcMultiHop = module {
        \\    in clk_fast: clock,
        \\    in clk_slow: clock,
        \\    var reg_fast = reg(u8, .{ .clk = clk_fast, .init = 0 });
        \\    var reg_slow = reg(u8, .{ .clk = clk_slow, .init = 0 });
        \\    wire w1: u8 = reg_fast + 1;
        \\    wire w2: u8 = w1 & 0x0F;
        \\    comb {
        \\        reg_slow.next = w2;
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    const res = elaborator.elaborate(null);
    try std.testing.expectError(error.ClockDomainCrossing, res);
}

test "cdc: safe cross-domain transfer with @sync2ff and ASYNC_REG emission" {
    const src =
        \\pub const SafeCdcSync = module {
        \\    in clk_a: clock,
        \\    in clk_b: clock,
        \\    out dout: u8,
        \\    var reg_a = reg(u8, .{ .clk = clk_a, .init = 0 });
        \\    var reg_b = reg(u8, .{ .clk = clk_b, .init = 0 });
        \\    wire reg_a_synced: u8 = @sync2ff(clk_b, reg_a);
        \\    comb {
        \\        reg_b.next = reg_a_synced;
        \\        dout = reg_b;
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    var hir_design = try elaborator.elaborate(null);
    defer hir_design.deinit();

    try std.testing.expectEqual(@as(usize, 1), hir_design.modules.len);
    const mod = hir_design.modules[0];

    // reg_a, reg_b, and 2 synchronizer stages = 4 registers total
    try std.testing.expectEqual(@as(usize, 4), mod.registers.len);

    var sync_stages_found: usize = 0;
    for (mod.registers) |r| {
        if (r.is_sync_stage) {
            sync_stages_found += 1;
            try std.testing.expectEqualStrings("clk_b", r.clk_name);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), sync_stages_found);

    // Verify SystemVerilog emission contains (* ASYNC_REG = "TRUE" *)
    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();
    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var sv_emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try sv_emitter.emitDesign(&hir_design, &sw);

    const sv_code = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "(* ASYNC_REG = \"TRUE\" *)") != null);
}

test "register assignment: := operator updates register" {
    const src =
        \\pub const RegAssign = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in en: u1,
        \\    out count: u8,
        \\    var count_reg = reg(u8, .{ .clk = clk, .rst = rst, .init = 0 });
        \\    comb {
        \\        if (en) {
        \\            count_reg := count_reg +% 1;
        \\        }
        \\        count = count_reg;
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    var hir_design = try elaborator.elaborate(null);
    defer hir_design.deinit();

    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();
    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var sv_emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try sv_emitter.emitDesign(&hir_design, &sw);

    const sv_code = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "count_reg_d = (count_reg_q +") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "count_reg_q <= count_reg_d") != null);
}

test "register assignment: := operator updates register array element" {
    const src =
        \\pub const ArrayAssign = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in wr_en: u1,
        \\    in wr_ptr: u4,
        \\    in din: u8,
        \\    out dout: u8,
        \\    var mem = reg([16]u8, .{ .clk = clk, .rst = rst, .init = 0 });
        \\    comb {
        \\        if (wr_en) {
        \\            mem[wr_ptr] := din;
        \\        }
        \\        dout = mem[wr_ptr];
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    var hir_design = try elaborator.elaborate(null);
    defer hir_design.deinit();

    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();
    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var sv_emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try sv_emitter.emitDesign(&hir_design, &sw);

    const sv_code = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "mem_d[wr_ptr] = din") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "mem_q <= mem_d") != null);
}

test "register assignment: := on combinational wire is rejected" {
    const src =
        \\pub const BadWireAssign = module {
        \\    in a: u8,
        \\    wire w: u8;
        \\    comb {
        \\        w := a + 1;
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    const res = elaborator.elaborate(null);
    try std.testing.expectError(error.TypeMismatch, res);
}







