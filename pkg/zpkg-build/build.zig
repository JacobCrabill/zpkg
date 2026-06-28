const std = @import("std");

// Re-export the public API so that consuming build.zig files can do:
//   const zpkg_build = @import("zpkg-build");
//   var pkg = zpkg_build.Package.init(...);
pub const Package = @import("src/root.zig").Package;
pub const RegisteredTarget = @import("src/root.zig").RegisteredTarget;
pub const TargetKind = @import("src/root.zig").TargetKind;
pub const Linkage = @import("src/root.zig").Linkage;
pub const EdgeRole = @import("src/root.zig").EdgeRole;
pub const Visibility = @import("src/root.zig").Visibility;
pub const TargetEdge = @import("src/root.zig").TargetEdge;
pub const IncludeDir = @import("src/root.zig").IncludeDir;
pub const CompileDefinition = @import("src/root.zig").CompileDefinition;
pub const OptionSnapshot = @import("src/root.zig").OptionSnapshot;
pub const DepAliasEntry = @import("src/root.zig").DepAliasEntry;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addModule("zpkg-build", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = lib;

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run zpkg-build tests");
    test_step.dependOn(&run_tests.step);
}
