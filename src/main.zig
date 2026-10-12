const std = @import("std");
const ArrayList = std.array_list.Managed;
const parser_mod = @import("parser.zig");
const elaborator_mod = @import("elaborator.zig");
const codegen_mod = @import("codegen/systemverilog.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_list = ArrayList([]const u8).init(allocator);
    defer args_list.deinit();

    var it = init.minimal.args.iterate();
    while (it.next()) |arg| {
        try args_list.append(arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, command, "compile") or std.mem.eql(u8, command, "lint") or std.mem.eql(u8, command, "check") or std.mem.eql(u8, command, "test")) {
        if (args.len < 3) {
            std.debug.print("Error: missing input .zhdl file\n\n", .{});
            printUsage();
            std.process.exit(1);
        }

        const input_path = args[2];
        var output_path: ?[]const u8 = null;
        var top_module: ?[]const u8 = null;

        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-o")) {
                if (i + 1 < args.len) {
                    output_path = args[i + 1];
                    i += 1;
                }
            } else if (std.mem.eql(u8, args[i], "--top")) {
                if (i + 1 < args.len) {
                    top_module = args[i + 1];
                    i += 1;
                }
            }
        }

        // Read source file
        const cwd = std.Io.Dir.cwd();
        const source = cwd.readFileAlloc(io, input_path, allocator, .unlimited) catch |err| {
            std.debug.print("Error reading file '{s}': {s}\n", .{ input_path, @errorName(err) });
            std.process.exit(1);
        };
        defer allocator.free(source);

        // Parse AST
        var parser = parser_mod.Parser.init(allocator, source);
        var ast_tree = parser.parse() catch |err| {
            std.debug.print("Parse error in '{s}': {s}\n", .{ input_path, @errorName(err) });
            std.process.exit(1);
        };
        defer ast_tree.deinit();

        // Elaborate AST -> HIR
        var elaborator = elaborator_mod.Elaborator.init(allocator, &ast_tree);
        defer elaborator.deinit();

        var hir_design = elaborator.elaborate(top_module) catch |err| {
            std.debug.print("Elaboration error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer hir_design.deinit();

        if (std.mem.eql(u8, command, "check")) {
            std.debug.print("✓ Syntax and semantics check passed: '{s}' (found {d} modules)\n", .{
                input_path,
                hir_design.modules.len,
            });
            return;
        }

        // Generate SystemVerilog
        var sv_buffer = ArrayList(u8).init(allocator);
        defer sv_buffer.deinit();

        var sw: codegen_mod.StringWriter = .{ .list = &sv_buffer };
        var emitter = codegen_mod.SystemVerilogEmitter.init(allocator);
        const is_test = std.mem.eql(u8, command, "test");
        try emitter.emitDesignEx(&hir_design, is_test, &sw);

        // Determine destination
        const target_out = output_path orelse blk: {
            if (std.mem.endsWith(u8, input_path, ".zhdl")) {
                break :blk try std.fmt.allocPrint(allocator, "{s}.sv", .{input_path[0 .. input_path.len - 5]});
            } else {
                break :blk try std.fmt.allocPrint(allocator, "{s}.sv", .{input_path});
            }
        };
        defer if (output_path == null) allocator.free(target_out);

        // Write output to file
        const out_file = cwd.createFile(io, target_out, .{}) catch |err| {
            std.debug.print("Error writing output file '{s}': {s}\n", .{ target_out, @errorName(err) });
            std.process.exit(1);
        };
        defer out_file.close(io);

        try out_file.writeStreamingAll(io, sv_buffer.items);
        if (!std.mem.eql(u8, command, "test")) {
            std.debug.print("✓ Successfully compiled '{s}' -> '{s}'\n", .{ input_path, target_out });
        }

        // If test command requested, compile and run simulation
        if (std.mem.eql(u8, command, "test")) {
            if (hir_design.testbenches.len == 0) {
                std.debug.print("No test declarations found in '{s}'\n", .{input_path});
                return;
            }

            const sim_dir = ".zhdl_sim";
            const v_res = std.process.run(allocator, io, .{
                .argv = &.{
                    "verilator",
                    "--binary",
                    "--timing",
                    "--trace",
                    "-Wno-fatal",
                    target_out,
                    "--prefix",
                    "Vtb",
                    "-Mdir",
                    sim_dir,
                },
            }) catch |err| {
                std.debug.print("Failed to run verilator: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            defer {
                allocator.free(v_res.stdout);
                allocator.free(v_res.stderr);
            }
            if (v_res.term != .exited or v_res.term.exited != 0) {
                std.debug.print("✗ Verilator compilation error:\n{s}\n{s}\n", .{ v_res.stdout, v_res.stderr });
                std.process.exit(1);
            }

            const exe_path = try std.fmt.allocPrint(allocator, "{s}/Vtb", .{sim_dir});
            defer allocator.free(exe_path);

            const sim_run = std.process.run(allocator, io, .{
                .argv = &.{exe_path},
            }) catch |err| {
                std.debug.print("Failed to execute simulation binary: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            defer {
                allocator.free(sim_run.stdout);
                allocator.free(sim_run.stderr);
            }

            if (sim_run.term == .exited and sim_run.term.exited == 0) {
                for (hir_design.testbenches, 0..) |tb, tb_idx| {
                    std.debug.print("{d}/{d} test.{s}...OK\n", .{ tb_idx + 1, hir_design.testbenches.len, tb.name });
                    for (tb.sim_stmts) |s| {
                        if (s.tag == .trace) {
                            std.debug.print("   Waveform saved to: {s}\n", .{s.data.trace.vcd_path});
                        }
                    }
                }
                std.debug.print("All {d} tests passed.\n", .{hir_design.testbenches.len});
            } else {
                for (hir_design.testbenches, 0..) |tb, tb_idx| {
                    std.debug.print("{d}/{d} test.{s}...FAIL\n", .{ tb_idx + 1, hir_design.testbenches.len, tb.name });
                }
                std.debug.print("{s}\n{s}\n", .{ sim_run.stdout, sim_run.stderr });
                std.process.exit(1);
            }
            return;
        }

        // If lint command requested, run verilator
        if (std.mem.eql(u8, command, "lint")) {
            std.debug.print("==> Running Verilator lint check on '{s}'...\n", .{target_out});
            const run_res = std.process.run(allocator, io, .{
                .argv = &.{
                    "verilator",
                    "--lint-only",
                    "-Wall",
                    target_out,
                },
            }) catch |err| {
                std.debug.print("Failed to run verilator: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            defer {
                allocator.free(run_res.stdout);
                allocator.free(run_res.stderr);
            }

            if (run_res.term == .exited and run_res.term.exited == 0) {
                std.debug.print("✓ Verilator lint check PASSED with 0 warnings/errors!\n", .{});
            } else {
                std.debug.print("✗ Verilator reported issues:\n{s}\n{s}\n", .{ run_res.stdout, run_res.stderr });
                std.process.exit(1);
            }
        }
    } else {
        std.debug.print("Unknown command: '{s}'\n\n", .{command});
        printUsage();
        std.process.exit(1);
    }
}

fn printUsage() void {
    const usage =
        \\ZHdl Compiler v0.1.0 - Hardware Description Language inspired by Zig
        \\Compiles to synthesizable IEEE 1800 SystemVerilog
        \\
        \\Usage:
        \\  zhdl compile <input.zhdl> [-o <output.sv>] [--top <ModuleName>]
        \\  zhdl test    <input.zhdl> [--trace]          (Compiles and runs simulation testbenches)
        \\  zhdl lint    <input.zhdl> [-o <output.sv>]   (Compiles and runs Verilator --lint-only)
        \\  zhdl check   <input.zhdl>                    (Validates syntax, types, and latch freedom)
        \\  zhdl help                                    (Displays this help message)
        \\
        \\Examples:
        \\  zhdl compile examples/counter.zhdl -o counter.sv
        \\  zhdl test    examples/counter.zhdl
        \\  zhdl lint    examples/fsm.zhdl
        \\
    ;
    std.debug.print("{s}", .{usage});
}
