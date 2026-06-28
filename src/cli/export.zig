const std = @import("std");
const schema = @import("../schema/root.zig");
const store_mod = @import("../store/store.zig");
const export_engine = @import("../export/export.zig");
const diag_util = @import("../util/diag.zig");

pub const help_text =
    \\zpkg export — Export a relocatable closure bundle
    \\
    \\Usage:
    \\  zpkg export <pkg-root> [<package_id>:<target_name>]
    \\
    \\Arguments:
    \\  <pkg-root>                      Path to the package directory
    \\  <package_id>:<target_name>      Optional: export a specific named target
    \\
    \\Example:
    \\  zpkg export .
    \\  zpkg export . myorg.mypkg:my_lib
    \\
;

pub fn run(args: []const []const u8, io: std.Io) !void {
    // Usage: zpkg export <pkg-root> [<package_id>:<target_name>]
    var pkg_root: ?[]const u8 = null;
    var named_arg: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            var buf: [2048]u8 = undefined;
            var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
            const w = &fw.interface;
            try w.writeAll(help_text);
            try w.flush();
            return;
        } else if (pkg_root == null) {
            pkg_root = args[i];
        } else if (named_arg == null) {
            named_arg = args[i];
        } else {
            try writeStderrFmt(io, "error: unexpected argument: {s}\n", .{args[i]});
            return error.InvalidArgument;
        }
    }

    const root = pkg_root orelse {
        try writeStderr(io, "error: export expects a package root path\nusage: zpkg export <pkg-root> [<package_id>:<target_name>]\n");
        return error.InvalidArgument;
    };

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const abs_root = diag_util.resolveAbsPath(allocator, root) catch |err| {
        try writeStderrFmt(io, "error: cannot resolve path '{s}': {s}\n", .{ root, @errorName(err) });
        return error.InvalidArgument;
    };
    defer allocator.free(abs_root);

    // Load lockfile bytes.
    var pkg_dir = std.Io.Dir.openDirAbsolute(io, abs_root, .{}) catch |err| {
        try writeStderrFmt(io, "error: cannot open package root '{s}': {s}\n", .{ abs_root, @errorName(err) });
        return error.InvalidArgument;
    };
    defer pkg_dir.close(io);

    const lockfile_bytes = pkg_dir.readFileAlloc(io, "zpkg.lock.zon", allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            try writeStderr(io, "error: no lockfile found; run 'zpkg lock <pkg-root>' first\n");
            return error.LockfileNotFound;
        },
        else => return err,
    };
    defer allocator.free(lockfile_bytes);

    const lockfile_sentinel = try allocator.dupeZ(u8, lockfile_bytes);
    defer allocator.free(lockfile_sentinel);

    const lockfile = schema.parseLockfileSourceAlloc(allocator, lockfile_sentinel) catch |err| {
        try writeStderrFmt(io, "error: failed to parse zpkg.lock.zon: {s}\n", .{@errorName(err)});
        return error.InvalidArgument;
    };
    defer lockfile.deinit(allocator);

    // Build export options.
    var opts: export_engine.ExportOptions = .{};
    if (named_arg) |named| {
        // Parse "package_id:target_name"
        const colon = std.mem.indexOfScalar(u8, named, ':') orelse {
            try writeStderrFmt(io, "error: named target must be 'package_id:target_name', got '{s}'\n", .{named});
            return error.InvalidArgument;
        };
        opts.target = .{ .named = .{
            .package_id = named[0..colon],
            .target_name = named[colon + 1 ..],
        } };
    }

    // Init store.
    var store = try store_mod.Store.init(allocator, io, abs_root);
    defer store.deinit();

    // Plan export.
    const instance_keys = try export_engine.planExport(allocator, lockfile, opts);
    defer {
        for (instance_keys) |k| allocator.free(k);
        allocator.free(instance_keys);
    }

    // Destination: <pkg-root>/.zpkg/export/bundle/
    const dest_dir = try std.Io.Dir.path.join(allocator, &.{ abs_root, ".zpkg", "export", "bundle" });
    defer allocator.free(dest_dir);

    // Print plan.
    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_file.interface;

    try stdout.print("Exporting {d} instance(s) to {s}\n", .{ instance_keys.len, dest_dir });
    try stdout.flush();

    // Assemble bundle.
    try export_engine.assembleBundle(allocator, io, instance_keys, &store, dest_dir);

    try stdout.print("Export complete: {s}\n", .{dest_dir});
    try stdout.flush();
}

fn writeStderr(io: std.Io, text: []const u8) !void {
    var buf: [2048]u8 = undefined;
    var f: std.Io.File.Writer = .init(.stderr(), io, &buf);
    const w = &f.interface;
    try w.writeAll(text);
    try w.flush();
}

fn writeStderrFmt(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [2048]u8 = undefined;
    var f: std.Io.File.Writer = .init(.stderr(), io, &buf);
    const w = &f.interface;
    try w.print(fmt, args);
    try w.flush();
}
