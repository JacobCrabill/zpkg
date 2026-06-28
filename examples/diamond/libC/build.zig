const std = @import("std");
const zpkg_build = @import("zpkg-build");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- zpkg-build: register targets and emit graph ---
    var pkg = zpkg_build.Package.init(b.allocator, "diamond.libC", "target", "0.1.0.0");

    _ = pkg.addTarget("libC", .library, .static, true) catch |err| {
        std.debug.print("zpkg-build: addTarget failed: {}\n", .{err});
        return;
    };
    pkg.addIncludeDir("libC", .{ .path = "include", .visibility = .public }) catch |err| {
        std.debug.print("zpkg-build: addIncludeDir failed: {}\n", .{err});
        return;
    };
    pkg.addArtifact("libC", "libC.a") catch |err| {
        std.debug.print("zpkg-build: addArtifact failed: {}\n", .{err});
        return;
    };
    pkg.addEdge("libC", .{
        .dep_alias = "libA",
        .target_name = "libA",
        .role = .link,
    }) catch |err| {
        std.debug.print("zpkg-build: addEdge failed: {}\n", .{err});
        return;
    };
    pkg.addDepAlias("libA", "diamond.libA") catch |err| {
        std.debug.print("zpkg-build: addDepAlias failed: {}\n", .{err});
        return;
    };

    pkg.emit(b.graph.io, b.pathFromRoot("zpkg.graph.zon")) catch |err| {
        std.debug.print("zpkg-build: emit failed: {}\n", .{err});
    };

    // --- Standard Zig build artifacts ---

    const libA_dep = b.dependency("libA", .{ .target = target, .optimize = optimize });
    const libA_art = libA_dep.artifact("A");

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    mod.addCSourceFile(.{ .file = b.path("src/libC.c"), .flags = &.{} });
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(libA_dep.path("include"));
    mod.linkLibrary(libA_art);

    const lib = b.addLibrary(.{
        .name = "C",
        .linkage = .static,
        .root_module = mod,
    });
    lib.installHeader(b.path("include/libC.h"), "libC.h");
    b.installArtifact(lib);
}
