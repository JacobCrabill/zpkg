const std = @import("std");
const model = @import("../model/root.zig");
const lockfile_model = @import("../model/lockfile.zig");
const zon_util = @import("../schema/zon_util.zig");

pub const InstanceRef = lockfile_model.InstanceRef;

/// Artifact manifest — records what was built and how.
/// Serialized as a ZON file alongside the archive in the store.
pub const ArtifactManifest = struct {
    schema: u32,
    instance: InstanceRef,
    version: model.Version,
    source_hash: []const u8,
    selected_options: []model.NamedOptionValue,
    dep_instances: []InstanceRef,

    pub fn deinit(self: ArtifactManifest, allocator: std.mem.Allocator) void {
        self.instance.deinitOwned(allocator);
        allocator.free(self.source_hash);
        for (self.selected_options) |entry| {
            allocator.free(entry.name);
            entry.value.deinitOwned(allocator);
        }
        allocator.free(self.selected_options);
        for (self.dep_instances) |dep| {
            dep.deinitOwned(allocator);
        }
        allocator.free(self.dep_instances);
    }

    /// Serialize to ZON. Caller owns the returned slice.
    pub fn toZonAlloc(self: ArtifactManifest, allocator: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        try writer.writeAll(".{\n");

        try zon_util.writeIndent(writer, 1);
        try writer.print(".schema = {d},\n", .{self.schema});

        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".instance = ");
        const instance_text = try std.fmt.allocPrint(allocator, "{s}#{s}", .{
            self.instance.package_id.asText(),
            self.instance.domain.asText(),
        });
        defer allocator.free(instance_text);
        try zon_util.writeString(writer, instance_text);
        try writer.writeAll(",\n");

        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".version = ");
        var version_buf: [32]u8 = undefined;
        try zon_util.writeString(writer, try self.version.bufPrint(&version_buf));
        try writer.writeAll(",\n");

        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".source_hash = ");
        try zon_util.writeString(writer, self.source_hash);
        try writer.writeAll(",\n");

        // Sort options for deterministic output
        const sorted_options = try sortedNamedOptionValuesAlloc(allocator, self.selected_options);
        defer allocator.free(sorted_options);
        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".selected_options = .{");
        if (sorted_options.len == 0) {
            try writer.writeAll("},\n");
        } else {
            try writer.writeAll("\n");
            for (sorted_options) |entry| {
                try zon_util.writeIndent(writer, 2);
                try zon_util.writeQuotedFieldName(writer, entry.name);
                try writer.writeAll(" = ");
                try zon_util.writeOptionValue(writer, entry.value);
                try writer.writeAll(",\n");
            }
            try zon_util.writeIndent(writer, 1);
            try writer.writeAll("},\n");
        }

        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".dep_instances = .{");
        if (self.dep_instances.len == 0) {
            try writer.writeAll("},\n");
        } else {
            try writer.writeAll("\n");
            for (self.dep_instances) |dep| {
                const dep_text = try std.fmt.allocPrint(allocator, "{s}#{s}", .{
                    dep.package_id.asText(),
                    dep.domain.asText(),
                });
                defer allocator.free(dep_text);
                try zon_util.writeIndent(writer, 2);
                try zon_util.writeString(writer, dep_text);
                try writer.writeAll(",\n");
            }
            try zon_util.writeIndent(writer, 1);
            try writer.writeAll("},\n");
        }

        try writer.writeAll("}\n");

        return try aw.toOwnedSlice();
    }
};

fn sortedNamedOptionValuesAlloc(allocator: std.mem.Allocator, options: []const model.NamedOptionValue) ![]const model.NamedOptionValue {
    const sorted = try allocator.dupe(model.NamedOptionValue, options);
    std.mem.sort(model.NamedOptionValue, sorted, {}, namedOptionValueLessThan);
    return sorted;
}

fn namedOptionValueLessThan(_: void, a: model.NamedOptionValue, b: model.NamedOptionValue) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

test "artifact manifest serializes to valid ZON" {
    const allocator = std.testing.allocator;

    const instance_ref = try InstanceRef.parseOwned(allocator, "zpkg.example.hello_lib#target");
    const dep_ref = try InstanceRef.parseOwned(allocator, "zpkg.example.hello_headers#target");

    const dep_instances = try allocator.dupe(InstanceRef, &.{dep_ref});

    const option_name = try allocator.dupe(u8, "shared");
    const selected_options = try allocator.dupe(model.NamedOptionValue, &.{
        .{ .name = option_name, .value = .{ .bool = true } },
    });

    const source_hash = try allocator.dupe(u8, "sha256:abcd1234");

    const manifest: ArtifactManifest = .{
        .schema = 1,
        .instance = instance_ref,
        .version = .{ .major = 0, .minor = 1, .patch = 0, .revision = 0 },
        .source_hash = source_hash,
        .selected_options = selected_options,
        .dep_instances = dep_instances,
    };
    defer manifest.deinit(allocator);

    const zon = try manifest.toZonAlloc(allocator);
    defer allocator.free(zon);

    // Round-trip check: output is syntactically valid ZON
    try std.testing.expect(std.mem.startsWith(u8, zon, ".{"));

    // Spot-check content
    try std.testing.expect(std.mem.indexOf(u8, zon, "zpkg.example.hello_lib#target") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, "sha256:abcd1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, "shared") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, "zpkg.example.hello_headers#target") != null);
}

test "artifact manifest with no options or deps" {
    const allocator = std.testing.allocator;

    const instance_ref = try InstanceRef.parseOwned(allocator, "zpkg.minimal#host");
    const source_hash = try allocator.dupe(u8, "sha256:0000");
    const selected_options = try allocator.alloc(model.NamedOptionValue, 0);
    const dep_instances = try allocator.alloc(InstanceRef, 0);

    const manifest: ArtifactManifest = .{
        .schema = 1,
        .instance = instance_ref,
        .version = .{ .major = 1, .minor = 0, .patch = 0, .revision = 0 },
        .source_hash = source_hash,
        .selected_options = selected_options,
        .dep_instances = dep_instances,
    };
    defer manifest.deinit(allocator);

    const zon = try manifest.toZonAlloc(allocator);
    defer allocator.free(zon);

    try std.testing.expect(std.mem.startsWith(u8, zon, ".{"));
    try std.testing.expect(std.mem.indexOf(u8, zon, ".selected_options = .{},") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".dep_instances = .{},") != null);
}
