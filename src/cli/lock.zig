const std = @import("std");
const model = @import("../model/root.zig");
const conditions = @import("../model/conditions.zig");
const schema = @import("../schema/zpkg.zig");
const resolve = @import("../resolve/root.zig");
const drift = @import("../resolve/drift.zig");

pub fn run(args: []const []const u8, io: std.Io) !void {
    if (args.len != 3) {
        try writeUsageError(io);
        return error.InvalidArgument;
    }

    const allocator = std.heap.page_allocator;
    const pkg_root = args[2];

    // Check if lockfile already exists
    const lockfile_path = try formatLockfilePath(allocator, pkg_root);
    defer allocator.free(lockfile_path);

    var dir = try std.Io.Dir.cwd().openDir(io, pkg_root, .{});
    defer dir.close(io);

    const lockfile_result = blk: {
        const f = dir.openFile(io, "zpkg.lock.zon", .{}) catch |err| switch (err) {
            error.FileNotFound, error.IsDir => break :blk false,
            else => return err,
        };
        f.close(io);
        break :blk true;
    };
    if (lockfile_result) {
        try writeLockfileExistsError(io);
        return error.LockfileExists;
    }

    // Parse manifest
    var manifest = schema.parseFileAlloc(allocator, dir, io, "zpkg.zon") catch |err| {
        const diagnostic = schema.formatDiagnosticAlloc(allocator, lockfile_path, err) catch "";
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

    var resolver = resolve.Resolver.init(allocator, environment.host_os, environment.host_arch, environment.target_os, environment.target_arch, &.{});
    defer resolver.deinit();

    const resolved = resolver.resolveRoot(manifest) catch |err| {
        try writeResolutionError(io, err);
        return error.InvalidArgument;
    };

    // Generate lockfile
    const lockfile = generateLockfile(allocator, resolved);
    defer lockfile.deinit(allocator);

    // Write lockfile
    const lockfile_content = lockfile.toZonAlloc(allocator) catch |err| {
        try writeGenerationError(io, err);
        return error.OutOfMemory;
    };
    defer allocator.free(lockfile_content);

    // Write to file
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
    try stdout.writeAll("Lockfile created: zpkg.lock.zon\n");
    try stdout.flush();
}

fn formatLockfilePath(allocator: std.mem.Allocator, pkg_root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/zpkg.lock.zon", .{pkg_root});
}

fn writeUsageError(io: std.Io) !void {
    try writeStderr(io,
        "error: lock expects exactly one package root path\n" ++
        "usage: zpkg lock <pkg-root>\n");
}

fn writeLockfileExistsError(io: std.Io) !void {
    try writeStderr(io,
        "error: lockfile already exists\n" ++
        "use 'zpkg update' to update an existing lockfile\n");
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

fn generateLockfile(allocator: std.mem.Allocator, resolved: resolve.ResolvedRoot) model.Lockfile {
    // Clone package_id so Lockfile.root owns its text independently of the
    // parsed manifest (which is freed separately via manifest.deinitOwned).
    const cloned_id = resolved.package_id.cloneOwned(allocator) catch unreachable;
    return .{
        .schema = 1,
        .root = .{
            .package_id = cloned_id,
            .version = resolved.version,
        },
        .generated_by = null,
        .instances = &.{},
    };
}
