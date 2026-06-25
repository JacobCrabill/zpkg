const std = @import("std");

pub fn build(b: *std.Build) void {
    const install_headers = b.addInstallDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .prefix,
        .install_subdir = "include",
    });
    b.getInstallStep().dependOn(&install_headers.step);
}
