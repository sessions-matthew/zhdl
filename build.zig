const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ZHdl pure Zig eDSL module
    const zhdl_mod = b.addModule("zhdl", .{
        .root_source_file = b.path("src/zhdl.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Main compiler executable (CLI)
    const exe = b.addExecutable(.{
        .name = "zhdl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Baseline compiler test suite
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Pure Zig eDSL module unit tests
    const zhdl_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zhdl.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_zhdl_tests = b.addRunArtifact(zhdl_tests);

    // Pure Zig eDSL examples test suite
    const edsl_examples_mod = b.createModule(.{
        .root_source_file = b.path("examples/edsl/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    edsl_examples_mod.addImport("zhdl", zhdl_mod);

    const edsl_examples_tests = b.addTest(.{
        .root_module = edsl_examples_mod,
    });
    const run_edsl_examples_tests = b.addRunArtifact(edsl_examples_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_zhdl_tests.step);
    test_step.dependOn(&run_edsl_examples_tests.step);

    const edsl_step = b.step("test-edsl", "Run pure Zig eDSL unit tests and examples");
    edsl_step.dependOn(&run_zhdl_tests.step);
    edsl_step.dependOn(&run_edsl_examples_tests.step);
}
