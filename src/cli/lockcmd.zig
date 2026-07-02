const std = @import("std");
const conditions = @import("../model/conditions.zig");
const schema = @import("../schema/zpkg.zig");
const resolve = @import("../resolve/root.zig");
const lockgen = @import("../resolve/lockgen.zig");
const diag = @import("../util/diag.zig");

/// Which command is driving: `create` is `zpkg lock` (refuses to clobber an
/// existing lockfile), `update` is `zpkg update` (rewrites in place, supports
/// `--dry-run`). The resolution + lockfile generation is identical either way.
pub const Mode = enum { create, update };

/// Shared implementation of `zpkg lock` and `zpkg update`. The two commands
/// differ only in a few mode-gated points (existing-lockfile check, `--dry-run`,
/// usage text, and the success message); everything else is common.
pub fn run(mode: Mode, args: []const []const u8, io: std.Io, help_text: []const u8) !void {
    if (args.len >= 3 and (std.mem.eql(u8, args[2], "--help") or std.mem.eql(u8, args[2], "-h"))) {
        return diag.writeHelp(io, help_text);
    }
    if (args.len < 3) {
        try usageError(io, mode);
        return error.InvalidArgument;
    }

    // `update` accepts an optional trailing `--dry-run`; `lock` takes no flags.
    var dry_run = false;
    switch (mode) {
        .create => if (args.len != 3) {
            try usageError(io, mode);
            return error.InvalidArgument;
        },
        .update => {
            if (args.len == 4 and std.mem.eql(u8, args[3], "--dry-run")) {
                dry_run = true;
            } else if (args.len != 3) {
                try usageError(io, mode);
                return error.InvalidArgument;
            }
        },
    }

    const allocator = std.heap.page_allocator;
    const pkg_root_raw = args[2];

    // Resolve the package root to an absolute path so it serves as the base for
    // computing relative source_path values in the lockfile.
    const pkg_root = diag.resolveAbsPath(allocator, pkg_root_raw) catch |err| {
        try diag.writeError(io, "cannot resolve path '{s}': {s}", .{ pkg_root_raw, @errorName(err) });
        return error.InvalidArgument;
    };
    defer allocator.free(pkg_root);

    var dir = std.Io.Dir.cwd().openDir(io, pkg_root, .{}) catch |err| {
        try diag.writeError(io, "cannot open package root '{s}': {s}", .{ pkg_root, @errorName(err) });
        return error.InvalidArgument;
    };
    defer dir.close(io);

    // `lock` refuses to overwrite an existing lockfile; `update` rewrites it.
    if (mode == .create and lockfileExists(io, dir)) {
        try diag.writeError(io, "lockfile already exists", .{});
        try diag.writeHint(io, "use 'zpkg update <pkg-root>' to refresh an existing lockfile", .{});
        return error.LockfileExists;
    }

    // Parse manifest.
    var manifest = schema.parseFileAlloc(allocator, dir, io, "zpkg.zon") catch |err| {
        const diagnostic = schema.formatDiagnosticAlloc(allocator, "zpkg.zon", err) catch "";
        defer allocator.free(diagnostic);
        try diag.writeStderr(io, diagnostic);
        try diag.writeHint(io, "is '{s}' a zpkg package? it needs a valid zpkg.zon", .{pkg_root});
        return error.InvalidArgument;
    };
    defer manifest.deinitOwned(allocator);

    // Resolve packages for the native host. Cross-target resolution is deferred
    // (see docs/profile-target-axis-plan.md); the build profile is a separate axis.
    const environment = conditions.detectHost();

    var resolver = resolve.Resolver.init(allocator, environment.host_os, environment.host_arch, environment.target_os, environment.target_arch, &.{}, pkg_root, io);
    defer resolver.deinit();

    const resolved = resolver.resolveRoot(manifest) catch |err| {
        try diag.writeError(io, "failed to resolve packages: {s}", .{@errorName(err)});
        return error.InvalidArgument;
    };

    // Generate lockfile.
    const lockfile = lockgen.generateLockfile(allocator, io, pkg_root, resolved, &resolver) catch |err| {
        try diag.writeError(io, "failed to generate lockfile: {s}", .{@errorName(err)});
        return error.OutOfMemory;
    };
    defer lockfile.deinit(allocator);

    const lockfile_content = lockfile.toZonAlloc(allocator) catch |err| {
        try diag.writeError(io, "failed to serialize lockfile: {s}", .{@errorName(err)});
        return error.OutOfMemory;
    };
    defer allocator.free(lockfile_content);

    // `--dry-run` prints the lockfile instead of writing it.
    if (dry_run) {
        try diag.writeStdout(io, lockfile_content);
        return;
    }

    const file = dir.createFile(io, "zpkg.lock.zon", .{}) catch |err| {
        try diag.writeError(io, "failed to write lockfile: {s}", .{@errorName(err)});
        return error.InvalidArgument;
    };
    defer file.close(io);

    try std.Io.File.writeStreamingAll(file, io, lockfile_content);

    try diag.writeStdout(io, switch (mode) {
        .create => "Lockfile created: zpkg.lock.zon\n",
        .update => "Lockfile updated: zpkg.lock.zon\n",
    });
}

fn lockfileExists(io: std.Io, dir: std.Io.Dir) bool {
    const f = dir.openFile(io, "zpkg.lock.zon", .{}) catch return false;
    f.close(io);
    return true;
}

fn usageError(io: std.Io, mode: Mode) !void {
    switch (mode) {
        .create => {
            try diag.writeError(io, "lock expects exactly one package root path", .{});
            try diag.writeHint(io, "usage: zpkg lock <pkg-root>", .{});
        },
        .update => {
            try diag.writeError(io, "update expects exactly one package root path", .{});
            try diag.writeHint(io, "usage: zpkg update <pkg-root> [--dry-run]", .{});
        },
    }
}
