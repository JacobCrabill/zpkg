const std = @import("std");
const model = @import("../model/root.zig");
const store_mod = @import("../store/store.zig");
const workspace_mod = @import("workspace.zig");
const source_pkg = @import("source_pkg.zig");
const binary_adapter = @import("binary_adapter.zig");

pub const DepPathMap = source_pkg.DepPathMap;

/// Shared realization primitives used by both `zpkg build` (which realizes each
/// instance as part of building it) and `zpkg realize` (which only materializes
/// the workspace from the lockfile + store).
///
/// Centralizing these here keeps the two entry points from drifting: previously
/// each carried its own copy of the workspace dep-map construction and the
/// source-fingerprint lookup, and any fix (e.g. carrying the package fingerprint
/// into the binary adapter) had to be applied in both places or one would silently
/// regress.
pub const Realizer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace: *workspace_mod.WorkspaceLayout,
    /// Absolute dir used to resolve relative `source_path` values from the lockfile.
    lockfile_dir: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        ws: *workspace_mod.WorkspaceLayout,
        lockfile_dir: []const u8,
    ) Realizer {
        return .{
            .allocator = allocator,
            .io = io,
            .workspace = ws,
            .lockfile_dir = lockfile_dir,
        };
    }

    /// Build an `alias → deps/<pkg_id>#<domain>` map from a lockfile instance's deps.
    /// Caller frees the result with `freeDepMap`.
    pub fn buildDepMap(self: Realizer, deps: []const model.lockfile.Dependency) !DepPathMap {
        var map = DepPathMap.init(self.allocator);
        errdefer freeDepMapImpl(self.allocator, &map);
        for (deps) |dep| {
            const dep_key = try std.fmt.allocPrint(self.allocator, "{s}#{s}", .{
                dep.instance.package_id.asText(),
                dep.instance.domain.asText(),
            });
            defer self.allocator.free(dep_key);
            try self.putDepEntry(&map, dep.alias, dep_key);
        }
        return map;
    }

    /// Build the root package's dep map from its manifest deps.  The root is not an
    /// entry in `lockfile.instances`, so its dependency domains are recovered by
    /// matching each manifest dep's package id against the resolved instances.
    /// Caller frees the result with `freeDepMap`.
    pub fn buildRootDepMap(
        self: Realizer,
        manifest_deps: []const model.Dependency,
        lockfile: model.Lockfile,
    ) !DepPathMap {
        var map = DepPathMap.init(self.allocator);
        errdefer freeDepMapImpl(self.allocator, &map);
        for (manifest_deps) |dep| {
            for (lockfile.instances) |*instance| {
                if (!instance.key.package_id.eql(dep.package)) continue;
                const dep_key = try std.fmt.allocPrint(self.allocator, "{s}#{s}", .{
                    instance.key.package_id.asText(),
                    instance.key.domain.asText(),
                });
                defer self.allocator.free(dep_key);
                try self.putDepEntry(&map, dep.alias, dep_key);
                break;
            }
        }
        return map;
    }

    /// Insert `alias → deps/<dep_key>` into `map`, duplicating the alias so the map
    /// owns both key and value.
    fn putDepEntry(self: Realizer, map: *DepPathMap, alias: []const u8, dep_key: []const u8) !void {
        const dep_path = try self.workspace.depPkgDir(self.allocator, dep_key);
        errdefer self.allocator.free(dep_path);
        const alias_key = try self.allocator.dupe(u8, alias);
        errdefer self.allocator.free(alias_key);
        try map.put(alias_key, dep_path);
    }

    pub fn freeDepMap(self: Realizer, map: *DepPathMap) void {
        freeDepMapImpl(self.allocator, map);
    }

    /// Read the raw contents of a package's source build.zig.zon.  `source_path`
    /// may be absolute or relative to `lockfile_dir`.  Caller owns the result.
    fn readSourceManifest(self: Realizer, source_path: []const u8) ![]u8 {
        if (source_path.len == 0) return error.MissingSourcePath;
        const src_abs = try resolveLockfilePath(self.allocator, self.lockfile_dir, source_path);
        defer self.allocator.free(src_abs);
        var dir = try std.Io.Dir.openDirAbsolute(self.io, src_abs, .{});
        defer dir.close(self.io);
        return dir.readFileAlloc(self.io, "build.zig.zon", self.allocator, .limited(64 * 1024));
    }

    /// Materialize a store artifact into `deps/<display_key>/` as a binary adapter:
    /// symlinks to the expanded prefix plus a generated `build.zig`, and a
    /// `build.zig.zon` copied from the source package (deps/paths rewritten).
    /// `store_key` is the content-addressed key used to fetch from the store.
    pub fn realizeBinaryAdapter(
        self: Realizer,
        store: *store_mod.Store,
        instance: *const model.lockfile.Instance,
        display_key: []const u8,
        store_key: []const u8,
    ) !void {
        const dest_dir = try self.ensureDepDir(display_key);
        defer self.allocator.free(dest_dir);

        const expanded = try store.expandArtifact(store_key);
        defer self.allocator.free(expanded);

        var dep_map = try self.buildDepMap(instance.deps);
        defer self.freeDepMap(&dep_map);

        // The adapter's build.zig.zon is the source package's build.zig.zon with only
        // deps/paths rewritten, so the package keeps its fingerprint and identity.
        const source_zon = try self.readSourceManifest(instance.source_path);
        defer self.allocator.free(source_zon);

        var adapter = binary_adapter.BinaryAdapter.init(self.allocator, self.io);
        try adapter.generate(dest_dir, expanded, dep_map, source_zon);
    }

    /// Materialize a source package into `deps/<display_key>/` (symlink forest plus a
    /// build.zig.zon copied from source with only `.dependencies` rewritten to the
    /// workspace-local paths).  `source_dir` is absolute.
    pub fn realizeSource(
        self: Realizer,
        source_dir: []const u8,
        display_key: []const u8,
        instance: *const model.lockfile.Instance,
    ) !void {
        const dest_dir = try self.ensureDepDir(display_key);
        defer self.allocator.free(dest_dir);
        var dep_map = try self.buildDepMap(instance.deps);
        defer self.freeDepMap(&dep_map);
        try self.writeSourceRealization(source_dir, dest_dir, dep_map);
    }

    /// Low-level source realization with a caller-provided dep map.  Used for the
    /// root package, whose dep map comes from the manifest (see `buildRootDepMap`)
    /// rather than a lockfile instance.  `dest_dir` must already exist.
    pub fn writeSourceRealization(
        self: Realizer,
        source_dir: []const u8,
        dest_dir: []const u8,
        dep_map: DepPathMap,
    ) !void {
        var sr = source_pkg.SourcePkgRealize.init(self.allocator, self.io);
        try sr.realize(source_dir, dest_dir, dep_map);
    }

    /// Ensure `deps/<display_key>/` exists and return its absolute path (caller owns).
    fn ensureDepDir(self: Realizer, display_key: []const u8) ![]u8 {
        const dest_dir = try self.workspace.depPkgDir(self.allocator, display_key);
        errdefer self.allocator.free(dest_dir);
        std.Io.Dir.createDirAbsolute(self.io, dest_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return dest_dir;
    }
};

fn freeDepMapImpl(allocator: std.mem.Allocator, map: *DepPathMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

/// Resolve a lockfile `source_path` (absolute, or relative to `lockfile_dir`) to an
/// absolute path.  Caller owns the returned slice.
pub fn resolveLockfilePath(
    allocator: std.mem.Allocator,
    lockfile_dir: []const u8,
    path: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.resolve(allocator, &.{ lockfile_dir, path });
}

test "buildDepMap maps aliases to workspace dep dirs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var layout = try workspace_mod.WorkspaceLayout.init(allocator, "/project", "debug-native");
    defer layout.deinit();

    var r = Realizer.init(allocator, io, &layout, "/project");

    const dep_ref = try model.lockfile.InstanceRef.parseOwned(allocator, "zpkg.example.lib#target");
    defer dep_ref.deinitOwned(allocator);
    const alias = try allocator.dupe(u8, "lib");
    defer allocator.free(alias);
    const deps = [_]model.lockfile.Dependency{.{ .alias = alias, .instance = dep_ref }};

    var map = try r.buildDepMap(&deps);
    defer r.freeDepMap(&map);

    const got = map.get("lib") orelse return error.MissingAlias;
    try std.testing.expectEqualStrings(
        "/project/.zpkg/work/debug-native/deps/zpkg.example.lib#target",
        got,
    );
}

test "resolveLockfilePath joins relative paths against lockfile dir" {
    const allocator = std.testing.allocator;

    const abs = try resolveLockfilePath(allocator, "/project", "/elsewhere/pkg");
    defer allocator.free(abs);
    try std.testing.expectEqualStrings("/elsewhere/pkg", abs);

    const rel = try resolveLockfilePath(allocator, "/project", "../sibling");
    defer allocator.free(rel);
    try std.testing.expectEqualStrings("/sibling", rel);
}
