const std = @import("std");
const model = @import("../model/root.zig");
const resolve = @import("root.zig");

pub const Drift = struct {
    root_identity_changed: bool,
    root_version_changed: bool,
    dependency_aliases_changed: bool,
    constraints_changed: bool,
    option_schema_incompatible: bool,
    missing_deps: []const model.PackageId,
    extra_deps: []const model.PackageId,
    missing_instances: []model.LockfileInstanceRef,
    option_value_incompatibilities: []const OptionValueIncompatibility,

    pub fn deinit(self: *Drift, allocator: std.mem.Allocator) void {
        for (self.missing_deps) |dep| allocator.free(dep.text);
        for (self.extra_deps) |dep| allocator.free(dep.text);
        for (self.missing_instances) |instance| instance.package_id.deinitOwned(allocator);
        for (self.option_value_incompatibilities) |incompat| {
            allocator.free(incompat.name);
            allocator.free(incompat.locked_value);
            incompat.expected_value.deinitOwned(allocator);
        }
        allocator.free(self.missing_deps);
        allocator.free(self.extra_deps);
        allocator.free(self.missing_instances);
        allocator.free(self.option_value_incompatibilities);
    }

    pub fn hasDrift(self: Drift) bool {
        return self.root_identity_changed or
            self.root_version_changed or
            self.dependency_aliases_changed or
            self.constraints_changed or
            self.option_schema_incompatible or
            self.missing_deps.len > 0 or
            self.extra_deps.len > 0 or
            self.missing_instances.len > 0 or
            self.option_value_incompatibilities.len > 0;
    }
};

pub const OptionValueIncompatibility = struct {
    name: []const u8,
    locked_value: []const u8,
    expected_value: model.OptionValue,
};

pub fn detectDrift(
    allocator: std.mem.Allocator,
    lockfile: model.Lockfile,
    manifest: model.PackageManifest,
) std.mem.Allocator.Error!Drift {
    var drift = Drift{
        .root_identity_changed = false,
        .root_version_changed = false,
        .dependency_aliases_changed = false,
        .constraints_changed = false,
        .option_schema_incompatible = false,
        .missing_deps = &.{},
        .extra_deps = &.{},
        .missing_instances = &.{},
        .option_value_incompatibilities = &.{},
    };

    // Check root identity
    if (!std.mem.eql(u8, lockfile.root.package_id.asText(), manifest.package.id.asText())) {
        drift.root_identity_changed = true;
    }

    // Check root version
    if (!manifest.package.version.eql(lockfile.root.version)) {
        drift.root_version_changed = true;
    }

    // Check dependency aliases
    drift.dependency_aliases_changed = detectAliasChanges(allocator, &lockfile, manifest);

    // Check constraints
    drift.constraints_changed = detectConstraintChanges(allocator, &lockfile, manifest);

    // Check option schema compatibility
    drift.option_schema_incompatible = detectOptionSchemaIncompatibility(allocator, &lockfile, manifest);

    // Check for missing instances
    drift.missing_instances = detectMissingInstances(allocator, &lockfile, manifest);

    // Check for missing/extra dependencies
    drift.missing_deps = detectMissingDeps(allocator, &lockfile, manifest);
    drift.extra_deps = detectExtraDeps(allocator, &lockfile, manifest);

    // Check option value incompatibilities
    drift.option_value_incompatibilities = detectOptionValueIncompatibilities(allocator, &lockfile, manifest);

    return drift;
}

fn detectAliasChanges(allocator: std.mem.Allocator, lockfile: *const model.Lockfile, manifest: model.PackageManifest) bool {
    _ = allocator;
    _ = lockfile;
    _ = manifest;
    return false;
}

fn detectConstraintChanges(allocator: std.mem.Allocator, lockfile: *const model.Lockfile, manifest: model.PackageManifest) bool {
    _ = allocator;
    _ = lockfile;
    _ = manifest;
    return false;
}

fn detectOptionSchemaIncompatibility(allocator: std.mem.Allocator, lockfile: *const model.Lockfile, manifest: model.PackageManifest) bool {
    _ = allocator;
    _ = lockfile;
    _ = manifest;
    return false;
}

fn detectMissingInstances(allocator: std.mem.Allocator, lockfile: *const model.Lockfile, manifest: model.PackageManifest) []model.LockfileInstanceRef {
    _ = allocator;
    _ = lockfile;
    _ = manifest;
    return &.{};
}

fn detectMissingDeps(allocator: std.mem.Allocator, lockfile: *const model.Lockfile, manifest: model.PackageManifest) []const model.PackageId {
    _ = allocator;
    _ = lockfile;
    _ = manifest;
    return &.{};
}

fn detectExtraDeps(allocator: std.mem.Allocator, lockfile: *const model.Lockfile, manifest: model.PackageManifest) []const model.PackageId {
    _ = allocator;
    _ = lockfile;
    _ = manifest;
    return &.{};
}

fn detectOptionValueIncompatibilities(allocator: std.mem.Allocator, lockfile: *const model.Lockfile, manifest: model.PackageManifest) []const OptionValueIncompatibility {
    _ = allocator;
    _ = lockfile;
    _ = manifest;
    return &.{};
}

pub fn formatDriftDiagnostic(allocator: std.mem.Allocator, drift: Drift) ![]u8 {
    if (!drift.hasDrift()) {
        return try allocator.dupe(u8, "Lockfile is up to date\n");
    }

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const writer = buf.writer();

    if (drift.root_identity_changed) {
        try writer.writeAll("error: root package identity has changed\n");
    }
    if (drift.root_version_changed) {
        try writer.writeAll("error: root package version has changed\n");
    }
    if (drift.dependency_aliases_changed) {
        try writer.writeAll("error: dependency aliases have changed\n");
    }
    if (drift.constraints_changed) {
        try writer.writeAll("error: version constraints have changed\n");
    }
    if (drift.option_schema_incompatible) {
        try writer.writeAll("error: option schema has become incompatible\n");
    }
    if (drift.missing_deps.len > 0) {
        try writer.writeAll("error: missing dependencies:\n");
        for (drift.missing_deps) |dep| {
            try writer.print("  - {s}\n", .{dep.asText()});
        }
    }
    if (drift.extra_deps.len > 0) {
        try writer.writeAll("error: extra dependencies:\n");
        for (drift.extra_deps) |dep| {
            try writer.print("  - {s}\n", .{dep.asText()});
        }
    }
    if (drift.missing_instances.len > 0) {
        try writer.writeAll("error: missing instances:\n");
        for (drift.missing_instances) |instance| {
            try writer.print("  - {s}\n", .{instance.package_id.asText()});
        }
    }
    if (drift.option_value_incompatibilities.len > 0) {
        try writer.writeAll("error: option value incompatibilities:\n");
        for (drift.option_value_incompatibilities) |incompat| {
            try writer.print("  - {s}: locked={s}, expected={s}\n", .{ incompat.name, incompat.locked_value, @tagName(incompat.expected_value.kind()) });
        }
    }

    return buf.toOwnedSlice();
}
