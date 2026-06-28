const std = @import("std");
const zpkg_build = @import("zpkg-build");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- zpkg-build: register targets and emit graph ---
    var pkg = zpkg_build.Package.init(
        b.allocator,
        "zpkg.example.hello_tool",
        "target",
        "0.1.0.0",
    );
    // Note: pkg.deinit() is intentionally not called here; the build
    // arena owns the lifetime and will free everything on exit.

    _ = pkg.addTarget("hello_tool", .executable, .default, true) catch |err| {
        std.debug.print("zpkg-build: addTarget failed: {}\n", .{err});
        return;
    };
    pkg.addArtifact("hello_tool", "hello-tool") catch |err| {
        std.debug.print("zpkg-build: addArtifact failed: {}\n", .{err});
        return;
    };

    pkg.emit(b.graph.io, "zpkg.graph.zon") catch |err| {
        std.debug.print("zpkg-build: emit failed: {}\n", .{err});
    };

    // --- Standard Zig build artifacts ---

    const exe = b.addExecutable(.{
        .name = "hello-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the hello-tool example");
    run_step.dependOn(&run_cmd.step);
}
