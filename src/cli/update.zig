const std = @import("std");
const model = @import("../model/root.zig");
const conditions = @import("../model/conditions.zig");
const schema = @import("../schema/zpkg.zig");
const resolve = @import("../resolve/root.zig");
const source_hash = @import("../hash/source_hash.zig");
const drift = @import("../resolve/drift.zig");
const diag_util = @import("../util/diag.zig");

pub const help_text =
    \\zpkg update — Update an existing lockfile in place
    \\
    \\Usage:
    \\  zpkg update <pkg-root> [--dry-run]
    \\
    \\Arguments:
    \\  <pkg-root>   Path to the package directory containing zpkg.zon
    \\
    \\Options:
    \\  --dry-run    Print the updated lockfile to stdout without writing to disk
    \\
    \\Example:
    \\  zpkg update .
    \\
;

pub fn run(args: []const []const u8, io: std.Io) !void {
    if (args.len >= 3 and (std.mem.eql(u8, args[2], "--help") or std.mem.eql(u8, args[2], "-h"))) {
        return writeHelp(io);
    }
    if (args.len < 3) {
        try writeUsageError(io);
        return error.InvalidArgument;
    }

    const allocator = std.heap.page_allocator;
    const pkg_root_raw = args[2];

    // Check if dry-run
    const dry_run = args.len == 4 and std.mem.eql(u8, args[3], "--dry-run");

    // Resolve the package root to an absolute path so lockfile source_path values are absolute.
    const pkg_root = diag_util.resolveAbsPath(allocator, pkg_root_raw) catch |err| {
        try writeStderrFmt(io, "error: cannot resolve path '{s}': {s}\n", .{ pkg_root_raw, @errorName(err) });
        return error.InvalidArgument;
    };
    defer allocator.free(pkg_root);

    var dir = std.Io.Dir.cwd().openDir(io, pkg_root, .{}) catch |err| {
        try writePackageRootError(io, pkg_root, err);
        return error.InvalidArgument;
    };
    defer dir.close(io);

    // Parse manifest
    var manifest = schema.parseFileAlloc(allocator, dir, io, "zpkg.zon") catch |err| {
        const diagnostic = schema.formatDiagnosticAlloc(allocator, "zpkg.zon", err) catch "";
        defer allocator.free(diagnostic);
        try writeStderr(io, diagnostic);
        return error.InvalidArgument;
    };
    defer manifest.deinitOwned(allocator);

    // Resolve packages
    const environment = conditions.Environment{
        .domain = .target,
        .host_os = conditions.Os.linux,
        .host_arch = conditions.Arch.x86_64,
        .target_os = conditions.Os.linux,
        .target_arch = conditions.Arch.x86_64,
    };

    var resolver = resolve.Resolver.init(allocator, environment.host_os, environment.host_arch, environment.target_os, environment.target_arch, &.{}, pkg_root, io);
    defer resolver.deinit();

    const resolved = resolver.resolveRoot(manifest) catch |err| {
        try writeResolutionError(io, err);
        return error.InvalidArgument;
    };

    // Generate lockfile
    const lockfile = generateLockfile(allocator, io, pkg_root, resolved, &resolver) catch |err| {
        try writeGenerationError(io, err);
        return error.OutOfMemory;
    };
    defer lockfile.deinit(allocator);

    if (dry_run) {
        // Just output the lockfile content
        const lockfile_content = lockfile.toZonAlloc(allocator) catch |err| {
            try writeGenerationError(io, err);
            return error.OutOfMemory;
        };
        defer allocator.free(lockfile_content);

        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
        const stdout = &stdout_writer_file.interface;
        try stdout.writeAll(lockfile_content);
        try stdout.flush();
        return;
    }

    // Write lockfile
    const lockfile_content = lockfile.toZonAlloc(allocator) catch |err| {
        try writeGenerationError(io, err);
        return error.OutOfMemory;
    };
    defer allocator.free(lockfile_content);

    const file = dir.createFile(io, "zpkg.lock.zon", .{}) catch |err| {
        try writeFileError(io, err);
        return error.InvalidArgument;
    };
    defer file.close(io);

    try std.Io.File.writeStreamingAll(file, io, lockfile_content);

    // Success message
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer_file.interface;
    try stdout.writeAll("Lockfile updated: zpkg.lock.zon\n");
    try stdout.flush();
}

fn writeHelp(io: std.Io) !void {
    var buf: [2048]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const w = &fw.interface;
    try w.writeAll(help_text);
    try w.flush();
}

fn writeUsageError(io: std.Io) !void {
    try writeStderr(io,
        "error: update expects exactly one package root path\n" ++
        "usage: zpkg update <pkg-root> [--dry-run]\n");
}

fn writePackageRootError(io: std.Io, pkg_root: []const u8, err: anyerror) !void {
    try writeStderrFmt(io, "error: cannot open package root {s}: {s}\n", .{ pkg_root, @errorName(err) });
}

fn writeResolutionError(io: std.Io, err: anyerror) !void {
    try writeStderrFmt(io, "error: failed to resolve packages: {s}\n", .{@errorName(err)});
}

fn writeGenerationError(io: std.Io, err: anyerror) !void {
    try writeStderrFmt(io, "error: failed to generate lockfile: {s}\n", .{@errorName(err)});
}

fn writeFileError(io: std.Io, err: anyerror) !void {
    try writeStderrFmt(io, "error: failed to write lockfile: {s}\n", .{@errorName(err)});
}

fn writeStderr(io: std.Io, text: []const u8) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer_file: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_writer_file.interface;
    try stderr.writeAll(text);
    try stderr.flush();
}

fn writeStderrFmt(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer_file: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_writer_file.interface;
    try stderr.print(fmt, args);
    try stderr.flush();
}

fn generateLockfile(allocator: std.mem.Allocator, io: std.Io, pkg_root: []const u8, resolved: resolve.ResolvedRoot, resolver: *resolve.Resolver) !model.Lockfile {
    const cloned_id = try resolved.package_id.cloneOwned(allocator);
    errdefer cloned_id.deinitOwned(allocator);

    var instances: std.ArrayList(model.LockfileInstance) = .empty;
    errdefer {
        for (instances.items) |inst| inst.deinit(allocator);
        instances.deinit(allocator);
    }

    var it = resolver.resolved.iterator();
    while (it.next()) |entry| {
        const pkg = entry.value_ptr.*;

        if (pkg.package_id.eql(resolved.package_id)) continue;

        const inst_key = try model.LockfileInstanceRef.parseOwned(allocator, entry.key_ptr.*);
        errdefer inst_key.deinitOwned(allocator);

        const inst_pkg_id = try pkg.package_id.cloneOwned(allocator);
        errdefer inst_pkg_id.deinitOwned(allocator);

        // Look up the absolute source dir recorded by the resolver.
        const instance_key_str = entry.key_ptr.*;
        const dep_dir_path = resolver.source_dirs.get(instance_key_str) orelse {
            std.log.err("zpkg: no source path recorded for '{s}'", .{instance_key_str});
            return error.MissingSourcePath;
        };

        // Compute source hash for this dependency.
        const dep_dir = try std.Io.Dir.cwd().openDir(io, dep_dir_path, .{});
        defer dep_dir.close(io);
        const hex = try source_hash.hashPackageSource(allocator, dep_dir, io, 1);
        const src_hash_str = try allocator.dupe(u8, &hex);
        errdefer allocator.free(src_hash_str);

        // Store source path relative to the lockfile directory (pkg_root) so the
        // lockfile is portable across machines with different checkout locations.
        const src_path_str = try std.fs.path.relativePosix(allocator, "/", pkg_root, dep_dir_path);
        errdefer allocator.free(src_path_str);

        var deps = try allocator.alloc(model.LockfileDependency, pkg.deps.len);
        errdefer allocator.free(deps);
        var deps_filled: usize = 0;
        errdefer {
            for (deps[0..deps_filled]) |dep| {
                dep.instance.deinitOwned(allocator);
                dep.deinit(allocator);
            }
        }
        for (pkg.deps, 0..) |dep, i| {
            deps[i] = .{
                .alias = try allocator.dupe(u8, dep.alias),
                .instance = .{
                    .package_id = try dep.instance.package_id.cloneOwned(allocator),
                    .domain = dep.instance.domain,
                },
            };
            deps_filled = i + 1;
        }

        try instances.append(allocator, .{
            .key = inst_key,
            .package_id = inst_pkg_id,
            .domain = pkg.domain,
            .version = pkg.version,
            .source_hash = src_hash_str,
            .source_path = src_path_str,
            .selected_options = &.{},
            .deps = deps,
        });
    }

    return .{
        .schema = 1,
        .root = .{
            .package_id = cloned_id,
            .version = resolved.version,
        },
        .generated_by = null,
        .instances = try instances.toOwnedSlice(allocator),
    };
}

