const std = @import("std");
const schema = @import("../schema/root.zig");
const realize = @import("../realize/root.zig");
const build_fallback = @import("../realize/build_fallback.zig");
const store_mod = @import("../store/store.zig");

pub fn run(args: []const []const u8, io: std.Io) !void {
    var with_tests = false;
    var pkg_root: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--with-tests")) {
            with_tests = true;
        } else if (pkg_root == null) {
            pkg_root = args[i];
        } else {
            try writeStderrFmt(io, "error: unexpected argument: {s}\n", .{args[i]});
            return error.InvalidArgument;
        }
    }

    const root = pkg_root orelse {
        try writeStderr(io, "error: build expects a package root path\nusage: zpkg build <pkg-root> [--with-tests]\n");
        return error.InvalidArgument;
    };

    const mode: build_fallback.BuildMode = if (with_tests) .build_with_tests else .build;

    try runBuild(root, mode, io);
}

pub fn runBuild(pkg_root: []const u8, mode: build_fallback.BuildMode, io: std.Io) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Open pkg-root dir.
    var pkg_dir = std.Io.Dir.openDirAbsolute(io, pkg_root, .{}) catch |err| {
        try writeStderrFmt(io, "error: cannot open package root '{s}': {s}\n", .{ pkg_root, @errorName(err) });
        return error.InvalidArgument;
    };
    defer pkg_dir.close(io);

    // Parse zpkg.zon.
    var manifest = schema.zpkg.parseFileAlloc(allocator, pkg_dir, io, "zpkg.zon") catch |err| {
        try writeStderrFmt(io, "error: failed to parse zpkg.zon: {s}\n", .{@errorName(err)});
        return error.InvalidArgument;
    };
    defer manifest.deinitOwned(allocator);

    // Load zpkg.lock.zon.
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

    // Validate lockfile root matches zpkg.zon identity.
    if (!lockfile.root.package_id.eql(manifest.package.id)) {
        try writeStderrFmt(io,
            "error: lockfile root '{s}' does not match zpkg.zon package '{s}'\n",
            .{ lockfile.root.package_id.asText(), manifest.package.id.asText() },
        );
        return error.LockfileMismatch;
    }

    // Init WorkspaceLayout.
    const profile = realize.workspace.defaultProfile();
    var layout = try realize.WorkspaceLayout.init(allocator, pkg_root, profile);
    defer layout.deinit();
    try layout.ensureDirs(io);

    // Init Store.
    var store = try store_mod.Store.init(allocator, io, pkg_root);
    defer store.deinit();

    // Plan the build.
    var plan = try build_fallback.planBuild(allocator, lockfile, &store, mode);
    defer plan.deinit();

    // Print plan summary.
    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_file.interface;

    try stdout.print(
        "Build plan: {d} instances ({d} store hits, {d} to build)\n",
        .{ plan.build_order.len, plan.store_hits.count(), plan.store_misses.count() },
    );
    try stdout.flush();

    // Execute plan.
    var executor = build_fallback.BuildExecutor.init(allocator, io, &store, &layout, pkg_root);
    defer executor.deinit();

    try executor.execute(plan, lockfile);

    try stdout.print(
        "Build complete. Profile: {s}\n",
        .{profile},
    );
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
