const std = @import("std");
const model = @import("../model/root.zig");
const store_mod = @import("../store/store.zig");
const realize = @import("root.zig");
const realizer_mod = @import("realizer.zig");
const manifest_mod = @import("../store/manifest.zig");
const instance_key_mod = @import("../hash/instance_key.zig");
const toolchain_fingerprint_mod = @import("../hash/toolchain_fingerprint.zig");
const source_hash_mod = @import("../hash/source_hash.zig");

pub const BuildMode = enum { build, build_with_tests, run_tests };

pub const BuildPlan = struct {
    allocator: std.mem.Allocator,
    /// Build mode for this plan (propagated to the executor).
    mode: BuildMode,
    /// Ordered list of display keys (<pkg_id>#<domain>), dependency-first.
    build_order: [][]u8,
    /// Wave-grouped view of build_order.
    /// waves[i] is a slice of pointers borrowed from build_order (not owned strings).
    /// Outer slice (waves) and inner slices (per-wave) are owned; strings are NOT freed here.
    waves: [][][]u8,
    /// Display keys already satisfied by the store.
    store_hits: std.StringHashMap(void),
    /// Display keys that need source builds.
    store_misses: std.StringHashMap(void),
    /// Maps display key (<pkg_id>#<domain>) → content-addressed hex-digest store key.
    /// Both key and value slices are owned by this map.
    instance_keys: std.StringHashMap([]const u8),

    pub fn deinit(self: *BuildPlan) void {
        // Free wave slices (inner and outer); strings are borrowed from build_order.
        for (self.waves) |wave| self.allocator.free(wave);
        self.allocator.free(self.waves);

        for (self.build_order) |key| self.allocator.free(key);
        self.allocator.free(self.build_order);

        var hit_it = self.store_hits.keyIterator();
        while (hit_it.next()) |k| self.allocator.free(k.*);
        self.store_hits.deinit();

        var miss_it = self.store_misses.keyIterator();
        while (miss_it.next()) |k| self.allocator.free(k.*);
        self.store_misses.deinit();

        var ik_it = self.instance_keys.iterator();
        while (ik_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.instance_keys.deinit();

        self.* = undefined;
    }
};

/// Plan which instances need building given a lockfile and store state.
/// Returns instances in dependency-first topological order, grouped into waves.
/// `toolchain_fp` is used to derive content-addressed store keys.
pub fn planBuild(
    allocator: std.mem.Allocator,
    lockfile: model.Lockfile,
    store: *store_mod.Store,
    mode: BuildMode,
    toolchain_fp: model.ToolchainFingerprint,
) !BuildPlan {
    var order: std.ArrayList([]u8) = .empty;
    errdefer {
        for (order.items) |k| allocator.free(k);
        order.deinit(allocator);
    }

    var levels: std.ArrayList(usize) = .empty;
    errdefer levels.deinit(allocator);

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

    var instance_keys = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = instance_keys.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        instance_keys.deinit();
    }

    // visited maps display key → computed level. Value 0 is both "leaf" and "in-progress"
    // (cycle guard); the actual level is updated after deps are processed.
    var visited = std.StringHashMap(usize).init(allocator);
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

        _ = try dfsVisit(
            allocator,
            lockfile,
            instance,
            &visited,
            &order,
            &levels,
            &store_hits,
            &store_misses,
            &instance_keys,
            store,
            toolchain_fp,
        );
    }

    // Build wave structure: group build_order entries by their level.
    const build_order_slice = try order.toOwnedSlice(allocator);
    errdefer {
        for (build_order_slice) |k| allocator.free(k);
        allocator.free(build_order_slice);
    }
    const levels_slice = try levels.toOwnedSlice(allocator);
    defer allocator.free(levels_slice);

    var max_level: usize = 0;
    for (levels_slice) |lvl| max_level = @max(max_level, lvl);

    // Count nodes per level.
    const level_counts = try allocator.alloc(usize, max_level + 1);
    defer allocator.free(level_counts);
    @memset(level_counts, 0);
    for (levels_slice) |lvl| level_counts[lvl] += 1;

    // Allocate outer waves slice; init each inner slice to empty so errdefer is safe.
    const waves = try allocator.alloc([][]u8, max_level + 1);
    errdefer {
        for (waves) |w| allocator.free(w);
        allocator.free(waves);
    }
    for (waves) |*w| w.* = &.{};
    for (0..max_level + 1) |i| {
        waves[i] = try allocator.alloc([]u8, level_counts[i]);
    }

    // Fill waves (reuse level_counts as fill cursor).
    @memset(level_counts, 0);
    for (build_order_slice, levels_slice) |key, lvl| {
        waves[lvl][level_counts[lvl]] = key; // borrowed pointer into build_order_slice
        level_counts[lvl] += 1;
    }

    return .{
        .allocator = allocator,
        .mode = mode,
        .build_order = build_order_slice,
        .waves = waves,
        .store_hits = store_hits,
        .store_misses = store_misses,
        .instance_keys = instance_keys,
    };
}

/// Recursive DFS visitor. Returns the computed level of `instance` (0 for leaves).
/// Appends to `order` and `levels` in post-order (deps before parent).
fn dfsVisit(
    allocator: std.mem.Allocator,
    lockfile: model.Lockfile,
    instance: *const model.lockfile.Instance,
    visited: *std.StringHashMap(usize),
    order: *std.ArrayList([]u8),
    levels: *std.ArrayList(usize),
    store_hits: *std.StringHashMap(void),
    store_misses: *std.StringHashMap(void),
    instance_keys: *std.StringHashMap([]const u8),
    store: *store_mod.Store,
    toolchain_fp: model.ToolchainFingerprint,
) !usize {
    const key_text = try std.fmt.allocPrint(allocator, "{s}#{s}", .{
        instance.key.package_id.asText(),
        instance.key.domain.asText(),
    });
    defer allocator.free(key_text);

    // Already visited — return cached level (or 0 for in-progress cycle guard).
    if (visited.get(key_text)) |level| return level;

    // Mark as in-progress with placeholder level 0 to break cycles.
    const visited_key = try allocator.dupe(u8, key_text);
    var visited_key_taken = false;
    errdefer if (!visited_key_taken) allocator.free(visited_key);
    try visited.put(visited_key, 0);
    visited_key_taken = true;

    // Visit deps first and accumulate the maximum dep level.
    var node_level: usize = 0;
    for (instance.deps) |dep| {
        const dep_key_text = try std.fmt.allocPrint(allocator, "{s}#{s}", .{
            dep.instance.package_id.asText(),
            dep.instance.domain.asText(),
        });
        defer allocator.free(dep_key_text);

        if (visited.get(dep_key_text)) |dep_level| {
            // Already visited (or in-progress cycle): use its cached level.
            node_level = @max(node_level, dep_level + 1);
            continue;
        }

        if (lockfile.findInstance(dep.instance)) |dep_instance| {
            const dep_level = try dfsVisit(
                allocator,
                lockfile,
                dep_instance,
                visited,
                order,
                levels,
                store_hits,
                store_misses,
                instance_keys,
                store,
                toolchain_fp,
            );
            node_level = @max(node_level, dep_level + 1);
        }
    }

    // Update visited entry with the actual computed level (was 0 placeholder).
    if (visited.getPtr(key_text)) |ptr| ptr.* = node_level;

    // Build the dep list for hash computation.
    // Each dep_hex slice is duped so it remains valid after the loop body frees dep_display.
    const owned_dep_keys = try allocator.alloc([]u8, instance.deps.len);
    var owned_dep_count: usize = 0;
    defer {
        for (owned_dep_keys[0..owned_dep_count]) |k| allocator.free(k);
        allocator.free(owned_dep_keys);
    }

    const deps_for_hash = try allocator.alloc(instance_key_mod.Dependency, instance.deps.len);
    defer allocator.free(deps_for_hash);

    for (instance.deps, 0..) |dep, i| {
        const dep_display = try std.fmt.allocPrint(allocator, "{s}#{s}", .{
            dep.instance.package_id.asText(),
            dep.instance.domain.asText(),
        });
        defer allocator.free(dep_display);

        // Prefer the already-computed hex key; fall back to the display key.
        const dep_hex_src = instance_keys.get(dep_display) orelse dep_display;
        const dep_hex = try allocator.dupe(u8, dep_hex_src);
        // No errdefer: owned_dep_keys[0..owned_dep_count] defer above handles cleanup.
        owned_dep_keys[owned_dep_count] = dep_hex;
        owned_dep_count += 1;

        deps_for_hash[i] = .{
            .instance_ref = dep.instance,
            .instance_key = dep_hex,
        };
    }

    // Derive the content-addressed store key.
    // TODO: thread actual optimize mode and linkage through BuildPlan.
    const hex_digest = instance_key_mod.deriveHex(allocator, .{
        .package_id = instance.key.package_id,
        .version = instance.version,
        .domain = instance.key.domain,
        .source_hash = instance.source_hash,
        .selected_options = instance.selected_options,
        .optimize = .Debug, // MVP: single debug-native profile
        .linkage = .static,
        .toolchain_fingerprint = toolchain_fp,
        .dependencies = deps_for_hash,
    }) catch fallbackHex(key_text, toolchain_fp);

    // Store mapping: display_key → hex_digest (both owned by instance_keys).
    const ik_key = try allocator.dupe(u8, key_text);
    var ik_key_taken = false;
    errdefer if (!ik_key_taken) allocator.free(ik_key);
    const hex_str = try allocator.dupe(u8, &hex_digest);
    var hex_str_taken = false;
    errdefer if (!hex_str_taken) allocator.free(hex_str);
    try instance_keys.put(ik_key, hex_str);
    ik_key_taken = true;
    hex_str_taken = true;

    // Append display key to build order and its level to levels.
    const order_key = try allocator.dupe(u8, key_text);
    var order_key_taken = false;
    errdefer if (!order_key_taken) allocator.free(order_key);
    try order.append(allocator, order_key);
    order_key_taken = true;
    try levels.append(allocator, node_level);

    // Check store using the content-addressed key.
    if (store.hasArtifact(hex_str)) {
        const hit_key = try allocator.dupe(u8, key_text);
        errdefer allocator.free(hit_key);
        try store_hits.put(hit_key, {});
    } else {
        const miss_key = try allocator.dupe(u8, key_text);
        errdefer allocator.free(miss_key);
        try store_misses.put(miss_key, {});
    }

    return node_level;
}

/// Produce a deterministic 64-char hex fallback when `deriveHex` cannot run
/// (e.g. because the lockfile instance has an empty source_hash in a test fixture).
/// Includes the toolchain fingerprint so artifacts from different toolchains do not
/// collide even when source_hash is missing.
fn fallbackHex(display_key: []const u8, toolchain_fp: model.ToolchainFingerprint) std.Build.Cache.HexDigest {
    var hh: std.Build.Cache.HashHelper = .{};
    hh.addBytes("zpkg.fallback");
    hh.addBytes(display_key);
    toolchain_fingerprint_mod.addToHash(&hh, toolchain_fp) catch {};
    return hh.final();
}

/// Shared context passed to each parallel build worker.
const WorkerCtx = struct {
    executor: *BuildExecutor,
    instance: *const model.lockfile.Instance,
    display_key: []const u8,
    store_key: []const u8,
    lockfile: model.Lockfile,
    mode: BuildMode,
    stdout_mutex: *std.Io.Mutex,
    failed: *std.atomic.Value(bool),
    test_failed: *std.atomic.Value(bool),
};

/// Thread worker: builds one instance and prints status under the shared mutex.
fn buildWorker(ctx: *WorkerCtx) void {
    const short_key = ctx.store_key[0..@min(16, ctx.store_key.len)];

    {
        ctx.stdout_mutex.lockUncancelable(ctx.executor.io);
        defer ctx.stdout_mutex.unlock(ctx.executor.io);
        var buf: [512]u8 = undefined;
        var f: std.Io.File.Writer = .init(.stdout(), ctx.executor.io, &buf);
        f.interface.print("[build] {s}  {s}\n", .{ ctx.display_key, short_key }) catch {};
        f.interface.flush() catch {};
    }

    ctx.executor.buildInstance(ctx.instance, ctx.display_key, ctx.store_key, ctx.lockfile, ctx.mode) catch |err| {
        ctx.failed.store(true, .release);
        if (err == error.TestsFailed) ctx.test_failed.store(true, .release);
        ctx.stdout_mutex.lockUncancelable(ctx.executor.io);
        defer ctx.stdout_mutex.unlock(ctx.executor.io);
        var buf: [512]u8 = undefined;
        var f: std.Io.File.Writer = .init(.stdout(), ctx.executor.io, &buf);
        f.interface.print("[fail]  {s}  {s}\n", .{ ctx.display_key, short_key }) catch {};
        f.interface.flush() catch {};
        return;
    };

    ctx.executor.reifyStoreHit(ctx.display_key, ctx.store_key, ctx.lockfile) catch {};

    {
        ctx.stdout_mutex.lockUncancelable(ctx.executor.io);
        defer ctx.stdout_mutex.unlock(ctx.executor.io);
        var buf: [512]u8 = undefined;
        var f: std.Io.File.Writer = .init(.stdout(), ctx.executor.io, &buf);
        f.interface.print("[done]  {s}  {s}\n", .{ ctx.display_key, short_key }) catch {};
        f.interface.flush() catch {};
    }
}

pub const BuildExecutor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *store_mod.Store,
    workspace: *realize.WorkspaceLayout,
    /// Root package source directory (absolute path).
    pkg_root: []const u8,
    /// Directory containing the lockfile (absolute path). Used to resolve relative
    /// source_path values stored in the lockfile.
    lockfile_dir: []const u8,
    /// Maximum number of concurrent build jobs (1 = serial).
    max_jobs: usize,
    /// When true, source drift is a hard error instead of a warning+rebuild.
    strict_lockfile: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        store: *store_mod.Store,
        workspace: *realize.WorkspaceLayout,
        pkg_root: []const u8,
        lockfile_dir: []const u8,
        max_jobs: usize,
        strict_lockfile: bool,
    ) BuildExecutor {
        return .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .workspace = workspace,
            .pkg_root = pkg_root,
            .lockfile_dir = lockfile_dir,
            .max_jobs = if (max_jobs == 0) 1 else max_jobs,
            .strict_lockfile = strict_lockfile,
        };
    }

    pub fn deinit(_: *BuildExecutor) void {}

    /// Create workspace directory and generate binary adapter for a store-hit instance.
    ///
    /// `display_key` is the human-readable `<pkg_id>#<domain>` string used for workspace
    /// directory names and lockfile lookups.
    /// `store_key`   is the content-addressed hex-digest used for store operations.
    fn reifyStoreHit(
        self: *BuildExecutor,
        display_key: []const u8,
        store_key: []const u8,
        lockfile: model.Lockfile,
    ) !void {
        const instance_ref = model.lockfile.InstanceRef.parse(display_key) catch return;
        const instance = lockfile.findInstance(instance_ref) orelse return;

        var r = realizer_mod.Realizer.init(self.allocator, self.io, self.workspace, self.lockfile_dir);
        try r.realizeBinaryAdapter(self.store, instance, display_key, store_key);
    }

    pub fn execute(
        self: *BuildExecutor,
        plan: BuildPlan,
        lockfile: model.Lockfile,
    ) !void {
        const allocator = self.allocator;
        var stdout_buf: [4096]u8 = undefined;
        var stdout_file: std.Io.File.Writer = .init(.stdout(), self.io, &stdout_buf);
        const stdout = &stdout_file.interface;

        var any_test_failed = false;
        var stdout_mutex: std.Io.Mutex = .init;

        // Pre-pass: detect source drift for all store hits before processing any waves.
        // Keys stored in `drifted` are borrowed from plan.build_order (valid for execute's lifetime).
        var drifted = std.StringHashMap(void).init(allocator);
        defer drifted.deinit();

        for (plan.waves) |wave| {
            for (wave) |key| {
                if (!plan.store_hits.contains(key)) continue;

                const instance_ref = model.lockfile.InstanceRef.parse(key) catch continue;
                const inst = lockfile.findInstance(instance_ref) orelse continue;

                if (inst.source_path.len == 0 or inst.source_hash.len == 0) continue;

                const resolved_src = resolveLockfilePath(allocator, self.lockfile_dir, inst.source_path) catch continue;
                defer allocator.free(resolved_src);
                const src_dir = std.Io.Dir.openDirAbsolute(self.io, resolved_src, .{}) catch continue;
                defer src_dir.close(self.io);

                const actual_hex = source_hash_mod.hashPackageSource(allocator, src_dir, self.io, 1) catch continue;

                if (!std.mem.eql(u8, &actual_hex, inst.source_hash)) {
                    if (self.strict_lockfile) {
                        try printStderr(self.io, "error: {s}: source has changed since last 'zpkg update'\n" ++
                            "       lockfile hash: {s}\n" ++
                            "       actual hash:   {s}\n" ++
                            "       Run 'zpkg update' to update the lockfile.\n", .{ key, inst.source_hash, actual_hex });
                        return error.SourceDrift;
                    } else {
                        try printStderr(self.io, "warning: {s}: source has changed since last 'zpkg update'\n" ++
                            "         lockfile hash: {s}\n" ++
                            "         actual hash:   {s}\n" ++
                            "         Forcing rebuild. Run 'zpkg update' to update the lockfile.\n", .{ key, inst.source_hash, actual_hex });
                        try drifted.put(key, {});
                    }
                }
            }
        }

        for (plan.waves) |wave| {
            // 1. Handle store hits in this wave serially (fast, no build work needed).
            for (wave) |key| {
                if (!plan.store_hits.contains(key)) continue;
                if (drifted.contains(key)) continue; // drift detected: rebuild in miss pass below
                const store_key = plan.instance_keys.get(key) orelse key;
                const short_key = store_key[0..@min(16, store_key.len)];

                if (plan.mode == .run_tests) {
                    try stdout.print("[skip] {s}  {s} (pre-built; no test binary)\n", .{ key, short_key });
                } else {
                    try stdout.print("[hit]  {s}  {s}\n", .{ key, short_key });
                }
                try stdout.flush();

                self.reifyStoreHit(key, store_key, lockfile) catch |err| {
                    try printStderr(self.io, "warning: failed to create binary adapter for '{s}': {s}\n", .{ key, @errorName(err) });
                };
            }

            // 2. Collect store misses in this wave for parallel dispatch.
            // Also include drifted keys (store hits whose source has changed).
            var miss_keys: std.ArrayList([]const u8) = .empty;
            defer miss_keys.deinit(allocator);
            for (wave) |key| {
                if (plan.store_misses.contains(key) or drifted.contains(key)) try miss_keys.append(allocator, key);
            }
            if (miss_keys.items.len == 0) continue;

            const jobs = @min(self.max_jobs, miss_keys.items.len);

            if (jobs <= 1) {
                // Serial path — identical behavior to original loop.
                for (miss_keys.items) |key| {
                    const store_key = plan.instance_keys.get(key) orelse key;
                    const short_key = store_key[0..@min(16, store_key.len)];

                    const instance_ref = model.lockfile.InstanceRef.parse(key) catch {
                        try printStderr(self.io, "error: invalid instance key in plan: {s}\n", .{key});
                        return error.InvalidInstanceKey;
                    };
                    const instance = lockfile.findInstance(instance_ref) orelse {
                        try printStderr(self.io, "error: instance not found in lockfile: {s}\n", .{key});
                        return error.InstanceNotFound;
                    };

                    try stdout.print("[build] {s}  {s}\n", .{ key, short_key });
                    try stdout.flush();

                    self.buildInstance(instance, key, store_key, lockfile, plan.mode) catch |err| {
                        if (err == error.TestsFailed) {
                            any_test_failed = true;
                            try stdout.print("[fail]  {s}  {s} (tests failed)\n", .{ key, short_key });
                            try stdout.flush();
                            continue;
                        }
                        return err;
                    };

                    try stdout.print("[done]  {s}  {s}\n", .{ key, short_key });
                    try stdout.flush();

                    self.reifyStoreHit(key, store_key, lockfile) catch |err| {
                        try printStderr(self.io, "warning: failed to reify '{s}' after build: {s}\n", .{ key, @errorName(err) });
                    };
                }
            } else {
                // Parallel path — dispatch misses in batches of max_jobs.
                // Pre-allocate at full wave size (reused across batches).
                var wave_failed = std.atomic.Value(bool).init(false);
                var wave_test_failed = std.atomic.Value(bool).init(false);

                const ctxs = try allocator.alloc(WorkerCtx, miss_keys.items.len);
                defer allocator.free(ctxs);
                const threads = try allocator.alloc(std.Thread, miss_keys.items.len);
                defer allocator.free(threads);

                // Validation pass: resolve all instances before spawning any threads.
                // This ensures no thread has been started if a validation error is returned.
                for (ctxs, miss_keys.items) |*ctx, key| {
                    const store_key = plan.instance_keys.get(key) orelse key;
                    const instance_ref = model.lockfile.InstanceRef.parse(key) catch {
                        try printStderr(self.io, "error: invalid instance key in plan: {s}\n", .{key});
                        return error.InvalidInstanceKey;
                    };
                    const instance = lockfile.findInstance(instance_ref) orelse {
                        try printStderr(self.io, "error: instance not found in lockfile: {s}\n", .{key});
                        return error.InstanceNotFound;
                    };
                    ctx.* = .{
                        .executor = self,
                        .instance = instance,
                        .display_key = key,
                        .store_key = store_key,
                        .lockfile = lockfile,
                        .mode = plan.mode,
                        .stdout_mutex = &stdout_mutex,
                        .failed = &wave_failed,
                        .test_failed = &wave_test_failed,
                    };
                }

                // Spawn-join pass: process in batches of max_jobs so --jobs N is honoured.
                var offset: usize = 0;
                while (offset < miss_keys.items.len) {
                    const end = @min(offset + self.max_jobs, miss_keys.items.len);
                    const batch_ctxs = ctxs[offset..end];
                    const batch_threads = threads[offset..end];

                    // Track how many threads were actually spawned so we can join them
                    // even if a spawn fails mid-batch.
                    var spawned: usize = 0;
                    errdefer for (batch_threads[0..spawned]) |t| t.join();
                    for (batch_ctxs, batch_threads) |*ctx, *t| {
                        t.* = try std.Thread.spawn(.{}, buildWorker, .{ctx});
                        spawned += 1;
                    }
                    for (batch_threads) |t| t.join();

                    offset = end;
                }

                if (wave_test_failed.load(.acquire)) any_test_failed = true;
                if (wave_failed.load(.acquire)) return error.BuildFailed;
            }
        }

        if (any_test_failed) return error.TestsFailed;
    }

    fn buildInstance(
        self: *BuildExecutor,
        instance: *const model.lockfile.Instance,
        display_key: []const u8,
        store_key: []const u8,
        lockfile: model.Lockfile,
        mode: BuildMode,
    ) !void {
        const allocator = self.allocator;

        // Resolve source_path from the lockfile: if absolute, use as-is (old lockfile
        // backward compat); if relative, resolve against lockfile_dir.
        if (instance.source_path.len == 0) {
            try printStderr(self.io, "error: '{s}' has no source_path in lockfile; re-run 'zpkg lock'\n", .{display_key});
            return error.MissingSourcePath;
        }
        const source_dir = try resolveLockfilePath(allocator, self.lockfile_dir, instance.source_path);
        defer allocator.free(source_dir);

        // Realized source dir in workspace: deps/<display_key>/
        const realized_dir = try self.workspace.depPkgDir(allocator, display_key);
        defer allocator.free(realized_dir);

        // Realize source package into workspace (creates the dir, symlinks the source
        // tree, and rewrites build.zig.zon dependencies to workspace-local paths).
        var r = realizer_mod.Realizer.init(allocator, self.io, self.workspace, self.lockfile_dir);
        r.realizeSource(source_dir, display_key, instance) catch |err| {
            try printStderr(self.io, "error: failed to realize source for '{s}': {s}\n", .{ display_key, @errorName(err) });
            return error.RealizeFailed;
        };

        // Create staging dir: <workspace_root>/staging/<display_key>/
        const staging_dir = try std.Io.Dir.path.join(allocator, &.{ self.workspace.workspace_root, "staging", display_key });
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

        // Open staging_dir as a Dir so runCapture can create per-pass temp files in it.
        const cap_dir = try std.Io.Dir.openDirAbsolute(self.io, staging_dir, .{});
        defer cap_dir.close(self.io);

        // Run `zig build install --prefix <staging_dir>` inside realized_dir.
        {
            const result = try runCapture(allocator, self.io,
                &.{ "zig", "build", "install", "--prefix", staging_dir },
                realized_dir, cap_dir);
            defer {
                allocator.free(result.stdout);
                allocator.free(result.stderr);
            }
            switch (result.term) {
                .exited => |code| {
                    if (code != 0) {
                        try printRaw(self.io, result.stderr);
                        try printStderr(self.io, "error: build failed for '{s}' (exit code {d})\n", .{ display_key, code });
                        return error.BuildFailed;
                    }
                },
                else => {
                    try printRaw(self.io, result.stderr);
                    try printStderr(self.io, "error: build process for '{s}' terminated abnormally\n", .{display_key});
                    return error.BuildFailed;
                },
            }
        }

        // Build dep_instances list for the manifest.
        const dep_instances = try allocator.alloc(manifest_mod.InstanceRef, instance.deps.len);
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

        // The manifest records the human-readable instance identity (display_key).
        const instance_ref = try manifest_mod.InstanceRef.parseOwned(allocator, display_key);
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
        _ = lockfile; // suppress unused warning
        // Use the content-addressed store_key for the store directory name.
        try self.store.storeArtifact(store_key, staging_dir, artifact_manifest);

        // When running in test mode, execute `zig build test --prefix <staging_dir>` as well.
        if (mode == .run_tests) {
            const test_result = try runCapture(allocator, self.io,
                &.{ "zig", "build", "test", "--prefix", staging_dir },
                realized_dir, cap_dir);
            defer {
                allocator.free(test_result.stdout);
                allocator.free(test_result.stderr);
            }
            switch (test_result.term) {
                .exited => |code| {
                    if (code != 0) {
                        try printRaw(self.io, test_result.stderr);
                        try printStderr(self.io, "error: tests failed for '{s}' (exit code {d})\n", .{ display_key, code });
                        return error.TestsFailed;
                    }
                },
                else => {
                    try printRaw(self.io, test_result.stderr);
                    try printStderr(self.io, "error: test process for '{s}' terminated abnormally\n", .{display_key});
                    return error.TestsFailed;
                },
            }
        }
    }
};

/// Resolve a lockfile source_path to an absolute path (see realizer.resolveLockfilePath).
const resolveLockfilePath = realizer_mod.resolveLockfilePath;

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

/// Monotonic counter for unique capture-file names; shared across threads.
var capture_seq = std.atomic.Value(u32).init(0);

/// Like std.process.run but redirects stdout/stderr to regular files in
/// `cap_dir` instead of anonymous pipes.  Regular files have no buffer-size
/// limit and avoid progress-display artifacts (\r etc.) that some Zig builds
/// emit even to non-TTY pipe fds.  Each call gets a unique file pair named by
/// an atomic counter so concurrent threads never collide.
///
/// Caller owns result.stdout and result.stderr; files are deleted before return.
pub fn runCapture(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: []const u8,
    cap_dir: std.Io.Dir,
) !std.process.RunResult {
    const seq = capture_seq.fetchAdd(1, .monotonic);

    var out_name_buf: [32]u8 = undefined;
    var err_name_buf: [32]u8 = undefined;
    const out_name = std.fmt.bufPrint(&out_name_buf, "cap-{d}-out", .{seq}) catch unreachable;
    const err_name = std.fmt.bufPrint(&err_name_buf, "cap-{d}-err", .{seq}) catch unreachable;

    // Create with .read = true so the same handle can be used for read-back,
    // and .truncate = true (default) so stale content is erased on retry.
    const out_file = try cap_dir.createFile(io, out_name, .{ .read = true });
    defer cap_dir.deleteFile(io, out_name) catch {};

    const err_file = try cap_dir.createFile(io, err_name, .{ .read = true });
    defer cap_dir.deleteFile(io, err_name) catch {};

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .{ .file = out_file },
        .stderr = .{ .file = err_file },
    });
    const term = try child.wait(io);

    // Read back the captured content.  The deferred deletes run after this.
    const stdout_bytes = try cap_dir.readFileAlloc(io, out_name, allocator, .unlimited);
    errdefer allocator.free(stdout_bytes);
    const stderr_bytes = try cap_dir.readFileAlloc(io, err_name, allocator, .unlimited);

    return .{ .term = term, .stdout = stdout_bytes, .stderr = stderr_bytes };
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
    const root_source_path = try allocator.dupe(u8, "/fake/root");
    const lib_source_path = try allocator.dupe(u8, "/fake/lib");

    const instances = try allocator.alloc(model.lockfile.Instance, 2);
    instances[0] = .{
        .key = root_ref,
        .package_id = try model.PackageId.parseOwned(allocator, "zpkg.example.root"),
        .domain = .target,
        .version = .{ .major = 0, .minor = 1, .patch = 0, .revision = 0 },
        .source_hash = root_source_hash,
        .source_path = root_source_path,
        .selected_options = root_options,
        .deps = root_deps,
    };
    instances[1] = .{
        .key = lib_ref,
        .package_id = try model.PackageId.parseOwned(allocator, "zpkg.example.lib"),
        .domain = .target,
        .version = .{ .major = 0, .minor = 1, .patch = 0, .revision = 0 },
        .source_hash = lib_source_hash,
        .source_path = lib_source_path,
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

    // Use a sample fingerprint (source_hashes are empty so keys will use the fallback path).
    const sample_fp = model.ToolchainFingerprint{
        .zig_version = "0.16.0",
        .host_triple = "x86_64-linux-gnu",
        .target_triple = "x86_64-linux-gnu",
        .c_compiler = .{ .id = "gcc", .version = "13.0.0" },
        .cxx_compiler = .{ .id = "g++", .version = "13.0.0" },
        .sysroot = .{ .id = "system", .version = "unknown" },
        .libc = .{ .id = "system", .version = "unknown" },
        .cxx_stdlib = .{ .id = "system", .version = "unknown" },
        .cxx_abi_mode = "unknown",
    };

    var plan = try planBuild(allocator, lockfile, &store, .build, sample_fp);
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

    // lib is a leaf (level 0), root depends on lib (level 1) → 2 waves.
    try std.testing.expectEqual(@as(usize, 2), plan.waves.len);
    try std.testing.expectEqual(@as(usize, 1), plan.waves[0].len);
    try std.testing.expectEqual(@as(usize, 1), plan.waves[1].len);
    try std.testing.expectEqualStrings("zpkg.example.lib#target", plan.waves[0][0]);
    try std.testing.expectEqualStrings("zpkg.example.root#target", plan.waves[1][0]);
}
