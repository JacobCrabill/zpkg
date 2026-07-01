const std = @import("std");
const zpkg_schema = @import("../schema/zpkg.zig");
const diag = @import("../util/diag.zig");

pub const help_text =
    \\zpkg inspect — Inspect package metadata from zpkg.zon
    \\
    \\Usage:
    \\  zpkg inspect <pkg-root>
    \\
    \\Arguments:
    \\  <pkg-root>   Path to the package directory containing zpkg.zon
    \\
    \\Example:
    \\  zpkg inspect .
    \\
;

pub fn run(args: []const []const u8, io: std.Io) !void {
    if (args.len >= 3 and (std.mem.eql(u8, args[2], "--help") or std.mem.eql(u8, args[2], "-h"))) {
        return writeHelp(io);
    }
    if (args.len != 3) {
        try writeUsageError(io);
        return error.InvalidArgument;
    }

    const allocator = std.heap.page_allocator;
    const pkg_root = args[2];
    const normalized = try inspectPackageAllocForCli(allocator, pkg_root, io);
    defer allocator.free(normalized);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer_file.interface;
    try stdout.writeAll(normalized);
    try stdout.flush();
}

pub fn inspectPackageAlloc(allocator: std.mem.Allocator, pkg_root: []const u8, io: std.Io) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, pkg_root, .{});
    defer dir.close(io);

    var manifest = try zpkg_schema.parseFileAlloc(allocator, dir, io, "zpkg.zon");
    defer manifest.deinitOwned(allocator);

    return zpkg_schema.formatNormalizedAlloc(allocator, manifest);
}

fn inspectPackageAllocForCli(allocator: std.mem.Allocator, pkg_root: []const u8, io: std.Io) ![]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, pkg_root, .{}) catch |err| {
        try writePackageRootError(io, pkg_root, err);
        return error.InvalidArgument;
    };
    defer dir.close(io);

    const manifest_rel_path = "zpkg.zon";
    const manifest_path = try std.fs.path.join(allocator, &.{ pkg_root, manifest_rel_path });
    defer allocator.free(manifest_path);

    const manifest_file = dir.openFile(io, manifest_rel_path, .{}) catch |err| {
        try writeMissingManifestError(io, manifest_path, err);
        return error.InvalidArgument;
    };
    manifest_file.close(io);

    var manifest = zpkg_schema.parseFileAlloc(allocator, dir, io, manifest_rel_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const diagnostic = try zpkg_schema.formatDiagnosticAlloc(allocator, manifest_path, err);
            defer allocator.free(diagnostic);
            try writeStderr(io, diagnostic);
            return error.InvalidArgument;
        },
    };
    defer manifest.deinitOwned(allocator);

    return zpkg_schema.formatNormalizedAlloc(allocator, manifest);
}

fn writeHelp(io: std.Io) !void {
    try diag.writeHelp(io, help_text);
}

fn writeUsageError(io: std.Io) !void {
    try writeStderr(io,
        "error: inspect expects exactly one package root path\n" ++
        "usage: zpkg inspect <pkg-root>\n");
}

fn writePackageRootError(io: std.Io, pkg_root: []const u8, err: anyerror) !void {
    try writeStderrFmt(io, "error: cannot open package root {s}: {s}\n", .{ pkg_root, @errorName(err) });
}

fn writeMissingManifestError(io: std.Io, manifest_path: []const u8, err: anyerror) !void {
    try writeStderrFmt(io, "error: cannot open manifest {s}: {s}\n", .{ manifest_path, @errorName(err) });
}

const writeStderr = diag.writeStderr;
const writeStderrFmt = diag.writeStderrFmt;

test "inspect renders normalized hello-lib manifest" {
    const allocator = std.testing.allocator;
    const rendered = try inspectPackageAlloc(allocator, "examples/hello-lib", std.testing.io);
    defer allocator.free(rendered);

    const expected = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/golden/schema/hello-lib.normalized.zon", allocator, .limited(64 * 1024));
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, rendered);
}
