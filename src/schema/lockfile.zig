const std = @import("std");
const model = @import("../model/root.zig");
const lockfile_model = @import("../model/lockfile.zig");
const zon_util = @import("zon_util.zig");

pub const ParseError = zon_util.ParseError || error{OutOfMemory};

pub fn parseSourceAlloc(allocator: std.mem.Allocator, source: [:0]const u8) ParseError!lockfile_model.Lockfile {
    var doc = try zon_util.parseDocument(allocator, source);
    defer doc.deinit(allocator);
    return parseDocumentAlloc(allocator, &doc);
}

fn parseDocumentAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document) ParseError!lockfile_model.Lockfile {
    const root_object = try zon_util.Object.fromNode(doc, .root);
    try root_object.validateOnlyFields(&.{ "schema", "root", "generated_by", "instances" });

    const schema = try zon_util.parseInt(doc, try root_object.require("schema"));
    if (schema != 1) return error.InvalidSchemaVersion;

    const root = try parseRootAlloc(allocator, doc, try root_object.require("root"));
    errdefer root.deinit(allocator);
    const generated_by = if (root_object.get("generated_by")) |node|
        try parseGeneratedByAlloc(allocator, doc, node)
    else
        null;
    errdefer if (generated_by) |entry| entry.deinit(allocator);
    const instances = try parseInstancesAlloc(allocator, doc, try root_object.require("instances"));
    errdefer {
        for (instances) |instance| instance.deinit(allocator);
        allocator.free(instances);
    }

    const result = lockfile_model.Lockfile{
        .schema = @intCast(schema),
        .root = root,
        .generated_by = generated_by,
        .instances = instances,
    };

    try validateInstances(result);
    return result;
}

fn parseRootAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError!lockfile_model.Root {
    const object = try zon_util.Object.fromNode(doc, node);
    try object.validateOnlyFields(&.{ "package", "version" });

    const package_text = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("package"));
    errdefer allocator.free(package_text);
    const version_text = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("version"));
    defer allocator.free(version_text);

    return .{
        .package_id = model.PackageId.adoptOwned(package_text) catch return error.InvalidPackageId,
        .version = model.Version.parse(version_text) catch return error.InvalidVersion,
    };
}

fn parseGeneratedByAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError!lockfile_model.GeneratedBy {
    const object = try zon_util.Object.fromNode(doc, node);
    try object.validateOnlyFields(&.{ "zpkg_version", "zig_version" });

    return .{
        .zpkg_version = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("zpkg_version")),
        .zig_version = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("zig_version")),
    };
}

fn parseInstancesAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError![]lockfile_model.Instance {
    const object = try zon_util.Object.fromNode(doc, node);
    const instances = try allocator.alloc(lockfile_model.Instance, object.fieldCount());
    errdefer allocator.free(instances);

    var initialized: usize = 0;
    errdefer {
        for (instances[0..initialized]) |instance| instance.deinit(allocator);
    }

    for (0..object.fieldCount()) |index| {
        const key_text = object.fieldName(index);
        const key = lockfile_model.InstanceRef.parseOwned(allocator, key_text) catch |err| switch (err) {
            error.InvalidPackageId => return error.InvalidPackageId,
            error.InvalidDomain => return error.InvalidDomain,
            else => return error.InvalidInstanceRef,
        };
        instances[index] = try parseInstanceAlloc(allocator, doc, key, object.fieldNode(index));
        initialized += 1;
    }

    return instances;
}

fn parseInstanceAlloc(
    allocator: std.mem.Allocator,
    doc: *const zon_util.Document,
    key: lockfile_model.InstanceRef,
    node: std.zig.Zoir.Node.Index,
) ParseError!lockfile_model.Instance {
    errdefer key.deinitOwned(allocator);
    const object = try zon_util.Object.fromNode(doc, node);
    try object.validateOnlyFields(&.{ "package", "domain", "version", "source_hash", "selected_options", "deps" });

    const package_text = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("package"));
    errdefer allocator.free(package_text);
    const version_text = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("version"));
    defer allocator.free(version_text);
    const source_hash = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("source_hash"));
    errdefer allocator.free(source_hash);

    const package_id = model.PackageId.adoptOwned(package_text) catch return error.InvalidPackageId;
    errdefer package_id.deinitOwned(allocator);
    const domain = zon_util.parseEnum(model.Domain, doc, try object.require("domain")) catch return error.InvalidDomain;
    const version = model.Version.parse(version_text) catch return error.InvalidVersion;
    const selected_options = try parseSelectedOptionsAlloc(allocator, doc, try object.require("selected_options"));
    errdefer {
        for (selected_options) |entry| {
            allocator.free(entry.name);
            entry.value.deinitOwned(allocator);
        }
        allocator.free(selected_options);
    }
    const deps = try parseDepsAlloc(allocator, doc, try object.require("deps"));
    errdefer {
        for (deps) |dep| {
            dep.instance.deinitOwned(allocator);
            dep.deinit(allocator);
        }
        allocator.free(deps);
    }

    return .{
        .key = key,
        .package_id = package_id,
        .domain = domain,
        .version = version,
        .source_hash = source_hash,
        .selected_options = selected_options,
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

fn parseDepsAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError![]lockfile_model.Dependency {
    const object = try zon_util.Object.fromNode(doc, node);
    const result = try allocator.alloc(lockfile_model.Dependency, object.fieldCount());
    errdefer allocator.free(result);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |dep| dep.deinit(allocator);
    }

    for (0..object.fieldCount()) |index| {
        const ref_text = try zon_util.parseNonEmptyStringAlloc(allocator, doc, object.fieldNode(index));
        defer allocator.free(ref_text);
        const alias = try allocator.dupe(u8, object.fieldName(index));
        errdefer allocator.free(alias);
        const instance = lockfile_model.InstanceRef.parseOwned(allocator, ref_text) catch |err| switch (err) {
            error.InvalidPackageId => return error.InvalidPackageId,
            error.InvalidDomain => return error.InvalidDomain,
            else => return error.InvalidInstanceRef,
        };
        result[index] = .{
            .alias = alias,
            .instance = instance,
        };
        initialized += 1;
    }

    return result;
}

fn validateInstances(lockfile: lockfile_model.Lockfile) ParseError!void {
    for (lockfile.instances, 0..) |instance, index| {
        if (!instance.key.package_id.eql(instance.package_id) or instance.key.domain != instance.domain) {
            return error.InstanceKeyMismatch;
        }

        for (lockfile.instances[index + 1 ..]) |other| {
            if (instance.key.eql(other.key)) return error.DuplicateIdentity;
        }

        for (instance.deps) |dep| {
            if (lockfile.findInstance(dep.instance) == null) return error.MissingReferencedInstance;
        }
    }
}

test "parse lockfile and preserve dependency aliases" {
    const source =
        \\.{
        \\    .schema = 1,
        \\    .root = .{
        \\        .package = "zpkg.example.hello_app",
        \\        .version = "0.1.0",
        \\    },
        \\    .generated_by = .{
        \\        .zpkg_version = "0.1.0",
        \\        .zig_version = "0.16.0",
        \\    },
        \\    .instances = .{
        \\        .@"zpkg.example.hello_app#target" = .{
        \\            .package = "zpkg.example.hello_app",
        \\            .domain = .target,
        \\            .version = "0.1.0",
        \\            .source_hash = "root-hash",
        \\            .selected_options = .{
        \\                .shared = true,
        \\            },
        \\            .deps = .{
        \\                .hello_lib = "zpkg.example.hello_lib#target",
        \\                .codegen = "zpkg.example.hello_tool#host",
        \\            },
        \\        },
        \\        .@"zpkg.example.hello_lib#target" = .{
        \\            .package = "zpkg.example.hello_lib",
        \\            .domain = .target,
        \\            .version = "0.1.0.0",
        \\            .source_hash = "lib-hash",
        \\            .selected_options = .{},
        \\            .deps = .{},
        \\        },
        \\        .@"zpkg.example.hello_tool#host" = .{
        \\            .package = "zpkg.example.hello_tool",
        \\            .domain = .host,
        \\            .version = "0.1.0.0",
        \\            .source_hash = "tool-hash",
        \\            .selected_options = .{},
        \\            .deps = .{},
        \\        },
        \\    },
        \\}
    ;

    const parsed = try parseSourceAlloc(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), parsed.instances.len);
    try std.testing.expectEqualStrings("hello_lib", parsed.instances[0].deps[0].alias);
    try std.testing.expectEqualStrings("codegen", parsed.instances[0].deps[1].alias);
    try std.testing.expectEqual(model.Version.init(0, 1, 0, 0), parsed.root.version);
}

test "reject missing referenced lockfile instance" {
    const source =
        \\.{
        \\    .schema = 1,
        \\    .root = .{ .package = "zpkg.example.hello_app", .version = "0.1.0.0" },
        \\    .instances = .{
        \\        .@"zpkg.example.hello_app#target" = .{
        \\            .package = "zpkg.example.hello_app",
        \\            .domain = .target,
        \\            .version = "0.1.0.0",
        \\            .source_hash = "root-hash",
        \\            .selected_options = .{},
        \\            .deps = .{ .missing = "zpkg.example.hello_lib#target" },
        \\        },
        \\    },
        \\}
    ;

    try std.testing.expectError(error.MissingReferencedInstance, parseSourceAlloc(std.testing.allocator, source));
}

test "reject instance key mismatch" {
    const source =
        \\.{
        \\    .schema = 1,
        \\    .root = .{ .package = "zpkg.example.hello_app", .version = "0.1.0.0" },
        \\    .instances = .{
        \\        .@"zpkg.example.hello_app#target" = .{
        \\            .package = "zpkg.example.hello_lib",
        \\            .domain = .target,
        \\            .version = "0.1.0.0",
        \\            .source_hash = "root-hash",
        \\            .selected_options = .{},
        \\            .deps = .{},
        \\        },
        \\    },
        \\}
    ;

    try std.testing.expectError(error.InstanceKeyMismatch, parseSourceAlloc(std.testing.allocator, source));
}

test "lockfile golden normalized zon" {
    const source =
        \\.{
        \\    .schema = 1,
        \\    .root = .{ .package = "zpkg.example.hello_app", .version = "0.1.0" },
        \\    .generated_by = .{ .zpkg_version = "0.1.0", .zig_version = "0.16.0" },
        \\    .instances = .{
        \\        .@"zpkg.example.hello_app#target" = .{
        \\            .package = "zpkg.example.hello_app",
        \\            .domain = .target,
        \\            .version = "0.1.0",
        \\            .source_hash = "root-hash",
        \\            .selected_options = .{ .shared = true },
        \\            .deps = .{ .hello_lib = "zpkg.example.hello_lib#target" },
        \\        },
        \\        .@"zpkg.example.hello_lib#target" = .{
        \\            .package = "zpkg.example.hello_lib",
        \\            .domain = .target,
        \\            .version = "0.1.0",
        \\            .source_hash = "lib-hash",
        \\            .selected_options = .{},
        \\            .deps = .{},
        \\        },
        \\    },
        \\}
    ;

    const parsed = try parseSourceAlloc(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    const rendered = try parsed.toZonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    const io = std.testing.io;
    const expected = try std.Io.Dir.cwd().readFileAlloc(io, "test/golden/schema/lockfile-normalized.zon", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, rendered);
}
