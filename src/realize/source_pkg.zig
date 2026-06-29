const std = @import("std");
const zon_util = @import("../schema/zon_util.zig");

pub const DepPathMap = std.StringHashMap([]const u8);

pub const SourcePkgRealize = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) SourcePkgRealize {
        return .{ .allocator = allocator, .io = io };
    }

    /// Realize a source package at `dest_dir`.
    ///
    /// - Creates a symlink from dest_dir/<entry> → source_dir/<entry> for each
    ///   entry in the source directory.  (Full-dir symlink if scanning fails.)
    /// - Writes a generated build.zig.zon at dest_dir with local path deps.
    /// - Copies zpkg.graph.zon into dest_dir if it exists in source_dir.
    pub fn realize(
        self: *SourcePkgRealize,
        source_dir: []const u8,
        dest_dir: []const u8,
        pkg_name: []const u8,  // kept for caller compatibility; name is now sourced from build.zig.zon
        dep_realized_paths: DepPathMap,
    ) !void {
        _ = pkg_name;
        // Symlink every top-level entry from source into dest.
        self.symlinkEntries(source_dir, dest_dir) catch {
            // Fallback: symlink entire source_dir as "src"
            const link_path = try std.Io.Dir.path.join(self.allocator, &.{ dest_dir, "src" });
            defer self.allocator.free(link_path);
            std.Io.Dir.symLinkAbsolute(self.io, source_dir, link_path, .{}) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        };

        // Read all static fields from the source build.zig.zon (everything except
        // .dependencies, which we replace with workspace-local paths).
        const source_fields = try self.readSourceFields(source_dir);
        defer source_fields.deinitOwned(self.allocator);

        // Collect extra build-tool deps (e.g. `zpkg-build`) not in the resolved map.
        var extra_deps = try self.readExtraDepsFromSource(source_dir, dep_realized_paths);
        defer {
            var it = extra_deps.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                self.allocator.free(e.value_ptr.*);
            }
            extra_deps.deinit();
        }

        const zon_content = try self.generateBuildZigZon(dest_dir, dep_realized_paths, extra_deps, source_fields);
        defer self.allocator.free(zon_content);
        try self.writeFile(dest_dir, "build.zig.zon", zon_content);

        // Copy zpkg.graph.zon if present
        self.copyGraphZon(source_dir, dest_dir) catch {};
    }

    fn symlinkEntries(self: *SourcePkgRealize, source_dir: []const u8, dest_dir: []const u8) !void {
        const src_dir = try std.Io.Dir.openDirAbsolute(self.io, source_dir, .{ .iterate = true });
        defer src_dir.close(self.io);

        var iter = src_dir.iterate();
        while (try iter.next(self.io)) |entry| {
            // Skip build.zig.zon — we generate our own
            if (std.mem.eql(u8, entry.name, "build.zig.zon")) continue;
            // Skip zpkg.graph.zon — copied separately
            if (std.mem.eql(u8, entry.name, "zpkg.graph.zon")) continue;

            const target = try std.Io.Dir.path.join(self.allocator, &.{ source_dir, entry.name });
            defer self.allocator.free(target);
            const link = try std.Io.Dir.path.join(self.allocator, &.{ dest_dir, entry.name });
            defer self.allocator.free(link);

            std.Io.Dir.symLinkAbsolute(self.io, target, link, .{}) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }

    fn copyGraphZon(self: *SourcePkgRealize, source_dir: []const u8, dest_dir: []const u8) !void {
        const src_path = try std.Io.Dir.path.join(self.allocator, &.{ source_dir, "zpkg.graph.zon" });
        defer self.allocator.free(src_path);

        const src_dir_path = std.Io.Dir.path.dirname(src_path) orelse ".";
        const src_dir_obj = try std.Io.Dir.openDirAbsolute(self.io, src_dir_path, .{});
        defer src_dir_obj.close(self.io);

        const content = try src_dir_obj.readFileAlloc(self.io, "zpkg.graph.zon", self.allocator, .limited(1 * 1024 * 1024));
        defer self.allocator.free(content);

        try self.writeFile(dest_dir, "zpkg.graph.zon", content);
    }

    fn writeFile(self: *SourcePkgRealize, dir_path: []const u8, sub_path: []const u8, content: []const u8) !void {
        const dir = try std.Io.Dir.openDirAbsolute(self.io, dir_path, .{});
        defer dir.close(self.io);
        try dir.writeFile(self.io, .{ .sub_path = sub_path, .data = content });
    }

    pub const SourceFields = struct {
        name: []const u8,
        fingerprint: ?u64,
        version: []const u8,
        minimum_zig_version: ?[]const u8,
        paths: [][]const u8,

        pub fn deinitOwned(self: SourceFields, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.version);
            if (self.minimum_zig_version) |v| allocator.free(v);
            for (self.paths) |p| allocator.free(p);
            allocator.free(self.paths);
        }
    };

    /// Read all static fields from the source build.zig.zon that must be copied
    /// verbatim into the workspace file.  Caller owns all slice fields (use
    /// `SourceFields.deinitOwned` to free).
    pub fn readSourceFields(self: *SourcePkgRealize, source_dir: []const u8) !SourceFields {
        const src_dir = try std.Io.Dir.openDirAbsolute(self.io, source_dir, .{});
        defer src_dir.close(self.io);
        const content = try src_dir.readFileAlloc(self.io, "build.zig.zon", self.allocator, .limited(64 * 1024));
        defer self.allocator.free(content);
        const sentinel = try self.allocator.dupeZ(u8, content);
        defer self.allocator.free(sentinel);

        var doc = try zon_util.parseDocument(self.allocator, sentinel);
        defer doc.deinit(self.allocator);
        const root = try zon_util.Object.fromNode(&doc, .root);

        // .name may be an enum literal (.my_pkg) or a quoted string ("my_pkg").
        const name_node = try root.require("name");
        const name = zon_util.parseEnumLiteralAlloc(self.allocator, &doc, name_node) catch blk: {
            // Fall back to string: re-wrap decoded bytes in quotes.
            const inner = try zon_util.parseNonEmptyStringAlloc(self.allocator, &doc, name_node);
            defer self.allocator.free(inner);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{inner});
        };
        errdefer self.allocator.free(name);

        const version_node = try root.require("version");
        const version = blk: {
            const inner = try zon_util.parseNonEmptyStringAlloc(self.allocator, &doc, version_node);
            defer self.allocator.free(inner);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{inner});
        };
        errdefer self.allocator.free(version);

        const minimum_zig_version: ?[]const u8 = if (root.get("minimum_zig_version")) |n| blk: {
            const inner = try zon_util.parseNonEmptyStringAlloc(self.allocator, &doc, n);
            defer self.allocator.free(inner);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{inner});
        } else null;
        errdefer if (minimum_zig_version) |v| self.allocator.free(v);

        const fingerprint: ?u64 = if (root.get("fingerprint")) |n| blk: {
            break :blk try zon_util.parseUint(&doc, n);
        } else null;

        const paths_node = try root.require("paths");
        const paths_arr = try zon_util.Array.fromNode(&doc, paths_node);
        const paths = try self.allocator.alloc([]const u8, paths_arr.len());
        errdefer self.allocator.free(paths);
        var paths_filled: usize = 0;
        errdefer for (paths[0..paths_filled]) |p| self.allocator.free(p);
        for (0..paths_arr.len()) |i| {
            paths[i] = try zon_util.parseNonEmptyStringAlloc(self.allocator, &doc, paths_arr.at(i));
            paths_filled += 1;
        }

        return .{
            .name = name,
            .fingerprint = fingerprint,
            .version = version,
            .minimum_zig_version = minimum_zig_version,
            .paths = paths,
        };
    }

    /// Parse the source build.zig.zon and return a map of dep_name → absolute_path
    /// for dependencies NOT already present in `resolved_deps`.  These are build-tool
    /// deps (e.g. `zpkg-build`) that the source build.zig needs but that zpkg doesn't
    /// manage through the lockfile.  Caller owns all keys and values in the returned map.
    pub fn readExtraDepsFromSource(
        self: *SourcePkgRealize,
        source_dir: []const u8,
        resolved_deps: DepPathMap,
    ) !DepPathMap {
        var result = DepPathMap.init(self.allocator);
        errdefer {
            var it = result.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                self.allocator.free(e.value_ptr.*);
            }
            result.deinit();
        }

        const src_dir_obj = std.Io.Dir.openDirAbsolute(self.io, source_dir, .{}) catch return result;
        defer src_dir_obj.close(self.io);
        const content = src_dir_obj.readFileAlloc(self.io, "build.zig.zon", self.allocator, .limited(64 * 1024)) catch return result;
        defer self.allocator.free(content);
        const sentinel = self.allocator.dupeZ(u8, content) catch return result;
        defer self.allocator.free(sentinel);

        var doc = zon_util.parseDocument(self.allocator, sentinel) catch return result;
        defer doc.deinit(self.allocator);
        const root = zon_util.Object.fromNode(&doc, .root) catch return result;

        const deps_node = root.get("dependencies") orelse return result;
        const deps_obj = zon_util.Object.fromNode(&doc, deps_node) catch return result;

        for (0..deps_obj.fieldCount()) |i| {
            const dep_name = deps_obj.fieldName(i);
            if (resolved_deps.contains(dep_name)) continue;

            const dep_val_obj = zon_util.Object.fromNode(&doc, deps_obj.fieldNode(i)) catch continue;
            const path_node = dep_val_obj.get("path") orelse continue;
            const rel_path = zon_util.parseNonEmptyStringAlloc(self.allocator, &doc, path_node) catch continue;
            defer self.allocator.free(rel_path);

            const abs_path = std.fs.path.resolve(self.allocator, &.{ source_dir, rel_path }) catch continue;
            errdefer self.allocator.free(abs_path);

            const key = self.allocator.dupe(u8, dep_name) catch {
                self.allocator.free(abs_path);
                continue;
            };
            errdefer self.allocator.free(key);

            try result.put(key, abs_path);
        }

        return result;
    }

    /// Generate the build.zig.zon content.  All static fields are copied verbatim
    /// from `fields` (sourced from the package's real build.zig.zon); only
    /// `.dependencies` is replaced with workspace-local paths.
    ///
    /// Determinism guarantee: dependency entries are emitted in lexicographic order.
    pub fn generateBuildZigZon(
        self: *SourcePkgRealize,
        dest_dir: []const u8,
        dep_realized_paths: DepPathMap,
        extra_deps: DepPathMap,
        fields: SourceFields,
    ) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;

        try w.writeAll(".{\n");
        try w.print("    .name = {s},\n", .{fields.name});
        try w.print("    .version = {s},\n", .{fields.version});
        if (fields.fingerprint) |fp| {
            try w.print("    .fingerprint = 0x{x:0>16},\n", .{fp});
        }
        if (fields.minimum_zig_version) |mzv| {
            try w.print("    .minimum_zig_version = {s},\n", .{mzv});
        }
        try w.writeAll("    .dependencies = .{\n");

        // Collect all dep keys (resolved + extra), sort for stable output.
        var keys = std.ArrayList([]const u8).empty;
        defer keys.deinit(self.allocator);
        var key_iter = dep_realized_paths.keyIterator();
        while (key_iter.next()) |k| try keys.append(self.allocator, k.*);
        var extra_iter = extra_deps.keyIterator();
        while (extra_iter.next()) |k| try keys.append(self.allocator, k.*);
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (keys.items) |key| {
            const abs_path = dep_realized_paths.get(key) orelse extra_deps.get(key).?;
            const rel_path = try relativePath(self.allocator, dest_dir, abs_path);
            defer self.allocator.free(rel_path);
            if (isBareIdentifier(key)) {
                try w.print("        .{s} = .{{ .path = \"{s}\" }},\n", .{ key, rel_path });
            } else {
                try w.print("        .@\"{s}\" = .{{ .path = \"{s}\" }},\n", .{ key, rel_path });
            }
        }

        try w.writeAll("    },\n");
        try w.writeAll("    .paths = .{\n");
        for (fields.paths) |p| {
            try w.print("        \"{s}\",\n", .{p});
        }
        try w.writeAll("    },\n");
        try w.writeAll("}\n");

        return try aw.toOwnedSlice();
    }
};

/// Returns true if `name` is a valid Zig bare identifier (no quoting needed).
/// Rejects empty strings, names starting with digits, names containing
/// non-alphanumeric/non-underscore characters, and Zig keywords.
fn isBareIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        const ok = switch (c) {
            'a'...'z', 'A'...'Z', '_' => true,
            '0'...'9' => i > 0,
            else => false,
        };
        if (!ok) return false;
    }
    // Reject Zig keywords that would be invalid as bare field names.
    const keywords = [_][]const u8{
        "addrspace", "align",    "allowzero", "and",      "anyframe",
        "anytype",   "asm",      "async",     "await",    "break",
        "callconv",  "catch",    "comptime",  "const",    "continue",
        "defer",     "else",     "enum",      "errdefer", "error",
        "export",    "extern",   "fn",        "for",      "if",
        "inline",    "linksection", "noalias", "noinline", "nosuspend",
        "opaque",    "or",       "orelse",    "packed",   "pub",
        "resume",    "return",   "struct",    "suspend",  "switch",
        "test",      "threadlocal", "try",    "union",    "unreachable",
        "usingnamespace", "var", "volatile",  "while",
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, name, kw)) return false;
    }
    return true;
}

/// Compute a relative path from `from_dir` to `to_path`.
/// Both must be absolute.  Caller owns the returned slice.
fn relativePath(allocator: std.mem.Allocator, from_dir: []const u8, to_path: []const u8) ![]u8 {
    // Count how many components we need to go up from from_dir
    var from_it = std.mem.splitScalar(u8, from_dir, '/');
    var to_it = std.mem.splitScalar(u8, to_path, '/');

    // Find common prefix length (in components)
    var from_parts: std.ArrayList([]const u8) = .empty;
    defer from_parts.deinit(allocator);
    var to_parts: std.ArrayList([]const u8) = .empty;
    defer to_parts.deinit(allocator);

    while (from_it.next()) |part| {
        if (part.len > 0) try from_parts.append(allocator, part);
    }
    while (to_it.next()) |part| {
        if (part.len > 0) try to_parts.append(allocator, part);
    }

    var common: usize = 0;
    while (common < from_parts.items.len and common < to_parts.items.len) {
        if (!std.mem.eql(u8, from_parts.items[common], to_parts.items[common])) break;
        common += 1;
    }

    const up_count = from_parts.items.len - common;
    const remaining = to_parts.items[common..];

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    for (0..up_count) |i| {
        if (i > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, "..");
    }
    for (remaining) |part| {
        if (result.items.len > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, part);
    }

    if (result.items.len == 0) {
        try result.append(allocator, '.');
    }

    return result.toOwnedSlice(allocator);
}

test "generateBuildZigZon produces correct content" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var realizer = SourcePkgRealize.init(allocator, io);
    var dep_map = DepPathMap.init(allocator);
    defer dep_map.deinit();
    try dep_map.put("hello_lib", "/project/.zpkg/work/debug-native/deps/zpkg.example.hello_lib#target");

    var empty_extra = DepPathMap.init(allocator);
    defer empty_extra.deinit();
    const fields = SourcePkgRealize.SourceFields{
        .name = ".hello_app",
        .fingerprint = null,
        .version = "\"0.1.0\"",
        .minimum_zig_version = "\"0.16.0\"",
        .paths = @constCast(&[_][]const u8{ "build.zig", "src" }),
    };
    const content = try realizer.generateBuildZigZon(
        "/project/.zpkg/work/debug-native/root",
        dep_map,
        empty_extra,
        fields,
    );
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, ".name = .hello_app") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".version = \"0.1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".minimum_zig_version = \"0.16.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".paths = .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "hello_lib") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".path =") != null);
}

test "generateBuildZigZon output is deterministic with multiple deps" {
    // Two maps with the same entries inserted in opposite order must produce
    // identical ZON output.  This verifies that we sort before emitting.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const dest = "/project/.zpkg/work/debug-native/root";
    const dep_a_path = "/project/.zpkg/work/debug-native/deps/zpkg.example.alpha";
    const dep_b_path = "/project/.zpkg/work/debug-native/deps/zpkg.example.beta";

    var map1 = DepPathMap.init(allocator);
    defer map1.deinit();
    try map1.put("alpha", dep_a_path);
    try map1.put("beta", dep_b_path);

    var map2 = DepPathMap.init(allocator);
    defer map2.deinit();
    // Insert in reverse order — if we relied on HashMap order, outputs would differ.
    try map2.put("beta", dep_b_path);
    try map2.put("alpha", dep_a_path);

    const fields = SourcePkgRealize.SourceFields{
        .name = ".mypkg",
        .fingerprint = null,
        .version = "\"0.0.0\"",
        .minimum_zig_version = null,
        .paths = @constCast(&[_][]const u8{"."}),
    };
    var empty1 = DepPathMap.init(allocator);
    defer empty1.deinit();
    var empty2 = DepPathMap.init(allocator);
    defer empty2.deinit();
    var r1 = SourcePkgRealize.init(allocator, io);
    const out1 = try r1.generateBuildZigZon(dest, map1, empty1, fields);
    defer allocator.free(out1);

    var r2 = SourcePkgRealize.init(allocator, io);
    const out2 = try r2.generateBuildZigZon(dest, map2, empty2, fields);
    defer allocator.free(out2);

    try std.testing.expectEqualStrings(out1, out2);

    // Also verify alpha appears before beta in the output.
    const alpha_pos = std.mem.indexOf(u8, out1, "alpha").?;
    const beta_pos = std.mem.indexOf(u8, out1, "beta").?;
    try std.testing.expect(alpha_pos < beta_pos);
}

test "relativePath computes sibling path" {
    const allocator = std.testing.allocator;
    const rel = try relativePath(allocator, "/a/b/c", "/a/b/d");
    defer allocator.free(rel);
    try std.testing.expectEqualStrings("../d", rel);
}

test "relativePath computes deeper path" {
    const allocator = std.testing.allocator;
    const rel = try relativePath(allocator, "/project/.zpkg/work/debug-native/root", "/project/.zpkg/work/debug-native/deps/mypkg");
    defer allocator.free(rel);
    try std.testing.expectEqualStrings("../deps/mypkg", rel);
}

test "generateBuildZigZon quotes dep names that are not bare identifiers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const dest = "/project/.zpkg/work/debug-native/root";
    var dep_map = DepPathMap.init(allocator);
    defer dep_map.deinit();
    try dep_map.put("hello-lib", "/project/.zpkg/work/debug-native/deps/hello-lib");
    try dep_map.put("hello_lib", "/project/.zpkg/work/debug-native/deps/hello_lib");

    var empty_extra2 = DepPathMap.init(allocator);
    defer empty_extra2.deinit();
    var realizer = SourcePkgRealize.init(allocator, io);
    const fields2 = SourcePkgRealize.SourceFields{
        .name = ".mypkg",
        .fingerprint = null,
        .version = "\"0.0.0\"",
        .minimum_zig_version = null,
        .paths = @constCast(&[_][]const u8{"."}),
    };
    const content = try realizer.generateBuildZigZon(dest, dep_map, empty_extra2, fields2);
    defer allocator.free(content);

    // hello-lib has a hyphen — must be wrapped with @"..."
    try std.testing.expect(std.mem.indexOf(u8, content, ".@\"hello-lib\"") != null);
    // hello_lib is a valid bare identifier — must NOT be wrapped
    try std.testing.expect(std.mem.indexOf(u8, content, ".hello_lib") != null);
    // Ensure the bare version is not accidentally emitted for the hyphenated name
    try std.testing.expect(std.mem.indexOf(u8, content, ".hello-lib") == null);
}

test "isBareIdentifier rejects keywords and non-identifier chars" {
    try std.testing.expect(isBareIdentifier("hello_lib") == true);
    try std.testing.expect(isBareIdentifier("_private") == true);
    try std.testing.expect(isBareIdentifier("hello-lib") == false);
    try std.testing.expect(isBareIdentifier("hello.lib") == false);
    try std.testing.expect(isBareIdentifier("") == false);
    try std.testing.expect(isBareIdentifier("1bad") == false);
    try std.testing.expect(isBareIdentifier("const") == false);
    try std.testing.expect(isBareIdentifier("fn") == false);
    try std.testing.expect(isBareIdentifier("pub") == false);
    try std.testing.expect(isBareIdentifier("return") == false);
    try std.testing.expect(isBareIdentifier("try") == false);
    try std.testing.expect(isBareIdentifier("error") == false);
    try std.testing.expect(isBareIdentifier("struct") == false);
}

/// Helper for tests: create a temp dir under /tmp with a unique name, write
/// build.zig.zon, run the callback, then delete the dir.
fn withTmpZon(
    io: std.Io,
    dir_name: []const u8,
    zon_content: []const u8,
) ![]u8 {
    // Return the absolute path; caller is responsible for cleanup.
    const tmp_path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/{s}", .{dir_name});
    std.Io.Dir.createDirAbsolute(io, tmp_path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    const dir_obj = try std.Io.Dir.openDirAbsolute(io, tmp_path, .{});
    defer dir_obj.close(io);
    try dir_obj.writeFile(io, .{ .sub_path = "build.zig.zon", .data = zon_content });
    return tmp_path;
}

fn cleanupTmpDir(io: std.Io, tmp_path: []const u8) void {
    const parent = std.Io.Dir.openDirAbsolute(io, "/tmp", .{}) catch return;
    defer parent.close(io);
    // sub_path relative to /tmp
    const base = std.fs.path.basename(tmp_path);
    parent.deleteTree(io, base) catch {};
}

test "readSourceFields handles field order: paths before name" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const zon =
        \\.{
        \\    .paths = .{ "build.zig", "src" },
        \\    .fingerprint = 0x0000000000000001,
        \\    .name = .my_pkg,
        \\    .version = "0.1.0",
        \\}
    ;
    const tmp_path = try withTmpZon(io, "zpkg_test_rsf_order", zon);
    defer {
        cleanupTmpDir(io, tmp_path);
        allocator.free(tmp_path);
    }

    var realizer = SourcePkgRealize.init(allocator, io);
    var fields = try realizer.readSourceFields(tmp_path);
    defer fields.deinitOwned(allocator);

    try std.testing.expectEqualStrings(".my_pkg", fields.name);
    try std.testing.expectEqualStrings("\"0.1.0\"", fields.version);
    try std.testing.expectEqual(@as(?u64, 1), fields.fingerprint);
    try std.testing.expectEqual(@as(usize, 2), fields.paths.len);
    try std.testing.expectEqualStrings("build.zig", fields.paths[0]);
    try std.testing.expectEqualStrings("src", fields.paths[1]);
}

test "readExtraDepsFromSource skips URL deps" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const zon =
        \\.{
        \\    .name = .my_pkg,
        \\    .version = "0.1.0",
        \\    .paths = .{"."},
        \\    .dependencies = .{
        \\        .url_dep = .{
        \\            .url = "https://example.com/foo.tar.gz",
        \\            .hash = "abc123",
        \\        },
        \\        .path_dep = .{
        \\            .path = "../some-lib",
        \\        },
        \\    },
        \\}
    ;
    const tmp_path = try withTmpZon(io, "zpkg_test_reds_url", zon);
    defer {
        cleanupTmpDir(io, tmp_path);
        allocator.free(tmp_path);
    }

    var resolved = DepPathMap.init(allocator);
    defer resolved.deinit();

    var realizer = SourcePkgRealize.init(allocator, io);
    var extra = try realizer.readExtraDepsFromSource(tmp_path, resolved);
    defer {
        var it = extra.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        extra.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), extra.count());
    try std.testing.expect(extra.contains("path_dep"));
    try std.testing.expect(!extra.contains("url_dep"));
}

test "readExtraDepsFromSource handles multi-line dep entries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // The old line-scanner would fail on this multi-line format.
    const zon =
        \\.{
        \\    .name = .my_pkg,
        \\    .version = "0.1.0",
        \\    .paths = .{"."},
        \\    .dependencies = .{
        \\        .zpkg_build = .{
        \\            .path =
        \\                "../zpkg-build",
        \\        },
        \\    },
        \\}
    ;
    const tmp_path = try withTmpZon(io, "zpkg_test_reds_multiline", zon);
    defer {
        cleanupTmpDir(io, tmp_path);
        allocator.free(tmp_path);
    }

    var resolved = DepPathMap.init(allocator);
    defer resolved.deinit();

    var realizer = SourcePkgRealize.init(allocator, io);
    var extra = try realizer.readExtraDepsFromSource(tmp_path, resolved);
    defer {
        var it = extra.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        extra.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), extra.count());
    try std.testing.expect(extra.contains("zpkg_build"));
}

test "readExtraDepsFromSource skips resolved deps" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const zon =
        \\.{
        \\    .name = .my_pkg,
        \\    .version = "0.1.0",
        \\    .paths = .{"."},
        \\    .dependencies = .{
        \\        .managed_dep = .{ .path = "../managed" },
        \\        .extra_dep = .{ .path = "../extra" },
        \\    },
        \\}
    ;
    const tmp_path = try withTmpZon(io, "zpkg_test_reds_resolved", zon);
    defer {
        cleanupTmpDir(io, tmp_path);
        allocator.free(tmp_path);
    }

    // Mark managed_dep as already resolved.
    var resolved = DepPathMap.init(allocator);
    defer resolved.deinit();
    try resolved.put("managed_dep", "/some/path");

    var realizer = SourcePkgRealize.init(allocator, io);
    var extra = try realizer.readExtraDepsFromSource(tmp_path, resolved);
    defer {
        var it = extra.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        extra.deinit();
    }

    // Only extra_dep should appear; managed_dep was in resolved.
    try std.testing.expectEqual(@as(usize, 1), extra.count());
    try std.testing.expect(extra.contains("extra_dep"));
    try std.testing.expect(!extra.contains("managed_dep"));
}
