const std = @import("std");
const model = @import("../model/root.zig");
const graph_model = @import("../model/graph.zig");
const manifest_model = @import("../model/manifest.zig");
const zon_util = @import("zon_util.zig");

pub const ParseError = zon_util.ParseError || error{ OutOfMemory, InvalidDependencyIdentity };

pub fn parseSourceAlloc(allocator: std.mem.Allocator, source: [:0]const u8) ParseError!manifest_model.Manifest {
    var doc = try zon_util.parseDocument(allocator, source);
    defer doc.deinit(allocator);
    return parseDocumentAlloc(allocator, &doc);
}

fn parseDocumentAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document) ParseError!manifest_model.Manifest {
    const object = try zon_util.Object.fromNode(doc, .root);
    try object.validateOnlyFields(&.{
        "schema",
        "name",
        "package_id",
        "package_version",
        "domain",
        "source_hash",
        "instance_key",
        "target",
        "optimize",
        "linkage",
        "selected_options",
        "exported_targets",
        "deps",
    });

    const schema = try zon_util.parseInt(doc, try object.require("schema"));
    if (schema != 1) return error.InvalidSchemaVersion;

    const name = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("name"));
    errdefer allocator.free(name);
    const package_id_text = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("package_id"));
    const package_version_text = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("package_version"));
    defer allocator.free(package_version_text);

    const package_id = model.PackageId.adoptOwned(package_id_text) catch {
        allocator.free(package_id_text);
        return error.InvalidPackageId;
    };
    errdefer package_id.deinitOwned(allocator);
    const package_version = model.Version.parse(package_version_text) catch return error.InvalidVersion;
    const domain = zon_util.parseEnum(model.Domain, doc, try object.require("domain")) catch return error.InvalidDomain;
    const source_hash = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("source_hash"));
    errdefer allocator.free(source_hash);
    const instance_key = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("instance_key"));
    errdefer allocator.free(instance_key);
    const target = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("target"));
    errdefer allocator.free(target);
    const optimize = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("optimize"));
    errdefer allocator.free(optimize);
    const linkage = zon_util.parseEnum(graph_model.Linkage, doc, try object.require("linkage")) catch return error.InvalidField;
    const selected_options = try parseSelectedOptionsAlloc(allocator, doc, try object.require("selected_options"));
    errdefer {
        for (selected_options) |entry| {
            allocator.free(entry.name);
            entry.value.deinitOwned(allocator);
        }
        allocator.free(selected_options);
    }
    const exported_targets = try parseExportedTargetsAlloc(allocator, doc, try object.require("exported_targets"));
    errdefer {
        for (exported_targets) |entry| allocator.free(entry);
        allocator.free(exported_targets);
    }
    const deps = try parseDepsAlloc(allocator, doc, try object.require("deps"));
    errdefer {
        for (deps) |entry| entry.deinit(allocator);
        allocator.free(deps);
    }

    return .{
        .schema = @intCast(schema),
        .name = name,
        .package_id = package_id,
        .package_version = package_version,
        .domain = domain,
        .source_hash = source_hash,
        .instance_key = instance_key,
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
        .selected_options = selected_options,
        .exported_targets = exported_targets,
        .deps = deps,
    };
}

fn parseSelectedOptionsAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError![]model.NamedOptionValue {
    const object = try zon_util.Object.fromNode(doc, node);
    const result = try allocator.alloc(model.NamedOptionValue, object.fieldCount());
    errdefer allocator.free(result);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |entry| {
            allocator.free(entry.name);
            entry.value.deinitOwned(allocator);
        }
    }

    for (0..object.fieldCount()) |index| {
        const name = try allocator.dupe(u8, object.fieldName(index));
        errdefer allocator.free(name);
        const value = try zon_util.parseOptionValueAlloc(allocator, doc, object.fieldNode(index));
        result[index] = .{
            .name = name,
            .value = value,
        };
        initialized += 1;
    }
    return result;
}

fn parseExportedTargetsAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError![]const []const u8 {
    const array = try zon_util.Array.fromNode(doc, node);
    const result = try allocator.alloc([]const u8, array.len());
    errdefer allocator.free(result);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |entry| allocator.free(entry);
    }

    for (0..array.len()) |index| {
        result[index] = try zon_util.parseNonEmptyStringAlloc(allocator, doc, array.at(index));
        initialized += 1;
    }
    return result;
}

fn parseDepsAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError![]manifest_model.Dependency {
    const object = try zon_util.Object.fromNode(doc, node);
    const result = try allocator.alloc(manifest_model.Dependency, object.fieldCount());
    errdefer allocator.free(result);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |entry| entry.deinit(allocator);
    }

    for (0..object.fieldCount()) |index| {
        const identity = try parseDependencyIdentityOwned(allocator, object.fieldName(index));
        errdefer identity.package_id.deinitOwned(allocator);
        const instance_key = try zon_util.parseNonEmptyStringAlloc(allocator, doc, object.fieldNode(index));
        result[index] = .{
            .package_id = identity.package_id,
            .domain = identity.domain,
            .instance_key = instance_key,
        };
        initialized += 1;
    }

    return result;
}

fn parseDependencyIdentityOwned(allocator: std.mem.Allocator, text: []const u8) ParseError!struct {
    package_id: model.PackageId,
    domain: model.Domain,
} {
    const hash_index = std.mem.lastIndexOfScalar(u8, text, '#') orelse return error.InvalidDependencyIdentity;
    const package_text = text[0..hash_index];
    const domain_text = text[hash_index + 1 ..];
    if (package_text.len == 0 or domain_text.len == 0) return error.InvalidDependencyIdentity;

    return .{
        .package_id = model.PackageId.parseOwned(allocator, package_text) catch return error.InvalidPackageId,
        .domain = model.Domain.parse(domain_text) catch return error.InvalidDomain,
    };
}

test "parse manifest schema" {
    const source =
        \\.{
        \\    .schema = 1,
        \\    .name = "hello-lib",
        \\    .package_id = "zpkg.example.hello_lib",
        \\    .package_version = "0.1.0",
        \\    .domain = .target,
        \\    .source_hash = "source-hash",
        \\    .instance_key = "instance-key",
        \\    .target = "x86_64-linux-gnu",
        \\    .optimize = "ReleaseFast",
        \\    .linkage = .shared,
        \\    .selected_options = .{ .shared = true },
        \\    .exported_targets = .{ "hello", "hello_headers" },
        \\    .deps = .{
        \\        .@"zpkg.example.protobuf#host" = "protobuf-host-instance",
        \\        .@"zpkg.example.protobuf#target" = "protobuf-target-instance",
        \\    },
        \\}
    ;

    const parsed = try parseSourceAlloc(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hello-lib", parsed.name);
    try std.testing.expectEqual(graph_model.Linkage.shared, parsed.linkage);
    try std.testing.expectEqualStrings("hello", parsed.exported_targets[0]);
    try std.testing.expectEqual(@as(usize, 2), parsed.deps.len);

    var saw_host = false;
    var saw_target = false;
    for (parsed.deps) |dep| {
        try std.testing.expectEqualStrings("zpkg.example.protobuf", dep.package_id.asText());
        switch (dep.domain) {
            .host => {
                saw_host = true;
                try std.testing.expectEqualStrings("protobuf-host-instance", dep.instance_key);
            },
            .target => {
                saw_target = true;
                try std.testing.expectEqualStrings("protobuf-target-instance", dep.instance_key);
            },
        }
    }

    try std.testing.expect(saw_host);
    try std.testing.expect(saw_target);
}

test "manifest rejects dependency identity without domain" {
    const source =
        \\.{
        \\    .schema = 1,
        \\    .name = "hello-lib",
        \\    .package_id = "zpkg.example.hello_lib",
        \\    .package_version = "0.1.0",
        \\    .domain = .target,
        \\    .source_hash = "source-hash",
        \\    .instance_key = "instance-key",
        \\    .target = "x86_64-linux-gnu",
        \\    .optimize = "ReleaseFast",
        \\    .linkage = .shared,
        \\    .selected_options = .{},
        \\    .exported_targets = .{},
        \\    .deps = .{ .@"zpkg.example.protobuf" = "protobuf-target-instance" },
        \\}
    ;

    try std.testing.expectError(error.InvalidDependencyIdentity, parseSourceAlloc(std.testing.allocator, source));
}

test "manifest golden normalized zon" {
    const source =
        \\.{
        \\    .schema = 1,
        \\    .name = "hello-lib",
        \\    .package_id = "zpkg.example.hello_lib",
        \\    .package_version = "0.1.0",
        \\    .domain = .target,
        \\    .source_hash = "source-hash",
        \\    .instance_key = "instance-key",
        \\    .target = "x86_64-linux-gnu",
        \\    .optimize = "ReleaseFast",
        \\    .linkage = .shared,
        \\    .selected_options = .{ .shared = true, .build_tests = false },
        \\    .exported_targets = .{ "hello", "hello_headers" },
        \\    .deps = .{
        \\        .@"zpkg.example.zlib#target" = "zlib-instance",
        \\        .@"zpkg.example.protobuf#target" = "protobuf-target-instance",
        \\        .@"zpkg.example.protobuf#host" = "protobuf-host-instance",
        \\    },
        \\}
    ;

    const parsed = try parseSourceAlloc(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    const rendered = try parsed.toZonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    const io = std.testing.io;
    const expected = try std.Io.Dir.cwd().readFileAlloc(io, "test/golden/schema/manifest-normalized.zon", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, rendered);
}
