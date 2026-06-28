const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{ .target = target, .optimize = optimize });
    mod.addCSourceFile(.{ .file = b.path("src/libB.c"), .flags = &.{} });
    mod.addIncludePath(b.path("include"));

    const lib = b.addLibrary(.{ .name = "B", .root_module = mod, .linkage = .static });
    b.installArtifact(lib);
    b.installDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .header,
        .install_subdir = "",
    });
}
