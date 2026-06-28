const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libA_dep = b.dependency("libA", .{ .target = target, .optimize = optimize });
    const libB_dep = b.dependency("libB", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{ .target = target, .optimize = optimize });
    mod.addCSourceFile(.{ .file = b.path("src/libD.c"), .flags = &.{} });
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(libA_dep.path("include"));
    mod.addIncludePath(libB_dep.path("include"));
    mod.linkLibrary(libA_dep.artifact("A"));
    mod.linkLibrary(libB_dep.artifact("B"));

    const lib = b.addLibrary(.{ .name = "D", .root_module = mod, .linkage = .static });
    b.installArtifact(lib);
    b.installDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .header,
        .install_subdir = "",
    });
}
