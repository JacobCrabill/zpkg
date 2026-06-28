const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libC_dep = b.dependency("libC", .{ .target = target, .optimize = optimize });
    const libD_dep = b.dependency("libD", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{ .target = target, .optimize = optimize });
    mod.addCSourceFile(.{ .file = b.path("src/libE.c"), .flags = &.{} });
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(libC_dep.path("include"));
    mod.addIncludePath(libD_dep.path("include"));
    mod.linkLibrary(libC_dep.artifact("C"));
    mod.linkLibrary(libD_dep.artifact("D"));

    const lib = b.addLibrary(.{ .name = "E", .root_module = mod, .linkage = .static });
    b.installArtifact(lib);
    b.installDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .header,
        .install_subdir = "",
    });
}
