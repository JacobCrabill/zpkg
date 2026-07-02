const std = @import("std");
const model = @import("../model/root.zig");
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

    // Resolve + generate the lockfile.
    const lockfile = resolveLockfile(allocator, io, pkg_root, manifest) catch |err| {
        try diag.writeError(io, "failed to resolve dependencies: {s}", .{@errorName(err)});
        return error.InvalidArgument;
    };
    defer lockfile.deinit(allocator);

    // `--dry-run` prints the lockfile instead of writing it.
    if (dry_run) {
        const content = lockfile.toZonAlloc(allocator) catch |err| {
            try diag.writeError(io, "failed to serialize lockfile: {s}", .{@errorName(err)});
            return error.OutOfMemory;
        };
        defer allocator.free(content);
        try diag.writeStdout(io, content);
        return;
    }

    writeLockfileToDir(allocator, io, dir, lockfile) catch |err| {
        try diag.writeError(io, "failed to write lockfile: {s}", .{@errorName(err)});
        return error.InvalidArgument;
    };

    try diag.writeStdout(io, switch (mode) {
        .create => "Lockfile created: zpkg.lock.zon\n",
        .update => "Lockfile updated: zpkg.lock.zon\n",
    });
}

/// Resolve the package at `pkg_root` for the native host and build a Lockfile in
/// memory. Caller owns the result (`lockfile.deinit(allocator)`). Cross-target
/// resolution is deferred (see docs/profile-target-axis-plan.md); the build
/// profile is a separate axis. Shared by `lock`/`update` and `build`'s auto-lock.
pub fn resolveLockfile(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_root: []const u8,
    manifest: schema.Manifest,
) !model.Lockfile {
    const environment = conditions.detectHost();
    var resolver = resolve.Resolver.init(allocator, environment.host_os, environment.host_arch, environment.target_os, environment.target_arch, &.{}, pkg_root, io);
    defer resolver.deinit();
    const resolved = try resolver.resolveRoot(manifest);
    // generateLockfile clones everything it needs, so the resolver may be freed after.
    return lockgen.generateLockfile(allocator, io, pkg_root, resolved, &resolver);
}

/// Serialize `lockfile` and write it to `<dir>/zpkg.lock.zon`.
pub fn writeLockfileToDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    lockfile: model.Lockfile,
) !void {
    const content = try lockfile.toZonAlloc(allocator);
    defer allocator.free(content);
    const file = try dir.createFile(io, "zpkg.lock.zon", .{});
    defer file.close(io);
    try std.Io.File.writeStreamingAll(file, io, content);
}

pub fn lockfileExists(io: std.Io, dir: std.Io.Dir) bool {
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
