const std = @import("std");
const model = @import("../model/root.zig");
const graph_model = @import("../model/graph.zig");
const zon_util = @import("zon_util.zig");

pub const ParseError = zon_util.ParseError || error{
    OutOfMemory,
    UndeclaredDependencyAlias,
};

pub fn parseSourceAlloc(allocator: std.mem.Allocator, source: [:0]const u8) ParseError!graph_model.Graph {
    var doc = try zon_util.parseDocument(allocator, source);
    defer doc.deinit(allocator);
    return parseDocumentAlloc(allocator, &doc);
}

fn parseDocumentAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document) ParseError!graph_model.Graph {
    const root_object = try zon_util.Object.fromNode(doc, .root);
    try root_object.validateOnlyFields(&.{ "schema", "package", "selected_options", "dependency_aliases", "targets" });

    const schema = try zon_util.parseInt(doc, try root_object.require("schema"));
    if (schema != 1) return error.InvalidSchemaVersion;

    const package = try parsePackageAlloc(allocator, doc, try root_object.require("package"));
    errdefer package.deinit(allocator);
    const selected_options = try parseSelectedOptionsAlloc(allocator, doc, try root_object.require("selected_options"));
    errdefer {
        for (selected_options) |entry| {
            allocator.free(entry.name);
            entry.value.deinitOwned(allocator);
        }
        allocator.free(selected_options);
    }
    const dependency_aliases = try parseDependencyAliasesAlloc(allocator, doc, try root_object.require("dependency_aliases"));
    errdefer {
        for (dependency_aliases) |entry| entry.deinit(allocator);
        allocator.free(dependency_aliases);
    }
    const targets = try parseTargetsAlloc(allocator, doc, try root_object.require("targets"));
    errdefer {
        for (targets) |entry| entry.deinit(allocator);
        allocator.free(targets);
    }

    const graph = graph_model.Graph{
        .schema = @intCast(schema),
        .package = package,
        .selected_options = selected_options,
        .dependency_aliases = dependency_aliases,
        .targets = targets,
    };

    try validateDependencyAliases(graph);
    return graph;
}

fn parsePackageAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError!graph_model.Package {
    const object = try zon_util.Object.fromNode(doc, node);
    try object.validateOnlyFields(&.{ "name", "id", "version", "domain" });

    const name = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("name"));
    errdefer allocator.free(name);
    const id_text = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("id"));
    errdefer allocator.free(id_text);
    const version_text = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("version"));
    defer allocator.free(version_text);

    return .{
        .name = name,
        .id = model.PackageId.adoptOwned(id_text) catch return error.InvalidPackageId,
        .version = model.Version.parse(version_text) catch return error.InvalidVersion,
        .domain = zon_util.parseEnum(model.Domain, doc, try object.require("domain")) catch return error.InvalidDomain,
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

fn parseDependencyAliasesAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError![]graph_model.DependencyAlias {
    const object = try zon_util.Object.fromNode(doc, node);
    const result = try allocator.alloc(graph_model.DependencyAlias, object.fieldCount());
    errdefer allocator.free(result);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |entry| entry.deinit(allocator);
    }

    for (0..object.fieldCount()) |index| {
        result[index] = try parseDependencyAliasAlloc(allocator, doc, object.fieldName(index), object.fieldNode(index));
        initialized += 1;
    }

    return result;
}

fn parseDependencyAliasAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, alias_name: []const u8, node: std.zig.Zoir.Node.Index) ParseError!graph_model.DependencyAlias {
    const object = try zon_util.Object.fromNode(doc, node);
    try object.validateOnlyFields(&.{ "package", "domain" });

    const package_text = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("package"));
    errdefer allocator.free(package_text);

    const alias = try allocator.dupe(u8, alias_name);
    errdefer allocator.free(alias);
    const package_id = model.PackageId.adoptOwned(package_text) catch return error.InvalidPackageId;
    errdefer package_id.deinitOwned(allocator);
    return .{
        .alias = alias,
        .package_id = package_id,
        .domain = zon_util.parseEnum(model.Domain, doc, try object.require("domain")) catch return error.InvalidDomain,
    };
}

fn parseTargetsAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError![]graph_model.Target {
    const object = try zon_util.Object.fromNode(doc, node);
    const result = try allocator.alloc(graph_model.Target, object.fieldCount());
    errdefer allocator.free(result);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |target| target.deinit(allocator);
    }

    for (0..object.fieldCount()) |index| {
        result[index] = try parseTargetAlloc(allocator, doc, object.fieldName(index), object.fieldNode(index));
        initialized += 1;
    }

    return result;
}

fn parseTargetAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, target_name: []const u8, node: std.zig.Zoir.Node.Index) ParseError!graph_model.Target {
    const object = try zon_util.Object.fromNode(doc, node);
    try object.validateOnlyFields(&.{ "kind", "linkage", "exported", "test_only", "include_dirs", "compile_definitions", "system_libs", "artifacts", "deps", "installs", "module" });

    const kind = zon_util.parseEnum(graph_model.TargetKind, doc, try object.require("kind")) catch return error.InvalidField;
    const linkage = if (object.get("linkage")) |linkage_node|
        zon_util.parseEnum(graph_model.Linkage, doc, linkage_node) catch return error.InvalidField
    else
        null;
    const exported = try zon_util.parseBool(doc, try object.require("exported"));
    const test_only = try zon_util.parseBool(doc, try object.require("test_only"));

    const include_dirs = if (object.get("include_dirs")) |child|
        try parseIncludeDirsAlloc(allocator, doc, child)
    else
        try allocator.alloc(graph_model.IncludeDir, 0);
    errdefer {
        for (include_dirs) |entry| entry.deinit(allocator);
        allocator.free(include_dirs);
    }

    const compile_definitions = if (object.get("compile_definitions")) |child|
        try parseCompileDefinitionsAlloc(allocator, doc, child)
    else
        try allocator.alloc(graph_model.CompileDefinition, 0);
    errdefer {
        for (compile_definitions) |entry| entry.deinit(allocator);
        allocator.free(compile_definitions);
    }

    const system_libs = if (object.get("system_libs")) |child|
        try parseSystemLibsAlloc(allocator, doc, child)
    else
        try allocator.alloc(graph_model.SystemLib, 0);
    errdefer {
        for (system_libs) |entry| entry.deinit(allocator);
        allocator.free(system_libs);
    }

    const artifacts = if (object.get("artifacts")) |child|
        try parseArtifactsAlloc(allocator, doc, child)
    else
        try allocator.alloc(graph_model.Artifact, 0);
    errdefer {
        for (artifacts) |entry| entry.deinit(allocator);
        allocator.free(artifacts);
    }

    const deps = if (object.get("deps")) |child|
        try parseEdgesAlloc(allocator, doc, child)
    else
        try allocator.alloc(graph_model.Edge, 0);
    errdefer {
        for (deps) |entry| entry.deinit(allocator);
        allocator.free(deps);
    }

    const installs = if (object.get("installs")) |child|
        try parseInstallsAlloc(allocator, doc, child)
    else
        try allocator.alloc(graph_model.Install, 0);
    errdefer {
        for (installs) |entry| entry.deinit(allocator);
        allocator.free(installs);
    }

    const module_meta = if (object.get("module")) |child|
        try parseModuleAlloc(allocator, doc, child)
    else
        null;
    errdefer if (module_meta) |entry| entry.deinit(allocator);

    if (kind == .library and linkage == null) return error.InvalidField;
    if (kind != .library and linkage != null) return error.InvalidField;
    if (kind == .headers and artifacts.len != 0) return error.InvalidField;
    if (kind != .resource_set and installs.len != 0) return error.InvalidField;
    if (kind != .zig_module and module_meta != null) return error.InvalidField;

    const name = try allocator.dupe(u8, target_name);
    errdefer allocator.free(name);

    return .{
        .name = name,
        .kind = kind,
        .linkage = linkage,
        .exported = exported,
        .test_only = test_only,
        .include_dirs = include_dirs,
        .compile_definitions = compile_definitions,
        .system_libs = system_libs,
        .artifacts = artifacts,
        .deps = deps,
        .installs = installs,
        .module = module_meta,
    };
}

fn parseIncludeDirsAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError![]graph_model.IncludeDir {
    const array = try zon_util.Array.fromNode(doc, node);
    const result = try allocator.alloc(graph_model.IncludeDir, array.len());
    errdefer allocator.free(result);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |entry| entry.deinit(allocator);
    }

    const Raw = struct { path: []const u8, visibility: graph_model.Visibility };
    for (0..array.len()) |index| {
        const raw = try zon_util.parseNodeAlloc(Raw, allocator, doc, array.at(index));
        result[index] = .{ .path = raw.path, .visibility = raw.visibility };
        initialized += 1;
    }
    return result;
}

fn parseCompileDefinitionsAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError![]graph_model.CompileDefinition {
    const array = try zon_util.Array.fromNode(doc, node);
    const result = try allocator.alloc(graph_model.CompileDefinition, array.len());
    errdefer allocator.free(result);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |entry| entry.deinit(allocator);
    }

    for (0..array.len()) |index| {
        const object = try zon_util.Object.fromNode(doc, array.at(index));
        try object.validateOnlyFields(&.{ "key", "value", "visibility" });
        result[index] = .{
            .key = try zon_util.parseNonEmptyStringAlloc(allocator, doc, try object.require("key")),
            .value = try zon_util.parseOptionValueAlloc(allocator, doc, try object.require("value")),
            .visibility = zon_util.parseEnum(graph_model.Visibility, doc, try object.require("visibility")) catch return error.InvalidField,
        };
        initialized += 1;
    }

    return result;
}

fn parseSystemLibsAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError![]graph_model.SystemLib {
    const array = try zon_util.Array.fromNode(doc, node);
    const result = try allocator.alloc(graph_model.SystemLib, array.len());
    errdefer allocator.free(result);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |entry| entry.deinit(allocator);
    }

    const Raw = struct { name: []const u8, visibility: graph_model.Visibility };
    for (0..array.len()) |index| {
        const raw = try zon_util.parseNodeAlloc(Raw, allocator, doc, array.at(index));
        result[index] = .{ .name = raw.name, .visibility = raw.visibility };
        initialized += 1;
    }
    return result;
}

fn parseArtifactsAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError![]graph_model.Artifact {
    const array = try zon_util.Array.fromNode(doc, node);
    const result = try allocator.alloc(graph_model.Artifact, array.len());
    errdefer allocator.free(result);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |entry| entry.deinit(allocator);
    }

    const Raw = struct { kind: graph_model.ArtifactKind, path: []const u8 };
    for (0..array.len()) |index| {
        const raw = try zon_util.parseNodeAlloc(Raw, allocator, doc, array.at(index));
        result[index] = .{ .kind = raw.kind, .path = raw.path };
        initialized += 1;
    }
    return result;
}

fn parseEdgesAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError![]graph_model.Edge {
    const object = try zon_util.Object.fromNode(doc, node);
    const result = try allocator.alloc(graph_model.Edge, object.fieldCount());
    errdefer allocator.free(result);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |entry| entry.deinit(allocator);
    }

    const Raw = struct {
        dep: []const u8,
        target: []const u8,
        role: graph_model.DependencyRole,
        visibility: graph_model.Visibility,
    };

    for (0..object.fieldCount()) |index| {
        const raw = try zon_util.parseNodeAlloc(Raw, allocator, doc, object.fieldNode(index));
        errdefer {
            allocator.free(raw.dep);
            allocator.free(raw.target);
        }
        const name = try allocator.dupe(u8, object.fieldName(index));
        errdefer allocator.free(name);
        result[index] = .{
            .name = name,
            .dep = raw.dep,
            .target = raw.target,
            .role = raw.role,
            .visibility = raw.visibility,
        };
        initialized += 1;
    }

    return result;
}

fn parseInstallsAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError![]graph_model.Install {
    const array = try zon_util.Array.fromNode(doc, node);
    const result = try allocator.alloc(graph_model.Install, array.len());
    errdefer allocator.free(result);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |entry| entry.deinit(allocator);
    }

    const Raw = struct {
        source: []const u8,
        dir: graph_model.ResourceDir,
        subdir: []const u8,
        dest: []const u8,
    };

    for (0..array.len()) |index| {
        const raw = try zon_util.parseNodeAlloc(Raw, allocator, doc, array.at(index));
        result[index] = .{
            .source = raw.source,
            .dir = raw.dir,
            .subdir = raw.subdir,
            .dest = raw.dest,
        };
        initialized += 1;
    }

    return result;
}

fn parseModuleAlloc(allocator: std.mem.Allocator, doc: *const zon_util.Document, node: std.zig.Zoir.Node.Index) ParseError!graph_model.Module {
    const Raw = struct { name: []const u8, root_source_file: []const u8 };
    const raw = try zon_util.parseNodeAlloc(Raw, allocator, doc, node);
    return .{ .name = raw.name, .root_source_file = raw.root_source_file };
}

fn validateDependencyAliases(graph: graph_model.Graph) ParseError!void {
    for (graph.targets) |target| {
        for (target.deps) |edge| {
            if (!hasDependencyAlias(graph.dependency_aliases, edge.dep)) {
                return error.UndeclaredDependencyAlias;
            }
        }
    }
}

fn hasDependencyAlias(dependency_aliases: []const graph_model.DependencyAlias, alias: []const u8) bool {
    for (dependency_aliases) |entry| {
        if (std.mem.eql(u8, entry.alias, alias)) return true;
    }
    return false;
}

test "parse graph target metadata" {
    const source =
        \\.{
        \\    .schema = 1,
        \\    .package = .{
        \\        .name = "hello-lib",
        \\        .id = "zpkg.example.hello_lib",
        \\        .version = "0.1.0",
        \\        .domain = .target,
        \\    },
        \\    .selected_options = .{ .shared = true },
        \\    .dependency_aliases = .{
        \\        .protobuf = .{ .package = "zpkg.example.protobuf", .domain = .target },
        \\    },
        \\    .targets = .{
        \\        .hello = .{
        \\            .kind = .library,
        \\            .linkage = .shared,
        \\            .exported = true,
        \\            .test_only = false,
        \\            .include_dirs = .{ .{ .path = "include", .visibility = .public } },
        \\            .compile_definitions = .{ .{ .key = "USE_SSL", .value = true, .visibility = .public } },
        \\            .system_libs = .{ .{ .name = "pthread", .visibility = .public } },
        \\            .artifacts = .{ .{ .kind = .library, .path = "lib/libhello.so" } },
        \\            .deps = .{
        \\                .protobuf_runtime = .{ .dep = "protobuf", .target = "protobuf", .role = .link, .visibility = .public },
        \\            },
        \\        },
        \\        .assets = .{
        \\            .kind = .resource_set,
        \\            .exported = true,
        \\            .test_only = false,
        \\            .include_dirs = .{},
        \\            .compile_definitions = .{},
        \\            .system_libs = .{},
        \\            .artifacts = .{},
        \\            .deps = .{},
        \\            .installs = .{
        \\                .{ .source = "models/default.bin", .dir = .share, .subdir = "hello/assets", .dest = "default.bin" },
        \\            },
        \\        },
        \\    },
        \\}
    ;

    const parsed = try parseSourceAlloc(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.targets.len);
    try std.testing.expectEqual(graph_model.TargetKind.library, parsed.targets[0].kind);
    try std.testing.expectEqualStrings("protobuf_runtime", parsed.targets[0].deps[0].name);
    try std.testing.expectEqualStrings("models/default.bin", parsed.targets[1].installs[0].source);
}

test "reject linkage on non-library target" {
    const source =
        \\.{
        \\    .schema = 1,
        \\    .package = .{ .name = "hello", .id = "zpkg.example.hello", .version = "0.1.0.0", .domain = .target },
        \\    .selected_options = .{},
        \\    .dependency_aliases = .{},
        \\    .targets = .{
        \\        .tool = .{
        \\            .kind = .executable,
        \\            .linkage = .shared,
        \\            .exported = true,
        \\            .test_only = false,
        \\            .include_dirs = .{},
        \\            .compile_definitions = .{},
        \\            .system_libs = .{},
        \\            .artifacts = .{},
        \\            .deps = .{},
        \\        },
        \\    },
        \\}
    ;

    try std.testing.expectError(error.InvalidField, parseSourceAlloc(std.testing.allocator, source));
}

test "reject headers target with artifacts" {
    const source =
        \\.{
        \\    .schema = 1,
        \\    .package = .{ .name = "hello", .id = "zpkg.example.hello", .version = "0.1.0.0", .domain = .target },
        \\    .selected_options = .{},
        \\    .dependency_aliases = .{},
        \\    .targets = .{
        \\        .headers = .{
        \\            .kind = .headers,
        \\            .exported = true,
        \\            .test_only = false,
        \\            .include_dirs = .{},
        \\            .compile_definitions = .{},
        \\            .system_libs = .{},
        \\            .artifacts = .{ .{ .kind = .library, .path = "lib/libbad.so" } },
        \\            .deps = .{},
        \\        },
        \\    },
        \\}
    ;

    try std.testing.expectError(error.InvalidField, parseSourceAlloc(std.testing.allocator, source));
}

test "reject graph edge with undeclared dependency alias" {
    const source =
        \\.{
        \\    .schema = 1,
        \\    .package = .{ .name = "hello", .id = "zpkg.example.hello", .version = "0.1.0.0", .domain = .target },
        \\    .selected_options = .{},
        \\    .dependency_aliases = .{
        \\        .protobuf = .{ .package = "zpkg.example.protobuf", .domain = .target },
        \\    },
        \\    .targets = .{
        \\        .hello = .{
        \\            .kind = .library,
        \\            .linkage = .shared,
        \\            .exported = true,
        \\            .test_only = false,
        \\            .include_dirs = .{},
        \\            .compile_definitions = .{},
        \\            .system_libs = .{},
        \\            .artifacts = .{},
        \\            .deps = .{
        \\                .bad = .{ .dep = "missing_alias", .target = "protobuf", .role = .link, .visibility = .public },
        \\            },
        \\        },
        \\    },
        \\}
    ;

    try std.testing.expectError(error.UndeclaredDependencyAlias, parseSourceAlloc(std.testing.allocator, source));
}

test "graph normalization is invariant to reordering" {
    const source =
        \\.{
        \\    .schema = 1,
        \\    .package = .{ .name = "hello-lib", .id = "zpkg.example.hello_lib", .version = "0.1.0", .domain = .target },
        \\    .selected_options = .{ .build_tests = false, .shared = true },
        \\    .dependency_aliases = .{
        \\        .protoc = .{ .package = "zpkg.example.protobuf", .domain = .host },
        \\        .protobuf = .{ .package = "zpkg.example.protobuf", .domain = .target },
        \\    },
        \\    .targets = .{
        \\        .build_helpers = .{
        \\            .kind = .zig_module,
        \\            .exported = true,
        \\            .test_only = false,
        \\            .include_dirs = .{},
        \\            .compile_definitions = .{},
        \\            .system_libs = .{},
        \\            .artifacts = .{},
        \\            .deps = .{},
        \\            .module = .{ .name = "build_helpers", .root_source_file = "src/build_helpers.zig" },
        \\        },
        \\        .assets = .{
        \\            .kind = .resource_set,
        \\            .exported = true,
        \\            .test_only = false,
        \\            .include_dirs = .{},
        \\            .compile_definitions = .{},
        \\            .system_libs = .{},
        \\            .artifacts = .{},
        \\            .deps = .{},
        \\            .installs = .{ .{ .source = "models/default.bin", .dir = .share, .subdir = "hello/assets", .dest = "default.bin" } },
        \\        },
        \\        .hello = .{
        \\            .kind = .library,
        \\            .linkage = .shared,
        \\            .exported = true,
        \\            .test_only = false,
        \\            .include_dirs = .{ .{ .path = "src", .visibility = .private }, .{ .path = "include", .visibility = .public } },
        \\            .compile_definitions = .{ .{ .key = "API_LEVEL", .value = 2, .visibility = .private }, .{ .key = "USE_SSL", .value = true, .visibility = .public } },
        \\            .system_libs = .{ .{ .name = "pthread", .visibility = .public } },
        \\            .artifacts = .{ .{ .kind = .library, .path = "lib/libhello.so" } },
        \\            .deps = .{
        \\                .codegen = .{ .dep = "protoc", .target = "protoc", .role = .tool, .visibility = .private },
        \\                .protobuf_runtime = .{ .dep = "protobuf", .target = "protobuf", .role = .link, .visibility = .public },
        \\            },
        \\        },
        \\    },
        \\}
    ;

    const parsed = try parseSourceAlloc(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    const rendered = try parsed.toZonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    const io = std.testing.io;
    const expected = try std.Io.Dir.cwd().readFileAlloc(io, "test/golden/schema/graph-normalized.zon", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, rendered);
}

test "graph golden normalized zon" {
    const source =
        \\.{
        \\    .schema = 1,
        \\    .package = .{
        \\        .name = "hello-lib",
        \\        .id = "zpkg.example.hello_lib",
        \\        .version = "0.1.0",
        \\        .domain = .target,
        \\    },
        \\    .selected_options = .{ .shared = true, .build_tests = false },
        \\    .dependency_aliases = .{
        \\        .protobuf = .{ .package = "zpkg.example.protobuf", .domain = .target },
        \\        .protoc = .{ .package = "zpkg.example.protobuf", .domain = .host },
        \\    },
        \\    .targets = .{
        \\        .hello = .{
        \\            .kind = .library,
        \\            .linkage = .shared,
        \\            .exported = true,
        \\            .test_only = false,
        \\            .include_dirs = .{
        \\                .{ .path = "include", .visibility = .public },
        \\                .{ .path = "src", .visibility = .private },
        \\            },
        \\            .compile_definitions = .{
        \\                .{ .key = "USE_SSL", .value = true, .visibility = .public },
        \\                .{ .key = "API_LEVEL", .value = 2, .visibility = .private },
        \\            },
        \\            .system_libs = .{ .{ .name = "pthread", .visibility = .public } },
        \\            .artifacts = .{ .{ .kind = .library, .path = "lib/libhello.so" } },
        \\            .deps = .{
        \\                .protobuf_runtime = .{ .dep = "protobuf", .target = "protobuf", .role = .link, .visibility = .public },
        \\                .codegen = .{ .dep = "protoc", .target = "protoc", .role = .tool, .visibility = .private },
        \\            },
        \\        },
        \\        .assets = .{
        \\            .kind = .resource_set,
        \\            .exported = true,
        \\            .test_only = false,
        \\            .include_dirs = .{},
        \\            .compile_definitions = .{},
        \\            .system_libs = .{},
        \\            .artifacts = .{},
        \\            .deps = .{},
        \\            .installs = .{ .{ .source = "models/default.bin", .dir = .share, .subdir = "hello/assets", .dest = "default.bin" } },
        \\        },
        \\        .build_helpers = .{
        \\            .kind = .zig_module,
        \\            .exported = true,
        \\            .test_only = false,
        \\            .include_dirs = .{},
        \\            .compile_definitions = .{},
        \\            .system_libs = .{},
        \\            .artifacts = .{},
        \\            .deps = .{},
        \\            .module = .{ .name = "build_helpers", .root_source_file = "src/build_helpers.zig" },
        \\        },
        \\    },
        \\}
    ;

    const parsed = try parseSourceAlloc(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    const rendered = try parsed.toZonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    const io = std.testing.io;
    const expected = try std.Io.Dir.cwd().readFileAlloc(io, "test/golden/schema/graph-normalized.zon", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, rendered);
}
