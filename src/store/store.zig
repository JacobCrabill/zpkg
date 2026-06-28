const std = @import("std");
const layout = @import("layout.zig");
const manifest_mod = @import("manifest.zig");
const archive_mod = @import("archive.zig");
const schema_mod = @import("../schema/zon_util.zig");

pub const ArtifactManifest = manifest_mod.ArtifactManifest;

pub const StoreStatus = enum {
    /// Archive, manifest, and expanded directory all present.
    ok,
    /// Not present in the store at all.
    missing,
    /// Archive present but no manifest.
    manifest_missing,
    /// Manifest present but no archive.
    archive_missing,
    /// Expanded directory present but no archive or manifest (partial/corrupt state).
    expanded_only,
    /// Archive and manifest present but not yet expanded to the prefix tree.
    not_expanded,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    store_root: []const u8,
    io: std.Io,

    /// Initialise a store rooted at `<workspace_root>/.zpkg/store/`.
    /// Creates the store directory tree if it does not exist.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, workspace_root: []const u8) !Store {
        const store_root = try layout.storeRoot(allocator, workspace_root);
        errdefer allocator.free(store_root);

        // Ensure the store root directory exists.
        std.Io.Dir.createDirAbsolute(io, store_root, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Ensure artifacts and expanded sub-directories exist.
        const artifacts_base = try std.Io.Dir.path.join(allocator, &.{ store_root, "artifacts" });
        defer allocator.free(artifacts_base);
        std.Io.Dir.createDirAbsolute(io, artifacts_base, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const expanded_base = try std.Io.Dir.path.join(allocator, &.{ store_root, "expanded" });
        defer allocator.free(expanded_base);
        std.Io.Dir.createDirAbsolute(io, expanded_base, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        return .{
            .allocator = allocator,
            .store_root = store_root,
            .io = io,
        };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.store_root);
        self.* = undefined;
    }

    /// Returns true if both the archive and the manifest exist for `instance_key`.
    pub fn hasArtifact(self: *Store, instance_key: []const u8) bool {
        const arch = layout.archivePath(self.allocator, self.store_root, instance_key) catch return false;
        defer self.allocator.free(arch);
        const mani = layout.manifestPath(self.allocator, self.store_root, instance_key) catch return false;
        defer self.allocator.free(mani);

        const arch_ok = if (std.Io.Dir.accessAbsolute(self.io, arch, .{})) |_| true else |_| false;
        const mani_ok = if (std.Io.Dir.accessAbsolute(self.io, mani, .{})) |_| true else |_| false;
        return arch_ok and mani_ok;
    }

    /// Archive `prefix_dir` and store the manifest under `instance_key`.
    /// Creates the artifact directory if it does not exist.
    pub fn storeArtifact(
        self: *Store,
        instance_key: []const u8,
        prefix_dir: []const u8,
        artifact_manifest: ArtifactManifest,
    ) !void {
        const art_dir = try layout.artifactsDir(self.allocator, self.store_root, instance_key);
        defer self.allocator.free(art_dir);

        std.Io.Dir.createDirAbsolute(self.io, art_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Write manifest.
        const mani_path = try layout.manifestPath(self.allocator, self.store_root, instance_key);
        defer self.allocator.free(mani_path);

        const zon_bytes = try artifact_manifest.toZonAlloc(self.allocator);
        defer self.allocator.free(zon_bytes);

        const mani_dir_path = std.Io.Dir.path.dirname(mani_path) orelse ".";
        const mani_base = std.Io.Dir.path.basename(mani_path);
        const mani_dir = try std.Io.Dir.openDirAbsolute(self.io, mani_dir_path, .{});
        defer mani_dir.close(self.io);
        try mani_dir.writeFile(self.io, .{ .sub_path = mani_base, .data = zon_bytes });

        // Create archive.
        const arch_path = try layout.archivePath(self.allocator, self.store_root, instance_key);
        defer self.allocator.free(arch_path);

        try archive_mod.createArchive(self.allocator, self.io, prefix_dir, arch_path);
    }

    /// Load and return the manifest for `instance_key`.
    /// The returned manifest must be freed by the caller via `ArtifactManifest.deinit`.
    pub fn loadManifest(self: *Store, instance_key: []const u8) !ArtifactManifest {
        const mani_path = try layout.manifestPath(self.allocator, self.store_root, instance_key);
        defer self.allocator.free(mani_path);

        const mani_dir_path = std.Io.Dir.path.dirname(mani_path) orelse ".";
        const mani_base = std.Io.Dir.path.basename(mani_path);

        const mani_dir = try std.Io.Dir.openDirAbsolute(self.io, mani_dir_path, .{});
        defer mani_dir.close(self.io);

        const bytes = try mani_dir.readFileAlloc(self.io, mani_base, self.allocator, .limited(1 * 1024 * 1024));
        defer self.allocator.free(bytes);

        return parseManifest(self.allocator, bytes);
    }

    /// Expand an archived artifact to `expanded/<instance_key>/`.
    /// Idempotent: if already expanded, returns the path immediately.
    /// Caller owns the returned path slice.
    pub fn expandArtifact(self: *Store, instance_key: []const u8) ![]const u8 {
        const exp_dir = try layout.expandedDir(self.allocator, self.store_root, instance_key);
        errdefer self.allocator.free(exp_dir);

        // If already expanded, return immediately.
        if (std.Io.Dir.accessAbsolute(self.io, exp_dir, .{})) |_| {
            return exp_dir;
        } else |_| {}

        const arch_path = try layout.archivePath(self.allocator, self.store_root, instance_key);
        defer self.allocator.free(arch_path);

        try archive_mod.extractArchive(self.allocator, self.io, arch_path, exp_dir);

        return exp_dir;
    }

    /// Diagnose the store health for `instance_key`.
    pub fn diagnose(self: *Store, instance_key: []const u8) StoreStatus {
        const arch = layout.archivePath(self.allocator, self.store_root, instance_key) catch return .missing;
        defer self.allocator.free(arch);
        const mani = layout.manifestPath(self.allocator, self.store_root, instance_key) catch return .missing;
        defer self.allocator.free(mani);
        const exp = layout.expandedDir(self.allocator, self.store_root, instance_key) catch return .missing;
        defer self.allocator.free(exp);

        const arch_ok = if (std.Io.Dir.accessAbsolute(self.io, arch, .{})) |_| true else |_| false;
        const mani_ok = if (std.Io.Dir.accessAbsolute(self.io, mani, .{})) |_| true else |_| false;
        const exp_ok = if (std.Io.Dir.accessAbsolute(self.io, exp, .{})) |_| true else |_| false;

        if (!arch_ok and !mani_ok) {
            if (exp_ok) return .expanded_only;
            return .missing;
        }
        if (!arch_ok) return .archive_missing;
        if (!mani_ok) return .manifest_missing;
        if (!exp_ok) return .not_expanded;
        return .ok;
    }
};

/// Parse a manifest ZON file. Validates structure and extracts all fields.
/// Caller owns the returned ArtifactManifest (call deinit).
pub fn parseManifest(allocator: std.mem.Allocator, zon_bytes: []const u8) !ArtifactManifest {
    const model = @import("../model/root.zig");
    const zon_util = @import("../schema/zon_util.zig");

    const sentinel = try allocator.dupeZ(u8, zon_bytes);
    defer allocator.free(sentinel);

    var doc = try zon_util.parseDocument(allocator, sentinel);
    defer doc.deinit(allocator);

    const root_node = std.zig.Zoir.Node.Index.root;
    const obj = try zon_util.Object.fromNode(&doc, root_node);

    // schema
    const schema_node = try obj.require("schema");
    const schema = try zon_util.parseInt(&doc, schema_node);
    if (schema != 1) return error.InvalidSchemaVersion;

    // instance
    const instance_node = try obj.require("instance");
    const instance_text = try zon_util.parseNonEmptyStringAlloc(allocator, &doc, instance_node);
    defer allocator.free(instance_text);
    const instance = try manifest_mod.InstanceRef.parseOwned(allocator, instance_text);
    errdefer instance.deinitOwned(allocator);

    // version
    const version_node = try obj.require("version");
    const version_text = try zon_util.parseNonEmptyStringAlloc(allocator, &doc, version_node);
    defer allocator.free(version_text);
    const ver = model.Version.parse(version_text) catch return error.InvalidVersion;

    // source_hash
    const sh_node = try obj.require("source_hash");
    const source_hash = try zon_util.parseNonEmptyStringAlloc(allocator, &doc, sh_node);
    errdefer allocator.free(source_hash);

    // selected_options
    const opts_node = try obj.require("selected_options");
    const opts_obj = try zon_util.Object.fromNode(&doc, opts_node);
    const selected_options = try allocator.alloc(model.NamedOptionValue, opts_obj.fieldCount());
    errdefer {
        for (selected_options) |entry| {
            allocator.free(entry.name);
            entry.value.deinitOwned(allocator);
        }
        allocator.free(selected_options);
    }
    for (0..opts_obj.fieldCount()) |i| {
        const name = try allocator.dupe(u8, opts_obj.fieldName(i));
        errdefer allocator.free(name);
        const val = try zon_util.parseOptionValueAlloc(allocator, &doc, opts_obj.fieldNode(i));
        selected_options[i] = .{ .name = name, .value = val };
    }

    // dep_instances
    const deps_node = try obj.require("dep_instances");
    const deps_arr = try zon_util.Array.fromNode(&doc, deps_node);
    const dep_instances = try allocator.alloc(manifest_mod.InstanceRef, deps_arr.len());
    errdefer {
        for (dep_instances) |dep| dep.deinitOwned(allocator);
        allocator.free(dep_instances);
    }
    for (0..deps_arr.len()) |i| {
        const dep_text = try zon_util.parseNonEmptyStringAlloc(allocator, &doc, deps_arr.at(i));
        defer allocator.free(dep_text);
        dep_instances[i] = try manifest_mod.InstanceRef.parseOwned(allocator, dep_text);
    }

    return .{
        .schema = @intCast(schema),
        .instance = instance,
        .version = ver,
        .source_hash = source_hash,
        .selected_options = selected_options,
        .dep_instances = dep_instances,
    };
}

test "parseManifest round-trip: serialize then deserialize matches original" {
    const allocator = std.testing.allocator;
    const model = @import("../model/root.zig");
    const InstanceRef = manifest_mod.InstanceRef;

    // Build original manifest.
    const instance_ref = try InstanceRef.parseOwned(allocator, "zpkg.example.hello_lib#target");
    const dep_ref = try InstanceRef.parseOwned(allocator, "zpkg.example.hello_headers#target");
    const dep_instances = try allocator.dupe(InstanceRef, &.{dep_ref});
    const opt_name = try allocator.dupe(u8, "shared");
    const selected_options = try allocator.dupe(model.NamedOptionValue, &.{
        .{ .name = opt_name, .value = .{ .bool = true } },
    });
    const source_hash = try allocator.dupe(u8, "sha256:deadbeef0123");

    const original: ArtifactManifest = .{
        .schema = 1,
        .instance = instance_ref,
        .version = .{ .major = 2, .minor = 3, .patch = 4, .revision = 5 },
        .source_hash = source_hash,
        .selected_options = selected_options,
        .dep_instances = dep_instances,
    };
    defer original.deinit(allocator);

    // Serialize.
    const zon_bytes = try original.toZonAlloc(allocator);
    defer allocator.free(zon_bytes);

    // Deserialize.
    const parsed = try parseManifest(allocator, zon_bytes);
    defer parsed.deinit(allocator);

    // Assertions: schema
    try std.testing.expectEqual(@as(u32, 1), parsed.schema);

    // instance key
    try std.testing.expectEqualStrings(
        original.instance.package_id.asText(),
        parsed.instance.package_id.asText(),
    );
    try std.testing.expectEqual(original.instance.domain, parsed.instance.domain);

    // version
    try std.testing.expectEqual(original.version, parsed.version);

    // source_hash
    try std.testing.expectEqualStrings(original.source_hash, parsed.source_hash);

    // selected_options: one entry with name="shared", value=true
    try std.testing.expectEqual(@as(usize, 1), parsed.selected_options.len);
    try std.testing.expectEqualStrings("shared", parsed.selected_options[0].name);
    try std.testing.expectEqual(true, parsed.selected_options[0].value.bool);

    // dep_instances: one entry
    try std.testing.expectEqual(@as(usize, 1), parsed.dep_instances.len);
    try std.testing.expectEqualStrings(
        "zpkg.example.hello_headers",
        parsed.dep_instances[0].package_id.asText(),
    );
    try std.testing.expectEqual(model.Domain.target, parsed.dep_instances[0].domain);
}
