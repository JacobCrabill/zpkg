const std = @import("std");
const zpkg_build = @import("zpkg-build");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- zpkg-build: register targets and emit graph ---
    var pkg = zpkg_build.Package.init(b.allocator, "diamond.libD", "target", "0.1.0.0");

    _ = pkg.addTarget("libD", .library, .static, true) catch |err| {
        std.debug.print("zpkg-build: addTarget failed: {}\n", .{err});
        return;
    };
    pkg.addIncludeDir("libD", .{ .path = "include", .visibility = .public }) catch |err| {
        std.debug.print("zpkg-build: addIncludeDir failed: {}\n", .{err});
        return;
    };
    pkg.addArtifact("libD", "libD.a") catch |err| {
        std.debug.print("zpkg-build: addArtifact failed: {}\n", .{err});
        return;
    };
    pkg.addEdge("libD", .{
        .dep_alias = "libA",
        .target_name = "libA",
        .role = .link,
    }) catch |err| {
        std.debug.print("zpkg-build: addEdge failed: {}\n", .{err});
        return;
    };
    pkg.addEdge("libD", .{
        .dep_alias = "libB",
        .target_name = "libB",
        .role = .link,
    }) catch |err| {
        std.debug.print("zpkg-build: addEdge failed: {}\n", .{err});
        return;
    };
    pkg.addDepAlias("libA", "diamond.libA") catch |err| {
        std.debug.print("zpkg-build: addDepAlias failed: {}\n", .{err});
        return;
    };
    pkg.addDepAlias("libB", "diamond.libB") catch |err| {
        std.debug.print("zpkg-build: addDepAlias failed: {}\n", .{err});
        return;
    };

    pkg.emit(b.graph.io, b.pathFromRoot("zpkg.graph.zon")) catch |err| {
        std.debug.print("zpkg-build: emit failed: {}\n", .{err});
    };

    // --- Standard Zig build artifacts ---

    const libA_dep = b.dependency("libA", .{ .target = target, .optimize = optimize });
    const libA_art = libA_dep.artifact("A");

    const libB_dep = b.dependency("libB", .{ .target = target, .optimize = optimize });
    const libB_art = libB_dep.artifact("B");

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    mod.addCSourceFile(.{ .file = b.path("src/libD.c"), .flags = &.{} });
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(libA_dep.path("include"));
    mod.addIncludePath(libB_dep.path("include"));
    mod.linkLibrary(libA_art);
    mod.linkLibrary(libB_art);

    const lib = b.addLibrary(.{
        .name = "D",
        .linkage = .static,
        .root_module = mod,
    });
    lib.installHeader(b.path("include/libD.h"), "libD.h");
    b.installArtifact(lib);
}
