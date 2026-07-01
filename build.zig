const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zpkg_mod = b.addModule("zpkg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "zpkg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zpkg", .module = zpkg_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the zpkg CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const module_tests = b.addTest(.{
        .root_module = zpkg_mod,
    });
    const run_module_tests = b.addRunArtifact(module_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // End-to-end integration test: drives the real CLI against the diamond
    // example (lock → build → run → rebuild → realize). Kept as its own step so
    // the common `zig build test` loop stays fast and toolchain-light; this step
    // shells out to `zig build` internally and needs a C toolchain.
    const integration_cmd = b.addSystemCommand(&.{ "bash", "test/integration/diamond.sh" });
    integration_cmd.setEnvironmentVariable("ZPKG_BIN", b.getInstallPath(.bin, "zpkg"));
    integration_cmd.step.dependOn(b.getInstallStep());
    // Never cached: the script mutates the example working tree.
    integration_cmd.has_side_effects = true;

    const integration_step = b.step("integration", "Run the diamond end-to-end integration test");
    integration_step.dependOn(&integration_cmd.step);
}
