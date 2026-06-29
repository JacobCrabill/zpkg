const std = @import("std");
const schema = @import("../schema/root.zig");
const realize = @import("../realize/root.zig");
const build_fallback = @import("../realize/build_fallback.zig");
const store_mod = @import("../store/store.zig");
const toolchain_fingerprint_mod = @import("../hash/toolchain_fingerprint.zig");
const diag = @import("../util/diag.zig");

pub const help_text =
    \\zpkg build — Build all instances from the lockfile
    \\
    \\Usage:
    \\  zpkg build <pkg-root> [--with-tests] [--jobs N] [--strict-lockfile]
    \\
    \\Arguments:
    \\  <pkg-root>        Path to the package directory containing zpkg.lock.zon
    \\
    \\Options:
    \\  --with-tests      Also build test instances
    \\  --jobs N          Maximum number of parallel build jobs (default: CPU count; 1 for serial)
    \\  --strict-lockfile Treat source drift as a hard error (default: warn and rebuild)
    \\
    \\Example:
    \\  zpkg build .
    \\  zpkg build . --jobs 1
    \\  zpkg build . --strict-lockfile
    \\
;

pub fn run(args: []const []const u8, io: std.Io) !void {
    var with_tests = false;
    var pkg_root: ?[]const u8 = null;
    var max_jobs: ?usize = null;
    var strict_lockfile = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            var buf: [2048]u8 = undefined;
            var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
            const w = &fw.interface;
            try w.writeAll(help_text);
            try w.flush();
            return;
        } else if (std.mem.eql(u8, args[i], "--with-tests")) {
            with_tests = true;
        } else if (std.mem.eql(u8, args[i], "--strict-lockfile")) {
            strict_lockfile = true;
        } else if (std.mem.eql(u8, args[i], "--jobs")) {
            i += 1;
            if (i >= args.len) {
                try writeStderr(io, "error: --jobs requires a number\n");
                return error.InvalidArgument;
            }
            const n = std.fmt.parseInt(usize, args[i], 10) catch {
                try writeStderrFmt(io, "error: --jobs value must be a positive integer: {s}\n", .{args[i]});
                return error.InvalidArgument;
            };
            if (n == 0) {
                try writeStderr(io, "error: --jobs must be at least 1\n");
                return error.InvalidArgument;
            }
            max_jobs = n;
        } else if (pkg_root == null) {
            pkg_root = args[i];
        } else {
            try writeStderrFmt(io, "error: unexpected argument: {s}\n", .{args[i]});
            return error.InvalidArgument;
        }
    }

    const root = pkg_root orelse {
        try writeStderr(io, "error: build expects a package root path\nusage: zpkg build <pkg-root> [--with-tests] [--jobs N]\n");
        return error.InvalidArgument;
    };

    const mode: build_fallback.BuildMode = if (with_tests) .build_with_tests else .build;

    try runBuild(root, mode, io, max_jobs, strict_lockfile);
}

pub fn runBuild(pkg_root: []const u8, mode: build_fallback.BuildMode, io: std.Io, max_jobs_override: ?usize, strict_lockfile: bool) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Resolve to absolute so openDirAbsolute and downstream path joins work.
    const abs_root = diag.resolveAbsPath(allocator, pkg_root) catch |err| {
        try writeStderrFmt(io, "error: cannot resolve path '{s}': {s}\n", .{ pkg_root, @errorName(err) });
        return error.InvalidArgument;
    };
    defer allocator.free(abs_root);

    // Open pkg-root dir.
    var pkg_dir = std.Io.Dir.openDirAbsolute(io, abs_root, .{}) catch |err| {
        try writeStderrFmt(io, "error: cannot open package root '{s}': {s}\n", .{ abs_root, @errorName(err) });
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
    var layout = try realize.WorkspaceLayout.init(allocator, abs_root, profile);
    defer layout.deinit();
    try layout.ensureDirs(io);

    // Init Store.
    var store = try store_mod.Store.init(allocator, io, abs_root);
    defer store.deinit();

    // Detect toolchain fingerprint once for the entire build invocation.
    const toolchain_fp = try toolchain_fingerprint_mod.detect(allocator, io);
    defer toolchain_fingerprint_mod.deinitOwned(allocator, toolchain_fp);

    // Plan the build.
    var plan = try build_fallback.planBuild(allocator, lockfile, &store, mode, toolchain_fp);
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

    // Resolve max_jobs: explicit flag > CPU count > fallback of 4.
    const max_jobs = max_jobs_override orelse (std.Thread.getCpuCount() catch 4);

    // Execute plan.
    var executor = build_fallback.BuildExecutor.init(allocator, io, &store, &layout, abs_root, abs_root, max_jobs, strict_lockfile);
    defer executor.deinit();

    try executor.execute(plan, lockfile);

    // Build the root package.
    try buildRoot(allocator, io, abs_root, manifest, lockfile, &layout, mode);

    try stdout.print(
        "Build complete. Profile: {s}\n",
        .{profile},
    );
    try stdout.flush();
}

fn buildRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_root: []const u8,
    manifest: schema.zpkg.Manifest,
    lockfile: schema.Lockfile,
    layout: *realize.WorkspaceLayout,
    mode: build_fallback.BuildMode,
) !void {
    const root_dir = try layout.rootPkgDir(allocator);
    defer allocator.free(root_dir);

    std.Io.Dir.createDirAbsolute(io, root_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Build dep_map: alias → workspace dep dir, from manifest deps cross-referenced
    // with lockfile instances.
    var root_dep_map = realize.DepPathMap.init(allocator);
    defer {
        var it = root_dep_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        root_dep_map.deinit();
    }

    for (manifest.deps) |dep| {
        // Find the lockfile instance for this dep.
        for (lockfile.instances) |instance| {
            if (!instance.key.package_id.eql(dep.package)) continue;
            const dep_key = try std.fmt.allocPrint(allocator, "{s}#{s}", .{
                instance.key.package_id.asText(),
                instance.key.domain.asText(),
            });
            defer allocator.free(dep_key);
            const dep_path = try layout.depPkgDir(allocator, dep_key);
            errdefer allocator.free(dep_path);
            const alias_key = try allocator.dupe(u8, dep.alias);
            errdefer allocator.free(alias_key);
            try root_dep_map.put(alias_key, dep_path);
            break;
        }
    }

    // Realize the root package into the workspace.
    var source_realizer = realize.SourcePkgRealize.init(allocator, io);
    source_realizer.realize(pkg_root, root_dir, manifest.package.id.asText(), root_dep_map) catch |err| {
        try writeStderrFmt(io, "error: failed to realize root package: {s}\n", .{@errorName(err)});
        return error.RealizeFailed;
    };

    // Run `zig build` in the root workspace dir.
    // Multi-pass: patch fingerprint mismatches (including adapter deps) then retry.
    const argv: []const []const u8 = switch (mode) {
        .build, .build_with_tests => &.{ "zig", "build" },
        .run_tests => &.{ "zig", "build", "test" },
    };

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_file.interface;
    try stdout.print("[build] {s} (root)\n", .{manifest.package.id.asText()});
    try stdout.flush();

    const root_ok = root_blk: {
        var pass: usize = 0;
        while (pass < 20) : (pass += 1) {
            const result = try std.process.run(allocator, io, .{
                .argv = argv,
                .cwd = .{ .path = root_dir },
            });
            defer {
                allocator.free(result.stdout);
                allocator.free(result.stderr);
            }

            const ok = switch (result.term) {
                .exited => |code| code == 0,
                else => false,
            };
            if (ok) break :root_blk true;

            if (build_fallback.extractSuggestedFingerprint(result.stderr)) |fp| {
                if (try build_fallback.extractFingerprintFilePath(allocator, result.stderr)) |fpath| {
                    defer allocator.free(fpath);
                    try build_fallback.patchFingerprintInFile(allocator, io, fpath, fp);
                    continue;
                }
                // No file path; patch root dir's build.zig.zon.
                try build_fallback.patchFingerprintInBuildZigZon(allocator, io, root_dir, fp);
                // Final pass with inherited stdio for real build output.
                var child2 = try std.process.spawn(io, .{
                    .argv = argv,
                    .cwd = .{ .path = root_dir },
                    .stdin = .inherit,
                    .stdout = .inherit,
                    .stderr = .inherit,
                });
                const term2 = try child2.wait(io);
                switch (term2) {
                    .exited => |code| {
                        if (code != 0) {
                            try writeStderrFmt(io, "error: build failed for root package (exit code {d})\n", .{code});
                            break :root_blk false;
                        }
                    },
                    else => {
                        try writeStderrFmt(io, "error: build process for root package terminated abnormally\n", .{});
                        break :root_blk false;
                    },
                }
                break :root_blk true;
            } else {
                // Real build failure; forward captured output.
                _ = result.stdout; // already shown via child2 in prior pass if applicable
                try writeStderrFmt(io, "{s}", .{result.stderr});
                switch (result.term) {
                    .exited => |code| try writeStderrFmt(io, "error: build failed for root package (exit code {d})\n", .{code}),
                    else => try writeStderrFmt(io, "error: build process for root package terminated abnormally\n", .{}),
                }
                break :root_blk false;
            }
        }
        try writeStderrFmt(io, "error: too many fingerprint correction passes for root package\n", .{});
        break :root_blk false;
    };
    if (!root_ok) return error.BuildFailed;

    try stdout.print("[done]  {s} (root)\n", .{manifest.package.id.asText()});
    try stdout.flush();

    // Symlink <pkg_root>/zig-out → <root_dir>/zig-out for easy access.
    const zig_out_target = try std.Io.Dir.path.join(allocator, &.{ root_dir, "zig-out" });
    defer allocator.free(zig_out_target);
    const zig_out_link = try std.Io.Dir.path.join(allocator, &.{ pkg_root, "zig-out" });
    defer allocator.free(zig_out_link);

    // Remove any existing entry at the link path before (re)creating.
    std.Io.Dir.cwd().deleteFile(io, zig_out_link) catch {};
    std.Io.Dir.symLinkAbsolute(io, zig_out_target, zig_out_link, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => try writeStderrFmt(io, "warning: could not symlink zig-out: {s}\n", .{@errorName(err)}),
    };
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
