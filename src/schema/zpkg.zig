const std = @import("std");
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;
const model = @import("../model/root.zig");
const package_model = @import("../model/package.zig");
const target_model = @import("../model/target.zig");

pub const Manifest = package_model.Manifest;
pub const ParseError = error{
    OutOfMemory,
    ParseZon,
    RootMustBeStruct,
    ExpectedStruct,
    ExpectedString,
    ExpectedBool,
    ExpectedInt,
    ExpectedEnumLiteral,
    InvalidSchemaVersion,
    MissingPackage,
    MissingTargets,
    MissingPackageName,
    MissingPackageId,
    MissingPackageVersion,
    MissingPackageBackend,
    MissingDependencyPackageId,
    MissingDependencyVersionRequirement,
    UnknownTopLevelField,
    UnknownPackageField,
    UnknownOptionField,
    UnknownDependencyField,
    UnknownRequirementField,
    UnknownTargetField,
    UnknownConditionField,
    UnknownOptionKind,
    UnsupportedBackend,
    UnsupportedTargetKind,
    InvalidLinkage,
    BadLinkagePlacement,
    MalformedVersion,
    InvalidPackageId,
    MalformedVersionConstraint,
    InvalidOptionDefault,
    UnknownConditionOption,
    ConditionOptionTypeMismatch,
    FieldNotAllowed,
    DuplicateTopLevelField,
    DuplicateOptionName,
    DuplicateDependencyAlias,
    DuplicateTargetName,
    DuplicateConditionOption,
    DuplicateField,
    EmptySourcePath,
    AbsoluteSourcePath,
};

pub fn formatDiagnosticAlloc(allocator: std.mem.Allocator, file_path: []const u8, err: ParseError) ![]u8 {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return std.fmt.allocPrint(
        allocator,
        "error: invalid zpkg.zon: {s}\nfile: {s}\nhelp: {s}\n",
        .{ parseErrorIssue(err), file_path, parseErrorHelp(err) },
    );
}

fn parseErrorIssue(err: ParseError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory while parsing zpkg.zon",
        error.ParseZon => "the file is not valid ZON",
        error.RootMustBeStruct => "the document root must be a ZON struct literal like .{ ... }",
        error.ExpectedStruct => "expected a ZON struct literal for this field",
        error.ExpectedString => "expected a string value",
        error.ExpectedBool => "expected a bool value",
        error.ExpectedInt => "expected an integer value",
        error.ExpectedEnumLiteral => "expected an enum literal like .zig or .library",
        error.InvalidSchemaVersion => "expected top-level .schema = 1",
        error.MissingPackage => "missing required .package section",
        error.MissingTargets => "missing required .targets section",
        error.MissingPackageName => "missing required .package.name string",
        error.MissingPackageId => "missing required .package.id string",
        error.MissingPackageVersion => "missing required .package.version string",
        error.MissingPackageBackend => "missing required .package.backend enum",
        error.MissingDependencyPackageId => "each .deps.<alias> entry must declare .package = \"<canonical package id>\"",
        error.MissingDependencyVersionRequirement => "each .deps.<alias>.require entry must declare .version = \"=<version>\"",
        error.UnknownTopLevelField => "unknown top-level field",
        error.UnknownPackageField => "unknown field inside .package",
        error.UnknownOptionField => "unknown field inside .options.<name>",
        error.UnknownDependencyField => "unknown field inside .deps.<alias>",
        error.UnknownRequirementField => "unknown field inside .deps.<alias>.require",
        error.UnknownTargetField => "unknown field inside .targets.<name>",
        error.UnknownConditionField => "unknown field inside .when",
        error.UnknownOptionKind => "unsupported .options.<name>.kind value",
        error.UnsupportedBackend => "unsupported .package.backend value",
        error.UnsupportedTargetKind => "unsupported .targets.<name>.kind value",
        error.InvalidLinkage => "unsupported .targets.<name>.linkage value",
        error.BadLinkagePlacement => ".targets.<name>.linkage is only valid for .library targets",
        error.MalformedVersion => ".package.version is malformed",
        error.InvalidPackageId => ".package.id or .deps.<alias>.package is not a valid canonical package id",
        error.MalformedVersionConstraint => ".deps.<alias>.require.version is malformed",
        error.InvalidOptionDefault => ".options.<name>.default must match .kind and .abi must be present",
        error.UnknownConditionOption => ".when.options references an option not declared in top-level .options",
        error.ConditionOptionTypeMismatch => ".when.options value type does not match the declared option kind",
        error.FieldNotAllowed => "a field is present where the Phase 01 schema does not allow it",
        error.DuplicateTopLevelField => "a top-level field is declared more than once",
        error.DuplicateOptionName => "an option name is declared more than once",
        error.DuplicateDependencyAlias => "a dependency alias is declared more than once",
        error.DuplicateTargetName => "a target name is declared more than once",
        error.DuplicateConditionOption => "a .when.options key is declared more than once",
        error.DuplicateField => "a field is declared more than once in the same object",
        error.EmptySourcePath => ".deps.<alias>.source_path must be a non-empty string",
        error.AbsoluteSourcePath => ".deps.<alias>.source_path must be a relative path, not an absolute one",
    };
}

fn parseErrorHelp(err: ParseError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "retry with more memory available",
        error.ParseZon => "check for ZON syntax errors or duplicate fields before semantic validation",
        error.RootMustBeStruct, error.ExpectedStruct => "rewrite the value as a ZON object, for example .{ .schema = 1, ... }",
        error.ExpectedString => "replace the value with a quoted string",
        error.ExpectedBool => "replace the value with true or false",
        error.ExpectedInt => "replace the value with an integer literal",
        error.ExpectedEnumLiteral => "replace the value with a supported enum literal such as .zig, .host, or .library",
        error.InvalidSchemaVersion => "set .schema = 1",
        error.MissingPackage => "add .package = .{ .name = \"...\", .id = \"...\", .version = \"1.2.3\", .backend = .zig }",
        error.MissingTargets => "add a .targets section declaring at least one exported/public target",
        error.MissingPackageName => "add .package.name = \"<display-name>\"",
        error.MissingPackageId => "add .package.id = \"namespace.package_name\"",
        error.MissingPackageVersion => "add .package.version = \"1.2.3\" or \"1.2.3.0\"",
        error.MissingPackageBackend => "add .package.backend = .zig",
        error.MissingDependencyPackageId => "for each dependency alias, add .package = \"namespace.package_name\"",
        error.MissingDependencyVersionRequirement, error.MalformedVersionConstraint => "for each dependency alias, use .require = .{ .version = \"=<version>\" } in Phase 01",
        error.UnknownTopLevelField => "allowed top-level fields are .schema, .package, .options, .deps, and .targets",
        error.UnknownPackageField => "allowed .package fields are .name, .id, .version, and .backend",
        error.UnknownOptionField => "allowed .options.<name> fields are .kind, .default, and .abi",
        error.UnknownDependencyField => "allowed .deps.<alias> fields are .package, .require, .when, and .source_path",
        error.UnknownRequirementField => "allowed .deps.<alias>.require fields are only .version in Phase 01",
        error.UnknownTargetField => "allowed .targets.<name> fields are .kind, .linkage, .test_only, and .when",
        error.UnknownConditionField => "allowed .when fields are .domain, .host_os, .host_arch, .target_os, .target_arch, and .options",
        error.UnknownOptionKind => "use one of .bool, .int, or .string",
        error.UnsupportedBackend => "Phase 01 only supports .package.backend = .zig",
        error.UnsupportedTargetKind => "use one of .library, .executable, .zig_module, .headers, or .resource_set",
        error.InvalidLinkage => "use one of .default, .shared, or .static",
        error.BadLinkagePlacement => "remove .linkage from non-library targets or change .kind to .library",
        error.MalformedVersion => "use x.y.z or x.y.z.w; the parser will normalize x.y.z to x.y.z.0",
        error.InvalidPackageId => "use a non-empty namespaced identifier like \"zpkg.example.hello_lib\"",
        error.InvalidOptionDefault => "ensure .default matches .kind and set .abi = true or false",
        error.UnknownConditionOption => "declare the option in top-level .options before referencing it in .when.options",
        error.ConditionOptionTypeMismatch => "make the .when.options value type match the option kind declared in .options",
        error.FieldNotAllowed => "remove the unsupported field from the manifest",
        error.DuplicateTopLevelField, error.DuplicateOptionName, error.DuplicateDependencyAlias, error.DuplicateTargetName, error.DuplicateConditionOption, error.DuplicateField => "remove the duplicate field so each key appears only once in its object",
        error.EmptySourcePath => "provide a non-empty relative path, e.g. .source_path = \"../my_dep\"",
        error.AbsoluteSourcePath => "use a relative path like \"../my_dep\" instead of an absolute path",
    };
}

pub fn parseSliceAlloc(allocator: std.mem.Allocator, source: [:0]const u8) ParseError!Manifest {
    var ast = Ast.parse(allocator, source, .zon) catch return error.OutOfMemory;
    defer ast.deinit(allocator);

    var zoir = std.zig.ZonGen.generate(allocator, ast, .{ .parse_str_lits = true }) catch return error.OutOfMemory;
    defer zoir.deinit(allocator);

    if (zoir.hasCompileErrors()) return error.ParseZon;

    return parseZoirAlloc(allocator, source, ast, zoir);
}

pub fn parseFileAlloc(allocator: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, sub_path: []const u8) ParseError!Manifest {
    const source = dir.readFileAllocOptions(
        io,
        sub_path,
        allocator,
        .limited(64 * 1024),
        .of(u8),
        null,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ParseZon,
    };
    defer allocator.free(source);

    const sentinel_source = allocator.dupeZ(u8, source) catch return error.OutOfMemory;
    defer allocator.free(sentinel_source);

    return parseSliceAlloc(allocator, sentinel_source);
}

pub fn formatNormalizedAlloc(allocator: std.mem.Allocator, manifest: Manifest) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try writeNormalizedWithAllocator(&aw.writer, allocator, manifest);
    return aw.toOwnedSlice();
}

pub fn writeNormalized(writer: *std.Io.Writer, manifest: Manifest) !void {
    try writeNormalizedWithAllocator(writer, std.heap.page_allocator, manifest);
}

fn writeNormalizedWithAllocator(writer: *std.Io.Writer, allocator: std.mem.Allocator, manifest: Manifest) !void {
    try writer.writeAll(".{\n");
    try writer.writeAll("    .schema = 1,\n\n");

    try writer.writeAll("    .package = .{\n");
    try writer.writeAll("        .name = ");
    try writeString(writer, manifest.package.name);
    try writer.writeAll(",\n");
    try writer.writeAll("        .id = ");
    try writeString(writer, manifest.package.id.text);
    try writer.writeAll(",\n");
    try writer.writeAll("        .version = ");
    var version_buf: [32]u8 = undefined;
    try writeString(writer, try manifest.package.version.bufPrint(&version_buf));
    try writer.writeAll(",\n");
    try writer.print("        .backend = .{s},\n", .{@tagName(manifest.package.backend)});
    try writer.writeAll("    },\n");

    if (manifest.options.len > 0) {
        const sorted_options = try sortedByNameAlloc(package_model.NamedOptionDefinition, allocator, manifest.options, "name");
        defer allocator.free(sorted_options);

        try writer.writeAll("\n    .options = .{\n");
        for (sorted_options) |option_definition| {
            try writer.writeAll("        ");
            try writeFieldName(writer, option_definition.name);
            try writer.writeAll(" = .{\n");
            try writer.print("            .kind = .{s},\n", .{@tagName(option_definition.definition.kind)});
            try writer.writeAll("            .default = ");
            try writeOptionValue(writer, option_definition.definition.default_value);
            try writer.writeAll(",\n");
            try writer.print("            .abi = {},\n", .{option_definition.definition.abi});
            try writer.writeAll("        },\n");
        }
        try writer.writeAll("    },\n");
    }

    if (manifest.deps.len > 0) {
        const sorted_deps = try sortedByNameAlloc(package_model.Dependency, allocator, manifest.deps, "alias");
        defer allocator.free(sorted_deps);

        try writer.writeAll("\n    .deps = .{\n");
        for (sorted_deps) |dep| {
            try writer.writeAll("        ");
            try writeFieldName(writer, dep.alias);
            try writer.writeAll(" = .{\n");
            try writer.writeAll("            .package = ");
            try writeString(writer, dep.package.text);
            try writer.writeAll(",\n");
            try writer.writeAll("            .require = .{ .version = ");
            var dep_version_buf: [32]u8 = undefined;
            const dep_version_text = try dep.require.exact.bufPrint(&dep_version_buf);
            var req_buf: [64]u8 = undefined;
            const req_text = try std.fmt.bufPrint(&req_buf, "={s}", .{dep_version_text});
            try writeString(writer, req_text);
            try writer.writeAll(" },\n");
            if (dep.when) |condition| {
                try writer.writeAll("            .when = ");
                try writeCondition(writer, allocator, condition, 3);
                try writer.writeAll(",\n");
            }
            try writer.writeAll("        },\n");
        }
        try writer.writeAll("    },\n");
    }

    const sorted_targets = try sortedByNameAlloc(target_model.NamedDeclaration, allocator, manifest.targets, "name");
    defer allocator.free(sorted_targets);

    try writer.writeAll("\n    .targets = .{\n");
    for (sorted_targets) |target| {
        try writer.writeAll("        ");
        try writeFieldName(writer, target.name);
        try writer.writeAll(" = .{\n");
        try writer.print("            .kind = .{s},\n", .{@tagName(target.declaration.kind)});
        if (target.declaration.linkage) |linkage| {
            try writer.print("            .linkage = .{s},\n", .{@tagName(linkage)});
        }
        if (target.declaration.test_only) {
            try writer.writeAll("            .test_only = true,\n");
        }
        if (target.declaration.when) |condition| {
            try writer.writeAll("            .when = ");
            try writeCondition(writer, allocator, condition, 3);
            try writer.writeAll(",\n");
        }
        try writer.writeAll("        },\n");
    }
    try writer.writeAll("    },\n");
    try writer.writeAll("}\n");
}

fn writeCondition(writer: *std.Io.Writer, allocator: std.mem.Allocator, condition: model.Condition, indent_level: usize) !void {
    try writer.writeAll(".{\n");
    if (condition.domain) |value| {
        try writeIndent(writer, indent_level + 1);
        try writer.print(".domain = .{s},\n", .{@tagName(value)});
    }
    if (condition.host_os) |value| {
        try writeIndent(writer, indent_level + 1);
        try writer.print(".host_os = .{s},\n", .{@tagName(value)});
    }
    if (condition.host_arch) |value| {
        try writeIndent(writer, indent_level + 1);
        try writer.print(".host_arch = .{s},\n", .{@tagName(value)});
    }
    if (condition.target_os) |value| {
        try writeIndent(writer, indent_level + 1);
        try writer.print(".target_os = .{s},\n", .{@tagName(value)});
    }
    if (condition.target_arch) |value| {
        try writeIndent(writer, indent_level + 1);
        try writer.print(".target_arch = .{s},\n", .{@tagName(value)});
    }
    if (condition.options.len > 0) {
        const sorted_options = try sortedByNameAlloc(model.ConditionOptionMatch, allocator, condition.options, "name");
        defer allocator.free(sorted_options);

        try writeIndent(writer, indent_level + 1);
        try writer.writeAll(".options = .{\n");
        for (sorted_options) |option_match| {
            try writeIndent(writer, indent_level + 2);
            try writeFieldName(writer, option_match.name);
            try writer.writeAll(" = ");
            try writeOptionValue(writer, option_match.value);
            try writer.writeAll(",\n");
        }
        try writeIndent(writer, indent_level + 1);
        try writer.writeAll("},\n");
    }
    try writeIndent(writer, indent_level);
    try writer.writeAll("}");
}

fn sortedByNameAlloc(comptime T: type, allocator: std.mem.Allocator, items: []const T, comptime field_name: []const u8) ![]T {
    const sorted = try allocator.dupe(T, items);
    std.mem.sort(T, sorted, {}, struct {
        fn lessThan(_: void, lhs: T, rhs: T) bool {
            return std.mem.lessThan(u8, @field(lhs, field_name), @field(rhs, field_name));
        }
    }.lessThan);
    return sorted;
}

fn writeIndent(writer: *std.Io.Writer, indent_level: usize) !void {
    for (0..indent_level) |_| {
        try writer.writeAll("    ");
    }
}

fn writeFieldName(writer: *std.Io.Writer, name: []const u8) !void {
    if (isBareIdentifier(name)) {
        try writer.print(".{s}", .{name});
    } else {
        try writer.writeAll(".@");
        try writeString(writer, name);
    }
}

fn isBareIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    }
    return true;
}

fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.zon.stringify.serialize(value, .{ .whitespace = false }, writer);
}

fn writeOptionValue(writer: *std.Io.Writer, value: model.OptionValue) !void {
    switch (value) {
        .bool => |bool_value| try writer.print("{}", .{bool_value}),
        .int => |int_value| try writer.print("{d}", .{int_value}),
        .string => |string_value| try writeString(writer, string_value),
    }
}

fn parseZoirAlloc(allocator: std.mem.Allocator, source: [:0]const u8, ast: Ast, zoir: Zoir) ParseError!Manifest {
    const root = zoir.nodes.items(.tag)[@intFromEnum(Zoir.Node.Index.root)];
    if (root != .struct_literal) return error.RootMustBeStruct;

    const top = try getStruct(Zoir.Node.Index.root, zoir);

    var package_node: ?Zoir.Node.Index = null;
    var options_node: ?Zoir.Node.Index = null;
    var deps_node: ?Zoir.Node.Index = null;
    var targets_node: ?Zoir.Node.Index = null;

    var seen_top = std.StringHashMapUnmanaged(void){};
    defer seen_top.deinit(allocator);

    var schema_seen = false;

    for (0..top.names.len) |index| {
        const field_name = top.names[index].get(zoir);
        const value_idx = top.vals.at(@intCast(index));
        if (seen_top.contains(field_name)) return error.DuplicateTopLevelField;
        try seen_top.put(allocator, field_name, {});

        if (std.mem.eql(u8, field_name, "schema")) {
            schema_seen = true;
            const schema = try parseU32(source, ast, zoir, value_idx);
            if (schema != package_model.schema_version) return error.InvalidSchemaVersion;
        } else if (std.mem.eql(u8, field_name, "package")) {
            package_node = value_idx;
        } else if (std.mem.eql(u8, field_name, "options")) {
            options_node = value_idx;
        } else if (std.mem.eql(u8, field_name, "deps")) {
            deps_node = value_idx;
        } else if (std.mem.eql(u8, field_name, "targets")) {
            targets_node = value_idx;
        } else {
            return error.UnknownTopLevelField;
        }
    }

    if (!schema_seen) return error.InvalidSchemaVersion;

    var package_info = try parsePackageInfo(allocator, source, ast, zoir, package_node orelse return error.MissingPackage);
    errdefer package_info.deinitOwned(allocator);

    const option_list = if (options_node) |node| try parseOptions(allocator, source, ast, zoir, node) else try allocator.alloc(package_model.NamedOptionDefinition, 0);
    errdefer {
        for (option_list) |*item| item.deinitOwned(allocator);
        allocator.free(option_list);
    }

    const dep_list = if (deps_node) |node| try parseDependencies(allocator, source, ast, zoir, node, option_list) else try allocator.alloc(package_model.Dependency, 0);
    errdefer {
        for (dep_list) |*item| item.deinitOwned(allocator);
        allocator.free(dep_list);
    }

    const target_list = try parseTargets(allocator, source, ast, zoir, targets_node orelse return error.MissingTargets, option_list);
    errdefer {
        for (target_list) |*item| item.deinitOwned(allocator);
        allocator.free(target_list);
    }

    return .{
        .schema = package_model.schema_version,
        .package = package_info,
        .options = option_list,
        .deps = dep_list,
        .targets = target_list,
    };
}

fn parsePackageInfo(allocator: std.mem.Allocator, source: [:0]const u8, ast: Ast, zoir: Zoir, node_idx: Zoir.Node.Index) ParseError!package_model.PackageInfo {
    _ = source;
    _ = ast;
    const node = try getStruct(node_idx, zoir);

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    var name_text: ?[]const u8 = null;
    errdefer if (name_text) |text| allocator.free(text);

    var id_text: ?[]const u8 = null;
    errdefer if (id_text) |text| allocator.free(text);

    var version: ?model.Version = null;
    var backend: ?package_model.Backend = null;

    for (0..node.names.len) |index| {
        const field_name = node.names[index].get(zoir);
        const value_idx = node.vals.at(@intCast(index));
        if (seen.contains(field_name)) return error.DuplicateField;
        try seen.put(allocator, field_name, {});

        if (std.mem.eql(u8, field_name, "name")) {
            name_text = try parseOwnedString(allocator, zoir, value_idx);
        } else if (std.mem.eql(u8, field_name, "id")) {
            id_text = try parseOwnedString(allocator, zoir, value_idx);
        } else if (std.mem.eql(u8, field_name, "version")) {
            const raw = try parseString(zoir, value_idx);
            version = model.Version.parse(raw) catch return error.MalformedVersion;
        } else if (std.mem.eql(u8, field_name, "backend")) {
            const raw = try parseEnumLiteral(zoir, value_idx);
            if (std.mem.eql(u8, raw, "zig")) {
                backend = .zig;
            } else {
                return error.UnsupportedBackend;
            }
        } else {
            return error.UnknownPackageField;
        }
    }

    const name = name_text orelse return error.MissingPackageName;
    if (name.len == 0) return error.MissingPackageName;

    const id_owned = id_text orelse return error.MissingPackageId;
    const id = model.PackageId.parse(id_owned) catch return error.InvalidPackageId;
    return .{
        .name = name,
        .id = id,
        .version = version orelse return error.MissingPackageVersion,
        .backend = backend orelse return error.MissingPackageBackend,
    };
}

fn parseOptions(allocator: std.mem.Allocator, source: [:0]const u8, ast: Ast, zoir: Zoir, node_idx: Zoir.Node.Index) ParseError![]package_model.NamedOptionDefinition {
    const node = try getStruct(node_idx, zoir);
    const result = try allocator.alloc(package_model.NamedOptionDefinition, node.names.len);
    errdefer allocator.free(result);

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*item| {
            item.deinitOwned(allocator);
        }
    }

    for (0..node.names.len) |index| {
        const option_name = node.names[index].get(zoir);
        const value_idx = node.vals.at(@intCast(index));
        if (seen.contains(option_name)) return error.DuplicateOptionName;
        try seen.put(allocator, option_name, {});

        result[index] = try parseOptionDefinition(allocator, source, ast, zoir, option_name, value_idx);
        initialized += 1;
    }

    return result;
}

fn parseOptionDefinition(allocator: std.mem.Allocator, source: [:0]const u8, ast: Ast, zoir: Zoir, name: []const u8, node_idx: Zoir.Node.Index) ParseError!package_model.NamedOptionDefinition {
    const node = try getStruct(node_idx, zoir);

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    var kind: ?model.OptionType = null;
    var default_value: ?model.OptionValue = null;
    errdefer if (default_value) |value| value.deinitOwned(allocator);

    var abi: ?bool = null;

    for (0..node.names.len) |index| {
        const field_name = node.names[index].get(zoir);
        const value_idx = node.vals.at(@intCast(index));
        if (seen.contains(field_name)) return error.DuplicateField;
        try seen.put(allocator, field_name, {});

        if (std.mem.eql(u8, field_name, "kind")) {
            const kind_text = try parseEnumLiteral(zoir, value_idx);
            kind = model.OptionType.parse(kind_text) orelse return error.UnknownOptionKind;
        } else if (std.mem.eql(u8, field_name, "default")) {
            default_value = try parseOptionValue(allocator, source, ast, zoir, value_idx);
        } else if (std.mem.eql(u8, field_name, "abi")) {
            abi = try parseBool(zoir, value_idx);
        } else {
            return error.UnknownOptionField;
        }
    }

    var definition = model.OptionDefinition{
        .kind = kind orelse return error.InvalidOptionDefault,
        .default_value = default_value orelse return error.InvalidOptionDefault,
        .abi = abi orelse return error.InvalidOptionDefault,
    };
    errdefer definition.default_value.deinitOwned(allocator);

    definition.validate() catch return error.InvalidOptionDefault;

    return .{
        .name = try allocator.dupe(u8, name),
        .definition = definition,
    };
}

fn parseDependencies(allocator: std.mem.Allocator, source: [:0]const u8, ast: Ast, zoir: Zoir, node_idx: Zoir.Node.Index, option_definitions: []const package_model.NamedOptionDefinition) ParseError![]package_model.Dependency {
    const node = try getStruct(node_idx, zoir);
    const result = try allocator.alloc(package_model.Dependency, node.names.len);
    errdefer allocator.free(result);

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*dep| {
            dep.deinitOwned(allocator);
        }
    }

    for (0..node.names.len) |index| {
        const alias = node.names[index].get(zoir);
        const value_idx = node.vals.at(@intCast(index));
        if (seen.contains(alias)) return error.DuplicateDependencyAlias;
        try seen.put(allocator, alias, {});

        result[index] = try parseDependency(allocator, source, ast, zoir, alias, value_idx, option_definitions);
        initialized += 1;
    }

    return result;
}

fn parseDependency(allocator: std.mem.Allocator, source: [:0]const u8, ast: Ast, zoir: Zoir, alias: []const u8, node_idx: Zoir.Node.Index, option_definitions: []const package_model.NamedOptionDefinition) ParseError!package_model.Dependency {
    const node = try getStruct(node_idx, zoir);

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    var package_id: ?model.PackageId = null;
    errdefer if (package_id) |id| allocator.free(id.text);

    var require: ?package_model.VersionRequirement = null;
    var when: ?model.Condition = null;
    errdefer if (when) |*condition| condition.deinitOwned(allocator);

    var source_path: ?[]const u8 = null;
    errdefer if (source_path) |sp| allocator.free(sp);

    for (0..node.names.len) |index| {
        const field_name = node.names[index].get(zoir);
        const value_idx = node.vals.at(@intCast(index));
        if (seen.contains(field_name)) return error.DuplicateField;
        try seen.put(allocator, field_name, {});

        if (std.mem.eql(u8, field_name, "package")) {
            const package_text = try parseOwnedString(allocator, zoir, value_idx);
            package_id = model.PackageId.parse(package_text) catch {
                allocator.free(package_text);
                return error.InvalidPackageId;
            };
        } else if (std.mem.eql(u8, field_name, "require")) {
            require = try parseRequire(allocator, zoir, value_idx);
        } else if (std.mem.eql(u8, field_name, "when")) {
            when = try parseCondition(allocator, source, ast, zoir, value_idx, option_definitions);
        } else if (std.mem.eql(u8, field_name, "source_path")) {
            source_path = try parseOwnedString(allocator, zoir, value_idx);
            if (source_path.?.len == 0) return error.EmptySourcePath;
            if (std.fs.path.isAbsolute(source_path.?)) return error.AbsoluteSourcePath;
        } else if (std.mem.eql(u8, field_name, "required")) {
            return error.FieldNotAllowed;
        } else {
            return error.UnknownDependencyField;
        }
    }

    const alias_owned = try allocator.dupe(u8, alias);
    errdefer allocator.free(alias_owned);

    return .{
        .alias = alias_owned,
        .package = package_id orelse return error.MissingDependencyPackageId,
        .require = require orelse return error.MissingDependencyVersionRequirement,
        .when = when,
        .source_path = source_path,
    };
}

fn parseRequire(allocator: std.mem.Allocator, zoir: Zoir, node_idx: Zoir.Node.Index) ParseError!package_model.VersionRequirement {
    const node = try getStruct(node_idx, zoir);
    _ = allocator;
    var version_requirement: ?package_model.VersionRequirement = null;
    for (0..node.names.len) |index| {
        const field_name = node.names[index].get(zoir);
        const value_idx = node.vals.at(@intCast(index));
        if (std.mem.eql(u8, field_name, "version")) {
            const raw = try parseString(zoir, value_idx);
            version_requirement = package_model.VersionRequirement.parse(raw) catch return error.MalformedVersionConstraint;
        } else {
            return error.UnknownRequirementField;
        }
    }
    return version_requirement orelse return error.MissingDependencyVersionRequirement;
}

fn parseTargets(allocator: std.mem.Allocator, source: [:0]const u8, ast: Ast, zoir: Zoir, node_idx: Zoir.Node.Index, option_definitions: []const package_model.NamedOptionDefinition) ParseError![]target_model.NamedDeclaration {
    const node = try getStruct(node_idx, zoir);
    const result = try allocator.alloc(target_model.NamedDeclaration, node.names.len);
    errdefer allocator.free(result);

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*item| {
            item.deinitOwned(allocator);
        }
    }

    for (0..node.names.len) |index| {
        const target_name = node.names[index].get(zoir);
        const value_idx = node.vals.at(@intCast(index));
        if (seen.contains(target_name)) return error.DuplicateTargetName;
        try seen.put(allocator, target_name, {});

        result[index] = try parseTargetDeclaration(allocator, source, ast, zoir, target_name, value_idx, option_definitions);
        initialized += 1;
    }

    return result;
}

fn parseTargetDeclaration(allocator: std.mem.Allocator, source: [:0]const u8, ast: Ast, zoir: Zoir, name: []const u8, node_idx: Zoir.Node.Index, option_definitions: []const package_model.NamedOptionDefinition) ParseError!target_model.NamedDeclaration {
    const node = try getStruct(node_idx, zoir);

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    var kind: ?target_model.Kind = null;
    var linkage: ?target_model.Linkage = null;
    var test_only = false;
    var when: ?model.Condition = null;
    errdefer if (when) |*condition| condition.deinitOwned(allocator);

    for (0..node.names.len) |index| {
        const field_name = node.names[index].get(zoir);
        const value_idx = node.vals.at(@intCast(index));
        if (seen.contains(field_name)) return error.DuplicateField;
        try seen.put(allocator, field_name, {});

        if (std.mem.eql(u8, field_name, "kind")) {
            const kind_text = try parseEnumLiteral(zoir, value_idx);
            kind = std.meta.stringToEnum(target_model.Kind, kind_text) orelse return error.UnsupportedTargetKind;
        } else if (std.mem.eql(u8, field_name, "linkage")) {
            const linkage_text = try parseEnumLiteral(zoir, value_idx);
            linkage = std.meta.stringToEnum(target_model.Linkage, linkage_text) orelse return error.InvalidLinkage;
        } else if (std.mem.eql(u8, field_name, "test_only")) {
            test_only = try parseBool(zoir, value_idx);
        } else if (std.mem.eql(u8, field_name, "when")) {
            when = try parseCondition(allocator, source, ast, zoir, value_idx, option_definitions);
        } else {
            return error.UnknownTargetField;
        }
    }

    const resolved_kind = kind orelse return error.UnsupportedTargetKind;
    if (linkage != null and resolved_kind != .library) return error.BadLinkagePlacement;

    return .{
        .name = try allocator.dupe(u8, name),
        .declaration = .{
            .kind = resolved_kind,
            .linkage = linkage,
            .test_only = test_only,
            .when = when,
        },
    };
}

fn parseCondition(allocator: std.mem.Allocator, source: [:0]const u8, ast: Ast, zoir: Zoir, node_idx: Zoir.Node.Index, option_definitions: []const package_model.NamedOptionDefinition) ParseError!model.Condition {
    const node = try getStruct(node_idx, zoir);

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    var domain: ?model.Domain = null;
    var host_os: ?model.ConditionOs = null;
    var host_arch: ?model.ConditionArch = null;
    var target_os: ?model.ConditionOs = null;
    var target_arch: ?model.ConditionArch = null;
    var option_matches = try allocator.alloc(model.ConditionOptionMatch, 0);
    errdefer {
        for (option_matches) |entry| entry.deinitOwned(allocator);
        allocator.free(option_matches);
    }

    for (0..node.names.len) |index| {
        const field_name = node.names[index].get(zoir);
        const value_idx = node.vals.at(@intCast(index));
        if (seen.contains(field_name)) return error.DuplicateField;
        try seen.put(allocator, field_name, {});

        if (std.mem.eql(u8, field_name, "domain")) {
            const domain_text = try parseEnumLiteral(zoir, value_idx);
            domain = model.Domain.parse(domain_text) catch return error.UnknownConditionField;
        } else if (std.mem.eql(u8, field_name, "host_os")) {
            const os_text = try parseEnumLiteral(zoir, value_idx);
            host_os = model.conditions.parseOs(os_text) catch return error.UnknownConditionField;
        } else if (std.mem.eql(u8, field_name, "host_arch")) {
            const arch_text = try parseEnumLiteral(zoir, value_idx);
            host_arch = model.conditions.parseArch(arch_text) catch return error.UnknownConditionField;
        } else if (std.mem.eql(u8, field_name, "target_os")) {
            const os_text = try parseEnumLiteral(zoir, value_idx);
            target_os = model.conditions.parseOs(os_text) catch return error.UnknownConditionField;
        } else if (std.mem.eql(u8, field_name, "target_arch")) {
            const arch_text = try parseEnumLiteral(zoir, value_idx);
            target_arch = model.conditions.parseArch(arch_text) catch return error.UnknownConditionField;
        } else if (std.mem.eql(u8, field_name, "options")) {
            const new_option_matches = try parseConditionOptions(allocator, source, ast, zoir, value_idx, option_definitions);
            allocator.free(option_matches);
            option_matches = new_option_matches;
        } else {
            return error.UnknownConditionField;
        }
    }

    return .{
        .domain = domain,
        .host_os = host_os,
        .host_arch = host_arch,
        .target_os = target_os,
        .target_arch = target_arch,
        .options = option_matches,
    };
}

fn parseConditionOptions(allocator: std.mem.Allocator, source: [:0]const u8, ast: Ast, zoir: Zoir, node_idx: Zoir.Node.Index, option_definitions: []const package_model.NamedOptionDefinition) ParseError![]model.ConditionOptionMatch {
    const node = try getStruct(node_idx, zoir);
    const result = try allocator.alloc(model.ConditionOptionMatch, node.names.len);
    errdefer allocator.free(result);

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |entry| entry.deinitOwned(allocator);
    }

    for (0..node.names.len) |index| {
        const option_name = node.names[index].get(zoir);
        const value_idx = node.vals.at(@intCast(index));
        if (seen.contains(option_name)) return error.DuplicateConditionOption;
        try seen.put(allocator, option_name, {});

        const option_definition = findOptionDefinition(option_definitions, option_name) orelse return error.UnknownConditionOption;
        const option_value = try parseOptionValue(allocator, source, ast, zoir, value_idx);
        errdefer option_value.deinitOwned(allocator);
        if (!option_value.matchesType(option_definition.definition.kind)) return error.ConditionOptionTypeMismatch;

        result[index] = .{
            .name = try allocator.dupe(u8, option_name),
            .value = option_value,
        };
        initialized += 1;
    }

    return result;
}

fn findOptionDefinition(option_definitions: []const package_model.NamedOptionDefinition, name: []const u8) ?package_model.NamedOptionDefinition {
    for (option_definitions) |option_definition| {
        if (std.mem.eql(u8, option_definition.name, name)) return option_definition;
    }
    return null;
}

fn parseOptionValue(allocator: std.mem.Allocator, source: [:0]const u8, ast: Ast, zoir: Zoir, node_idx: Zoir.Node.Index) ParseError!model.OptionValue {
    return switch (node_idx.get(zoir)) {
        .true => .{ .bool = true },
        .false => .{ .bool = false },
        .string_literal => |text| .{ .string = try allocator.dupe(u8, text) },
        .int_literal => .{ .int = try parseI64(source, ast, zoir, node_idx) },
        else => error.InvalidOptionDefault,
    };
}

fn parseBool(zoir: Zoir, node_idx: Zoir.Node.Index) ParseError!bool {
    return switch (node_idx.get(zoir)) {
        .true => true,
        .false => false,
        else => error.ExpectedBool,
    };
}

fn parseString(zoir: Zoir, node_idx: Zoir.Node.Index) ParseError![]const u8 {
    return switch (node_idx.get(zoir)) {
        .string_literal => |text| text,
        else => error.ExpectedString,
    };
}

fn parseOwnedString(allocator: std.mem.Allocator, zoir: Zoir, node_idx: Zoir.Node.Index) ParseError![]const u8 {
    return allocator.dupe(u8, try parseString(zoir, node_idx)) catch return error.OutOfMemory;
}

fn parseEnumLiteral(zoir: Zoir, node_idx: Zoir.Node.Index) ParseError![]const u8 {
    return switch (node_idx.get(zoir)) {
        .enum_literal => |text| text.get(zoir),
        else => error.ExpectedEnumLiteral,
    };
}

fn parseI64(source: [:0]const u8, ast: Ast, zoir: Zoir, node_idx: Zoir.Node.Index) ParseError!i64 {
    _ = source;
    switch (node_idx.get(zoir)) {
        .int_literal => {},
        else => return error.ExpectedInt,
    }
    const ast_node = node_idx.getAstNode(zoir);
    const literal_text = ast.getNodeSource(ast_node);
    return std.fmt.parseInt(i64, literal_text, 0) catch return error.ExpectedInt;
}

fn parseU32(source: [:0]const u8, ast: Ast, zoir: Zoir, node_idx: Zoir.Node.Index) ParseError!u32 {
    _ = source;
    switch (node_idx.get(zoir)) {
        .int_literal => {},
        else => return error.ExpectedInt,
    }
    const ast_node = node_idx.getAstNode(zoir);
    const literal_text = ast.getNodeSource(ast_node);
    return std.fmt.parseInt(u32, literal_text, 0) catch return error.ExpectedInt;
}

fn getStruct(node_idx: Zoir.Node.Index, zoir: Zoir) ParseError!@FieldType(Zoir.Node, "struct_literal") {
    return switch (node_idx.get(zoir)) {
        .struct_literal => |node| node,
        .empty_literal => .{ .names = &.{}, .vals = .{ .start = @enumFromInt(0), .len = 0 } },
        else => error.ExpectedStruct,
    };
}

test "parse example hello-lib fixture and match golden" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const source = try std.Io.Dir.cwd().readFileAlloc(io, "examples/hello-lib/zpkg.zon", allocator, .limited(64 * 1024));
    defer allocator.free(source);
    const sentinel_source = try allocator.dupeZ(u8, source);
    defer allocator.free(sentinel_source);

    var manifest = try parseSliceAlloc(allocator, sentinel_source);
    defer manifest.deinitOwned(allocator);

    try std.testing.expectEqualStrings("hello-lib", manifest.package.name);
    try std.testing.expectEqualStrings("zpkg.example.hello_lib", manifest.package.id.text);
    try std.testing.expectEqual(model.Version.init(0, 1, 0, 0), manifest.package.version);
    try std.testing.expectEqual(@as(usize, 1), manifest.options.len);
    try std.testing.expectEqual(@as(usize, 0), manifest.deps.len);
    try std.testing.expectEqual(@as(usize, 3), manifest.targets.len);
    try std.testing.expectEqual(target_model.Kind.library, manifest.targets[0].declaration.kind);
    try std.testing.expectEqual(target_model.Linkage.@"default", manifest.targets[0].declaration.linkage.?);

    const normalized = try formatNormalizedAlloc(allocator, manifest);
    defer allocator.free(normalized);

    const expected = try std.Io.Dir.cwd().readFileAlloc(io, "test/golden/schema/hello-lib.normalized.zon", allocator, .limited(64 * 1024));
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, normalized);
}

test "parse full featured manifest and match golden" {
    const allocator = std.testing.allocator;
    const source =
        \\.{
        \\    .schema = 1,
        \\    .package = .{
        \\        .name = "tracker",
        \\        .id = "sai.pilot.object_tracker",
        \\        .version = "1.2.3",
        \\        .backend = .zig,
        \\    },
        \\    .options = .{
        \\        .shared = .{ .kind = .bool, .default = true, .abi = true },
        \\        .api_level = .{ .kind = .int, .default = 2, .abi = true },
        \\        .flavor = .{ .kind = .string, .default = "default", .abi = false },
        \\    },
        \\    .deps = .{
        \\        .protobuf = .{
        \\            .package = "sai.upstream.protobuf",
        \\            .require = .{ .version = "=4.1.2" },
        \\        },
        \\        .gtest = .{
        \\            .package = "sai.upstream.gtest",
        \\            .require = .{ .version = "=1.14.0.0" },
        \\            .when = .{
        \\                .domain = .host,
        \\                .options = .{
        \\                    .flavor = "default",
        \\                },
        \\            },
        \\        },
        \\    },
        \\    .targets = .{
        \\        .tracker = .{ .kind = .library, .linkage = .default },
        \\        .tracker_headers = .{ .kind = .headers },
        \\        .tracker_tests = .{
        \\            .kind = .executable,
        \\            .test_only = true,
        \\            .when = .{ .options = .{ .flavor = "default" } },
        \\        },
        \\    },
        \\}
    ;
    const sentinel_source = try allocator.dupeZ(u8, source);
    defer allocator.free(sentinel_source);

    var manifest = try parseSliceAlloc(allocator, sentinel_source);
    defer manifest.deinitOwned(allocator);

    try std.testing.expectEqualStrings("1.2.3.0", blk: {
        var version_buf: [32]u8 = undefined;
        break :blk try manifest.package.version.bufPrint(&version_buf);
    });
    try std.testing.expectEqual(@as(usize, 3), manifest.options.len);
    try std.testing.expectEqual(@as(usize, 2), manifest.deps.len);
    try std.testing.expectEqual(@as(usize, 3), manifest.targets.len);
    try std.testing.expectEqual(model.Domain.host, manifest.deps[1].when.?.domain.?);
    try std.testing.expectEqualStrings("flavor", manifest.deps[1].when.?.options[0].name);

    const normalized = try formatNormalizedAlloc(allocator, manifest);
    defer allocator.free(normalized);

    const io = std.testing.io;
    const expected = try std.Io.Dir.cwd().readFileAlloc(io, "test/golden/schema/full.normalized.zon", allocator, .limited(64 * 1024));
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, normalized);
}

test "normalization is canonical regardless of declaration order" {
    const allocator = std.testing.allocator;
    const source =
        \\.{
        \\    .schema = 1,
        \\    .package = .{
        \\        .name = "tracker",
        \\        .id = "sai.pilot.object_tracker",
        \\        .version = "1.2.3",
        \\        .backend = .zig,
        \\    },
        \\    .options = .{
        \\        .shared = .{ .kind = .bool, .default = true, .abi = true },
        \\        .flavor = .{ .kind = .string, .default = "default", .abi = false },
        \\        .api_level = .{ .kind = .int, .default = 2, .abi = true },
        \\    },
        \\    .deps = .{
        \\        .protobuf = .{
        \\            .package = "sai.upstream.protobuf",
        \\            .require = .{ .version = "=4.1.2" },
        \\        },
        \\        .gtest = .{
        \\            .package = "sai.upstream.gtest",
        \\            .require = .{ .version = "=1.14.0.0" },
        \\            .when = .{
        \\                .options = .{
        \\                    .flavor = "default",
        \\                },
        \\                .domain = .host,
        \\            },
        \\        },
        \\    },
        \\    .targets = .{
        \\        .tracker_tests = .{
        \\            .kind = .executable,
        \\            .test_only = true,
        \\            .when = .{ .options = .{ .flavor = "default" } },
        \\        },
        \\        .tracker = .{ .kind = .library, .linkage = .default },
        \\        .tracker_headers = .{ .kind = .headers },
        \\    },
        \\}
    ;
    const sentinel_source = try allocator.dupeZ(u8, source);
    defer allocator.free(sentinel_source);

    var manifest = try parseSliceAlloc(allocator, sentinel_source);
    defer manifest.deinitOwned(allocator);

    const normalized = try formatNormalizedAlloc(allocator, manifest);
    defer allocator.free(normalized);

    const io = std.testing.io;
    const expected = try std.Io.Dir.cwd().readFileAlloc(io, "test/golden/schema/full.normalized.zon", allocator, .limited(64 * 1024));
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, normalized);
}

fn expectParseError(source: []const u8, expected: ParseError) !void {
    const allocator = std.testing.allocator;
    const sentinel_source = try allocator.dupeZ(u8, source);
    defer allocator.free(sentinel_source);
    try std.testing.expectError(expected, parseSliceAlloc(allocator, sentinel_source));
}

test "reject malformed versions malformed version constraints invalid package ids empty package names and missing dependency fields" {
    try expectParseError(
        \\.{
        \\    .schema = 1,
        \\    .package = .{ .name = "x", .id = "zpkg.example.x", .version = "1.2", .backend = .zig },
        \\    .targets = .{ .x = .{ .kind = .executable } },
        \\}
    , error.MalformedVersion);

    try expectParseError(
        \\.{
        \\    .schema = 1,
        \\    .package = .{ .name = "", .id = "zpkg.example.x", .version = "1.2.3", .backend = .zig },
        \\    .targets = .{ .x = .{ .kind = .executable } },
        \\}
    , error.MissingPackageName);

    try expectParseError(
        \\.{
        \\    .schema = 1,
        \\    .package = .{ .name = "x", .id = "not_namespaced", .version = "1.2.3", .backend = .zig },
        \\    .targets = .{ .x = .{ .kind = .executable } },
        \\}
    , error.InvalidPackageId);

    try expectParseError(
        \\.{
        \\    .schema = 1,
        \\    .package = .{ .name = "x", .id = "zpkg.example.x", .version = "1.2.3", .backend = .zig },
        \\    .deps = .{ .foo = .{ .require = .{ .version = "=1.2.3" } } },
        \\    .targets = .{ .x = .{ .kind = .executable } },
        \\}
    , error.MissingDependencyPackageId);

    try expectParseError(
        \\.{
        \\    .schema = 1,
        \\    .package = .{ .name = "x", .id = "zpkg.example.x", .version = "1.2.3", .backend = .zig },
        \\    .deps = .{ .foo = .{ .package = "zpkg.example.foo" } },
        \\    .targets = .{ .x = .{ .kind = .executable } },
        \\}
    , error.MissingDependencyVersionRequirement);

    try expectParseError(
        \\.{
        \\    .schema = 1,
        \\    .package = .{ .name = "x", .id = "zpkg.example.x", .version = "1.2.3", .backend = .zig },
        \\    .deps = .{ .foo = .{ .package = "zpkg.example.foo", .require = .{} } },
        \\    .targets = .{ .x = .{ .kind = .executable } },
        \\}
    , error.MissingDependencyVersionRequirement);

    try expectParseError(
        \\.{
        \\    .schema = 1,
        \\    .package = .{ .name = "x", .id = "zpkg.example.x", .version = "1.2.3", .backend = .zig },
        \\    .deps = .{ .foo = .{ .package = "zpkg.example.foo", .require = .{ .version = "^1.2.3" } } },
        \\    .targets = .{ .x = .{ .kind = .executable } },
        \\}
    , error.MalformedVersionConstraint);
}

test "reject invalid target kinds and bad linkage placement" {
    try expectParseError(
        \\.{
        \\    .schema = 1,
        \\    .package = .{ .name = "x", .id = "zpkg.example.x", .version = "1.2.3", .backend = .zig },
        \\    .targets = .{ .x = .{ .kind = .plugin } },
        \\}
    , error.UnsupportedTargetKind);

    try expectParseError(
        \\.{
        \\    .schema = 1,
        \\    .package = .{ .name = "x", .id = "zpkg.example.x", .version = "1.2.3", .backend = .zig },
        \\    .targets = .{ .x = .{ .kind = .executable, .linkage = .shared } },
        \\}
    , error.BadLinkagePlacement);
}

test "reject unsupported condition axes invalid condition placement and condition option mismatches" {
    try expectParseError(
        \\.{
        \\    .schema = 1,
        \\    .package = .{
        \\        .name = "x",
        \\        .id = "zpkg.example.x",
        \\        .version = "1.2.3",
        \\        .backend = .zig,
        \\    },
        \\    .targets = .{
        \\        .x = .{ .kind = .executable, .when = .{ .host_abi = .gnu } },
        \\    },
        \\}
    , error.UnknownConditionField);

    try expectParseError(
        \\.{
        \\    .schema = 1,
        \\    .package = .{
        \\        .name = "x",
        \\        .id = "zpkg.example.x",
        \\        .version = "1.2.3",
        \\        .backend = .zig,
        \\    },
        \\    .options = .{
        \\        .shared = .{ .kind = .bool, .default = true, .abi = true, .when = .{ .domain = .host } },
        \\    },
        \\    .targets = .{ .x = .{ .kind = .executable } },
        \\}
    , error.UnknownOptionField);

    try expectParseError(
        \\.{
        \\    .schema = 1,
        \\    .package = .{
        \\        .name = "x",
        \\        .id = "zpkg.example.x",
        \\        .version = "1.2.3",
        \\        .backend = .zig,
        \\    },
        \\    .options = .{
        \\        .shared = .{ .kind = .bool, .default = true, .abi = true },
        \\    },
        \\    .targets = .{
        \\        .x = .{ .kind = .executable, .when = .{ .options = .{ .shared = "yes" } } },
        \\    },
        \\}
    , error.ConditionOptionTypeMismatch);
}

test "reject disallowed dependency fields and duplicate target names" {
    try expectParseError(
        \\.{
        \\    .schema = 1,
        \\    .package = .{ .name = "x", .id = "zpkg.example.x", .version = "1.2.3", .backend = .zig },
        \\    .deps = .{ .foo = .{ .package = "zpkg.example.foo", .require = .{ .version = "=1.0.0" }, .required = true } },
        \\    .targets = .{ .x = .{ .kind = .executable } },
        \\}
    , error.FieldNotAllowed);

    try expectParseError(
        \\.{
        \\    .schema = 1,
        \\    .package = .{ .name = "x", .id = "zpkg.example.x", .version = "1.2.3", .backend = .zig },
        \\    .targets = .{
        \\        .x = .{ .kind = .executable },
        \\        .x = .{ .kind = .headers },
        \\    },
        \\}
    , error.ParseZon);
}

test "diagnostic for malformed package version is actionable" {
    const allocator = std.testing.allocator;
    const diagnostic = try formatDiagnosticAlloc(allocator, "fixtures/bad-version/zpkg.zon", error.MalformedVersion);
    defer allocator.free(diagnostic);

    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "fixtures/bad-version/zpkg.zon") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, ".package.version") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "x.y.z or x.y.z.w") != null);
}

test "diagnostic for bad linkage placement is actionable" {
    const allocator = std.testing.allocator;
    const diagnostic = try formatDiagnosticAlloc(allocator, "fixtures/bad-linkage/zpkg.zon", error.BadLinkagePlacement);
    defer allocator.free(diagnostic);

    try std.testing.expect(std.mem.indexOf(u8, diagnostic, ".targets.<name>.linkage") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "only valid for .library targets") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "remove .linkage") != null);
}
