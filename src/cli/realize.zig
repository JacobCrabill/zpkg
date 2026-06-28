const std = @import("std");
const schema = @import("../schema/root.zig");
const realize = @import("../realize/root.zig");
const store_mod = @import("../store/store.zig");
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
    const profile = realize.workspace.defaultProfile();
    var layout = try realize.WorkspaceLayout.init(allocator, pkg_root, profile);
    defer layout.deinit();

    // 6. Ensure dirs exist
    try layout.ensureDirs(io);

    // 7. Init store (workspace root = pkg_root)
    var store = try store_mod.Store.init(allocator, io, pkg_root);
    defer store.deinit();

    // 8. Realize each instance
    var source_realizer = realize.SourcePkgRealize.init(allocator, io);
    var binary_adapter = realize.BinaryAdapter.init(allocator, io);

    for (lockfile.instances) |instance| {
        const key_text = try std.fmt.allocPrint(allocator, "{s}#{s}", .{
            instance.key.package_id.asText(),
            instance.key.domain.asText(),
        });
        defer allocator.free(key_text);

        const dest_dir = try layout.depPkgDir(allocator, key_text);
        defer allocator.free(dest_dir);

        // Ensure dep dir exists
        std.Io.Dir.createDirAbsolute(io, dest_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Build dep_realized_paths for this instance.
        // dep_map owns both the key (duped from dep.alias) and the value (allocated path).
        var dep_map = realize.DepPathMap.init(allocator);
        for (instance.deps) |dep| {
            const dep_key_text = try std.fmt.allocPrint(allocator, "{s}#{s}", .{
                dep.instance.package_id.asText(),
                dep.instance.domain.asText(),
            });
            defer allocator.free(dep_key_text);
            const dep_path = try layout.depPkgDir(allocator, dep_key_text);
            errdefer allocator.free(dep_path);
            // Dup dep.alias so the map key doesn't borrow from the lockfile allocation.
            const alias_key = try allocator.dupe(u8, dep.alias);
            errdefer allocator.free(alias_key);
            try dep_map.put(alias_key, dep_path);
        }
        defer {
            var it = dep_map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            dep_map.deinit();
        }

        if (store.hasArtifact(key_text)) {
            // Binary: expand from store and generate adapter
            const expanded = store.expandArtifact(key_text) catch |err| {
                try writeStderrFmt(io, "warning: failed to expand artifact '{s}': {s}\n", .{ key_text, @errorName(err) });
                continue;
            };
            defer allocator.free(expanded);

            const artifact_manifest = store.loadManifest(key_text) catch |err| {
                try writeStderrFmt(io, "warning: failed to load manifest for '{s}': {s}\n", .{ key_text, @errorName(err) });
                continue;
            };
            defer artifact_manifest.deinit(allocator);

            binary_adapter.generate(dest_dir, expanded, artifact_manifest, dep_map) catch |err| {
                try writeStderrFmt(io, "warning: failed to generate adapter for '{s}': {s}\n", .{ key_text, @errorName(err) });
            };
        } else {
            // Source: symlink forest from adjacent source directory.
            // MVP convention: source lives at <pkg_root>/../<last-component-of-package-id>
            // where the last component is the portion after the final '.'.
            // Use instance.package_id (the direct field, same as instance.key.package_id)
            // because it is guaranteed populated by lockfile parsing.
            const pkg_name = instance.package_id.asText();
            // Extract last dot-separated component; fall back to full name if no '.' present.
            const pkg_basename = if (std.mem.lastIndexOfScalar(u8, pkg_name, '.')) |dot_idx|
                pkg_name[dot_idx + 1 ..]
            else
                pkg_name;
            const source_dir = try std.Io.Dir.path.join(allocator, &.{ pkg_root, "..", pkg_basename });
            defer allocator.free(source_dir);

            source_realizer.realize(source_dir, dest_dir, pkg_name, dep_map) catch |err| {
                try writeStderrFmt(io, "warning: failed to realize source for '{s}': {s}\n", .{ key_text, @errorName(err) });
            };
        }
    }

    // 9. Realize root package itself as source pkg
    {
        const root_dir = try layout.rootPkgDir(allocator);
        defer allocator.free(root_dir);

        // root_dep_map owns both duped keys (from dep.alias) and allocated value paths.
        var root_dep_map = realize.DepPathMap.init(allocator);
        defer {
            var it = root_dep_map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            root_dep_map.deinit();
        }

        // Find root instance in lockfile to get its deps.
        // Use manifest.package.id for the source realize call below.
        const root_pkg_name = manifest.package.id.asText();
        for (lockfile.instances) |instance| {
            if (instance.key.package_id.eql(lockfile.root.package_id)) {
                for (instance.deps) |dep| {
                    const dep_key_text = try std.fmt.allocPrint(allocator, "{s}#{s}", .{
                        dep.instance.package_id.asText(),
                        dep.instance.domain.asText(),
                    });
                    defer allocator.free(dep_key_text);
                    const dep_path = try layout.depPkgDir(allocator, dep_key_text);
                    errdefer allocator.free(dep_path);
                    // Dup dep.alias so the map key doesn't borrow from the lockfile allocation.
                    const alias_key = try allocator.dupe(u8, dep.alias);
                    errdefer allocator.free(alias_key);
                    try root_dep_map.put(alias_key, dep_path);
                }
                break;
            }
        }

        source_realizer.realize(pkg_root, root_dir, root_pkg_name, root_dep_map) catch |err| {
            try writeStderrFmt(io, "warning: failed to realize root package: {s}\n", .{@errorName(err)});
        };
    }

    // 10. Print success summary
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer_file.interface;
    try stdout.print(
        "Workspace realized at: {s}\n  Profile: {s}\n  Instances: {d}\n",
        .{ layout.workspace_root, profile, lockfile.instances.len },
    );
    try stdout.flush();
}

fn writeStderr(io: std.Io, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var f: std.Io.File.Writer = .init(.stderr(), io, &buf);
    const w = &f.interface;
    try w.writeAll(text);
    try w.flush();
}

fn writeStderrFmt(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var f: std.Io.File.Writer = .init(.stderr(), io, &buf);
    const w = &f.interface;
    try w.print(fmt, args);
    try w.flush();
}
