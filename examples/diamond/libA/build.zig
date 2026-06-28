const std = @import("std");
const zpkg_build = @import("zpkg-build");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- zpkg-build: register targets and emit graph ---
    var pkg = zpkg_build.Package.init(b.allocator, "diamond.libA", "target", "0.1.0.0");

    _ = pkg.addTarget("libA", .library, .static, true) catch |err| {
        std.debug.print("zpkg-build: addTarget failed: {}\n", .{err});
        return;
    };
    pkg.addIncludeDir("libA", .{ .path = "include", .visibility = .public }) catch |err| {
        std.debug.print("zpkg-build: addIncludeDir failed: {}\n", .{err});
        return;
    };
    pkg.addArtifact("libA", "libA.a") catch |err| {
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
    mod.addCSourceFile(.{ .file = b.path("src/libA.c"), .flags = &.{} });
    mod.addIncludePath(b.path("include"));

    const lib = b.addLibrary(.{
        .name = "A",
        .linkage = .static,
        .root_module = mod,
    });
    lib.installHeader(b.path("include/libA.h"), "libA.h");
    b.installArtifact(lib);
}
