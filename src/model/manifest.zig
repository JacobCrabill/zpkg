const std = @import("std");
const model = @import("root.zig");
const graph_model = @import("graph.zig");
const zon_util = @import("../schema/zon_util.zig");

pub const Dependency = struct {
    package_id: model.PackageId,
    domain: model.Domain,
    instance_key: []const u8,

    pub fn deinit(self: Dependency, allocator: std.mem.Allocator) void {
        self.package_id.deinitOwned(allocator);
        allocator.free(self.instance_key);
    }
};

pub const Manifest = struct {
    schema: u32,
    name: []const u8,
    package_id: model.PackageId,
    package_version: model.Version,
    domain: model.Domain,
    source_hash: []const u8,
    instance_key: []const u8,
    target: []const u8,
    optimize: []const u8,
    linkage: graph_model.Linkage,
    selected_options: []model.NamedOptionValue,
    exported_targets: []const []const u8,
    deps: []Dependency,

    pub fn deinit(self: Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.package_id.deinitOwned(allocator);
        allocator.free(self.source_hash);
        allocator.free(self.instance_key);
        allocator.free(self.target);
        allocator.free(self.optimize);
        for (self.selected_options) |entry| {
            allocator.free(entry.name);
            entry.value.deinitOwned(allocator);
        }
        allocator.free(self.selected_options);
        for (self.exported_targets) |entry| allocator.free(entry);
        allocator.free(self.exported_targets);
        for (self.deps) |entry| entry.deinit(allocator);
        allocator.free(self.deps);
    }

    pub fn toZonAlloc(self: Manifest, allocator: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        try writer.writeAll(".{\n");
        try zon_util.writeIndent(writer, 1);
        try writer.print(".schema = {d},\n", .{self.schema});
        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".name = ");
        try zon_util.writeString(writer, self.name);
        try writer.writeAll(",\n");
        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".package_id = ");
        try zon_util.writeString(writer, self.package_id.asText());
        try writer.writeAll(",\n");
        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".package_version = ");
        var version_buf: [32]u8 = undefined;
        try zon_util.writeString(writer, try self.package_version.bufPrint(&version_buf));
        try writer.writeAll(",\n");
        try zon_util.writeIndent(writer, 1);
        try writer.print(".domain = .{s},\n", .{self.domain.asText()});
        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".source_hash = ");
        try zon_util.writeString(writer, self.source_hash);
        try writer.writeAll(",\n");
        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".instance_key = ");
        try zon_util.writeString(writer, self.instance_key);
        try writer.writeAll(",\n");
        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".target = ");
        try zon_util.writeString(writer, self.target);
        try writer.writeAll(",\n");
        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".optimize = ");
        try zon_util.writeString(writer, self.optimize);
        try writer.writeAll(",\n");
        try zon_util.writeIndent(writer, 1);
        try writer.print(".linkage = .{s},\n", .{self.linkage.asText()});

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

        const sorted_exported_targets = try sortedStringsAlloc(allocator, self.exported_targets);
        defer allocator.free(sorted_exported_targets);
        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".exported_targets = .{");
        if (sorted_exported_targets.len == 0) {
            try writer.writeAll("},\n");
        } else {
            try writer.writeAll("\n");
            for (sorted_exported_targets) |entry| {
                try zon_util.writeIndent(writer, 2);
                try zon_util.writeString(writer, entry);
                try writer.writeAll(",\n");
            }
            try zon_util.writeIndent(writer, 1);
            try writer.writeAll("},\n");
        }

        const sorted_deps = try sortedDependenciesAlloc(allocator, self.deps);
        defer allocator.free(sorted_deps);
        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".deps = .{");
        if (sorted_deps.len == 0) {
            try writer.writeAll("},\n");
        } else {
            try writer.writeAll("\n");
            for (sorted_deps) |entry| {
                const dep_identity = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ entry.package_id.asText(), entry.domain.asText() });
                defer allocator.free(dep_identity);

                try zon_util.writeIndent(writer, 2);
                try zon_util.writeQuotedFieldName(writer, dep_identity);
                try writer.writeAll(" = ");
                try zon_util.writeString(writer, entry.instance_key);
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
    sortSlice(model.NamedOptionValue, sorted, namedOptionValueLessThan);
    return sorted;
}

fn sortedDependenciesAlloc(allocator: std.mem.Allocator, deps: []const Dependency) ![]const Dependency {
    const sorted = try allocator.dupe(Dependency, deps);
    sortSlice(Dependency, sorted, dependencyLessThan);
    return sorted;
}

fn sortedStringsAlloc(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const sorted = try allocator.dupe([]const u8, values);
    sortSlice([]const u8, sorted, stringLessThan);
    return sorted;
}

fn namedOptionValueLessThan(a: model.NamedOptionValue, b: model.NamedOptionValue) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn dependencyLessThan(a: Dependency, b: Dependency) bool {
    const package_order = std.mem.order(u8, a.package_id.asText(), b.package_id.asText());
    if (package_order != .eq) return package_order == .lt;
    return @intFromEnum(a.domain) < @intFromEnum(b.domain);
}

fn stringLessThan(a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
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
