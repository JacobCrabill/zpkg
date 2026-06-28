const std = @import("std");

pub const validate = @import("validate.zig");
pub const ValidationError = validate.ValidationError;
pub const ValidationResult = validate.ValidationResult;
pub const ValidationIssue = validate.ValidationIssue;
pub const DeclaredTarget = validate.DeclaredTarget;

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
    default,
    static,
    dynamic,

    pub fn asText(self: Linkage) []const u8 {
        return @tagName(self);
    }
};

pub const EdgeRole = enum {
    link,
    tool,
    build,
    test_dep,

    pub fn asText(self: EdgeRole) []const u8 {
        return @tagName(self);
    }
};

pub const Visibility = enum {
    public,
    private,

    pub fn asText(self: Visibility) []const u8 {
        return @tagName(self);
    }
};

pub const TargetEdge = struct {
    dep_alias: []const u8,
    target_name: []const u8,
    role: EdgeRole,
};

pub const IncludeDir = struct {
    path: []const u8,
    visibility: Visibility,
};

pub const CompileDefinition = struct {
    name: []const u8,
    value: ?[]const u8,
    visibility: Visibility,
};

pub const OptionSnapshot = struct {
    name: []const u8,
    value: []const u8,
};

pub const DepAliasEntry = struct {
    alias: []const u8,
    package_id: []const u8,
};

/// A target registered with the Package. All list fields use ArrayList
/// (unmanaged style in Zig 0.16) for in-place accumulation.
/// Always mutate via Package helpers to ensure memory is properly owned.
pub const RegisteredTarget = struct {
    name: []const u8,
    kind: TargetKind,
    linkage: Linkage,
    exported: bool,
    edges: std.ArrayList(TargetEdge),
    include_dirs: std.ArrayList(IncludeDir),
    compile_defs: std.ArrayList(CompileDefinition),
    artifacts: std.ArrayList([]const u8),
    system_libs: std.ArrayList([]const u8),
    resources: std.ArrayList([]const u8),

    pub fn deinit(self: *RegisteredTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.edges.items) |e| {
            allocator.free(e.dep_alias);
            allocator.free(e.target_name);
        }
        self.edges.deinit(allocator);
        for (self.include_dirs.items) |d| allocator.free(d.path);
        self.include_dirs.deinit(allocator);
        for (self.compile_defs.items) |d| {
            allocator.free(d.name);
            if (d.value) |v| allocator.free(v);
        }
        self.compile_defs.deinit(allocator);
        for (self.artifacts.items) |a| allocator.free(a);
        self.artifacts.deinit(allocator);
        for (self.system_libs.items) |s| allocator.free(s);
        self.system_libs.deinit(allocator);
        for (self.resources.items) |r| allocator.free(r);
        self.resources.deinit(allocator);
    }
};

pub const Package = struct {
    allocator: std.mem.Allocator,
    package_id: []const u8,
    domain: []const u8,
    version: []const u8,
    targets: std.ArrayList(RegisteredTarget),
    selected_options: std.ArrayList(OptionSnapshot),
    dep_aliases: std.ArrayList(DepAliasEntry),

    pub fn init(
        allocator: std.mem.Allocator,
        package_id: []const u8,
        domain: []const u8,
        version: []const u8,
    ) Package {
        return .{
            .allocator = allocator,
            .package_id = package_id,
            .domain = domain,
            .version = version,
            .targets = .empty,
            .selected_options = .empty,
            .dep_aliases = .empty,
        };
    }

    pub fn deinit(self: *Package) void {
        for (self.targets.items) |*t| t.deinit(self.allocator);
        self.targets.deinit(self.allocator);
        for (self.selected_options.items) |o| {
            self.allocator.free(o.name);
            self.allocator.free(o.value);
        }
        self.selected_options.deinit(self.allocator);
        for (self.dep_aliases.items) |a| {
            self.allocator.free(a.alias);
            self.allocator.free(a.package_id);
        }
        self.dep_aliases.deinit(self.allocator);
    }

    /// Register a new target and return a pointer to it for further configuration.
    pub fn addTarget(
        self: *Package,
        name: []const u8,
        kind: TargetKind,
        linkage: Linkage,
        exported: bool,
    ) !*RegisteredTarget {
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);

        try self.targets.append(self.allocator, .{
            .name = name_owned,
            .kind = kind,
            .linkage = linkage,
            .exported = exported,
            .edges = .empty,
            .include_dirs = .empty,
            .compile_defs = .empty,
            .artifacts = .empty,
            .system_libs = .empty,
            .resources = .empty,
        });
        return &self.targets.items[self.targets.items.len - 1];
    }

    /// Add an edge to an already-registered target (looked up by name).
    pub fn addEdge(
        self: *Package,
        target_name: []const u8,
        edge: TargetEdge,
    ) !void {
        const t = self.findTarget(target_name) orelse return error.TargetNotFound;
        const dep_alias_owned = try self.allocator.dupe(u8, edge.dep_alias);
        errdefer self.allocator.free(dep_alias_owned);
        const tgt_name_owned = try self.allocator.dupe(u8, edge.target_name);
        errdefer self.allocator.free(tgt_name_owned);
        try t.edges.append(self.allocator, .{
            .dep_alias = dep_alias_owned,
            .target_name = tgt_name_owned,
            .role = edge.role,
        });
    }

    /// Add an include dir to a target; dups the path string.
    pub fn addIncludeDir(
        self: *Package,
        target_name: []const u8,
        dir: IncludeDir,
    ) !void {
        const t = self.findTarget(target_name) orelse return error.TargetNotFound;
        const path_owned = try self.allocator.dupe(u8, dir.path);
        errdefer self.allocator.free(path_owned);
        try t.include_dirs.append(self.allocator, .{ .path = path_owned, .visibility = dir.visibility });
    }

    /// Add an artifact filename to a target; dups the name string.
    pub fn addArtifact(self: *Package, target_name: []const u8, name: []const u8) !void {
        const t = self.findTarget(target_name) orelse return error.TargetNotFound;
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        try t.artifacts.append(self.allocator, name_owned);
    }

    /// Record a build option snapshot (name + stringified value).
    pub fn addOption(self: *Package, name: []const u8, value: []const u8) !void {
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        const value_owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_owned);
        try self.selected_options.append(self.allocator, .{ .name = name_owned, .value = value_owned });
    }

    /// Record a dependency alias mapping.
    pub fn addDepAlias(self: *Package, alias: []const u8, package_id: []const u8) !void {
        const alias_owned = try self.allocator.dupe(u8, alias);
        errdefer self.allocator.free(alias_owned);
        const pkg_id_owned = try self.allocator.dupe(u8, package_id);
        errdefer self.allocator.free(pkg_id_owned);
        try self.dep_aliases.append(self.allocator, .{ .alias = alias_owned, .package_id = pkg_id_owned });
    }

    fn findTarget(self: *Package, name: []const u8) ?*RegisteredTarget {
        for (self.targets.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    /// Emit zpkg.graph.zon to the given path.
    /// `io` should be `b.graph.io` when called from a build.zig.
    pub fn emit(self: *Package, io: std.Io, path: []const u8) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;

        try w.writeAll(".{\n");
        try w.writeAll("    .schema = 1,\n");
        try w.print("    .package = \"{s}\",\n", .{self.package_id});
        try w.print("    .domain = .{s},\n", .{self.domain});
        try w.print("    .version = \"{s}\",\n", .{self.version});

        // selected_options (sorted by name for determinism)
        const sorted_opts = try self.allocator.dupe(OptionSnapshot, self.selected_options.items);
        defer self.allocator.free(sorted_opts);
        std.sort.pdq(OptionSnapshot, sorted_opts, {}, struct {
            fn lt(_: void, a: OptionSnapshot, b: OptionSnapshot) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lt);

        try w.writeAll("    .selected_options = .{");
        if (sorted_opts.len == 0) {
            try w.writeAll("},\n");
        } else {
            try w.writeAll("\n");
            for (sorted_opts) |o| {
                if (isBareIdentifier(o.name)) {
                    try w.print("        .{s} = \"{s}\",\n", .{ o.name, o.value });
                } else {
                    try w.print("        .@\"{s}\" = \"{s}\",\n", .{ o.name, o.value });
                }
            }
            try w.writeAll("    },\n");
        }

        // dep_alias_mapping (sorted by alias for determinism)
        const sorted_aliases = try self.allocator.dupe(DepAliasEntry, self.dep_aliases.items);
        defer self.allocator.free(sorted_aliases);
        std.sort.pdq(DepAliasEntry, sorted_aliases, {}, struct {
            fn lt(_: void, a: DepAliasEntry, b: DepAliasEntry) bool {
                return std.mem.order(u8, a.alias, b.alias) == .lt;
            }
        }.lt);

        try w.writeAll("    .dep_alias_mapping = .{");
        if (sorted_aliases.len == 0) {
            try w.writeAll("},\n");
        } else {
            try w.writeAll("\n");
            for (sorted_aliases) |a| {
                if (isBareIdentifier(a.alias)) {
                    try w.print("        .{s} = \"{s}\",\n", .{ a.alias, a.package_id });
                } else {
                    try w.print("        .@\"{s}\" = \"{s}\",\n", .{ a.alias, a.package_id });
                }
            }
            try w.writeAll("    },\n");
        }

        // targets (sorted by name for determinism — sort indices to avoid
        // shallow-copying structs that contain ArrayList headers)
        const sorted_indices = try self.allocator.alloc(usize, self.targets.items.len);
        defer self.allocator.free(sorted_indices);
        for (sorted_indices, 0..) |*idx, i| idx.* = i;
        std.mem.sort(usize, sorted_indices, self.targets.items, struct {
            fn lessThan(targets: []const RegisteredTarget, a: usize, b: usize) bool {
                return std.mem.order(u8, targets[a].name, targets[b].name) == .lt;
            }
        }.lessThan);

        try w.writeAll("    .targets = .{");
        if (sorted_indices.len == 0) {
            try w.writeAll("},\n");
        } else {
            try w.writeAll("\n");
            for (sorted_indices) |idx| {
                try writeTarget(w, &self.targets.items[idx]);
            }
            try w.writeAll("    },\n");
        }

        try w.writeAll("}\n");

        const contents = try aw.toOwnedSlice();
        defer self.allocator.free(contents);

        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = contents,
        });
    }
};

fn writeTarget(w: anytype, t: *const RegisteredTarget) !void {
    if (isBareIdentifier(t.name)) {
        try w.print("        .{s} = .{{\n", .{t.name});
    } else {
        try w.print("        .@\"{s}\" = .{{\n", .{t.name});
    }
    try w.print("            .kind = .{s},\n", .{t.kind.asText()});
    try w.print("            .linkage = .{s},\n", .{t.linkage.asText()});
    try w.print("            .exported = {},\n", .{t.exported});

    try w.writeAll("            .edges = .{");
    if (t.edges.items.len == 0) {
        try w.writeAll("},\n");
    } else {
        try w.writeAll("\n");
        for (t.edges.items) |e| {
            try w.print(
                "                .{{ .dep_alias = \"{s}\", .target_name = \"{s}\", .role = .{s} }},\n",
                .{ e.dep_alias, e.target_name, e.role.asText() },
            );
        }
        try w.writeAll("            },\n");
    }

    try w.writeAll("            .include_dirs = .{");
    if (t.include_dirs.items.len == 0) {
        try w.writeAll("},\n");
    } else {
        try w.writeAll("\n");
        for (t.include_dirs.items) |d| {
            try w.print(
                "                .{{ .path = \"{s}\", .visibility = .{s} }},\n",
                .{ d.path, d.visibility.asText() },
            );
        }
        try w.writeAll("            },\n");
    }

    try w.writeAll("            .compile_defs = .{");
    if (t.compile_defs.items.len == 0) {
        try w.writeAll("},\n");
    } else {
        try w.writeAll("\n");
        for (t.compile_defs.items) |d| {
            if (d.value) |v| {
                try w.print(
                    "                .{{ .name = \"{s}\", .value = \"{s}\", .visibility = .{s} }},\n",
                    .{ d.name, v, d.visibility.asText() },
                );
            } else {
                try w.print(
                    "                .{{ .name = \"{s}\", .value = null, .visibility = .{s} }},\n",
                    .{ d.name, d.visibility.asText() },
                );
            }
        }
        try w.writeAll("            },\n");
    }

    try w.writeAll("            .artifacts = .{");
    if (t.artifacts.items.len == 0) {
        try w.writeAll("},\n");
    } else {
        try w.writeAll("\n");
        for (t.artifacts.items) |a| {
            try w.print("                \"{s}\",\n", .{a});
        }
        try w.writeAll("            },\n");
    }

    try w.writeAll("            .system_libs = .{");
    if (t.system_libs.items.len == 0) {
        try w.writeAll("},\n");
    } else {
        try w.writeAll("\n");
        for (t.system_libs.items) |s| {
            try w.print("                \"{s}\",\n", .{s});
        }
        try w.writeAll("            },\n");
    }

    try w.writeAll("            .resources = .{");
    if (t.resources.items.len == 0) {
        try w.writeAll("},\n");
    } else {
        try w.writeAll("\n");
        for (t.resources.items) |r| {
            try w.print("                \"{s}\",\n", .{r});
        }
        try w.writeAll("            },\n");
    }

    try w.writeAll("        },\n");
}

fn isBareIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    }
    return true;
}

// ---- Unit tests ----

test "addTarget registers target with correct fields" {
    const allocator = std.testing.allocator;
    var pkg = Package.init(allocator, "zpkg.test.pkg", "target", "1.0.0.0");
    defer pkg.deinit();

    const t = try pkg.addTarget("mylib", .library, .dynamic, true);
    try std.testing.expectEqualStrings("mylib", t.name);
    try std.testing.expect(t.kind == .library);
    try std.testing.expect(t.linkage == .dynamic);
    try std.testing.expect(t.exported == true);
    try std.testing.expect(t.edges.items.len == 0);
    try std.testing.expect(pkg.targets.items.len == 1);
}

test "emit writes valid ZON with expected content" {
    const allocator = std.testing.allocator;
    var pkg = Package.init(allocator, "zpkg.test.emit", "target", "0.1.0.0");
    defer pkg.deinit();

    _ = try pkg.addTarget("hello", .library, .dynamic, true);
    try pkg.addIncludeDir("hello", .{ .path = "include", .visibility = .public });
    try pkg.addArtifact("hello", "libhello.so");
    try pkg.addOption("shared", "true");

    var threaded: std.Io.Threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    const tmp_path = "/tmp/zpkg_test_emit.graph.zon";
    try pkg.emit(io, tmp_path);

    const contents = try std.Io.Dir.cwd().readFileAlloc(io, tmp_path, allocator, .unlimited);
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, ".schema = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "zpkg.test.emit") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "selected_options") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, ".shared = \"true\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "dep_alias_mapping") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, ".hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, ".kind = .library") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "libhello.so") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, ".path = \"include\"") != null);
}
