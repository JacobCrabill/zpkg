const std = @import("std");
const zpkg_build = @import("zpkg-build");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- zpkg-build: register targets and emit graph ---
    var pkg = zpkg_build.Package.init(b.allocator, "diamond.libE", "target", "0.1.0.0");

    _ = pkg.addTarget("libE", .library, .static, true) catch |err| {
        std.debug.print("zpkg-build: addTarget failed: {}\n", .{err});
        return;
    };
    pkg.addIncludeDir("libE", .{ .path = "include", .visibility = .public }) catch |err| {
        std.debug.print("zpkg-build: addIncludeDir failed: {}\n", .{err});
        return;
    };
    pkg.addArtifact("libE", "libE.a") catch |err| {
        std.debug.print("zpkg-build: addArtifact failed: {}\n", .{err});
        return;
    };
    pkg.addEdge("libE", .{
        .dep_alias = "libC",
        .target_name = "libC",
        .role = .link,
    }) catch |err| {
        std.debug.print("zpkg-build: addEdge failed: {}\n", .{err});
        return;
    };
    pkg.addEdge("libE", .{
        .dep_alias = "libD",
        .target_name = "libD",
        .role = .link,
    }) catch |err| {
        std.debug.print("zpkg-build: addEdge failed: {}\n", .{err});
        return;
    };
    pkg.addDepAlias("libC", "diamond.libC") catch |err| {
        std.debug.print("zpkg-build: addDepAlias failed: {}\n", .{err});
        return;
    };
    pkg.addDepAlias("libD", "diamond.libD") catch |err| {
        std.debug.print("zpkg-build: addDepAlias failed: {}\n", .{err});
        return;
    };

    pkg.emit(b.graph.io, b.pathFromRoot("zpkg.graph.zon")) catch |err| {
        std.debug.print("zpkg-build: emit failed: {}\n", .{err});
    };

    // --- Standard Zig build artifacts ---

    const libC_dep = b.dependency("libC", .{ .target = target, .optimize = optimize });
    const libC_art = libC_dep.artifact("C");

    const libD_dep = b.dependency("libD", .{ .target = target, .optimize = optimize });
    const libD_art = libD_dep.artifact("D");

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    mod.addCSourceFile(.{ .file = b.path("src/libE.c"), .flags = &.{} });
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(libC_dep.path("include"));
    mod.addIncludePath(libD_dep.path("include"));
    mod.linkLibrary(libC_art);
    mod.linkLibrary(libD_art);

    const lib = b.addLibrary(.{
        .name = "E",
        .linkage = .static,
        .root_module = mod,
    });
    lib.installHeader(b.path("include/libE.h"), "libE.h");
    b.installArtifact(lib);
}
