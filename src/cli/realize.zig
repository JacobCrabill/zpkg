const std = @import("std");
const schema = @import("../schema/root.zig");
const realize = @import("../realize/root.zig");
const store_mod = @import("../store/store.zig");
const toolchain_fingerprint_mod = @import("../hash/toolchain_fingerprint.zig");
const diag_util = @import("../util/diag.zig");

pub const help_text =
    \\zpkg realize — Materialize the generated workspace (.zpkg/)
    \\
    \\Usage:
    \\  zpkg realize <pkg-root>
    \\
    \\Arguments:
    \\  <pkg-root>   Path to the package directory containing zpkg.lock.zon
    \\
    \\Example:
    \\  zpkg realize .
    \\
;

pub fn run(args: []const []const u8, io: std.Io) !void {
    if (args.len >= 3 and (std.mem.eql(u8, args[2], "--help") or std.mem.eql(u8, args[2], "-h"))) {
        var buf: [2048]u8 = undefined;
        var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
        const w = &fw.interface;
        try w.writeAll(help_text);
        try w.flush();
        return;
    }
    if (args.len != 3) {
        try writeStderr(io,
            "error: realize expects exactly one package root path\n" ++
            "usage: zpkg realize <pkg-root>\n");
        return error.InvalidArgument;
    }

    const allocator = std.heap.page_allocator;

    const abs_root = diag_util.resolveAbsPath(allocator, args[2]) catch |err| {
        try writeStderrFmt(io, "error: cannot resolve path '{s}': {s}\n", .{ args[2], @errorName(err) });
        return error.InvalidArgument;
    };
    defer allocator.free(abs_root);
    const pkg_root = abs_root;

    // 1. Open pkg-root dir
    var pkg_dir = std.Io.Dir.openDirAbsolute(io, pkg_root, .{}) catch |err| {
        try writeStderrFmt(io, "error: cannot open package root '{s}': {s}\n", .{ pkg_root, @errorName(err) });
        return error.InvalidArgument;
    };
    defer pkg_dir.close(io);

    // 2. Parse zpkg.zon
    var manifest = schema.zpkg.parseFileAlloc(allocator, pkg_dir, io, "zpkg.zon") catch |err| {
        try writeStderrFmt(io, "error: failed to parse zpkg.zon: {s}\n", .{@errorName(err)});
        return error.InvalidArgument;
    };
    defer manifest.deinitOwned(allocator);

    // 3. Load zpkg.lock.zon
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

    // 4. Validate lockfile root matches zpkg.zon identity
    if (!lockfile.root.package_id.eql(manifest.package.id)) {
        try writeStderrFmt(io,
            "error: lockfile root '{s}' does not match zpkg.zon package '{s}'\n",
            .{ lockfile.root.package_id.asText(), manifest.package.id.asText() },
        );
        return error.LockfileMismatch;
    }

    // 5. Init WorkspaceLayout with default profile
    const profile: realize.Profile = .{};
    const profile_slug = try profile.slug(allocator);
    defer allocator.free(profile_slug);
    var layout = try realize.WorkspaceLayout.init(allocator, pkg_root, profile_slug);
    defer layout.deinit();

    // 6. Ensure dirs exist
    try layout.ensureDirs(io);

    // 7. Init store (workspace root = pkg_root)
    var store = try store_mod.Store.init(allocator, io, pkg_root);
    defer store.deinit();

    // 8. Detect the toolchain fingerprint and plan the build so we can derive the
    //    content-addressed store keys.  These must match the keys `zpkg build`
    //    writes under, otherwise every instance would miss the store.
    const toolchain_fp = try toolchain_fingerprint_mod.detect(allocator, io, profile.target);
    defer toolchain_fingerprint_mod.deinitOwned(allocator, toolchain_fp);

    const key_config = realize.build_fallback.KeyConfig.fromProfile(profile, toolchain_fp);
    var plan = try realize.planBuild(allocator, lockfile, &store, .build, key_config);
    defer plan.deinit();

    // 9. Realize each instance: a store hit becomes a binary adapter; a miss is
    //    materialized as a source package from its recorded source_path.
    var r = realize.Realizer.init(allocator, io, &layout, pkg_root);

    for (lockfile.instances) |*instance| {
        const display_key = try std.fmt.allocPrint(allocator, "{s}#{s}", .{
            instance.key.package_id.asText(),
            instance.key.domain.asText(),
        });
        defer allocator.free(display_key);

        const store_key = plan.instance_keys.get(display_key) orelse display_key;

        if (store.hasArtifact(store_key)) {
            r.realizeBinaryAdapter(&store, instance, display_key, store_key) catch |err| {
                try writeStderrFmt(io, "warning: failed to generate adapter for '{s}': {s}\n", .{ display_key, @errorName(err) });
            };
        } else {
            if (instance.source_path.len == 0) {
                try writeStderrFmt(io, "warning: '{s}' has no source_path in lockfile; skipping\n", .{display_key});
                continue;
            }
            const source_dir = realize.resolveLockfilePath(allocator, pkg_root, instance.source_path) catch |err| {
                try writeStderrFmt(io, "warning: cannot resolve source for '{s}': {s}\n", .{ display_key, @errorName(err) });
                continue;
            };
            defer allocator.free(source_dir);

            r.realizeSource(source_dir, display_key, instance) catch |err| {
                try writeStderrFmt(io, "warning: failed to realize source for '{s}': {s}\n", .{ display_key, @errorName(err) });
            };
        }
    }

    // 10. Realize the root package itself as a source pkg. Its dep map comes from
    //     the manifest, since the root is not an entry in lockfile.instances.
    {
        const root_dir = try layout.rootPkgDir(allocator);
        defer allocator.free(root_dir);

        std.Io.Dir.createDirAbsolute(io, root_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var root_dep_map = try r.buildRootDepMap(manifest.deps, lockfile);
        defer r.freeDepMap(&root_dep_map);

        r.writeSourceRealization(pkg_root, root_dir, root_dep_map) catch |err| {
            try writeStderrFmt(io, "warning: failed to realize root package: {s}\n", .{@errorName(err)});
        };
    }

    // 11. Print success summary
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer_file.interface;
    try stdout.print(
        "Workspace realized at: {s}\n  Profile: {s}\n  Instances: {d}\n",
        .{ layout.workspace_root, profile_slug, lockfile.instances.len },
    );
    try stdout.flush();
}

const writeStderr = diag_util.writeStderr;
const writeStderrFmt = diag_util.writeStderrFmt;
