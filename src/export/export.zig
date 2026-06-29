const std = @import("std");
const model = @import("../model/root.zig");
const store_mod = @import("../store/store.zig");

pub const ExportTarget = union(enum) {
    /// Export the entire root package (all target-domain instances).
    package,
    /// Export a specific named target within a specific package.
    named: struct {
        package_id: []const u8,
        target_name: []const u8,
    },
};

pub const ExportOptions = struct {
    target: ExportTarget = .package,
    /// Default: target-domain only.
    domain: model.Domain = .target,
    /// Include test instances. TODO: lockfile has no test markers yet; excluded by name heuristic.
    include_tests: bool = false,
};

/// Plan which instances belong in the export closure.
///
/// Returns a caller-owned slice of owned key strings of the form
/// `"<package_id>#<domain>"`. Free each element and the slice itself.
///
/// TODO: The lockfile does not yet carry a `is_test` flag per instance.
/// As a temporary heuristic, instances whose package_id ends in `.test`
/// or `_test` are excluded when `opts.include_tests` is false.
pub fn planExport(
    allocator: std.mem.Allocator,
    lockfile: model.Lockfile,
    opts: ExportOptions,
) ![]const []const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }

    for (lockfile.instances) |instance| {
        // Filter by domain.
        if (instance.domain != opts.domain) continue;

        // Heuristic test filter (TODO: replace with explicit lockfile marker).
        if (!opts.include_tests) {
            const id = instance.package_id.asText();
            if (std.mem.endsWith(u8, id, ".test") or
                std.mem.endsWith(u8, id, "_test"))
            {
                continue;
            }
        }

        // For named target, filter by package_id and target_name.
        switch (opts.target) {
            .package => {},
            .named => |named| {
                if (!std.mem.eql(u8, instance.package_id.asText(), named.package_id)) continue;
                // Filter by target_name if the instance carries one.
                if (named.target_name.len > 0) {
                    if (instance.target_name) |tn| {
                        if (!std.mem.eql(u8, tn, named.target_name)) continue;
                    }
                    // If instance.target_name is null, include it (backwards compat).
                }
            },
        }

        const key = try std.fmt.allocPrint(
            allocator,
            "{s}#{s}",
            .{ instance.package_id.asText(), instance.domain.asText() },
        );
        errdefer allocator.free(key);
        try keys.append(allocator, key);
    }

    return try keys.toOwnedSlice(allocator);
}

pub const CollisionError = error{
    /// Two source instances provide the same destination path with different content.
    ContentCollision,
};

/// Assemble the export bundle at `dest_dir` from `instance_keys`.
///
/// For each instance, expands it in the store (if needed), then merges
/// `bin/`, `lib/`, `include/`, and `share/` into `dest_dir`.
///
/// Collision policy:
/// - Byte-identical files: allowed (skip the duplicate).
/// - Different-content files: returns `error.ContentCollision` after printing a diagnostic.
pub fn assembleBundle(
    allocator: std.mem.Allocator,
    io: std.Io,
    instance_keys: []const []const u8,
    store: *store_mod.Store,
    dest_dir: []const u8,
) !void {
    // Create destination directory tree.
    std.Io.Dir.createDirAbsolute(io, dest_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const subdirs = [_][]const u8{ "bin", "lib", "include", "share" };

    for (subdirs) |sub| {
        const sub_path = try std.Io.Dir.path.join(allocator, &.{ dest_dir, sub });
        defer allocator.free(sub_path);
        std.Io.Dir.createDirAbsolute(io, sub_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Track which instance provided each destination path for collision diagnostics.
    // key = dest-relative path (owned), value = source instance key (borrowed from instance_keys).
    var path_owner: std.StringHashMapUnmanaged([]const u8) = .{};
    defer {
        var it = path_owner.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        path_owner.deinit(allocator);
    }

    for (instance_keys) |instance_key| {
        const prefix = try store.expandArtifact(instance_key);
        defer allocator.free(prefix);

        for (subdirs) |sub| {
            const src_sub = try std.Io.Dir.path.join(allocator, &.{ prefix, sub });
            defer allocator.free(src_sub);

            // Skip if the subdirectory doesn't exist in this instance's prefix.
            std.Io.Dir.accessAbsolute(io, src_sub, .{}) catch continue;

            const src_dir = try std.Io.Dir.openDirAbsolute(io, src_sub, .{ .iterate = true });
            defer src_dir.close(io);

            var walker = try src_dir.walk(allocator);
            defer walker.deinit();

            while (try walker.next(io)) |entry| {
                if (entry.kind != .file) continue;

                // Relative path within the sub-directory (e.g. "libfoo.a").
                const rel_path = entry.path;

                // Destination path relative to dest_dir root (e.g. "lib/libfoo.a").
                const dest_rel = try std.Io.Dir.path.join(allocator, &.{ sub, rel_path });
                errdefer allocator.free(dest_rel);

                const dest_abs = try std.Io.Dir.path.join(allocator, &.{ dest_dir, dest_rel });
                defer allocator.free(dest_abs);

                // Read source file bytes.
                const src_bytes = try entry.dir.readFileAlloc(io, entry.basename, allocator, .limited(64 * 1024 * 1024));
                defer allocator.free(src_bytes);

                // Check for collision.
                if (std.Io.Dir.accessAbsolute(io, dest_abs, .{})) |_| {
                    // File already exists; check byte equality.
                    const dest_dir_path = std.Io.Dir.path.dirname(dest_abs) orelse dest_dir;
                    const dest_base = std.Io.Dir.path.basename(dest_abs);
                    const dest_d = try std.Io.Dir.openDirAbsolute(io, dest_dir_path, .{});
                    defer dest_d.close(io);
                    const existing_bytes = try dest_d.readFileAlloc(io, dest_base, allocator, .limited(64 * 1024 * 1024));
                    defer allocator.free(existing_bytes);

                    if (std.mem.eql(u8, src_bytes, existing_bytes)) {
                        // Byte-identical collision: skip this file. Free dest_rel now since
                        // it's neither handed to path_owner (success path) nor freed by
                        // the errdefer above (which only fires on error, not on continue).
                        allocator.free(dest_rel);
                        continue;
                    }

                    // Content collision: report and fail.
                    const prior_owner = path_owner.get(dest_rel) orelse "<unknown>";
                    var err_buf: [1024]u8 = undefined;
                    var err_writer_file: std.Io.File.Writer = .init(.stderr(), io, &err_buf);
                    const err_writer = &err_writer_file.interface;
                    try err_writer.print(
                        "error: content collision at '{s}': provided by '{s}' and '{s}'\n",
                        .{ dest_rel, prior_owner, instance_key },
                    );
                    try err_writer.flush();
                    allocator.free(dest_rel);
                    return error.ContentCollision;
                } else |_| {}

                // Ensure parent directory exists.
                const dest_parent = std.Io.Dir.path.dirname(dest_abs) orelse dest_dir;
                if (!std.mem.eql(u8, dest_parent, dest_dir)) {
                    std.Io.Dir.createDirAbsolute(io, dest_parent, .default_dir) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return err,
                    };
                }

                // Write the file.
                const dest_file_dir_path = std.Io.Dir.path.dirname(dest_abs) orelse dest_dir;
                const dest_file_base = std.Io.Dir.path.basename(dest_abs);
                const dest_file_dir = try std.Io.Dir.openDirAbsolute(io, dest_file_dir_path, .{});
                defer dest_file_dir.close(io);
                try dest_file_dir.writeFile(io, .{ .sub_path = dest_file_base, .data = src_bytes });

                // Record ownership for future collision diagnostics.
                const owned_dest_rel = dest_rel; // already allocated
                try path_owner.put(allocator, owned_dest_rel, instance_key);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "planExport: filters by domain and test heuristic" {
    const allocator = std.testing.allocator;
    const model_pkg = @import("../model/root.zig");

    // Build a minimal lockfile with three instances:
    //   1. foo#target   -> should be included
    //   2. foo.test#target -> excluded by test heuristic
    //   3. foo#host     -> excluded by domain filter
    const pid_foo = try model_pkg.PackageId.parse("zpkg.example.foo");
    const pid_foo_test = try model_pkg.PackageId.parse("zpkg.example.foo.test");

    const instances = try allocator.alloc(model_pkg.LockfileInstance, 3);
    defer allocator.free(instances);

    instances[0] = .{
        .key = .{ .package_id = pid_foo, .domain = .target },
        .package_id = pid_foo,
        .domain = .target,
        .version = .{ .major = 1, .minor = 0, .patch = 0, .revision = 0 },
        .source_hash = "sha256:aabb",
        .source_path = "/fake/foo",
        .selected_options = &.{},
        .deps = &.{},
    };
    instances[1] = .{
        .key = .{ .package_id = pid_foo_test, .domain = .target },
        .package_id = pid_foo_test,
        .domain = .target,
        .version = .{ .major = 1, .minor = 0, .patch = 0, .revision = 0 },
        .source_hash = "sha256:ccdd",
        .source_path = "/fake/foo_test",
        .selected_options = &.{},
        .deps = &.{},
    };
    instances[2] = .{
        .key = .{ .package_id = pid_foo, .domain = .host },
        .package_id = pid_foo,
        .domain = .host,
        .version = .{ .major = 1, .minor = 0, .patch = 0, .revision = 0 },
        .source_hash = "sha256:eeff",
        .source_path = "/fake/foo_host",
        .selected_options = &.{},
        .deps = &.{},
    };

    const lockfile: model_pkg.Lockfile = .{
        .schema = 1,
        .root = .{
            .package_id = pid_foo,
            .version = .{ .major = 1, .minor = 0, .patch = 0, .revision = 0 },
        },
        .generated_by = null,
        .instances = instances,
    };

    const keys = try planExport(allocator, lockfile, .{});
    defer {
        for (keys) |k| allocator.free(k);
        allocator.free(keys);
    }

    try std.testing.expectEqual(@as(usize, 1), keys.len);
    try std.testing.expectEqualStrings("zpkg.example.foo#target", keys[0]);
}

test "planExport: include_tests includes test-suffixed instances" {
    const allocator = std.testing.allocator;
    const model_pkg = @import("../model/root.zig");

    const pid_bar = try model_pkg.PackageId.parse("zpkg.example.bar");
    const pid_bar_test = try model_pkg.PackageId.parse("zpkg.example.bar.test");

    const instances = try allocator.alloc(model_pkg.LockfileInstance, 2);
    defer allocator.free(instances);

    instances[0] = .{
        .key = .{ .package_id = pid_bar, .domain = .target },
        .package_id = pid_bar,
        .domain = .target,
        .version = .{ .major = 0, .minor = 1, .patch = 0, .revision = 0 },
        .source_hash = "sha256:1111",
        .source_path = "/fake/bar",
        .selected_options = &.{},
        .deps = &.{},
    };
    instances[1] = .{
        .key = .{ .package_id = pid_bar_test, .domain = .target },
        .package_id = pid_bar_test,
        .domain = .target,
        .version = .{ .major = 0, .minor = 1, .patch = 0, .revision = 0 },
        .source_hash = "sha256:2222",
        .source_path = "/fake/bar_test",
        .selected_options = &.{},
        .deps = &.{},
    };

    const lockfile: model_pkg.Lockfile = .{
        .schema = 1,
        .root = .{
            .package_id = pid_bar,
            .version = .{ .major = 0, .minor = 1, .patch = 0, .revision = 0 },
        },
        .generated_by = null,
        .instances = instances,
    };

    const keys = try planExport(allocator, lockfile, .{ .include_tests = true });
    defer {
        for (keys) |k| allocator.free(k);
        allocator.free(keys);
    }

    try std.testing.expectEqual(@as(usize, 2), keys.len);
}

test "planExport: named target filters by target_name" {
    const allocator = std.testing.allocator;
    const model_pkg = @import("../model/root.zig");

    // Two instances for the same package_id but different target_names.
    // planExport with named target "lib" should return only instance[0].
    const pid = try model_pkg.PackageId.parse("zpkg.example.multi");

    const instances = try allocator.alloc(model_pkg.LockfileInstance, 2);
    defer allocator.free(instances);

    instances[0] = .{
        .key = .{ .package_id = pid, .domain = .target },
        .package_id = pid,
        .domain = .target,
        .version = .{ .major = 1, .minor = 0, .patch = 0, .revision = 0 },
        .source_hash = "sha256:aaaa",
        .source_path = "/fake/multi",
        .selected_options = &.{},
        .deps = &.{},
        .target_name = "lib",
    };
    instances[1] = .{
        .key = .{ .package_id = pid, .domain = .target },
        .package_id = pid,
        .domain = .target,
        .version = .{ .major = 1, .minor = 0, .patch = 0, .revision = 0 },
        .source_hash = "sha256:bbbb",
        .source_path = "/fake/multi",
        .selected_options = &.{},
        .deps = &.{},
        .target_name = "exe",
    };

    const lockfile: model_pkg.Lockfile = .{
        .schema = 1,
        .root = .{
            .package_id = pid,
            .version = .{ .major = 1, .minor = 0, .patch = 0, .revision = 0 },
        },
        .generated_by = null,
        .instances = instances,
    };

    // Filter by target_name "lib" — should match only instances[0].
    const keys = try planExport(allocator, lockfile, .{
        .target = .{ .named = .{ .package_id = "zpkg.example.multi", .target_name = "lib" } },
    });
    defer {
        for (keys) |k| allocator.free(k);
        allocator.free(keys);
    }

    try std.testing.expectEqual(@as(usize, 1), keys.len);
    try std.testing.expectEqualStrings("zpkg.example.multi#target", keys[0]);

    // Filter by target_name "exe" — should match only instances[1].
    const keys2 = try planExport(allocator, lockfile, .{
        .target = .{ .named = .{ .package_id = "zpkg.example.multi", .target_name = "exe" } },
    });
    defer {
        for (keys2) |k| allocator.free(k);
        allocator.free(keys2);
    }

    try std.testing.expectEqual(@as(usize, 1), keys2.len);
    try std.testing.expectEqualStrings("zpkg.example.multi#target", keys2[0]);

    // Filter with empty target_name — should match both (backwards compat).
    const keys3 = try planExport(allocator, lockfile, .{
        .target = .{ .named = .{ .package_id = "zpkg.example.multi", .target_name = "" } },
    });
    defer {
        for (keys3) |k| allocator.free(k);
        allocator.free(keys3);
    }

    try std.testing.expectEqual(@as(usize, 2), keys3.len);
}
