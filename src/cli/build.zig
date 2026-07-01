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
    \\  zpkg build <pkg-root> [options]
    \\
    \\Arguments:
    \\  <pkg-root>        Path to the package directory containing zpkg.lock.zon
    \\
    \\Options:
    \\  --with-tests            Also build test instances
    \\  --jobs N                Maximum number of parallel build jobs (default: CPU count; 1 for serial)
    \\  --strict-lockfile       Treat source drift as a hard error (default: warn and rebuild)
    \\  --release[=safe|fast|small]  Optimized build (bare --release = ReleaseFast; default is Debug)
    \\  --target <triple>       Cross-compile for a Zig target triple (default: native)
    \\
    \\Example:
    \\  zpkg build .
    \\  zpkg build . --release
    \\  zpkg build . --release=small --target aarch64-linux-gnu
    \\
;

pub fn run(args: []const []const u8, io: std.Io) !void {
    var with_tests = false;
    var pkg_root: ?[]const u8 = null;
    var max_jobs: ?usize = null;
    var strict_lockfile = false;
    var profile: realize.Profile = .{};

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            try diag.writeHelp(io, help_text);
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
        } else if (try tryParseProfileFlag(args, &i, &profile, io)) {
            // handled (index advanced by the helper if it consumed a value)
        } else if (pkg_root == null) {
            pkg_root = args[i];
        } else {
            try writeStderrFmt(io, "error: unexpected argument: {s}\n", .{args[i]});
            return error.InvalidArgument;
        }
    }

    const root = pkg_root orelse {
        try writeStderr(io, "error: build expects a package root path\n" ++
            "usage: zpkg build <pkg-root> [--with-tests] [--jobs N] [--release[=safe|fast|small]] [--target <triple>]\n");
        return error.InvalidArgument;
    };

    const mode: build_fallback.BuildMode = if (with_tests) .build_with_tests else .build;

    try runBuild(root, mode, io, max_jobs, strict_lockfile, profile);
}

/// If `args[i.*]` is a build-profile flag (`--release[=…]`, `--target …`), apply
/// it to `profile`, advance `i` past any consumed value, and return true. Returns
/// false if the arg is not a profile flag. Returns an error (after printing a
/// diagnostic) if it is a profile flag but malformed.
///
/// Note: `profile.linkage` is part of the store-key identity but has no CLI flag
/// yet — there is no standard `zig build` linkage option to make it actually
/// change the output, so exposing it would only mislabel the store entry. Deferred
/// until packages expose a linkage option (see docs/profile-target-axis-plan.md).
///
/// Shared by `zpkg build` and `zpkg test`.
pub fn tryParseProfileFlag(
    args: []const []const u8,
    i: *usize,
    profile: *realize.Profile,
    io: std.Io,
) !bool {
    const arg = args[i.*];
    if (std.mem.eql(u8, arg, "--release")) {
        profile.optimize = .ReleaseFast;
    } else if (std.mem.startsWith(u8, arg, "--release=")) {
        const v = arg["--release=".len..];
        profile.optimize = if (std.mem.eql(u8, v, "safe"))
            .ReleaseSafe
        else if (std.mem.eql(u8, v, "fast"))
            .ReleaseFast
        else if (std.mem.eql(u8, v, "small"))
            .ReleaseSmall
        else {
            try writeStderrFmt(io, "error: --release must be safe|fast|small, got '{s}'\n", .{v});
            return error.InvalidArgument;
        };
    } else if (std.mem.eql(u8, arg, "--target")) {
        i.* += 1;
        if (i.* >= args.len) {
            try writeStderr(io, "error: --target requires a triple (e.g. x86_64-linux-gnu)\n");
            return error.InvalidArgument;
        }
        profile.target = args[i.*];
    } else if (std.mem.startsWith(u8, arg, "--target=")) {
        profile.target = arg["--target=".len..];
    } else {
        return false;
    }
    return true;
}

pub fn runBuild(
    pkg_root: []const u8,
    mode: build_fallback.BuildMode,
    io: std.Io,
    max_jobs_override: ?usize,
    strict_lockfile: bool,
    profile: realize.Profile,
) !void {
    // Running foreign-target test binaries needs an emulator/runner; out of scope.
    if (mode == .run_tests and profile.target != null) {
        try writeStderr(io, "error: 'zpkg test' cannot run tests for a non-native --target\n");
        return error.InvalidArgument;
    }

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

    // Init WorkspaceLayout for the build profile.
    const profile_slug = try profile.slug(allocator);
    defer allocator.free(profile_slug);
    var layout = try realize.WorkspaceLayout.init(allocator, abs_root, profile_slug);
    defer layout.deinit();
    try layout.ensureDirs(io);

    // Init Store.
    var store = try store_mod.Store.init(allocator, io, abs_root);
    defer store.deinit();

    // Detect toolchain fingerprint (with the requested target) for the invocation.
    const toolchain_fp = try toolchain_fingerprint_mod.detect(allocator, io, profile.target);
    defer toolchain_fingerprint_mod.deinitOwned(allocator, toolchain_fp);

    // Plan the build. The profile (optimize/linkage/target) is folded into the keys.
    const key_config = build_fallback.KeyConfig.fromProfile(profile, toolchain_fp);
    var plan = try build_fallback.planBuild(allocator, lockfile, &store, mode, key_config);
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
    var executor = build_fallback.BuildExecutor.init(allocator, io, &store, &layout, abs_root, abs_root, max_jobs, strict_lockfile, profile);
    defer executor.deinit();

    try executor.execute(plan, lockfile);

    // Build the root package.
    try buildRoot(allocator, io, abs_root, manifest, lockfile, &layout, mode, profile);

    try stdout.print(
        "Build complete. Profile: {s}\n",
        .{profile_slug},
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
    profile: realize.Profile,
) !void {
    const root_dir = try layout.rootPkgDir(allocator);
    defer allocator.free(root_dir);

    std.Io.Dir.createDirAbsolute(io, root_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Realize the root package into the workspace. Its dep map comes from the
    // manifest (the root is not an entry in lockfile.instances).
    var r = realize.Realizer.init(allocator, io, layout, pkg_root);
    var root_dep_map = try r.buildRootDepMap(manifest.deps, lockfile);
    defer r.freeDepMap(&root_dep_map);

    r.writeSourceRealization(pkg_root, root_dir, root_dep_map) catch |err| {
        try writeStderrFmt(io, "error: failed to realize root package: {s}\n", .{@errorName(err)});
        return error.RealizeFailed;
    };

    // Run `zig build` in the root workspace dir, with the profile flags appended.
    const base_argv: []const []const u8 = switch (mode) {
        .build, .build_with_tests => &.{ "zig", "build" },
        .run_tests => &.{ "zig", "build", "test" },
    };
    const build_flags = try build_fallback.profileBuildFlags(allocator, profile);
    defer build_fallback.freeBuildFlags(allocator, build_flags);
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    try argv_list.appendSlice(allocator, base_argv);
    try argv_list.appendSlice(allocator, build_flags);
    const argv = argv_list.items;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_file.interface;
    try stdout.print("[build] {s} (root)\n", .{manifest.package.id.asText()});
    try stdout.flush();

    // Cap dir for the root build: use root_dir itself (it already exists and is
    // unique per workspace profile).
    const cap_dir = try std.Io.Dir.openDirAbsolute(io, root_dir, .{});
    defer cap_dir.close(io);

    {
        const result = try build_fallback.runCapture(allocator, io, argv, root_dir, cap_dir);
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        switch (result.term) {
            .exited => |code| {
                if (code != 0) {
                    try writeStderrFmt(io, "{s}", .{result.stderr});
                    try writeStderrFmt(io, "error: build failed for root package (exit code {d})\n", .{code});
                    return error.BuildFailed;
                }
            },
            else => {
                try writeStderrFmt(io, "{s}", .{result.stderr});
                try writeStderrFmt(io, "error: build process for root package terminated abnormally\n", .{});
                return error.BuildFailed;
            },
        }
    }

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

const writeStderr = diag.writeStderr;
const writeStderrFmt = diag.writeStderrFmt;
