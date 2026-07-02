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
            try diag_util.writeHelp(io, help_text);
            return;
        } else if (pkg_root == null) {
            pkg_root = args[i];
        } else if (named_arg == null) {
            named_arg = args[i];
        } else {
            try diag_util.writeError(io, "unexpected argument: {s}", .{args[i]});
            try diag_util.writeHint(io, "run 'zpkg export --help' for usage", .{});
            return error.InvalidArgument;
        }
    }

    const root = pkg_root orelse {
        try diag_util.writeError(io, "export expects a package root path", .{});
        try diag_util.writeHint(io, "usage: zpkg export <pkg-root> [<package_id>:<target_name>]", .{});
        return error.InvalidArgument;
    };

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const abs_root = diag_util.resolveAbsPath(allocator, root) catch |err| {
        try diag_util.writeError(io, "cannot resolve path '{s}': {s}", .{ root, @errorName(err) });
        return error.InvalidArgument;
    };
    defer allocator.free(abs_root);

    // Load lockfile bytes.
    var pkg_dir = std.Io.Dir.openDirAbsolute(io, abs_root, .{}) catch |err| {
        try diag_util.writeError(io, "cannot open package root '{s}': {s}", .{ abs_root, @errorName(err) });
        return error.InvalidArgument;
    };
    defer pkg_dir.close(io);

    const lockfile_bytes = pkg_dir.readFileAlloc(io, "zpkg.lock.zon", allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            try diag_util.writeLockfileMissingError(io);
            return error.LockfileNotFound;
        },
        else => return err,
    };
    defer allocator.free(lockfile_bytes);

    const lockfile_sentinel = try allocator.dupeZ(u8, lockfile_bytes);
    defer allocator.free(lockfile_sentinel);

    const lockfile = schema.parseLockfileSourceAlloc(allocator, lockfile_sentinel) catch |err| {
        try diag_util.writeError(io, "failed to parse zpkg.lock.zon: {s}", .{@errorName(err)});
        try diag_util.writeHint(io, "run 'zpkg lock <pkg-root>' to regenerate the lockfile", .{});
        return error.InvalidArgument;
    };
    defer lockfile.deinit(allocator);

    // Build export options.
    var opts: export_engine.ExportOptions = .{};
    if (named_arg) |named| {
        // Parse "package_id:target_name"
        const colon = std.mem.indexOfScalar(u8, named, ':') orelse {
            try diag_util.writeError(io, "named target must be 'package_id:target_name', got '{s}'", .{named});
            try diag_util.writeHint(io, "example: zpkg export . myorg.mypkg:my_lib", .{});
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

const writeStderr = diag_util.writeStderr;
const writeStderrFmt = diag_util.writeStderrFmt;
