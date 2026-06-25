const std = @import("std");
const model = @import("root.zig");
const zon_util = @import("../schema/zon_util.zig");

pub const Visibility = enum {
    public,
    private,

    pub fn asText(self: Visibility) []const u8 {
        return @tagName(self);
    }
};

pub const TargetKind = enum {
    library,
    executable,
    zig_module,
    headers,
    resource_set,

    pub fn asText(self: TargetKind) []const u8 {
        return @tagName(self);
    }
};

pub const Linkage = enum {
    shared,
    static,

    pub fn asText(self: Linkage) []const u8 {
        return @tagName(self);
    }
};

pub const ArtifactKind = enum {
    library,
    executable,

    pub fn asText(self: ArtifactKind) []const u8 {
        return @tagName(self);
    }
};

pub const DependencyRole = enum {
    link,
    tool,
    build,
    @"test",

    pub fn asText(self: DependencyRole) []const u8 {
        return @tagName(self);
    }
};

pub const ResourceDir = enum {
    share,

    pub fn asText(self: ResourceDir) []const u8 {
        return @tagName(self);
    }
};

pub const Package = struct {
    name: []const u8,
    id: model.PackageId,
    version: model.Version,
    domain: model.Domain,

    pub fn deinit(self: Package, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.id.deinitOwned(allocator);
    }
};

pub const DependencyAlias = struct {
    alias: []const u8,
    package_id: model.PackageId,
    domain: model.Domain,

    pub fn deinit(self: DependencyAlias, allocator: std.mem.Allocator) void {
        allocator.free(self.alias);
        self.package_id.deinitOwned(allocator);
    }
};

pub const IncludeDir = struct {
    path: []const u8,
    visibility: Visibility,

    pub fn deinit(self: IncludeDir, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const CompileDefinition = struct {
    key: []const u8,
    value: model.OptionValue,
    visibility: Visibility,

    pub fn deinit(self: CompileDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        self.value.deinitOwned(allocator);
    }
};

pub const SystemLib = struct {
    name: []const u8,
    visibility: Visibility,

    pub fn deinit(self: SystemLib, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const Artifact = struct {
    kind: ArtifactKind,
    path: []const u8,

    pub fn deinit(self: Artifact, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const Edge = struct {
    name: []const u8,
    dep: []const u8,
    target: []const u8,
    role: DependencyRole,
    visibility: Visibility,

    pub fn deinit(self: Edge, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.dep);
        allocator.free(self.target);
    }
};

pub const Install = struct {
    source: []const u8,
    dir: ResourceDir,
    subdir: []const u8,
    dest: []const u8,

    pub fn deinit(self: Install, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.subdir);
        allocator.free(self.dest);
    }
};

pub const Module = struct {
    name: []const u8,
    root_source_file: []const u8,

    pub fn deinit(self: Module, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.root_source_file);
    }
};

pub const Target = struct {
    name: []const u8,
    kind: TargetKind,
    linkage: ?Linkage,
    exported: bool,
    test_only: bool,
    include_dirs: []IncludeDir,
    compile_definitions: []CompileDefinition,
    system_libs: []SystemLib,
    artifacts: []Artifact,
    deps: []Edge,
    installs: []Install,
    module: ?Module,

    pub fn deinit(self: Target, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.include_dirs) |entry| entry.deinit(allocator);
        allocator.free(self.include_dirs);
        for (self.compile_definitions) |entry| entry.deinit(allocator);
        allocator.free(self.compile_definitions);
        for (self.system_libs) |entry| entry.deinit(allocator);
        allocator.free(self.system_libs);
        for (self.artifacts) |entry| entry.deinit(allocator);
        allocator.free(self.artifacts);
        for (self.deps) |entry| entry.deinit(allocator);
        allocator.free(self.deps);
        for (self.installs) |entry| entry.deinit(allocator);
        allocator.free(self.installs);
        if (self.module) |module| module.deinit(allocator);
    }
};

pub const Graph = struct {
    schema: u32,
    package: Package,
    selected_options: []model.NamedOptionValue,
    dependency_aliases: []DependencyAlias,
    targets: []Target,

    pub fn deinit(self: Graph, allocator: std.mem.Allocator) void {
        self.package.deinit(allocator);
        for (self.selected_options) |entry| {
            allocator.free(entry.name);
            entry.value.deinitOwned(allocator);
        }
        allocator.free(self.selected_options);
        for (self.dependency_aliases) |entry| entry.deinit(allocator);
        allocator.free(self.dependency_aliases);
        for (self.targets) |entry| entry.deinit(allocator);
        allocator.free(self.targets);
    }

    pub fn toZonAlloc(self: Graph, allocator: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        try writer.writeAll(".{\n");
        try zon_util.writeIndent(writer, 1);
        try writer.print(".schema = {d},\n\n", .{self.schema});

        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".package = .{\n");
        try zon_util.writeIndent(writer, 2);
        try writer.writeAll(".name = ");
        try zon_util.writeString(writer, self.package.name);
        try writer.writeAll(",\n");
        try zon_util.writeIndent(writer, 2);
        try writer.writeAll(".id = ");
        try zon_util.writeString(writer, self.package.id.asText());
        try writer.writeAll(",\n");
        try zon_util.writeIndent(writer, 2);
        try writer.writeAll(".version = ");
        var version_buf: [32]u8 = undefined;
        try zon_util.writeString(writer, try self.package.version.bufPrint(&version_buf));
        try writer.writeAll(",\n");
        try zon_util.writeIndent(writer, 2);
        try writer.print(".domain = .{s},\n", .{self.package.domain.asText()});
        try zon_util.writeIndent(writer, 1);
        try writer.writeAll("},\n\n");

        const sorted_options = try sortedNamedOptionValuesAlloc(allocator, self.selected_options);
        defer allocator.free(sorted_options);
        try writeNamedOptionMap(writer, 1, ".selected_options", sorted_options);
        try writer.writeAll("\n\n");

        const sorted_aliases = try sortedDependencyAliasesAlloc(allocator, self.dependency_aliases);
        defer allocator.free(sorted_aliases);
        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".dependency_aliases = .{");
        if (sorted_aliases.len == 0) {
            try writer.writeAll("},\n\n");
        } else {
            try writer.writeAll("\n");
            for (sorted_aliases) |alias| {
                try zon_util.writeIndent(writer, 2);
                try zon_util.writeQuotedFieldName(writer, alias.alias);
                try writer.writeAll(" = .{\n");
                try zon_util.writeIndent(writer, 3);
                try writer.writeAll(".package = ");
                try zon_util.writeString(writer, alias.package_id.asText());
                try writer.writeAll(",\n");
                try zon_util.writeIndent(writer, 3);
                try writer.print(".domain = .{s},\n", .{alias.domain.asText()});
                try zon_util.writeIndent(writer, 2);
                try writer.writeAll("},\n");
            }
            try zon_util.writeIndent(writer, 1);
            try writer.writeAll("},\n\n");
        }

        const sorted_targets = try sortedTargetsAlloc(allocator, self.targets);
        defer allocator.free(sorted_targets);
        try zon_util.writeIndent(writer, 1);
        try writer.writeAll(".targets = .{");
        if (sorted_targets.len == 0) {
            try writer.writeAll("},\n");
        } else {
            try writer.writeAll("\n");
            for (sorted_targets) |target| {
                try zon_util.writeIndent(writer, 2);
                try zon_util.writeQuotedFieldName(writer, target.name);
                try writer.writeAll(" = .{\n");
                try zon_util.writeIndent(writer, 3);
                try writer.print(".kind = .{s},\n", .{target.kind.asText()});
                if (target.linkage) |linkage| {
                    try zon_util.writeIndent(writer, 3);
                    try writer.print(".linkage = .{s},\n", .{linkage.asText()});
                }
                try zon_util.writeIndent(writer, 3);
                try writer.print(".exported = {},\n", .{target.exported});
                try zon_util.writeIndent(writer, 3);
                try writer.print(".test_only = {},\n", .{target.test_only});

                try writeIncludeDirs(writer, allocator, 3, target.include_dirs);
                try writeCompileDefinitions(writer, allocator, 3, target.compile_definitions);
                try writeSystemLibs(writer, allocator, 3, target.system_libs);
                try writeArtifacts(writer, allocator, 3, target.artifacts);
                try writeEdges(writer, allocator, 3, target.deps);
                if (target.installs.len > 0) try writeInstalls(writer, allocator, 3, target.installs);
                if (target.module) |module| {
                    try zon_util.writeIndent(writer, 3);
                    try writer.writeAll(".module = .{\n");
                    try zon_util.writeIndent(writer, 4);
                    try writer.writeAll(".name = ");
                    try zon_util.writeString(writer, module.name);
                    try writer.writeAll(",\n");
                    try zon_util.writeIndent(writer, 4);
                    try writer.writeAll(".root_source_file = ");
                    try zon_util.writeString(writer, module.root_source_file);
                    try writer.writeAll(",\n");
                    try zon_util.writeIndent(writer, 3);
                    try writer.writeAll("},\n");
                }

                try zon_util.writeIndent(writer, 2);
                try writer.writeAll("},\n");
            }
            try zon_util.writeIndent(writer, 1);
            try writer.writeAll("},\n");
        }

        try writer.writeAll("}\n");
        return try aw.toOwnedSlice();
    }
};

fn writeNamedOptionMap(writer: *std.Io.Writer, depth: usize, field_name: []const u8, entries: []const model.NamedOptionValue) !void {
    try zon_util.writeIndent(writer, depth);
    try writer.print("{s} = .{{", .{field_name});
    if (entries.len == 0) {
        try writer.writeAll("},");
        return;
    }
    try writer.writeAll("\n");
    for (entries) |entry| {
        try zon_util.writeIndent(writer, depth + 1);
        try zon_util.writeQuotedFieldName(writer, entry.name);
        try writer.writeAll(" = ");
        try zon_util.writeOptionValue(writer, entry.value);
        try writer.writeAll(",\n");
    }
    try zon_util.writeIndent(writer, depth);
    try writer.writeAll("},");
}

fn writeIncludeDirs(writer: *std.Io.Writer, allocator: std.mem.Allocator, depth: usize, entries: []const IncludeDir) !void {
    const sorted_entries = try sortedIncludeDirsAlloc(allocator, entries);
    defer allocator.free(sorted_entries);
    try zon_util.writeIndent(writer, depth);
    try writer.writeAll(".include_dirs = .{");
    if (entries.len == 0) {
        try writer.writeAll("},\n");
        return;
    }
    try writer.writeAll("\n");
    for (sorted_entries) |entry| {
        try zon_util.writeIndent(writer, depth + 1);
        try writer.writeAll(".{ .path = ");
        try zon_util.writeString(writer, entry.path);
        try writer.print(", .visibility = .{s} }},\n", .{entry.visibility.asText()});
    }
    try zon_util.writeIndent(writer, depth);
    try writer.writeAll("},\n");
}

fn writeCompileDefinitions(writer: *std.Io.Writer, allocator: std.mem.Allocator, depth: usize, entries: []const CompileDefinition) !void {
    const sorted_entries = try sortedCompileDefinitionsAlloc(allocator, entries);
    defer allocator.free(sorted_entries);
    try zon_util.writeIndent(writer, depth);
    try writer.writeAll(".compile_definitions = .{");
    if (entries.len == 0) {
        try writer.writeAll("},\n");
        return;
    }
    try writer.writeAll("\n");
    for (sorted_entries) |entry| {
        try zon_util.writeIndent(writer, depth + 1);
        try writer.writeAll(".{ .key = ");
        try zon_util.writeString(writer, entry.key);
        try writer.writeAll(", .value = ");
        try zon_util.writeOptionValue(writer, entry.value);
        try writer.print(", .visibility = .{s} }},\n", .{entry.visibility.asText()});
    }
    try zon_util.writeIndent(writer, depth);
    try writer.writeAll("},\n");
}

fn writeSystemLibs(writer: *std.Io.Writer, allocator: std.mem.Allocator, depth: usize, entries: []const SystemLib) !void {
    const sorted_entries = try sortedSystemLibsAlloc(allocator, entries);
    defer allocator.free(sorted_entries);
    try zon_util.writeIndent(writer, depth);
    try writer.writeAll(".system_libs = .{");
    if (entries.len == 0) {
        try writer.writeAll("},\n");
        return;
    }
    try writer.writeAll("\n");
    for (sorted_entries) |entry| {
        try zon_util.writeIndent(writer, depth + 1);
        try writer.writeAll(".{ .name = ");
        try zon_util.writeString(writer, entry.name);
        try writer.print(", .visibility = .{s} }},\n", .{entry.visibility.asText()});
    }
    try zon_util.writeIndent(writer, depth);
    try writer.writeAll("},\n");
}

fn writeArtifacts(writer: *std.Io.Writer, allocator: std.mem.Allocator, depth: usize, entries: []const Artifact) !void {
    const sorted_entries = try sortedArtifactsAlloc(allocator, entries);
    defer allocator.free(sorted_entries);
    try zon_util.writeIndent(writer, depth);
    try writer.writeAll(".artifacts = .{");
    if (entries.len == 0) {
        try writer.writeAll("},\n");
        return;
    }
    try writer.writeAll("\n");
    for (sorted_entries) |entry| {
        try zon_util.writeIndent(writer, depth + 1);
        try writer.print(".{{ .kind = .{s}, .path = ", .{entry.kind.asText()});
        try zon_util.writeString(writer, entry.path);
        try writer.writeAll(" },\n");
    }
    try zon_util.writeIndent(writer, depth);
    try writer.writeAll("},\n");
}

fn writeEdges(writer: *std.Io.Writer, allocator: std.mem.Allocator, depth: usize, entries: []const Edge) !void {
    const sorted_entries = try sortedEdgesAlloc(allocator, entries);
    defer allocator.free(sorted_entries);
    try zon_util.writeIndent(writer, depth);
    try writer.writeAll(".deps = .{");
    if (entries.len == 0) {
        try writer.writeAll("},\n");
        return;
    }
    try writer.writeAll("\n");
    for (sorted_entries) |entry| {
        try zon_util.writeIndent(writer, depth + 1);
        try zon_util.writeQuotedFieldName(writer, entry.name);
        try writer.writeAll(" = .{ .dep = ");
        try zon_util.writeString(writer, entry.dep);
        try writer.writeAll(", .target = ");
        try zon_util.writeString(writer, entry.target);
        try writer.print(", .role = .{s}, .visibility = .{s} }},\n", .{ entry.role.asText(), entry.visibility.asText() });
    }
    try zon_util.writeIndent(writer, depth);
    try writer.writeAll("},\n");
}

fn writeInstalls(writer: *std.Io.Writer, allocator: std.mem.Allocator, depth: usize, entries: []const Install) !void {
    const sorted_entries = try sortedInstallsAlloc(allocator, entries);
    defer allocator.free(sorted_entries);
    try zon_util.writeIndent(writer, depth);
    try writer.writeAll(".installs = .{");
    if (entries.len == 0) {
        try writer.writeAll("},\n");
        return;
    }
    try writer.writeAll("\n");
    for (sorted_entries) |entry| {
        try zon_util.writeIndent(writer, depth + 1);
        try writer.writeAll(".{ .source = ");
        try zon_util.writeString(writer, entry.source);
        try writer.print(", .dir = .{s}, .subdir = ", .{entry.dir.asText()});
        try zon_util.writeString(writer, entry.subdir);
        try writer.writeAll(", .dest = ");
        try zon_util.writeString(writer, entry.dest);
        try writer.writeAll(" },\n");
    }
    try zon_util.writeIndent(writer, depth);
    try writer.writeAll("},\n");
}

fn sortedNamedOptionValuesAlloc(allocator: std.mem.Allocator, options: []const model.NamedOptionValue) ![]const model.NamedOptionValue {
    const sorted = try allocator.dupe(model.NamedOptionValue, options);
    sortSlice(model.NamedOptionValue, sorted, namedOptionValueLessThan);
    return sorted;
}

fn sortedDependencyAliasesAlloc(allocator: std.mem.Allocator, dependency_aliases: []const DependencyAlias) ![]const DependencyAlias {
    const sorted = try allocator.dupe(DependencyAlias, dependency_aliases);
    sortSlice(DependencyAlias, sorted, dependencyAliasLessThan);
    return sorted;
}

fn sortedTargetsAlloc(allocator: std.mem.Allocator, targets: []const Target) ![]const Target {
    const sorted = try allocator.dupe(Target, targets);
    sortSlice(Target, sorted, targetLessThan);
    return sorted;
}

fn sortedIncludeDirsAlloc(allocator: std.mem.Allocator, include_dirs: []const IncludeDir) ![]const IncludeDir {
    const sorted = try allocator.dupe(IncludeDir, include_dirs);
    sortSlice(IncludeDir, sorted, includeDirLessThan);
    return sorted;
}

fn sortedCompileDefinitionsAlloc(allocator: std.mem.Allocator, definitions: []const CompileDefinition) ![]const CompileDefinition {
    const sorted = try allocator.dupe(CompileDefinition, definitions);
    sortSlice(CompileDefinition, sorted, compileDefinitionLessThan);
    return sorted;
}

fn sortedSystemLibsAlloc(allocator: std.mem.Allocator, system_libs: []const SystemLib) ![]const SystemLib {
    const sorted = try allocator.dupe(SystemLib, system_libs);
    sortSlice(SystemLib, sorted, systemLibLessThan);
    return sorted;
}

fn sortedArtifactsAlloc(allocator: std.mem.Allocator, artifacts: []const Artifact) ![]const Artifact {
    const sorted = try allocator.dupe(Artifact, artifacts);
    sortSlice(Artifact, sorted, artifactLessThan);
    return sorted;
}

fn sortedEdgesAlloc(allocator: std.mem.Allocator, edges: []const Edge) ![]const Edge {
    const sorted = try allocator.dupe(Edge, edges);
    sortSlice(Edge, sorted, edgeLessThan);
    return sorted;
}

fn sortedInstallsAlloc(allocator: std.mem.Allocator, installs: []const Install) ![]const Install {
    const sorted = try allocator.dupe(Install, installs);
    sortSlice(Install, sorted, installLessThan);
    return sorted;
}

fn namedOptionValueLessThan(a: model.NamedOptionValue, b: model.NamedOptionValue) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn dependencyAliasLessThan(a: DependencyAlias, b: DependencyAlias) bool {
    return std.mem.order(u8, a.alias, b.alias) == .lt;
}

fn targetLessThan(a: Target, b: Target) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn includeDirLessThan(a: IncludeDir, b: IncludeDir) bool {
    const path_order = std.mem.order(u8, a.path, b.path);
    if (path_order != .eq) return path_order == .lt;
    return @intFromEnum(a.visibility) < @intFromEnum(b.visibility);
}

fn compileDefinitionLessThan(a: CompileDefinition, b: CompileDefinition) bool {
    const key_order = std.mem.order(u8, a.key, b.key);
    if (key_order != .eq) return key_order == .lt;
    const value_order = zon_util.compareOptionValue(a.value, b.value);
    if (value_order != .eq) return value_order == .lt;
    return @intFromEnum(a.visibility) < @intFromEnum(b.visibility);
}

fn systemLibLessThan(a: SystemLib, b: SystemLib) bool {
    const name_order = std.mem.order(u8, a.name, b.name);
    if (name_order != .eq) return name_order == .lt;
    return @intFromEnum(a.visibility) < @intFromEnum(b.visibility);
}

fn artifactLessThan(a: Artifact, b: Artifact) bool {
    if (@intFromEnum(a.kind) != @intFromEnum(b.kind)) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn edgeLessThan(a: Edge, b: Edge) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn installLessThan(a: Install, b: Install) bool {
    const source_order = std.mem.order(u8, a.source, b.source);
    if (source_order != .eq) return source_order == .lt;
    const subdir_order = std.mem.order(u8, a.subdir, b.subdir);
    if (subdir_order != .eq) return subdir_order == .lt;
    return std.mem.order(u8, a.dest, b.dest) == .lt;
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
