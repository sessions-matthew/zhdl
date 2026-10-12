const std = @import("std");
const ArrayList = std.array_list.Managed;
const hir = @import("hir.zig");
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
        \\    in rst_n: reset(.low),
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

test "packed struct: field offsets, reading member fields, and bit slicing" {
    const src =
        \\pub const Header = packed struct {
        \\    cmd: u8,
        \\    addr: u16,
        \\    flag: u1,
        \\};
        \\
        \\pub const StructReader = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in raw_packet: Header,
        \\    out cmd_out: u8,
        \\    out addr_out: u16,
        \\    out flag_out: u1,
        \\    comb {
        \\        cmd_out = raw_packet.cmd;
        \\        addr_out = raw_packet.addr;
        \\        flag_out = raw_packet.flag;
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

    // Verify port width is 25 (8 + 16 + 1)
    const mod = hir_design.modules[0];
    var found_packet = false;
    for (mod.ports) |p| {
        if (std.mem.eql(u8, p.name, "raw_packet")) {
            found_packet = true;
            try std.testing.expectEqual(@as(u32, 25), p.hir_type.width);
            try std.testing.expectEqual(hir.HirTypeTag.packed_struct, p.hir_type.tag);
            try std.testing.expectEqual(@as(usize, 3), p.hir_type.struct_fields.len);
            try std.testing.expectEqualStrings("cmd", p.hir_type.struct_fields[0].name);
            try std.testing.expectEqual(@as(u32, 8), p.hir_type.struct_fields[0].width);
            try std.testing.expectEqual(@as(u32, 0), p.hir_type.struct_fields[0].offset);

            try std.testing.expectEqualStrings("addr", p.hir_type.struct_fields[1].name);
            try std.testing.expectEqual(@as(u32, 16), p.hir_type.struct_fields[1].width);
            try std.testing.expectEqual(@as(u32, 8), p.hir_type.struct_fields[1].offset);

            try std.testing.expectEqualStrings("flag", p.hir_type.struct_fields[2].name);
            try std.testing.expectEqual(@as(u32, 1), p.hir_type.struct_fields[2].width);
            try std.testing.expectEqual(@as(u32, 24), p.hir_type.struct_fields[2].offset);
        }
    }
    try std.testing.expect(found_packet);

    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();
    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var sv_emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try sv_emitter.emitDesign(&hir_design, &sw);

    const sv_code = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "raw_packet[7:0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "raw_packet[23:8]") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "raw_packet[24]") != null);
}

test "packed struct: field assignment and struct literal initialization" {
    const src =
        \\pub const Header = packed struct {
        \\    cmd: u8,
        \\    addr: u16,
        \\    flag: u1,
        \\};
        \\
        \\pub const StructWriter = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in en: u1,
        \\    out pkt_out: Header,
        \\    reg pkt_reg: Header = 0;
        \\    comb {
        \\        if (en) {
        \\            pkt_reg.cmd := 0x42;
        \\            pkt_reg.flag := 1;
        \\        }
        \\        pkt_out = pkt_reg;
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
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "pkt_reg_d[7:0] =") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "pkt_reg_d[24] =") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "pkt_reg_q <= pkt_reg_d") != null);
}

fn runVerilatorLint(allocator: std.mem.Allocator, sv_source: []const u8) !void {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const tmp_path = ".test_tmp_lint.sv";
    const out_file = try cwd.createFile(io, tmp_path, .{});
    try out_file.writeStreamingAll(io, sv_source);
    out_file.close(io);
    defer {
        cwd.deleteFile(io, tmp_path) catch {};
    }

    const run_res = try std.process.run(allocator, io, .{
        .argv = &.{
            "verilator",
            "--lint-only",
            "-Wall",
            tmp_path,
        },
    });
    defer {
        allocator.free(run_res.stdout);
        allocator.free(run_res.stderr);
    }
    if (run_res.term != .exited or run_res.term.exited != 0) {
        std.debug.print("Verilator lint failed:\n{s}\n{s}\n", .{ run_res.stdout, run_res.stderr });
        return error.VerilatorLintFailed;
    }
}

fn runVerilatorSim(allocator: std.mem.Allocator, sv_source: []const u8) !void {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const tmp_sv = ".test_tmp_sim.sv";
    const sim_dir = ".test_tmp_sim_dir";
    const out_file = try cwd.createFile(io, tmp_sv, .{});
    try out_file.writeStreamingAll(io, sv_source);
    out_file.close(io);
    defer {
        cwd.deleteFile(io, tmp_sv) catch {};
        const rm_res = std.process.run(allocator, io, .{
            .argv = &.{ "rm", "-rf", sim_dir },
        }) catch null;
        if (rm_res) |res| {
            allocator.free(res.stdout);
            allocator.free(res.stderr);
        }
    }

    const v_res = try std.process.run(allocator, io, .{
        .argv = &.{
            "verilator",
            "--binary",
            "--timing",
            "-Wno-fatal",
            "-Wno-MULTIDRIVEN",
            tmp_sv,
            "--prefix",
            "Vtb",
            "-Mdir",
            sim_dir,
        },
    });
    defer {
        allocator.free(v_res.stdout);
        allocator.free(v_res.stderr);
    }
    if (v_res.term != .exited or v_res.term.exited != 0) {
        std.debug.print("Verilator sim compile failed:\n{s}\n{s}\n", .{ v_res.stdout, v_res.stderr });
        return error.VerilatorCompileFailed;
    }

    const exe_path = try std.fmt.allocPrint(allocator, "{s}/Vtb", .{sim_dir});
    defer allocator.free(exe_path);

    const run_res = try std.process.run(allocator, io, .{
        .argv = &.{exe_path},
    });
    defer {
        allocator.free(run_res.stdout);
        allocator.free(run_res.stderr);
    }
    if (run_res.term != .exited or run_res.term.exited != 0) {
        std.debug.print("Simulation execution failed:\n{s}\n{s}\n", .{ run_res.stdout, run_res.stderr });
        return error.SimulationFailed;
    }
}

test "hardware optional: declaration, valid/data fields, auto-wrapping, and reset to null" {
    const src =
        \\pub const OptionalDevice = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in push: u1,
        \\    in clear: u1,
        \\    in in_byte: u8,
        \\    out has_data: u1,
        \\    out rx_byte: u8,
        \\
        \\    reg opt_rx: ?u8 = null;
        \\
        \\    comb {
        \\        if (push) {
            \\            opt_rx := in_byte;
            \\        } else if (clear) {
            \\            opt_rx := null;
            \\        }
        \\
        \\        has_data = opt_rx.valid;
        \\        rx_byte = opt_rx.data;
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

    const mod = hir_design.modules[0];
    try std.testing.expectEqual(@as(usize, 1), mod.registers.len);
    const reg_rx = mod.registers[0];
    try std.testing.expectEqualStrings("opt_rx", reg_rx.name);
    try std.testing.expectEqual(hir.HirTypeTag.optional, reg_rx.hir_type.tag);
    try std.testing.expectEqual(@as(u32, 9), reg_rx.hir_type.width);
    try std.testing.expectEqual(@as(u32, 8), reg_rx.hir_type.elem_width);
    try std.testing.expectEqual(@as(usize, 2), reg_rx.hir_type.struct_fields.len);

    try std.testing.expectEqualStrings("data", reg_rx.hir_type.struct_fields[0].name);
    try std.testing.expectEqual(@as(u32, 8), reg_rx.hir_type.struct_fields[0].width);
    try std.testing.expectEqual(@as(u32, 0), reg_rx.hir_type.struct_fields[0].offset);

    try std.testing.expectEqualStrings("valid", reg_rx.hir_type.struct_fields[1].name);
    try std.testing.expectEqual(@as(u32, 1), reg_rx.hir_type.struct_fields[1].width);
    try std.testing.expectEqual(@as(u32, 8), reg_rx.hir_type.struct_fields[1].offset);

    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();
    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var sv_emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try sv_emitter.emitDesign(&hir_design, &sw);

    const sv_code = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "logic [8:0] opt_rx_q, opt_rx_d;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "opt_rx_q <= 9'h0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "opt_rx_d = {1'd1, in_byte};") != null or std.mem.indexOf(u8, sv_code, "opt_rx_d = {1'b1, in_byte};") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "opt_rx_d = 9'd0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "has_data = opt_rx_q[8];") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "rx_byte = opt_rx_q[7:0];") != null);

    // Verify SystemVerilog emission passes Verilator lint with 0 errors
    try runVerilatorLint(std.testing.allocator, sv_code);
}

test "hardware optional: payload unwrapping with if (opt) |byte|" {
    const src =
        \\pub const OptionalUnwrapper = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in load: u1,
        \\    in reset_opt: u1,
        \\    in payload_in: u8,
        \\    out out_data: u8,
        \\
        \\    reg opt_rx: ?u8 = null;
        \\
        \\    comb {
        \\        if (load) {
        \\            opt_rx := payload_in;
        \\        } else if (reset_opt) {
        \\            opt_rx := null;
        \\        }
        \\
        \\        out_data = 0;
        \\        if (opt_rx) |byte| {
        \\            out_data = byte;
        \\        }
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
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "if (opt_rx_q[8]) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "\\byte  = opt_rx_q[7:0];") != null or std.mem.indexOf(u8, sv_code, "byte = opt_rx_q[7:0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "out_data = \\byte ;") != null or std.mem.indexOf(u8, sv_code, "out_data = byte;") != null);

    // Verify SystemVerilog emission passes Verilator lint with 0 errors
    try runVerilatorLint(std.testing.allocator, sv_code);
}

test "hardware optional: direct field assignment and if without capture" {
    const src =
        \\pub const OptionalDirectFields = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in en: u1,
        \\    in data_val: u16,
        \\    out is_valid_out: u1,
        \\    out data_val_out: u16,
        \\
        \\    reg opt_word: ?u16 = null;
        \\
        \\    comb {
        \\        if (en) {
        \\            opt_word.valid := 1;
        \\            opt_word.data := data_val;
        \\        }
        \\
        \\        is_valid_out = 0;
        \\        if (opt_word) {
        \\            is_valid_out = 1;
        \\        }
        \\        data_val_out = opt_word.data;
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
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "opt_word_d[16] = 1'd1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "opt_word_d[15:0] = data_val;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "if (opt_word_q[16]) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "data_val_out = opt_word_q[15:0];") != null);

    // Verify SystemVerilog emission passes Verilator lint with 0 errors
    try runVerilatorLint(std.testing.allocator, sv_code);
}

test "hardware tagged union: definition, variant initialization, tag & payload access" {
    const src =
        \\const Packet = union(enum) {
        \\    ping: u8,
        \\    data: u32,
        \\    ack: void,
        \\};
        \\
        \\pub const TaggedUnionBasic = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in set_ping: u1,
        \\    in in_ping: u8,
        \\    out current_tag: u2,
        \\    out ping_val: u8,
        \\    out data_val: u32,
        \\
        \\    reg pkt: Packet = Packet{ .ack = 0 };
        \\
        \\    comb {
        \\        if (set_ping) {
        \\            pkt := Packet{ .ping = 8'hA5 };
        \\        }
        \\
        \\        current_tag = pkt.tag;
        \\        ping_val = pkt.ping;
        \\        data_val = pkt.data;
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

    const mod = hir_design.modules[0];
    try std.testing.expectEqual(@as(usize, 1), mod.registers.len);
    const reg_pkt = mod.registers[0];
    try std.testing.expectEqualStrings("pkt", reg_pkt.name);
    try std.testing.expectEqual(hir.HirTypeTag.tagged_union, reg_pkt.hir_type.tag);
    // tag_width = ceil(log2(3)) = 2, max_payload = 32, total = 34
    try std.testing.expectEqual(@as(u32, 34), reg_pkt.hir_type.width);
    try std.testing.expectEqual(@as(u32, 32), reg_pkt.hir_type.elem_width);
    try std.testing.expectEqual(@as(u32, 2), reg_pkt.hir_type.tag_width);
    try std.testing.expectEqual(@as(usize, 3), reg_pkt.hir_type.union_fields.len);

    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();
    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var sv_emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try sv_emitter.emitDesign(&hir_design, &sw);

    const sv_code = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "logic [33:0] pkt_q, pkt_d;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "pkt_d = {2'd0, 24'd0, 8'ha5};") != null or std.mem.indexOf(u8, sv_code, "pkt_d = {2'd0, 24'd0, 8'hA5};") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "current_tag = pkt_q[33:32];") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "ping_val = pkt_q[7:0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "data_val = pkt_q[31:0];") != null);

    // Verify SystemVerilog emission passes Verilator lint with 0 errors
    try runVerilatorLint(std.testing.allocator, sv_code);
}

test "hardware tagged union: pattern matching switch with payload capture" {
    const src =
        \\const Packet = union(enum) {
        \\    ping: u8,
        \\    data: u32,
        \\    ack: void,
        \\};
        \\
        \\pub const TaggedUnionSwitch = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in load_ping: u1,
        \\    in in_ping: u8,
        \\    out out_val: u8,
        \\
        \\    reg pkt: Packet = Packet{ .ack = 0 };
        \\
        \\    comb {
        \\        if (load_ping) {
        \\            pkt.ping := in_ping;
        \\        }
        \\
        \\        out_val = 0;
        \\        switch (pkt) {
        \\            .ping => |p| {
        \\                out_val = p;
        \\            },
        \\            .data => |d| {
        \\                out_val = d[7:0];
        \\            },
        \\            .ack => {
        \\                out_val = 0;
        \\            },
        \\        }
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
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "pkt_d[7:0] = in_ping;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "pkt_d[33:32] = 2'd0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "case (pkt_q[33:32])") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "p = pkt_q[7:0];") != null or std.mem.indexOf(u8, sv_code, "\\p  = pkt_q[7:0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "out_val = p;") != null or std.mem.indexOf(u8, sv_code, "out_val = \\p ;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "d = pkt_q[31:0];") != null or std.mem.indexOf(u8, sv_code, "\\d  = pkt_q[31:0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "out_val = d[7:0];") != null or std.mem.indexOf(u8, sv_code, "out_val = \\d [7:0];") != null);

    // Verify SystemVerilog emission passes Verilator lint with 0 errors
    try runVerilatorLint(std.testing.allocator, sv_code);
}

test "hardware tagged union: explicit tag type and anonymous variant struct init" {
    const src =
        \\const Message = union(enum(u4)) {
        \\    header: u16,
        \\    payload: u64,
        \\    trailer: u8,
        \\    empty: void,
        \\};
        \\
        \\pub const TaggedUnionExplicitTag = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in load_hdr: u1,
        \\    in hdr_val: u16,
        \\    out tag_out: u4,
        \\    out hdr_out: u16,
        \\
        \\    reg msg: Message = .{ .empty = 0 };
        \\
        \\    comb {
        \\        if (load_hdr) {
        \\            msg := .{ .header = hdr_val };
        \\        }
        \\
        \\        tag_out = msg.tag;
        \\        hdr_out = msg.header;
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

    const mod = hir_design.modules[0];
    const reg_msg = mod.registers[0];
    try std.testing.expectEqual(@as(u32, 4), reg_msg.hir_type.tag_width);
    try std.testing.expectEqual(@as(u32, 64), reg_msg.hir_type.elem_width);
    try std.testing.expectEqual(@as(u32, 68), reg_msg.hir_type.width);

    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();
    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var sv_emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try sv_emitter.emitDesign(&hir_design, &sw);

    const sv_code = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "logic [67:0] msg_q, msg_d;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "msg_d = {4'd0, 48'd0, hdr_val};") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "tag_out = msg_q[67:64];") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "hdr_out = msg_q[15:0];") != null);

    // Verify SystemVerilog emission passes Verilator lint with 0 errors
    try runVerilatorLint(std.testing.allocator, sv_code);
}

test "type methods: packed struct methods with isZero and isNegative and static call" {
    const src =
        \\pub const Float16 = packed struct {
        \\    sign: u1,
        \\    exp: u5,
        \\    mantissa: u10,
        \\
        \\    pub fn isZero(self: Float16) u1 {
        \\        return self.exp == 0 and self.mantissa == 0;
        \\    }
        \\
        \\    pub fn isNegative(self: Float16) u1 {
        \\        return self.sign == 1;
        \\    }
        \\};
        \\
        \\pub const FloatChecker = module {
        \\    in f: Float16,
        \\    out is_z: u1,
        \\    out is_neg: u1,
        \\    out is_z_static: u1,
        \\
        \\    comb {
        \\        is_z = f.isZero();
        \\        is_neg = f.isNegative();
        \\        is_z_static = Float16.isZero(f);
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
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "is_z = ((f[5:1] == 5'd0) && (f[15:6] == 10'd0));") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "is_neg = (f[0] == 1'd1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "is_z_static = ((f[5:1] == 5'd0) && (f[15:6] == 10'd0));") != null);

    // Verify SystemVerilog emission passes Verilator lint with 0 errors
    try runVerilatorLint(std.testing.allocator, sv_code);
}

test "combinational helper functions: top-level pure function inlining" {
    const src =
        \\pub fn clamp_add(a: u8, b: u8) u8 {
        \\    return if (a > 200) 200 else a + b;
        \\}
        \\
        \\pub const MathUnit = module {
        \\    in in_a: u8,
        \\    in in_b: u8,
        \\    out res: u8,
        \\
        \\    comb {
        \\        res = clamp_add(in_a, in_b);
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
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "res =") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "in_a + in_b") != null);

    try runVerilatorLint(std.testing.allocator, sv_code);
}

test "type methods: tagged union method inlining" {
    const src =
        \\pub const Command = union(enum) {
        \\    idle: void,
        \\    read: u16,
        \\    write: u32,
        \\
        \\    pub fn isWrite(self: Command) u1 {
        \\        return self.tag == 2;
        \\    }
        \\};
        \\
        \\pub const CmdFilter = module {
        \\    in cmd: Command,
        \\    out is_w: u1,
        \\
        \\    comb {
        \\        is_w = cmd.isWrite();
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
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "is_w = (cmd[33:32] == 2'd2);") != null);

    try runVerilatorLint(std.testing.allocator, sv_code);
}

test "type methods: method calling another method and register state" {
    const src =
        \\pub const Number = packed struct {
        \\    val: u8,
        \\
        \\    pub fn isZero(self: Number) u1 {
        \\        return self.val == 0;
        \\    }
        \\
        \\    pub fn isNonZero(self: Number) u1 {
        \\        return self.isZero() == 0;
        \\    }
        \\};
        \\
        \\pub const RegMethodModule = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in in_num: Number,
        \\    out out_nz: u1,
        \\
        \\    reg num_reg: Number = .{ .val = 0 };
        \\
        \\    comb {
        \\        num_reg := in_num;
        \\        out_nz = num_reg.isNonZero();
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
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "out_nz = ((num_reg_q[7:0] == 8'd0) == 1'd0);") != null);

    try runVerilatorLint(std.testing.allocator, sv_code);
}

test "generic module instantiation and monomorphization with Counter(8) and Counter(16)" {
    const src =
        \\pub fn Counter(comptime W: u32) type {
        \\    return module {
        \\        in clk: clock,
        \\        in rst: reset,
        \\        in en: u1,
        \\        out count: u(W),
        \\        reg count_reg: u(W) = 0;
        \\        comb {
        \\            if (en) {
        \\                count_reg := count_reg +% 1;
        \\            }
        \\            count = count_reg;
        \\        }
        \\    };
        \\}
        \\
        \\pub const Top = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in en: u1,
        \\    out count8: u8,
        \\    out count16: u16,
        \\
        \\    const c8 = Counter(8).instantiate(.{
        \\        .clk = clk,
        \\        .rst = rst,
        \\        .en = en,
        \\        .count = count8,
        \\    });
        \\
        \\    const c16 = Counter(16).instantiate(.{
        \\        .clk = clk,
        \\        .rst = rst,
        \\        .en = en,
        \\        .count = count16,
        \\    });
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    var hir_design = try elaborator.elaborate(null);
    defer hir_design.deinit();

    try std.testing.expectEqual(@as(usize, 3), hir_design.modules.len);

    var found_top = false;
    var found_c8 = false;
    var found_c16 = false;

    for (hir_design.modules) |mod| {
        if (std.mem.eql(u8, mod.name, "Top")) {
            found_top = true;
            try std.testing.expectEqual(@as(usize, 2), mod.instances.len);
        } else if (std.mem.eql(u8, mod.name, "Counter_8")) {
            found_c8 = true;
            try std.testing.expectEqual(@as(usize, 1), mod.registers.len);
            try std.testing.expectEqual(@as(u32, 8), mod.registers[0].hir_type.width);
            for (mod.ports) |p| {
                if (std.mem.eql(u8, p.name, "count")) {
                    try std.testing.expectEqual(@as(u32, 8), p.hir_type.width);
                }
            }
        } else if (std.mem.eql(u8, mod.name, "Counter_16")) {
            found_c16 = true;
            try std.testing.expectEqual(@as(usize, 1), mod.registers.len);
            try std.testing.expectEqual(@as(u32, 16), mod.registers[0].hir_type.width);
            for (mod.ports) |p| {
                if (std.mem.eql(u8, p.name, "count")) {
                    try std.testing.expectEqual(@as(u32, 16), p.hir_type.width);
                }
            }
        }
    }

    try std.testing.expect(found_top);
    try std.testing.expect(found_c8);
    try std.testing.expect(found_c16);

    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();
    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var sv_emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try sv_emitter.emitDesign(&hir_design, &sw);

    const sv_code = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "module Top") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "module Counter_8") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "module Counter_16") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "Counter_8 u_c8 (") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "Counter_16 u_c16 (") != null);

    try runVerilatorLint(std.testing.allocator, sv_code);
}

test "generic module alias instantiation with top-level and module-level const" {
    const src =
        \\pub fn Counter(comptime W: u32) type {
        \\    return module {
        \\        in clk: clock,
        \\        in rst: reset,
        \\        in en: u1,
        \\        out count: u(W),
        \\        reg count_reg: u(W) = 0;
        \\        comb {
        \\            if (en) {
        \\                count_reg := count_reg +% 1;
        \\            }
        \\            count = count_reg;
        \\        }
        \\    };
        \\}
        \\
        \\// Top-level module alias
        \\pub const Counter8 = Counter(8);
        \\
        \\pub const Top = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in en: u1,
        \\    out count8: u8,
        \\    out count16: u16,
        \\
        \\    // Instantiation using top-level alias
        \\    const c8 = Counter8.instantiate(.{
        \\        .clk = clk,
        \\        .rst = rst,
        \\        .en = en,
        \\        .count = count8,
        \\    });
        \\
        \\    // Module-level alias
        \\    const Counter16 = Counter(16);
        \\    const c16 = Counter16.instantiate(.{
        \\        .clk = clk,
        \\        .rst = rst,
        \\        .en = en,
        \\        .count = count16,
        \\    });
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    var hir_design = try elaborator.elaborate(null);
    defer hir_design.deinit();

    try std.testing.expectEqual(@as(usize, 3), hir_design.modules.len);

    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();
    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var sv_emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try sv_emitter.emitDesign(&hir_design, &sw);

    const sv_code = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "module Top") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "module Counter_8") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "module Counter_16") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "Counter_8 u_c8 (") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "Counter_16 u_c16 (") != null);

    try runVerilatorLint(std.testing.allocator, sv_code);
}

test "generic module with type parameter" {
    const src =
        \\pub fn Pipe(comptime T: type) type {
        \\    return module {
        \\        in clk: clock,
        \\        in rst: reset,
        \\        in d_in: T,
        \\        out d_out: T,
        \\        reg stage: T = 0;
        \\        comb {
        \\            stage := d_in;
        \\            d_out = stage;
        \\        }
        \\    };
        \\}
        \\
        \\pub const Top = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    in byte_in: u8,
        \\    out byte_out: u8,
        \\    in word_in: u16,
        \\    out word_out: u16,
        \\
        \\    const p8 = Pipe(u8).instantiate(.{
        \\        .clk = clk,
        \\        .rst = rst,
        \\        .d_in = byte_in,
        \\        .d_out = byte_out,
        \\    });
        \\
        \\    const p16 = Pipe(u16).instantiate(.{
        \\        .clk = clk,
        \\        .rst = rst,
        \\        .d_in = word_in,
        \\        .d_out = word_out,
        \\    });
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    var hir_design = try elaborator.elaborate(null);
    defer hir_design.deinit();

    try std.testing.expectEqual(@as(usize, 3), hir_design.modules.len);

    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();
    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var sv_emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try sv_emitter.emitDesign(&hir_design, &sw);

    const sv_code = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "module Top") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "module Pipe_u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "module Pipe_u16") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "Pipe_u8 u_p8 (") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "Pipe_u16 u_p16 (") != null);

    try runVerilatorLint(std.testing.allocator, sv_code);
}

test "generic module instantiated in hardware testbench" {
    const src =
        \\pub fn Counter(comptime W: u32) type {
        \\    return module {
        \\        in clk: clock,
        \\        in rst: reset,
        \\        in en: u1,
        \\        out count: u(W),
        \\        reg count_reg: u(W) = 0;
        \\        comb {
        \\            if (en) {
        \\                count_reg := count_reg +% 1;
        \\            }
        \\            count = count_reg;
        \\        }
        \\    };
        \\}
        \\
        \\test "Counter8 TB" {
        \\    wire clk: clock;
        \\    wire rst: reset;
        \\    wire en: u1;
        \\    wire count: u8;
        \\
        \\    const dut = Counter(8).instantiate(.{
        \\        .clk = clk,
        \\        .rst = rst,
        \\        .en = en,
        \\        .count = count,
        \\    });
        \\
        \\    sim {
        \\        clk.generate(10);
        \\        rst.pulse(2);
        \\        en = 1;
        \\        step(5);
        \\        assert(count == 5, "Counter should have counted to 5");
        \\    }
        \\}
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    var hir_design = try elaborator.elaborate(null);
    defer hir_design.deinit();

    try std.testing.expectEqual(@as(usize, 1), hir_design.modules.len);
    try std.testing.expectEqualStrings("Counter_8", hir_design.modules[0].name);
    try std.testing.expectEqual(@as(usize, 1), hir_design.testbenches.len);
    try std.testing.expectEqualStrings("Counter8 TB", hir_design.testbenches[0].name);

    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();
    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var sv_emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try sv_emitter.emitDesign(&hir_design, &sw);

    const sv_code = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "module Counter_8") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "module tb_Counter8_TB;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "Counter_8 dut (") != null);

    try runVerilatorLint(std.testing.allocator, sv_code);
}

test "time-based testing: delay with typed units (ns, us, ms, ps)" {
    const src =
        \\pub const Inverter = module {
        \\    in a: u1,
        \\    out y: u1,
        \\    comb {
        \\        y = ~a;
        \\    }
        \\};
        \\
        \\test "TimeDelay TB" {
        \\    in a: u1;
        \\    out y: u1;
        \\
        \\    const dut = Inverter.instantiate(.{
        \\        .a = a,
        \\        .y = y,
        \\    });
        \\
        \\    sim {
        \\        a = 0;
        \\        delay(100ps);
        \\        assert(y == 1, "y should be 1");
        \\        a = 1;
        \\        delay(50ns);
        \\        assert(y == 0, "y should be 0");
        \\        delay(10us);
        \\        delay(2ms);
        \\        delay(1s);
        \\        finish();
        \\    }
        \\}
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    var hir_design = try elaborator.elaborate(null);
    defer hir_design.deinit();

    try std.testing.expectEqual(@as(usize, 1), hir_design.testbenches.len);
    const tb = hir_design.testbenches[0];

    // Verify HIR sim statement types and raw values
    var found_ps = false;
    var found_ns = false;
    var found_us = false;
    var found_ms = false;
    var found_s = false;

    for (tb.sim_stmts) |stmt| {
        if (stmt.tag == .delay) {
            if (std.mem.eql(u8, stmt.data.delay.raw, "100ps")) found_ps = true;
            if (std.mem.eql(u8, stmt.data.delay.raw, "50ns") and stmt.data.delay.ns == 50) found_ns = true;
            if (std.mem.eql(u8, stmt.data.delay.raw, "10us") and stmt.data.delay.ns == 10000) found_us = true;
            if (std.mem.eql(u8, stmt.data.delay.raw, "2ms") and stmt.data.delay.ns == 2000000) found_ms = true;
            if (std.mem.eql(u8, stmt.data.delay.raw, "1s") and stmt.data.delay.ns == 1000000000) found_s = true;
        }
    }

    try std.testing.expect(found_ps);
    try std.testing.expect(found_ns);
    try std.testing.expect(found_us);
    try std.testing.expect(found_ms);
    try std.testing.expect(found_s);

    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();
    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var sv_emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try sv_emitter.emitDesign(&hir_design, &sw);

    const sv_code = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "#100ps;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "#50ns;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "#10us;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "#2ms;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "#1s;") != null);

    try runVerilatorLint(std.testing.allocator, sv_code);
    try runVerilatorSim(std.testing.allocator, sv_code);
}

test "time-based testing: clk.generate and wait_for with time literal timeout" {
    const src =
        \\pub const StepDevice = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    out ready: u1,
        \\    var count = reg(u4, .{ .clk = clk, .rst = rst, .init = 0 });
        \\    comb {
        \\        count := count +% 1;
        \\        ready = (count >= 2);
        \\    }
        \\};
        \\
        \\test "WaitTime TB" {
        \\    in clk: clock;
        \\    in rst: reset;
        \\    out ready: u1;
        \\
        \\    const dut = StepDevice.instantiate(.{
        \\        .clk = clk,
        \\        .rst = rst,
        \\        .ready = ready,
        \\    });
        \\
        \\    sim {
        \\        clk.generate(10ns);
        \\        rst.pulse(1);
        \\        wait_for(ready == 1, 100ns);
        \\        assert(ready == 1, "Ready should be high");
        \\        assert_within(ready == 1, 50ns);
        \\        finish();
        \\    }
        \\}
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    var hir_design = try elaborator.elaborate(null);
    defer hir_design.deinit();

    try std.testing.expectEqual(@as(usize, 1), hir_design.testbenches.len);
    const tb = hir_design.testbenches[0];

    try std.testing.expectEqual(@as(usize, 1), tb.clock_gens.len);
    try std.testing.expectEqualStrings("clk", tb.clock_gens[0].clk_name);
    try std.testing.expectEqual(@as(u64, 10), tb.clock_gens[0].period_ns);
    try std.testing.expectEqualStrings("10ns", tb.clock_gens[0].raw);

    var sv_buffer = ArrayList(u8).init(std.testing.allocator);
    defer sv_buffer.deinit();
    var sw = @import("codegen/systemverilog.zig").StringWriter{ .list = &sv_buffer };
    var sv_emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try sv_emitter.emitDesign(&hir_design, &sw);

    const sv_code = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "always #5ns clk = ~clk;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "fork") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "#100ns;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "[TIMEOUT] wait_for timed out after 100ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "join_any") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "disable fork;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "#50ns;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "[TIMEOUT] wait_for timed out after 50ns") != null);

    try runVerilatorLint(std.testing.allocator, sv_code);
    try runVerilatorSim(std.testing.allocator, sv_code);
}

test "typed reset polarity: explicit polarity without variable name deduction" {
    const src =
        \\pub const TypedResetModule = module {
        \\    in clk: clock,
        \\    // Variable named rst_n but typed active-high: MUST emit posedge rst_n and if (rst_n)!
        \\    in rst_n: reset(.high),
        \\    // Variable without _n but typed active-low: MUST emit negedge rst_custom and if (!rst_custom)!
        \\    in rst_custom: reset(.low),
        \\    in d: u8,
        \\    out q1: u8,
        \\    out q2: u8,
        \\
        \\    reg(clk, rst_n) r1: u8 = 0;
        \\    reg(clk, rst_custom) r2: u8 = 0;
        \\
        \\    comb {
        \\        r1.next = d;
        \\        r2.next = d;
        \\        q1 = r1;
        \\        q2 = r2;
        \\    }
        \\};
        \\
        \\test "TypedResetTb" {
        \\    wire clk: clock;
        \\    wire rst_n: reset(.high);
        \\    wire rst_custom: reset(.low);
        \\    wire d: u8;
        \\    wire q1: u8;
        \\    wire q2: u8;
        \\
        \\    const dut = TypedResetModule.instantiate(.{
        \\        .clk = clk,
        \\        .rst_n = rst_n,
        \\        .rst_custom = rst_custom,
        \\        .d = d,
        \\        .q1 = q1,
        \\        .q2 = q2,
        \\    });
        \\
        \\    sim {
        \\        clk.generate(10);
        \\        rst_n.pulse(2);
        \\        rst_custom.pulse(2);
        \\        step(clk, 4);
        \\    }
        \\}
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
    var emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try emitter.emitDesign(&hir_design, &sw);

    const sv_code = sv_buffer.items;

    // Verify rst_n (typed .high) emits posedge rst_n and if (rst_n)
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "always_ff @(posedge clk or posedge rst_n) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "if (rst_n) begin") != null);

    // Verify rst_custom (typed .low) emits negedge rst_custom and if (!rst_custom)
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "always_ff @(posedge clk or negedge rst_custom) begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "if (!rst_custom) begin") != null);

    // Verify testbench pulse emission:
    // rst_n (.high): 1 then 0
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "rst_n = 1'b1;\n        repeat (2) @(posedge clk);\n        rst_n = 1'b0;") != null);
    // rst_custom (.low): 0 then 1
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "rst_custom = 1'b0;\n        repeat (2) @(posedge clk);\n        rst_custom = 1'b1;") != null);

    try runVerilatorLint(std.testing.allocator, sv_code);
    try runVerilatorSim(std.testing.allocator, sv_code);
}

test "dynamic enum variant resolution without hardcoded name deduction" {
    const src =
        \\pub const CustomEnumMod = module {
        \\    in clk: clock,
        \\    in rst: reset,
        \\    const State = enum(u3) {
        \\        idle = 0,
        \\        running = 1,
        \\        waiting = 5,
        \\        finished = 7,
        \\    };
        \\    in next_state: State,
        \\    out current_code: u3,
        \\
        \\    reg state_reg: State = 0;
        \\
        \\    comb {
        \\        state_reg.next = next_state;
        \\        current_code = state_reg;
        \\    }
        \\};
        \\
        \\test "CustomEnumTb" {
        \\    wire clk: clock;
        \\    wire rst: reset;
        \\    const State = enum(u3) {
        \\        idle = 0,
        \\        running = 1,
        \\        waiting = 5,
        \\        finished = 7,
        \\    };
        \\    wire next_state: State = 0;
        \\    wire current_code: u3;
        \\
        \\    const dut = CustomEnumMod.instantiate(.{
        \\        .clk = clk,
        \\        .rst = rst,
        \\        .next_state = next_state,
        \\        .current_code = current_code,
        \\    });
        \\
        \\    sim {
        \\        clk.generate(10);
        \\        rst.pulse(2);
        \\        next_state = .waiting;
        \\        step(clk, 2);
        \\        assert(current_code == 5, "current_code should be 5 for .waiting");
        \\        next_state = .finished;
        \\        step(clk, 2);
        \\        assert(current_code == 7, "current_code should be 7 for .finished");
        \\    }
        \\}
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
    var emitter = @import("codegen/systemverilog.zig").SystemVerilogEmitter.init(std.testing.allocator);
    try emitter.emitDesign(&hir_design, &sw);

    const sv_code = sv_buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "next_state = 3'd5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv_code, "next_state = 3'd7;") != null);

    try runVerilatorLint(std.testing.allocator, sv_code);
    try runVerilatorSim(std.testing.allocator, sv_code);
}

test "strict clock domain binding: error on missing clock port" {
    const src =
        \\pub const NoClockModule = module {
        \\    in data: u8,
        \\    out result: u8,
        \\    reg count: u8 = 0;
        \\    comb {
        \\        count.next = data;
        \\        result = count;
        \\    }
        \\};
    ;

    var parser = @import("parser.zig").Parser.init(std.testing.allocator, src);
    var ast_tree = try parser.parse();
    defer ast_tree.deinit();

    var elaborator = @import("elaborator.zig").Elaborator.init(std.testing.allocator, &ast_tree);
    defer elaborator.deinit();

    const res = elaborator.elaborate(null);
    try std.testing.expectError(error.MissingClockSignal, res);
}

test "loop detection: combinational wire with _q or _d suffix is correctly caught" {
    const src =
        \\pub const LoopSuffix = module {
        \\    in in_data: u8,
        \\    out out_data: u8,
        \\    wire test_d: u8;
        \\    comb {
        \\        test_d = test_d + in_data;
        \\        out_data = test_d;
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














