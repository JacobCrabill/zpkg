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
    const normalized = try inspectPackageAlloc(allocator, args[2], io, true);
    defer allocator.free(normalized);

    try diag.writeStdout(io, normalized);
}

/// Parse `<pkg_root>/zpkg.zon` and return its normalized rendering (caller owns).
///
/// When `diagnostics` is true, human-readable errors are written to stderr and
/// failures collapse to `error.InvalidArgument` (CLI use); when false, the
/// underlying errors propagate unchanged (test use).
pub fn inspectPackageAlloc(
    allocator: std.mem.Allocator,
    pkg_root: []const u8,
    io: std.Io,
    diagnostics: bool,
) ![]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, pkg_root, .{}) catch |err| {
        if (!diagnostics) return err;
        try diag.writeError(io, "cannot open package root '{s}': {s}", .{ pkg_root, @errorName(err) });
        return error.InvalidArgument;
    };
    defer dir.close(io);

    if (diagnostics) {
        // Give a targeted message when zpkg.zon itself is missing.
        const f = dir.openFile(io, "zpkg.zon", .{}) catch {
            try diag.writeManifestMissingError(io, pkg_root);
            return error.InvalidArgument;
        };
        f.close(io);
    }

    var manifest = zpkg_schema.parseFileAlloc(allocator, dir, io, "zpkg.zon") catch |err| {
        if (!diagnostics or err == error.OutOfMemory) return err;
        const manifest_path = try std.fs.path.join(allocator, &.{ pkg_root, "zpkg.zon" });
        defer allocator.free(manifest_path);
        const diagnostic = try zpkg_schema.formatDiagnosticAlloc(allocator, manifest_path, err);
        defer allocator.free(diagnostic);
        try writeStderr(io, diagnostic);
        try diag.writeHint(io, "is '{s}' a zpkg package? it needs a valid zpkg.zon", .{pkg_root});
        return error.InvalidArgument;
    };
    defer manifest.deinitOwned(allocator);

    return zpkg_schema.formatNormalizedAlloc(allocator, manifest);
}

fn writeHelp(io: std.Io) !void {
    try diag.writeHelp(io, help_text);
}

fn writeUsageError(io: std.Io) !void {
    try diag.writeError(io, "inspect expects exactly one package root path", .{});
    try diag.writeHint(io, "usage: zpkg inspect <pkg-root>", .{});
}

const writeStderr = diag.writeStderr;
const writeStderrFmt = diag.writeStderrFmt;

test "inspect renders normalized hello-lib manifest" {
    const allocator = std.testing.allocator;
    const rendered = try inspectPackageAlloc(allocator, "examples/hello-lib", std.testing.io, false);
    defer allocator.free(rendered);

    const expected = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/golden/schema/hello-lib.normalized.zon", allocator, .limited(64 * 1024));
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, rendered);
}
