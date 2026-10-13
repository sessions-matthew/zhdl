const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ZHdl pure Zig eDSL module
    _ = b.addModule("zhdl", .{
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

    // Pure Zig eDSL test suite (Option 1)
    const edsl_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zhdl.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_edsl_tests = b.addRunArtifact(edsl_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_edsl_tests.step);

    const edsl_step = b.step("test-edsl", "Run pure Zig eDSL unit tests");
    edsl_step.dependOn(&run_edsl_tests.step);
}
