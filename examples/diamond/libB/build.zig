const std = @import("std");
const zpkg_build = @import("zpkg-build");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- zpkg-build: register targets and emit graph ---
    var pkg = zpkg_build.Package.init(b.allocator, "diamond.libB", "target", "0.1.0.0");

    _ = pkg.addTarget("libB", .library, .static, true) catch |err| {
        std.debug.print("zpkg-build: addTarget failed: {}\n", .{err});
        return;
    };
    pkg.addIncludeDir("libB", .{ .path = "include", .visibility = .public }) catch |err| {
        std.debug.print("zpkg-build: addIncludeDir failed: {}\n", .{err});
        return;
    };
    pkg.addArtifact("libB", "libB.a") catch |err| {
        std.debug.print("zpkg-build: addArtifact failed: {}\n", .{err});
        return;
    };

    pkg.emit(b.graph.io, b.pathFromRoot("zpkg.graph.zon")) catch |err| {
        std.debug.print("zpkg-build: emit failed: {}\n", .{err});
    };

    // --- Standard Zig build artifacts ---

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    mod.addCSourceFile(.{ .file = b.path("src/libB.c"), .flags = &.{} });
    mod.addIncludePath(b.path("include"));

    const lib = b.addLibrary(.{
        .name = "B",
        .linkage = .static,
        .root_module = mod,
    });
    lib.installHeader(b.path("include/libB.h"), "libB.h");
    b.installArtifact(lib);
}
