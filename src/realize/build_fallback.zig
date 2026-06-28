const std = @import("std");
const model = @import("../model/root.zig");
const store_mod = @import("../store/store.zig");
const realize = @import("root.zig");
const manifest_mod = @import("../store/manifest.zig");

pub const BuildMode = enum { build, build_with_tests, run_tests };

pub const BuildPlan = struct {
    allocator: std.mem.Allocator,
    /// Build mode for this plan (propagated to the executor).
    mode: BuildMode,
    /// Ordered list of instance key strings (dependency-first, leaves first).
    build_order: [][]u8,
    /// Instance keys already satisfied by the store.
    store_hits: std.StringHashMap(void),
    /// Instance keys that need source builds.
    store_misses: std.StringHashMap(void),

    pub fn deinit(self: *BuildPlan) void {
        for (self.build_order) |key| self.allocator.free(key);
        self.allocator.free(self.build_order);

        var hit_it = self.store_hits.keyIterator();
        while (hit_it.next()) |k| self.allocator.free(k.*);
        self.store_hits.deinit();

        var miss_it = self.store_misses.keyIterator();
        while (miss_it.next()) |k| self.allocator.free(k.*);
        self.store_misses.deinit();

        self.* = undefined;
    }
};

/// Plan which instances need building given a lockfile and store state.
/// Returns instances in dependency-first topological order.
pub fn planBuild(
    allocator: std.mem.Allocator,
    lockfile: model.Lockfile,
    store: *store_mod.Store,
    mode: BuildMode,
) !BuildPlan {
    var order: std.ArrayList([]u8) = .empty;
    errdefer {
        for (order.items) |k| allocator.free(k);
        order.deinit(allocator);
    }

    var store_hits = std.StringHashMap(void).init(allocator);
    errdefer {
        var it = store_hits.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        store_hits.deinit();
    }

    var store_misses = std.StringHashMap(void).init(allocator);
    errdefer {
        var it = store_misses.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        store_misses.deinit();
    }

    // visited set tracks instance keys we've already appended to order.
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var it = visited.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        visited.deinit();
    }

    // DFS from each instance not yet visited.
    for (lockfile.instances) |*instance| {
        const key_text = try std.fmt.allocPrint(allocator, "{s}#{s}", .{
            instance.key.package_id.asText(),
            instance.key.domain.asText(),
        });
        defer allocator.free(key_text);

        if (visited.contains(key_text)) continue;

        try dfsVisit(
            allocator,
            lockfile,
            instance,
            &visited,
            &order,
            &store_hits,
            &store_misses,
            store,
        );
    }

    return .{
        .allocator = allocator,
        .mode = mode,
        .build_order = try order.toOwnedSlice(allocator),
        .store_hits = store_hits,
        .store_misses = store_misses,
    };
}

fn dfsVisit(
    allocator: std.mem.Allocator,
    lockfile: model.Lockfile,
    instance: *const model.lockfile.Instance,
    visited: *std.StringHashMap(void),
    order: *std.ArrayList([]u8),
    store_hits: *std.StringHashMap(void),
    store_misses: *std.StringHashMap(void),
    store: *store_mod.Store,
) !void {
    const key_text = try std.fmt.allocPrint(allocator, "{s}#{s}", .{
        instance.key.package_id.asText(),
        instance.key.domain.asText(),
    });
    defer allocator.free(key_text);

    if (visited.contains(key_text)) return;

    // Mark visited before recursing to handle cycles gracefully.
    const visited_key = try allocator.dupe(u8, key_text);
    errdefer allocator.free(visited_key);
    try visited.put(visited_key, {});

    // Visit deps first.
    for (instance.deps) |dep| {
        const dep_key_text = try std.fmt.allocPrint(allocator, "{s}#{s}", .{
            dep.instance.package_id.asText(),
            dep.instance.domain.asText(),
        });
        defer allocator.free(dep_key_text);

        if (visited.contains(dep_key_text)) continue;

        if (lockfile.findInstance(dep.instance)) |dep_instance| {
            try dfsVisit(allocator, lockfile, dep_instance, visited, order, store_hits, store_misses, store);
        }
    }

    // Append this instance to the order.
    const order_key = try allocator.dupe(u8, key_text);
    errdefer allocator.free(order_key);
    try order.append(allocator, order_key);

    // Check store.
    if (store.hasArtifact(key_text)) {
        const hit_key = try allocator.dupe(u8, key_text);
        errdefer allocator.free(hit_key);
        try store_hits.put(hit_key, {});
    } else {
        const miss_key = try allocator.dupe(u8, key_text);
        errdefer allocator.free(miss_key);
        try store_misses.put(miss_key, {});
    }
}

pub const BuildExecutor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *store_mod.Store,
    workspace: *realize.WorkspaceLayout,
    /// Root package source directory (absolute path).
    pkg_root: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        store: *store_mod.Store,
        workspace: *realize.WorkspaceLayout,
        pkg_root: []const u8,
    ) BuildExecutor {
        return .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .workspace = workspace,
            .pkg_root = pkg_root,
        };
    }

    pub fn deinit(_: *BuildExecutor) void {}

    pub fn execute(
        self: *BuildExecutor,
        plan: BuildPlan,
        lockfile: model.Lockfile,
    ) !void {
        var stdout_buf: [4096]u8 = undefined;
        var stdout_file: std.Io.File.Writer = .init(.stdout(), self.io, &stdout_buf);
        const stdout = &stdout_file.interface;

        var any_test_failed = false;

        for (plan.build_order) |key| {
            if (plan.store_hits.contains(key)) {
                if (plan.mode == .run_tests) {
                    try stdout.print("[skip] {s} (pre-built; no test binary)\n", .{key});
                } else {
                    try stdout.print("[hit]  {s}\n", .{key});
                }
                try stdout.flush();
                continue;
            }

            // Find the instance in the lockfile.
            const instance_ref = model.lockfile.InstanceRef.parse(key) catch {
                try printStderr(self.io, "error: invalid instance key in plan: {s}\n", .{key});
                return error.InvalidInstanceKey;
            };
            const instance = lockfile.findInstance(instance_ref) orelse {
                try printStderr(self.io, "error: instance not found in lockfile: {s}\n", .{key});
                return error.InstanceNotFound;
            };

            try stdout.print("[build] {s}\n", .{key});
            try stdout.flush();

            self.buildInstance(instance, key, lockfile, plan.mode) catch |err| {
                if (err == error.TestsFailed) {
                    any_test_failed = true;
                    try stdout.print("[fail]  {s} (tests failed)\n", .{key});
                    try stdout.flush();
                    continue;
                }
                return err;
            };

            try stdout.print("[done]  {s}\n", .{key});
            try stdout.flush();
        }

        if (any_test_failed) return error.TestsFailed;
    }

    fn buildInstance(
        self: *BuildExecutor,
        instance: *const model.lockfile.Instance,
        key: []const u8,
        lockfile: model.Lockfile,
        mode: BuildMode,
    ) !void {
        const allocator = self.allocator;

        // Determine source directory: <pkg_root>/../<basename_of_package_id>
        const pkg_name = instance.package_id.asText();
        const pkg_basename = if (std.mem.lastIndexOfScalar(u8, pkg_name, '.')) |dot_idx|
            pkg_name[dot_idx + 1 ..]
        else
            pkg_name;
        const source_dir = try std.Io.Dir.path.join(allocator, &.{ self.pkg_root, "..", pkg_basename });
        defer allocator.free(source_dir);

        // Realized source dir in workspace: deps/<key>/
        const realized_dir = try self.workspace.depPkgDir(allocator, key);
        defer allocator.free(realized_dir);

        // Ensure realized dir exists.
        std.Io.Dir.createDirAbsolute(self.io, realized_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Build dep_realized_paths for this instance.
        var dep_map = realize.DepPathMap.init(allocator);
        defer {
            var it = dep_map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            dep_map.deinit();
        }
        for (instance.deps) |dep| {
            const dep_key = try std.fmt.allocPrint(allocator, "{s}#{s}", .{
                dep.instance.package_id.asText(),
                dep.instance.domain.asText(),
            });
            defer allocator.free(dep_key);
            const dep_path = try self.workspace.depPkgDir(allocator, dep_key);
            errdefer allocator.free(dep_path);
            const alias_key = try allocator.dupe(u8, dep.alias);
            errdefer allocator.free(alias_key);
            try dep_map.put(alias_key, dep_path);
        }

        // Realize source package into workspace.
        var source_realizer = realize.SourcePkgRealize.init(allocator, self.io);
        source_realizer.realize(source_dir, realized_dir, pkg_name, dep_map) catch |err| {
            try printStderr(self.io, "error: failed to realize source for '{s}': {s}\n", .{ key, @errorName(err) });
            return error.RealizeFailed;
        };

        // Create staging dir: <workspace_root>/staging/<key>/
        const staging_dir = try std.Io.Dir.path.join(allocator, &.{ self.workspace.workspace_root, "staging", key });
        defer allocator.free(staging_dir);

        std.Io.Dir.createDirAbsolute(self.io, staging_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                // Try creating parent first.
                const staging_parent = try std.Io.Dir.path.join(allocator, &.{ self.workspace.workspace_root, "staging" });
                defer allocator.free(staging_parent);
                std.Io.Dir.createDirAbsolute(self.io, staging_parent, .default_dir) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return e,
                };
                std.Io.Dir.createDirAbsolute(self.io, staging_dir, .default_dir) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return e,
                };
            },
        };

        // Run `zig build install --prefix <staging_dir>` inside realized_dir.
        var child = try std.process.spawn(self.io, .{
            .argv = &.{ "zig", "build", "install", "--prefix", staging_dir },
            .cwd = .{ .path = realized_dir },
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        const term = try child.wait(self.io);
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    try printStderr(self.io, "error: build failed for '{s}' (exit code {d})\n", .{ key, code });
                    return error.BuildFailed;
                }
            },
            else => {
                try printStderr(self.io, "error: build process for '{s}' terminated abnormally\n", .{key});
                return error.BuildFailed;
            },
        }

        // Build dep_instances list for the manifest.
        const dep_instances = try allocator.alloc(manifest_mod.InstanceRef, instance.deps.len);
        // defer (not errdefer) covers both success and error; errdefer here would double-free the
        // outer slice since the defer block below unconditionally frees it.
        var dep_instances_init: usize = 0;
        defer {
            for (dep_instances[0..dep_instances_init]) |d| d.deinitOwned(allocator);
            allocator.free(dep_instances);
        }
        for (instance.deps, 0..) |dep, i| {
            const dep_key = try std.fmt.allocPrint(allocator, "{s}#{s}", .{
                dep.instance.package_id.asText(),
                dep.instance.domain.asText(),
            });
            defer allocator.free(dep_key);
            dep_instances[i] = try manifest_mod.InstanceRef.parseOwned(allocator, dep_key);
            dep_instances_init += 1;
        }

        // Build selected_options list for the manifest.
        const selected_options = try allocator.alloc(model.NamedOptionValue, instance.selected_options.len);
        var selected_options_init: usize = 0;
        defer {
            for (selected_options[0..selected_options_init]) |opt| allocator.free(opt.name);
            allocator.free(selected_options);
        }
        for (instance.selected_options, 0..) |opt, i| {
            selected_options[i] = .{
                .name = try allocator.dupe(u8, opt.name),
                .value = opt.value, // OptionValue is a tagged union; no heap for scalar variants
            };
            selected_options_init += 1;
        }

        const instance_ref = try manifest_mod.InstanceRef.parseOwned(allocator, key);
        // defer (not errdefer): storeArtifact only reads the manifest; we own instance_ref
        // throughout and must free it regardless of whether storeArtifact succeeds or fails.
        defer instance_ref.deinitOwned(allocator);

        const source_hash = try allocator.dupe(u8, if (instance.source_hash.len > 0) instance.source_hash else "");
        defer allocator.free(source_hash);

        const artifact_manifest = manifest_mod.ArtifactManifest{
            .schema = 1,
            .instance = instance_ref,
            .version = instance.version,
            .source_hash = source_hash,
            .selected_options = selected_options,
            .dep_instances = dep_instances,
        };
        // storeArtifact serializes the manifest but does not take ownership of any fields.
        // All heap fields (instance_ref, source_hash, selected_options, dep_instances) are
        // freed by the defer blocks above when this function exits.
        _ = lockfile; // suppress unused warning
        try self.store.storeArtifact(key, staging_dir, artifact_manifest);

        // When running in test mode, execute `zig build test --prefix <staging_dir>` as well.
        if (mode == .run_tests) {
            var test_child = try std.process.spawn(self.io, .{
                .argv = &.{ "zig", "build", "test", "--prefix", staging_dir },
                .cwd = .{ .path = realized_dir },
                .stdin = .inherit,
                .stdout = .inherit,
                .stderr = .inherit,
            });
            const test_term = try test_child.wait(self.io);
            switch (test_term) {
                .exited => |code| {
                    if (code != 0) {
                        try printStderr(self.io, "error: tests failed for '{s}' (exit code {d})\n", .{ key, code });
                        return error.TestsFailed;
                    }
                },
                else => {
                    try printStderr(self.io, "error: test process for '{s}' terminated abnormally\n", .{key});
                    return error.TestsFailed;
                },
            }
        }
    }
};

fn printStderr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [2048]u8 = undefined;
    var f: std.Io.File.Writer = .init(.stderr(), io, &buf);
    const w = &f.interface;
    try w.print(fmt, args);
    try w.flush();
}

test "planBuild topological order: leaves before parents" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Build a simple lockfile: root depends on lib, lib has no deps.
    const lib_ref = try model.lockfile.InstanceRef.parseOwned(allocator, "zpkg.example.lib#target");
    const root_ref = try model.lockfile.InstanceRef.parseOwned(allocator, "zpkg.example.root#target");

    // Dep entry in root pointing to lib.
    const dep_ref_for_root = try model.lockfile.InstanceRef.parseOwned(allocator, "zpkg.example.lib#target");
    const dep_alias = try allocator.dupe(u8, "lib");

    const lib_deps = try allocator.alloc(model.lockfile.Dependency, 0);
    const lib_options = try allocator.alloc(model.NamedOptionValue, 0);
    const root_deps = try allocator.alloc(model.lockfile.Dependency, 1);
    root_deps[0] = .{ .alias = dep_alias, .instance = dep_ref_for_root };
    const root_options = try allocator.alloc(model.NamedOptionValue, 0);

    const lib_source_hash = try allocator.dupe(u8, "");
    const root_source_hash = try allocator.dupe(u8, "");

    const instances = try allocator.alloc(model.lockfile.Instance, 2);
    instances[0] = .{
        .key = root_ref,
        .package_id = try model.PackageId.parseOwned(allocator, "zpkg.example.root"),
        .domain = .target,
        .version = .{ .major = 0, .minor = 1, .patch = 0, .revision = 0 },
        .source_hash = root_source_hash,
        .selected_options = root_options,
        .deps = root_deps,
    };
    instances[1] = .{
        .key = lib_ref,
        .package_id = try model.PackageId.parseOwned(allocator, "zpkg.example.lib"),
        .domain = .target,
        .version = .{ .major = 0, .minor = 1, .patch = 0, .revision = 0 },
        .source_hash = lib_source_hash,
        .selected_options = lib_options,
        .deps = lib_deps,
    };

    const root_pkg_ref = try model.PackageId.parseOwned(allocator, "zpkg.example.root");
    const lockfile = model.Lockfile{
        .schema = 1,
        .root = .{
            .package_id = root_pkg_ref,
            .version = .{ .major = 0, .minor = 1, .patch = 0, .revision = 0 },
        },
        .generated_by = null,
        .instances = instances,
    };
    defer lockfile.deinit(allocator);

    // Store.init needs <workspace>/.zpkg to exist before it can create the store subdir.
    std.Io.Dir.createDirAbsolute(io, "/tmp/.zpkg", .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    var store = try store_mod.Store.init(allocator, io, "/tmp");
    defer store.deinit();

    var plan = try planBuild(allocator, lockfile, &store, .build);
    defer plan.deinit();

    // The plan should have both instances.
    try std.testing.expectEqual(@as(usize, 2), plan.build_order.len);

    // lib must appear before root in the order (lib is a leaf dep of root).
    var lib_pos: ?usize = null;
    var root_pos: ?usize = null;
    for (plan.build_order, 0..) |key, i| {
        if (std.mem.eql(u8, key, "zpkg.example.lib#target")) lib_pos = i;
        if (std.mem.eql(u8, key, "zpkg.example.root#target")) root_pos = i;
    }
    try std.testing.expect(lib_pos != null);
    try std.testing.expect(root_pos != null);
    try std.testing.expect(lib_pos.? < root_pos.?);
}
