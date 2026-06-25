const std = @import("std");
const model = @import("root.zig");
const zon_util = @import("../schema/zon_util.zig");

pub const InstanceRef = struct {
    package_id: model.PackageId,
    domain: model.Domain,

    pub fn parse(text: []const u8) !InstanceRef {
        const hash_index = std.mem.lastIndexOfScalar(u8, text, '#') orelse return error.InvalidInstanceRef;
        const package_text = text[0..hash_index];
        const domain_text = text[hash_index + 1 ..];
        if (package_text.len == 0 or domain_text.len == 0) return error.InvalidInstanceRef;
        return .{
            .package_id = model.PackageId.parse(package_text) catch return error.InvalidPackageId,
            .domain = model.Domain.parse(domain_text) catch return error.InvalidDomain,
        };
    }

    pub fn parseOwned(allocator: std.mem.Allocator, text: []const u8) !InstanceRef {
        const borrowed = try parse(text);
        return .{
            .package_id = try borrowed.package_id.cloneOwned(allocator),
            .domain = borrowed.domain,
        };
    }

    pub fn deinitOwned(self: InstanceRef, allocator: std.mem.Allocator) void {
        self.package_id.deinitOwned(allocator);
    }

    pub fn eql(self: InstanceRef, other: InstanceRef) bool {
        return self.package_id.eql(other.package_id) and self.domain == other.domain;
    }

    pub fn format(self: InstanceRef, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        try writer.print("{s}#{s}", .{ self.package_id.asText(), self.domain.asText() });
    }
};

pub const Root = struct {
    package_id: model.PackageId,
    version: model.Version,

    pub fn deinit(self: Root, allocator: std.mem.Allocator) void {
        self.package_id.deinitOwned(allocator);
    }
};

pub const GeneratedBy = struct {
    zpkg_version: []const u8,
    zig_version: []const u8,

    pub fn deinit(self: GeneratedBy, allocator: std.mem.Allocator) void {
        allocator.free(self.zpkg_version);
        allocator.free(self.zig_version);
    }
};

pub const Dependency = struct {
    alias: []const u8,
    instance: InstanceRef,

    pub fn deinit(self: Dependency, allocator: std.mem.Allocator) void {
        allocator.free(self.alias);
    }
};

pub const Instance = struct {
    key: InstanceRef,
    package_id: model.PackageId,
    domain: model.Domain,
    version: model.Version,
    source_hash: []const u8,
    selected_options: []model.NamedOptionValue,
    deps: []Dependency,

    pub fn deinit(self: Instance, allocator: std.mem.Allocator) void {
        self.key.deinitOwned(allocator);
        self.package_id.deinitOwned(allocator);
        allocator.free(self.source_hash);
        for (self.selected_options) |entry| {
            allocator.free(entry.name);
            entry.value.deinitOwned(allocator);
        }
        allocator.free(self.selected_options);
        for (self.deps) |dep| {
            dep.instance.deinitOwned(allocator);
            dep.deinit(allocator);
        }
        allocator.free(self.deps);
    }
};

pub const Lockfile = struct {
    schema: u32,
    root: Root,
    generated_by: ?GeneratedBy,
    instances: []Instance,

    pub fn deinit(self: Lockfile, allocator: std.mem.Allocator) void {
        self.root.deinit(allocator);
        if (self.generated_by) |generated_by| generated_by.deinit(allocator);
        for (self.instances) |instance| instance.deinit(allocator);
        allocator.free(self.instances);
    }

    pub fn findInstance(self: Lockfile, key: InstanceRef) ?*const Instance {
        for (self.instances) |*instance| {
            if (instance.key.eql(key)) return instance;
        }
        return null;
    }

    pub fn toZonAlloc(self: Lockfile, allocator: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        try writer.writeAll(".{\n");
        try zon_util.writeIndent(writer, 1);
        try writer.print(".schema = {d},\n\n", .{self.schema});

        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".root = .{\n");
        try zon_util.writeIndent(writer, 2);
        try writer.writeAll(".package = ");
        try zon_util.writeString(writer, self.root.package_id.asText());
        try writer.writeAll(",\n");
        try zon_util.writeIndent(writer, 2);
        try writer.writeAll(".version = ");
        var version_buf: [32]u8 = undefined;
        try zon_util.writeString(writer, try self.root.version.bufPrint(&version_buf));
        try writer.writeAll(",\n");
        try zon_util.writeIndent(writer, 1);
        try writer.writeAll("},\n");

        if (self.generated_by) |generated_by| {
            try writer.writeAll("\n");
            try zon_util.writeIndent(writer, 1);
            try writer.writeAll(".generated_by = .{\n");
            try zon_util.writeIndent(writer, 2);
            try writer.writeAll(".zpkg_version = ");
            try zon_util.writeString(writer, generated_by.zpkg_version);
            try writer.writeAll(",\n");
            try zon_util.writeIndent(writer, 2);
            try writer.writeAll(".zig_version = ");
            try zon_util.writeString(writer, generated_by.zig_version);
            try writer.writeAll(",\n");
            try zon_util.writeIndent(writer, 1);
            try writer.writeAll("},\n");
        }

        const sorted_instances = try sortedInstancesAlloc(allocator, self.instances);
        defer allocator.free(sorted_instances);

        try writer.writeAll("\n");
        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".instances = .{\n");
        for (sorted_instances) |instance| {
            const key_text = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ instance.key.package_id.asText(), instance.key.domain.asText() });
            defer allocator.free(key_text);

            try zon_util.writeIndent(writer, 2);
            try zon_util.writeQuotedFieldName(writer, key_text);
            try writer.writeAll(" = .{\n");
            try zon_util.writeIndent(writer, 3);
            try writer.writeAll(".package = ");
            try zon_util.writeString(writer, instance.package_id.asText());
            try writer.writeAll(",\n");
            try zon_util.writeIndent(writer, 3);
            try writer.print(".domain = .{s},\n", .{instance.domain.asText()});
            try zon_util.writeIndent(writer, 3);
            try writer.writeAll(".version = ");
            var instance_version_buf: [32]u8 = undefined;
            try zon_util.writeString(writer, try instance.version.bufPrint(&instance_version_buf));
            try writer.writeAll(",\n");
            try zon_util.writeIndent(writer, 3);
            try writer.writeAll(".source_hash = ");
            try zon_util.writeString(writer, instance.source_hash);
            try writer.writeAll(",\n");

            const sorted_options = try sortedNamedOptionValuesAlloc(allocator, instance.selected_options);
            defer allocator.free(sorted_options);
            try zon_util.writeIndent(writer, 3);
            try writer.writeAll(".selected_options = .{");
            if (sorted_options.len == 0) {
                try writer.writeAll("},\n");
            } else {
                try writer.writeAll("\n");
                for (sorted_options) |entry| {
                    try zon_util.writeIndent(writer, 4);
                    try zon_util.writeQuotedFieldName(writer, entry.name);
                    try writer.writeAll(" = ");
                    try zon_util.writeOptionValue(writer, entry.value);
                    try writer.writeAll(",\n");
                }
                try zon_util.writeIndent(writer, 3);
                try writer.writeAll("},\n");
            }

            const sorted_deps = try sortedDependenciesAlloc(allocator, instance.deps);
            defer allocator.free(sorted_deps);
            try zon_util.writeIndent(writer, 3);
            try writer.writeAll(".deps = .{");
            if (sorted_deps.len == 0) {
                try writer.writeAll("},\n");
            } else {
                try writer.writeAll("\n");
                for (sorted_deps) |dep| {
                    const dep_text = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ dep.instance.package_id.asText(), dep.instance.domain.asText() });
                    defer allocator.free(dep_text);
                    try zon_util.writeIndent(writer, 4);
                    try zon_util.writeQuotedFieldName(writer, dep.alias);
                    try writer.writeAll(" = ");
                    try zon_util.writeString(writer, dep_text);
                    try writer.writeAll(",\n");
                }
                try zon_util.writeIndent(writer, 3);
                try writer.writeAll("},\n");
            }

            try zon_util.writeIndent(writer, 2);
            try writer.writeAll("},\n");
        }
        try zon_util.writeIndent(writer, 1);
        try writer.writeAll("},\n");
        try writer.writeAll("}\n");

        return try aw.toOwnedSlice();
    }
};

fn sortedInstancesAlloc(allocator: std.mem.Allocator, instances: []const Instance) ![]const Instance {
    const sorted = try allocator.dupe(Instance, instances);
    sortSlice(Instance, sorted, instanceLessThan);
    return sorted;
}

fn sortedDependenciesAlloc(allocator: std.mem.Allocator, deps: []const Dependency) ![]const Dependency {
    const sorted = try allocator.dupe(Dependency, deps);
    sortSlice(Dependency, sorted, dependencyLessThan);
    return sorted;
}

fn sortedNamedOptionValuesAlloc(allocator: std.mem.Allocator, options: []const model.NamedOptionValue) ![]const model.NamedOptionValue {
    const sorted = try allocator.dupe(model.NamedOptionValue, options);
    sortSlice(model.NamedOptionValue, sorted, namedOptionValueLessThan);
    return sorted;
}

fn instanceLessThan(a: Instance, b: Instance) bool {
    return instanceRefLessThan(a.key, b.key);
}

fn dependencyLessThan(a: Dependency, b: Dependency) bool {
    return std.mem.order(u8, a.alias, b.alias) == .lt;
}

fn namedOptionValueLessThan(a: model.NamedOptionValue, b: model.NamedOptionValue) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn instanceRefLessThan(a: InstanceRef, b: InstanceRef) bool {
    const package_order = std.mem.order(u8, a.package_id.asText(), b.package_id.asText());
    if (package_order != .eq) return package_order == .lt;
    return @intFromEnum(a.domain) < @intFromEnum(b.domain);
}

fn sortSlice(comptime T: type, items: []T, lessThan: fn (T, T) bool) void {
    if (items.len <= 1) return;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const value = items[i];
        var j = i;
        while (j > 0 and lessThan(value, items[j - 1])) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = value;
    }
}

test "instance ref parses canonical lockfile identities" {
    const ref = try InstanceRef.parse("zpkg.example.hello_lib#target");
    try std.testing.expectEqualStrings("zpkg.example.hello_lib", ref.package_id.asText());
    try std.testing.expectEqual(model.Domain.target, ref.domain);
    try std.testing.expectError(error.InvalidInstanceRef, InstanceRef.parse("zpkg.example.hello_lib"));
}
