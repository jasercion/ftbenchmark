// build.zig
// Build configuration for Fermi LAT Binned Likelihood Benchmark Tool

const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options
    const target = b.standardTargetOptions(.{
        .default_target = .{},
    });

    // Standard optimization options
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });

    // Main executable
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/fermi_binned_likelihood_benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });

    const exe = b.addExecutable(.{
        .name = "fermi_benchmark",
        .root_module = root_module,
    });

    // Install the executable
    b.installArtifact(exe);

    // Create a run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Create the "run" step
    const run_step = b.step("run", "Run the Fermi benchmark tool");
    run_step.dependOn(&run_cmd.step);

    // Create a dry-run step for convenience
    const dry_run_cmd = b.addRunArtifact(exe);
    dry_run_cmd.step.dependOn(b.getInstallStep());
    dry_run_cmd.addArgs(&.{"--dry-run"});

    const dry_run_step = b.step("dry-run", "Run in dry-run mode (print commands without executing)");
    dry_run_step.dependOn(&dry_run_cmd.step);

    // Create a verbose run step
    const verbose_cmd = b.addRunArtifact(exe);
    verbose_cmd.step.dependOn(b.getInstallStep());
    verbose_cmd.addArgs(&.{ "--verbose", "--dry-run" });

    const verbose_step = b.step("verbose", "Run in verbose dry-run mode");
    verbose_step.dependOn(&verbose_cmd.step);

    // Unit tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/fermi_binned_likelihood_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Documentation generation
    const docs_module = b.createModule(.{
        .root_source_file = b.path("src/fermi_binned_likelihood_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });

    const docs = b.addLibrary(.{
        .name = "fermi_benchmark_docs",
        .root_module = docs_module,
        .linkage = .static,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // Check step (compile without producing output - useful for CI)
    const check_module = b.createModule(.{
        .root_source_file = b.path("src/fermi_binned_likelihood_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });

    const check = b.addExecutable(.{
        .name = "fermi_benchmark",
        .root_module = check_module,
    });

    const check_step = b.step("check", "Check if the code compiles");
    check_step.dependOn(&check.step);

    // Add format check step
    const fmt = b.addFmt(.{
        .paths = &.{
            b.path("src/fermi_binned_likelihood_benchmark.zig"),
            b.path("build.zig"),
        },
        .check = true,
    });

    const fmt_step = b.step("fmt-check", "Check code formatting");
    fmt_step.dependOn(&fmt.step);

    // Add format fix step
    const fmt_fix = b.addFmt(.{
        .paths = &.{
            b.path("src/fermi_binned_likelihood_benchmark.zig"),
            b.path("build.zig"),
        },
        .check = false,
    });

    const fmt_fix_step = b.step("fmt", "Fix code formatting");
    fmt_fix_step.dependOn(&fmt_fix.step);
}
