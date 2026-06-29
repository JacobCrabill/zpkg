const std = @import("std");
const model = @import("../model/root.zig");
const conditions = @import("../model/conditions.zig");
const options = @import("../model/options.zig");
const schema = @import("../schema/zpkg.zig");

pub const ResolverError = error{
    UnknownDependency,
    MissingDependency,
    CircularDependency,
    UnresolvedDependency,
    InvalidCondition,
    OptionNotDeclared,
    OptionTypeMismatch,
    DependencyManifestNotFound,
    MissingSourcePath,
};

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    environment: conditions.Environment,
    selected_options: []const model.NamedOptionValue,
    resolved: ResolvedGraph,
    package_cache: PackageCache,
    source_root: []const u8,
    io: std.Io,
    /// Maps "<pkg_id>#<domain>" → absolute source directory path (owned strings).
    source_dirs: std.StringHashMap([]u8),

    pub fn init(
        allocator: std.mem.Allocator,
        host_os: conditions.Os,
        host_arch: conditions.Arch,
        target_os: conditions.Os,
        target_arch: conditions.Arch,
        option_values: []const model.NamedOptionValue,
        source_root: []const u8,
        io: std.Io,
    ) Resolver {
        return .{
            .allocator = allocator,
            .environment = .{
                .domain = .target,
                .host_os = host_os,
                .host_arch = host_arch,
                .target_os = target_os,
                .target_arch = target_arch,
            },
            .selected_options = option_values,
            .resolved = ResolvedGraph.init(allocator),
            .package_cache = PackageCache.init(allocator),
            .source_root = source_root,
            .io = io,
            .source_dirs = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Resolver) void {
        self.resolved.deinit();
        self.package_cache.deinit();
        var vit = self.source_dirs.valueIterator();
        while (vit.next()) |v| self.allocator.free(v.*);
        var kit = self.source_dirs.keyIterator();
        while (kit.next()) |k| self.allocator.free(k.*);
        self.source_dirs.deinit();
    }

    pub fn resolveRoot(
        self: *Resolver,
        root_manifest: model.PackageManifest,
    ) (ResolverError || std.mem.Allocator.Error)!ResolvedRoot {
        // Record the root package's source directory before resolving.
        // Use catch instead of errdefer so we don't double-free after map takes ownership.
        const root_key = try std.fmt.allocPrint(self.allocator, "{s}#target", .{root_manifest.package.id.asText()});
        const root_dir = self.allocator.dupe(u8, self.source_root) catch {
            self.allocator.free(root_key);
            return error.OutOfMemory;
        };
        self.source_dirs.put(root_key, root_dir) catch {
            self.allocator.free(root_dir);
            self.allocator.free(root_key);
            return error.OutOfMemory;
        };
        // root_key and root_dir are now owned by source_dirs; deinit() will free them.

        _ = try self.resolvePackage(.{
            .package_id = root_manifest.package.id,
            .version = root_manifest.package.version,
            .domain = .target,
            .manifest = root_manifest,
        });
        return .{
            .package_id = root_manifest.package.id,
            .version = root_manifest.package.version,
        };
    }

    fn resolvePackage(
        self: *Resolver,
        pkg: PackageContext,
    ) (ResolverError || std.mem.Allocator.Error)!void {
        const instance_key = try formatInstanceKey(self.allocator, pkg.package_id, pkg.domain);

        if (self.resolved.get(instance_key)) |_| {
            self.allocator.free(instance_key);
            return;
        }

        // Heap-allocate so the map can hold a stable pointer.
        const resolved = try self.allocator.create(ResolvedPackage);
        resolved.* = ResolvedPackage.init(self.allocator, pkg.package_id, pkg.domain, pkg.version);

        // Track whether we still own resolved+key (before map takes ownership).
        var owned = true;
        defer if (owned) {
            resolved.deinit();
            self.allocator.destroy(resolved);
            self.allocator.free(instance_key);
        };

        try self.resolved.put(instance_key, resolved);
        owned = false; // map now owns both; remove() will clean up on error

        self.resolveDependencies(pkg, resolved) catch |err| {
            self.resolved.remove(instance_key); // deinits, destroys, and frees key
            return err;
        };
    }

    fn resolveDependencies(
        self: *Resolver,
        pkg: PackageContext,
        resolved: *ResolvedPackage,
    ) (ResolverError || std.mem.Allocator.Error)!void {
        const domain = pkg.domain;
        self.environment.domain = domain;

        const manifests = try self.resolveManifests(pkg);
        defer self.allocator.free(manifests);

        for (manifests) |manifest| {
            try self.resolvePackage(.{
                .package_id = manifest.package.id,
                .version = manifest.package.version,
                .domain = domain,
                .manifest = manifest,
            });
            try resolved.appendDep(.{
                .alias = manifest.package.name,
                .instance = .{
                    .package_id = manifest.package.id,
                    .domain = domain,
                },
            });
        }
    }

    fn resolveManifests(self: *Resolver, pkg: PackageContext) ![]const model.PackageManifest {
        const manifests = try self.allocator.alloc(model.PackageManifest, pkg.manifest.deps.len);
        var i: usize = 0;
        errdefer {
            for (manifests[0..i]) |*manifest| {
                manifest.deinitOwned(self.allocator);
            }
            self.allocator.free(manifests);
        }

        // Look up the current package's source directory.
        // Keys are always "#target" since source_path is a single path regardless of domain.
        const current_key = try std.fmt.allocPrint(self.allocator, "{s}#target", .{
            pkg.package_id.asText(),
        });
        defer self.allocator.free(current_key);
        const current_source_dir = self.source_dirs.get(current_key) orelse self.source_root;

        for (pkg.manifest.deps) |dep| {
            // Check if the dependency condition is satisfied
            if (dep.when) |condition| {
                if (!condition.matches(self.environment, self.selected_options)) {
                    continue;
                }
            }

            // Look up the manifest in cache first.
            // cache_key ownership: freed on cache hit; transferred to map on miss.
            const cache_key = try std.fmt.allocPrint(self.allocator, "{s}#{s}", .{ dep.package.asText(), pkg.domain.asText() });

            if (self.package_cache.get(cache_key)) |cached_manifest| {
                self.allocator.free(cache_key); // we own it, not inserted
                manifests[i] = cached_manifest.*;
                i += 1;
                continue;
            }

            // Parse the dependency manifest using the explicit source_path.
            const dep_manifest = try self.parseDependencyManifest(dep, current_source_dir);

            // Cache takes ownership of cache_key.
            self.package_cache.put(cache_key, dep_manifest);

            manifests[i] = dep_manifest;
            i += 1;
        }

        // Resize to actual count
        const trimmed = try self.allocator.alloc(model.PackageManifest, i);
        @memcpy(trimmed, manifests[0..i]);
        self.allocator.free(manifests);

        return trimmed;
    }

    fn parseDependencyManifest(self: *Resolver, dep: model.Dependency, current_source_dir: []const u8) !model.PackageManifest {
        const sp = dep.source_path orelse {
            std.log.err("zpkg: dependency '{s}' (package '{s}') has no source_path.\n" ++
                "Add .source_path = \"<relative-path>\" to the deps.{s} entry in zpkg.zon.", .{
                dep.alias, dep.package.asText(), dep.alias,
            });
            return error.MissingSourcePath;
        };

        const abs_dep_dir = try std.fs.path.resolve(self.allocator, &.{ current_source_dir, sp });
        defer self.allocator.free(abs_dep_dir);

        var dep_dir = std.Io.Dir.cwd().openDir(self.io, abs_dep_dir, .{}) catch {
            std.log.err("zpkg: dependency manifest not found at '{s}/zpkg.zon'", .{abs_dep_dir});
            return error.DependencyManifestNotFound;
        };
        defer dep_dir.close(self.io);

        var dep_manifest = schema.parseFileAlloc(self.allocator, dep_dir, self.io, "zpkg.zon") catch {
            std.log.err("zpkg: failed to parse dependency manifest at '{s}/zpkg.zon'", .{abs_dep_dir});
            return error.DependencyManifestNotFound;
        };
        errdefer dep_manifest.deinitOwned(self.allocator);

        // Store the resolved absolute source directory for this dep, keyed as "<pkg_id>#target".
        // Use catch blocks (not errdefer) to avoid freeing after map takes ownership.
        const dir_key = try std.fmt.allocPrint(self.allocator, "{s}#target", .{dep.package.asText()});
        if (!self.source_dirs.contains(dir_key)) {
            const dir_owned = self.allocator.dupe(u8, abs_dep_dir) catch {
                self.allocator.free(dir_key);
                return error.OutOfMemory;
            };
            self.source_dirs.put(dir_key, dir_owned) catch {
                self.allocator.free(dir_owned);
                self.allocator.free(dir_key);
                return error.OutOfMemory;
            };
            // dir_key and dir_owned ownership transferred to map.
        } else {
            self.allocator.free(dir_key);
        }

        return dep_manifest;
    }
};

pub const ResolvedGraph = struct {
    allocator: std.mem.Allocator,
    entries: ResolvedEntryList,

    fn init(allocator: std.mem.Allocator) ResolvedGraph {
        return .{
            .allocator = allocator,
            .entries = ResolvedEntryList.init(allocator),
        };
    }

    fn deinit(self: *ResolvedGraph) void {
        self.entries.deinit();
    }

    fn get(self: *ResolvedGraph, key: []const u8) ?*ResolvedPackage {
        return self.entries.get(key);
    }

    fn put(self: *ResolvedGraph, key: []const u8, value: *ResolvedPackage) !void {
        try self.entries.put(key, value);
    }



    fn remove(self: *ResolvedGraph, key: []const u8) void {
        self.entries.remove(key);
    }

    pub fn iterator(self: *ResolvedGraph) ResolvedEntryList.Iterator {
        return self.entries.iterator();
    }
};

const ResolvedEntryList = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(*ResolvedPackage),

    pub const Iterator = std.StringHashMapUnmanaged(*ResolvedPackage).Iterator;

    fn init(allocator: std.mem.Allocator) ResolvedEntryList {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMapUnmanaged(*ResolvedPackage){},
        };
    }

    fn deinit(self: *ResolvedEntryList) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit(self.allocator);
    }

    fn get(self: *ResolvedEntryList, key: []const u8) ?*ResolvedPackage {
        return self.entries.get(key);
    }

    fn put(self: *ResolvedEntryList, key: []const u8, value: *ResolvedPackage) !void {
        try self.entries.put(self.allocator, key, value);
    }

    fn remove(self: *ResolvedEntryList, key: []const u8) void {
        if (self.entries.fetchRemove(key)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);
            self.allocator.free(kv.key);
        }
    }

    fn iterator(self: *ResolvedEntryList) Iterator {
        return self.entries.iterator();
    }
};

pub const ResolvedPackage = struct {
    allocator: std.mem.Allocator,
    package_id: model.PackageId,
    domain: model.Domain,
    version: model.Version,
    deps: []Dependency,

    fn init(allocator: std.mem.Allocator, package_id: model.PackageId, domain: model.Domain, version: model.Version) ResolvedPackage {
        const cloned_package_id = package_id.cloneOwned(allocator) catch unreachable;
        return .{
            .allocator = allocator,
            .package_id = cloned_package_id,
            .domain = domain,
            .version = version,
            .deps = &.{},
        };
    }

    fn deinit(self: *ResolvedPackage) void {
        if (self.deps.len > 0) self.allocator.free(self.deps);
        self.package_id.deinitOwned(self.allocator);
    }

    fn appendDep(self: *ResolvedPackage, dep: Dependency) !void {
        const new_deps = try self.allocator.alloc(Dependency, self.deps.len + 1);
        @memcpy(new_deps[0..self.deps.len], self.deps);
        new_deps[self.deps.len] = dep;
        const old = self.deps;
        self.deps = new_deps;
        if (old.len > 0) self.allocator.free(old);
    }
};

pub const Dependency = struct {
    alias: []const u8,
    instance: model.LockfileInstanceRef,
};

const PackageContext = struct {
    package_id: model.PackageId,
    version: model.Version,
    domain: model.Domain,
    manifest: model.PackageManifest,
};

pub const ResolvedRoot = struct {
    package_id: model.PackageId,
    version: model.Version,
};

const PackageCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(model.PackageManifest),

    fn init(allocator: std.mem.Allocator) PackageCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMapUnmanaged(model.PackageManifest){},
        };
    }

    fn deinit(self: *PackageCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinitOwned(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit(self.allocator);
    }

    fn get(self: *PackageCache, key: []const u8) ?*const model.PackageManifest {
        return self.entries.getPtr(key);
    }

    fn put(self: *PackageCache, key: []const u8, value: model.PackageManifest) void {
        self.entries.put(self.allocator, key, value) catch unreachable;
    }

    fn remove(self: *PackageCache, key: []const u8) void {
        _ = self.entries.remove(key);
    }
};

fn formatInstanceKey(allocator: std.mem.Allocator, package_id: model.PackageId, domain: model.Domain) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}#{s}",
        .{ package_id.asText(), domain.asText() },
    );
}

test "resolver initializes correctly" {
    const allocator = std.testing.allocator;
    var resolver = Resolver.init(allocator, .linux, .x86_64, .linux, .x86_64, &.{}, ".", std.testing.io);
    defer resolver.deinit();

    _ = resolver.allocator;
}

test "resolver resolves empty package" {
    const allocator = std.testing.allocator;
    var resolver = Resolver.init(allocator, .linux, .x86_64, .linux, .x86_64, &.{}, ".", std.testing.io);
    defer resolver.deinit();

    const manifest = model.PackageManifest{
        .schema = 1,
        .package = .{
            .name = "test",
            .id = model.PackageId.parse("test.example.test") catch unreachable,
            .version = model.Version.parse("1.0.0") catch unreachable,
            .backend = .zig,
        },
        .options = &.{},
        .deps = &.{},
        .targets = &.{},
    };

    const resolved = try resolver.resolveRoot(manifest);
    try std.testing.expectEqualStrings("test.example.test", resolved.package_id.asText());
}
