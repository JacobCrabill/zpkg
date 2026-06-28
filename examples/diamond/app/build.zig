const std = @import("std");
const zpkg_build = @import("zpkg-build");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- zpkg-build: register targets and emit graph ---
    var pkg = zpkg_build.Package.init(b.allocator, "diamond.app", "target", "0.1.0.0");

    _ = pkg.addTarget("app", .executable, .default, true) catch |err| {
        std.debug.print("zpkg-build: addTarget failed: {}\n", .{err});
        return;
    };
    pkg.addArtifact("app", "app") catch |err| {
        std.debug.print("zpkg-build: addArtifact failed: {}\n", .{err});
        return;
    };
    pkg.addEdge("app", .{
        .dep_alias = "libE",
        .target_name = "libE",
        .role = .link,
    }) catch |err| {
        std.debug.print("zpkg-build: addEdge failed: {}\n", .{err});
        return;
    };
    pkg.addDepAlias("libE", "diamond.libE") catch |err| {
        std.debug.print("zpkg-build: addDepAlias failed: {}\n", .{err});
        return;
    };

    pkg.emit(b.graph.io, b.pathFromRoot("zpkg.graph.zon")) catch |err| {
        std.debug.print("zpkg-build: emit failed: {}\n", .{err});
    };

    // --- Standard Zig build artifacts ---

    const libE_dep = b.dependency("libE", .{ .target = target, .optimize = optimize });
    const libE_art = libE_dep.artifact("E");

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addCSourceFile(.{ .file = b.path("src/main.c"), .flags = &.{} });
    mod.addIncludePath(libE_dep.path("include"));
    mod.linkLibrary(libE_art);

    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the diamond app example");
    run_step.dependOn(&run_cmd.step);
}
