const std = @import("std");
const zpkg_build = @import("zpkg-build");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- zpkg-build: register targets and emit graph ---
    var pkg = zpkg_build.Package.init(
        b.allocator,
        "zpkg.example.hello_tests",
        "target",
        "0.1.0.0",
    );
    // Note: pkg.deinit() is intentionally not called here; the build
    // arena owns the lifetime and will free everything on exit.

    _ = pkg.addTarget("hello_tests", .executable, .default, true) catch |err| {
        std.debug.print("zpkg-build: addTarget failed: {}\n", .{err});
        return;
    };
    pkg.addEdge("hello_tests", .{
        .dep_alias = "hello_lib",
        .target_name = "hello",
        .role = .test_dep,
    }) catch |err| {
        std.debug.print("zpkg-build: addEdge failed: {}\n", .{err});
        return;
    };
    pkg.addEdge("hello_tests", .{
        .dep_alias = "hello_tool",
        .target_name = "hello_tool",
        .role = .tool,
    }) catch |err| {
        std.debug.print("zpkg-build: addEdge failed: {}\n", .{err});
        return;
    };
    pkg.addDepAlias("hello_lib", "zpkg.example.hello_lib") catch |err| {
        std.debug.print("zpkg-build: addDepAlias failed: {}\n", .{err});
        return;
    };
    pkg.addDepAlias("hello_tool", "zpkg.example.hello_tool") catch |err| {
        std.debug.print("zpkg-build: addDepAlias failed: {}\n", .{err});
        return;
    };
    pkg.addOption("build_tests", "true") catch |err| {
        std.debug.print("zpkg-build: addOption failed: {}\n", .{err});
        return;
    };

    pkg.emit(b.graph.io, "zpkg.graph.zon") catch |err| {
        std.debug.print("zpkg-build: emit failed: {}\n", .{err});
    };

    // --- Standard Zig build artifacts ---

    const exe = b.addExecutable(.{
        .name = "hello-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run the hello-tests example tests");
    test_step.dependOn(&run_unit_tests.step);
}
