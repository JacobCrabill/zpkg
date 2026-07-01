const std = @import("std");
const model = @import("../model/root.zig");
const source_hash = @import("../hash/source_hash.zig");
const resolve = @import("root.zig");

/// Build a `model.Lockfile` from a completed resolution.
///
/// For each non-root resolved instance this records the package's source hash and
/// a `source_path` stored relative to `pkg_root` (the lockfile directory) so the
/// lockfile is portable across machines with different checkout locations.
///
/// Shared by the `lock` and `update` commands — the only difference between those
/// commands is what they do with the returned lockfile, not how it is built.
pub fn generateLockfile(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_root: []const u8,
    resolved: resolve.ResolvedRoot,
    resolver: *resolve.Resolver,
) !model.Lockfile {
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

        // Skip the root package — it is represented by lockfile.root, not instances.
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
        // Both pkg_root and dep_dir_path are absolute; pass "/" as cwd (ignored for
        // absolute inputs by resolvePosix internally).
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
