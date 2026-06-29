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

    /// Create workspace directory and generate binary adapter for a store-hit instance.
    fn reifyStoreHit(self: *BuildExecutor, key: []const u8, lockfile: model.Lockfile) !void {
        const allocator = self.allocator;

        // Find the lockfile instance.
        const instance_ref = model.lockfile.InstanceRef.parse(key) catch return;
        const instance = lockfile.findInstance(instance_ref) orelse return;

        // Create workspace dep dir.
        const dest_dir = try self.workspace.depPkgDir(allocator, key);
        defer allocator.free(dest_dir);
        std.Io.Dir.createDirAbsolute(self.io, dest_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Expand artifact to the store's expanded prefix.
        const expanded = try self.store.expandArtifact(key);
        defer allocator.free(expanded);

        // Load artifact manifest.
        const artifact_manifest = try self.store.loadManifest(key);
        defer artifact_manifest.deinit(allocator);

        // Build dep_map: alias → workspace dep dir for each dep instance.
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

        // Generate binary adapter.
        var adapter = realize.BinaryAdapter.init(allocator, self.io);
        try adapter.generate(dest_dir, expanded, artifact_manifest, dep_map);
    }

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

                // Generate binary adapter so downstream source builds can consume it.
                self.reifyStoreHit(key, lockfile) catch |err| {
                    try printStderr(self.io, "warning: failed to create binary adapter for '{s}': {s}\n", .{ key, @errorName(err) });
                };
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
        // Multi-pass: patch fingerprint mismatches in any file that Zig reports
        // (including binary adapter deps), then retry until success or real failure.
        const build_ok = build_blk: {
            var pass: usize = 0;
            while (pass < 20) : (pass += 1) {
                const result = try std.process.run(allocator, self.io, .{
                    .argv = &.{ "zig", "build", "install", "--prefix", staging_dir },
                    .cwd = .{ .path = realized_dir },
                });
                defer {
                    allocator.free(result.stdout);
                    allocator.free(result.stderr);
                }

                const ok = switch (result.term) {
                    .exited => |code| code == 0,
                    else => false,
                };
                if (ok) break :build_blk true;

                if (extractSuggestedFingerprint(result.stderr)) |fp| {
                    if (try extractFingerprintFilePath(allocator, result.stderr)) |fpath| {
                        defer allocator.free(fpath);
                        try patchFingerprintInFile(allocator, self.io, fpath, fp);
                        // Retry on next pass.
                        continue;
                    }
                    // No file path in error; fall back to patching the realized dir.
                    try patchFingerprintInBuildZigZon(allocator, self.io, realized_dir, fp);
                    // One more pass with inherited stdio for real build output.
                    var child2 = try std.process.spawn(self.io, .{
                        .argv = &.{ "zig", "build", "install", "--prefix", staging_dir },
                        .cwd = .{ .path = realized_dir },
                        .stdin = .inherit,
                        .stdout = .inherit,
                        .stderr = .inherit,
                    });
                    const term2 = try child2.wait(self.io);
                    switch (term2) {
                        .exited => |code| {
                            if (code != 0) {
                                try printStderr(self.io, "error: build failed for '{s}' (exit code {d})\n", .{ key, code });
                                break :build_blk false;
                            }
                        },
                        else => {
                            try printStderr(self.io, "error: build process for '{s}' terminated abnormally\n", .{key});
                            break :build_blk false;
                        },
                    }
                    break :build_blk true;
                } else {
                    // Real build failure; forward captured stderr.
                    try printRaw(self.io, result.stderr);
                    switch (result.term) {
                        .exited => |code| try printStderr(self.io, "error: build failed for '{s}' (exit code {d})\n", .{ key, code }),
                        else => try printStderr(self.io, "error: build process for '{s}' terminated abnormally\n", .{key}),
                    }
                    break :build_blk false;
                }
            }
            // Exhausted retries.
            try printStderr(self.io, "error: too many fingerprint correction passes for '{s}'\n", .{key});
            break :build_blk false;
        };
        if (!build_ok) return error.BuildFailed;

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

fn printRaw(io: std.Io, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var f: std.Io.File.Writer = .init(.stderr(), io, &buf);
    const w = &f.interface;
    try w.writeAll(text);
    try w.flush();
}

/// Scan zig build stderr for the fingerprint suggestion produced by lines like:
///   "use this value: 0x41a21f2b57209636"
pub fn extractSuggestedFingerprint(stderr: []const u8) ?u64 {
    const needle = "use this value: 0x";
    const start = std.mem.indexOf(u8, stderr, needle) orelse return null;
    const hex_start = start + needle.len;
    // Find end of hex digits.
    var hex_end = hex_start;
    while (hex_end < stderr.len and std.ascii.isHex(stderr[hex_end])) : (hex_end += 1) {}
    if (hex_end == hex_start) return null;
    return std.fmt.parseInt(u64, stderr[hex_start..hex_end], 16) catch null;
}

/// Rewrite the `fingerprint` field in `<dir>/build.zig.zon`.
pub fn patchFingerprintInBuildZigZon(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, fp: u64) !void {
    const file_path = try std.Io.Dir.path.join(allocator, &.{ dir, "build.zig.zon" });
    defer allocator.free(file_path);
    try patchFingerprintInFile(allocator, io, file_path, fp);
}

/// Rewrite the `fingerprint` field in the given `build.zig.zon` file (absolute path).
pub fn patchFingerprintInFile(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, fp: u64) !void {
    const dir_path = std.Io.Dir.path.dirname(file_path) orelse ".";
    const base_name = std.Io.Dir.path.basename(file_path);

    const dir_obj = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir_obj.close(io);

    const content = try dir_obj.readFileAlloc(io, base_name, allocator, .limited(256 * 1024));
    defer allocator.free(content);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    const fp_needle = ".fingerprint = ";
    if (std.mem.indexOf(u8, content, fp_needle)) |needle_pos| {
        // Replace existing fingerprint line.
        try w.writeAll(content[0 .. needle_pos + fp_needle.len]);
        try w.print("0x{x:0>16}", .{fp});
        // Skip old value up to the comma.
        const after_needle = needle_pos + fp_needle.len;
        const comma = std.mem.indexOfScalarPos(u8, content, after_needle, ',') orelse content.len;
        try w.writeAll(content[comma..]);
    } else {
        // Insert fingerprint after opening `.{`.
        const open_brace = std.mem.indexOf(u8, content, ".{\n") orelse {
            // Unexpected format; just prepend.
            try w.print(".{{\n    .fingerprint = 0x{x:0>16},\n", .{fp});
            try w.writeAll(content);
            const patched = try aw.toOwnedSlice();
            defer allocator.free(patched);
            return dir_obj.writeFile(io, .{ .sub_path = base_name, .data = patched });
        };
        const insert_at = open_brace + ".{\n".len;
        try w.writeAll(content[0..insert_at]);
        try w.print("    .fingerprint = 0x{x:0>16},\n", .{fp});
        try w.writeAll(content[insert_at..]);
    }

    const patched = try aw.toOwnedSlice();
    defer allocator.free(patched);
    try dir_obj.writeFile(io, .{ .sub_path = base_name, .data = patched });
}

/// Extract the absolute path to the `build.zig.zon` file that triggered a fingerprint
/// error. Zig's error format is:
///   /abs/path/to/build.zig.zon:1:2: error: invalid fingerprint: ...
/// Returns null if the pattern is not found. Caller owns the returned slice.
pub fn extractFingerprintFilePath(allocator: std.mem.Allocator, stderr: []const u8) !?[]u8 {
    const zon_file = "build.zig.zon";
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, stderr, search_pos, zon_file)) |idx| {
        const after = idx + zon_file.len;
        // Must be followed by ':' (line:col indicator).
        if (after < stderr.len and stderr[after] == ':') {
            // Find the start of the line containing this occurrence.
            const line_start = if (std.mem.lastIndexOfScalar(u8, stderr[0..idx], '\n')) |nl|
                nl + 1
            else
                0;
            // Path = stderr[line_start .. after] (includes "build.zig.zon", excludes ':')
            return try allocator.dupe(u8, stderr[line_start..after]);
        }
        search_pos = after;
    }
    return null;
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
