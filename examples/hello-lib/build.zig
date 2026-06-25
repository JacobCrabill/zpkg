const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "hello",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);

    const install_headers = b.addInstallDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .prefix,
        .install_subdir = "include",
    });
    b.getInstallStep().dependOn(&install_headers.step);

    const install_resources = b.addInstallDirectory(.{
        .source_dir = b.path("resources"),
        .install_dir = .prefix,
        .install_subdir = "share/hello-lib",
    });
    b.getInstallStep().dependOn(&install_resources.step);
}
