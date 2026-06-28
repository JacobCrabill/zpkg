const std = @import("std");
const zpkg_build = @import("zpkg-build");

pub fn build(b: *std.Build) void {
    // --- zpkg-build: register targets and emit graph ---
    var pkg = zpkg_build.Package.init(
        b.allocator,
        "zpkg.example.hello_headers",
        "target",
        "0.1.0.0",
    );
    // Note: pkg.deinit() is intentionally not called here; the build
    // arena owns the lifetime and will free everything on exit.

    _ = pkg.addTarget("hello_headers", .headers, .default, true) catch |err| {
        std.debug.print("zpkg-build: addTarget failed: {}\n", .{err});
        return;
    };
    pkg.addIncludeDir("hello_headers", .{ .path = "include", .visibility = .public }) catch |err| {
        std.debug.print("zpkg-build: addIncludeDir failed: {}\n", .{err});
        return;
    };

    pkg.emit(b.graph.io, "zpkg.graph.zon") catch |err| {
        std.debug.print("zpkg-build: emit failed: {}\n", .{err});
    };

    // --- Standard Zig build artifacts ---

    const install_headers = b.addInstallDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .prefix,
        .install_subdir = "include",
    });
    b.getInstallStep().dependOn(&install_headers.step);
}
