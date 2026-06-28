const std = @import("std");
const zpkg_build = @import("zpkg-build");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- zpkg-build: register targets and emit graph ---
    var pkg = zpkg_build.Package.init(
        b.allocator,
        "zpkg.example.hello_lib",
        "target",
        "0.1.0.0",
    );
    // Note: pkg.deinit() is intentionally not called here; the build
    // arena owns the lifetime and will free everything on exit.

    _ = pkg.addTarget("hello", .library, .dynamic, true) catch |err| {
        std.debug.print("zpkg-build: addTarget failed: {}\n", .{err});
        return;
    };
    pkg.addIncludeDir("hello", .{ .path = "include", .visibility = .public }) catch |err| {
        std.debug.print("zpkg-build: addIncludeDir failed: {}\n", .{err});
        return;
    };
    pkg.addArtifact("hello", "libhello.so") catch |err| {
        std.debug.print("zpkg-build: addArtifact failed: {}\n", .{err});
        return;
    };

    _ = pkg.addTarget("hello_headers", .headers, .default, true) catch |err| {
        std.debug.print("zpkg-build: addTarget failed: {}\n", .{err});
        return;
    };

    _ = pkg.addTarget("hello_assets", .resource_set, .default, true) catch |err| {
        std.debug.print("zpkg-build: addTarget failed: {}\n", .{err});
        return;
    };

    // Record the build option snapshot for this instance
    pkg.addOption("shared", "true") catch |err| {
        std.debug.print("zpkg-build: addOption failed: {}\n", .{err});
        return;
    };

    pkg.emit(b.graph.io, "zpkg.graph.zon") catch |err| {
        std.debug.print("zpkg-build: emit failed: {}\n", .{err});
    };

    // --- Standard Zig build artifacts ---

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

    const unit_tests = b.addTest(.{
        .root_module = lib.root_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run hello-lib tests");
    test_step.dependOn(&run_unit_tests.step);
}
