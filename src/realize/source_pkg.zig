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
    /// - Writes a build.zig.zon at dest_dir that is the source build.zig.zon
    ///   with only the `.dependencies` field replaced by workspace-local paths.
    ///   All other fields (name, version, fingerprint, paths, etc.) are copied
    ///   verbatim.
    /// - Copies zpkg.graph.zon into dest_dir if it exists in source_dir.
    pub fn realize(
        self: *SourcePkgRealize,
        source_dir: []const u8,
        dest_dir: []const u8,
        dep_realized_paths: DepPathMap,
    ) !void {
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
        const src_dir_obj = try std.Io.Dir.openDirAbsolute(self.io, source_dir, .{});
        defer src_dir_obj.close(self.io);
        const source_content = try src_dir_obj.readFileAlloc(self.io, "build.zig.zon", self.allocator, .limited(64 * 1024));
        defer self.allocator.free(source_content);

        // Collect extra build-tool deps (e.g. `zpkg-build`) not in the resolved map.
        var extra_deps = try self.readExtraDepsFromSource(source_dir, source_content, dep_realized_paths);
        defer {
            var it = extra_deps.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                self.allocator.free(e.value_ptr.*);
            }
            extra_deps.deinit();
        }

        const zon_content = try self.rewriteDependencies(source_content, dest_dir, dep_realized_paths, extra_deps);
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
            // Skip generated / workspace-artifact entries to avoid symlink loops
            // and polluting the workspace with non-source content.
            if (std.mem.eql(u8, entry.name, "build.zig.zon")) continue;
            if (std.mem.eql(u8, entry.name, "zpkg.graph.zon")) continue;
            if (std.mem.eql(u8, entry.name, "zpkg.lock.zon")) continue;
            if (std.mem.eql(u8, entry.name, "zig-out")) continue;
            if (std.mem.eql(u8, entry.name, ".zig-cache")) continue;
            if (std.mem.eql(u8, entry.name, ".zpkg")) continue;

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


    /// Parse `source_content` (the source build.zig.zon) and return a map of
    /// dep_name → absolute_path for dependencies NOT already present in
    /// `resolved_deps`.  These are build-tool deps (e.g. `zpkg-build`) that the
    /// source build.zig needs but that zpkg doesn't manage through the lockfile.
    /// Relative dep paths are resolved against `source_dir`.  Caller owns all keys
    /// and values in the returned map.
    pub fn readExtraDepsFromSource(
        self: *SourcePkgRealize,
        source_dir: []const u8,
        source_content: []const u8,
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

        const sentinel = self.allocator.dupeZ(u8, source_content) catch return result;
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

    /// Copy source_content verbatim, replacing only the `.dependencies` field
    /// with workspace-local paths.  All other fields — including name, version,
    /// fingerprint, minimum_zig_version, paths — are preserved exactly as written.
    ///
    /// Dependency entries are emitted in lexicographic order for determinism.
    pub fn rewriteDependencies(
        self: *SourcePkgRealize,
        source_content: []const u8,
        dest_dir: []const u8,
        dep_realized_paths: DepPathMap,
        extra_deps: DepPathMap,
    ) ![]u8 {
        const new_deps = try emitDependenciesField(self.allocator, dest_dir, dep_realized_paths, extra_deps);
        defer self.allocator.free(new_deps);
        return replaceStructField(self.allocator, source_content, ".dependencies", new_deps);
    }
};

/// Emit a `.dependencies = .{ ... },\n` field body from a dep-path map.  Keys from
/// both maps are merged, sorted for determinism, and bare-identifier-quoted as
/// needed; each dep path is emitted relative to `dest_dir`.  Caller owns the result.
pub fn emitDependenciesField(
    allocator: std.mem.Allocator,
    dest_dir: []const u8,
    dep_realized_paths: DepPathMap,
    extra_deps: DepPathMap,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll(".dependencies = .{\n");

    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    var it1 = dep_realized_paths.keyIterator();
    while (it1.next()) |k| try keys.append(allocator, k.*);
    var it2 = extra_deps.keyIterator();
    while (it2.next()) |k| try keys.append(allocator, k.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (keys.items) |key| {
        const abs_path = dep_realized_paths.get(key) orelse extra_deps.get(key).?;
        const rel_path = try relativePath(allocator, dest_dir, abs_path);
        defer allocator.free(rel_path);
        if (isBareIdentifier(key)) {
            try w.print("        .{s} = .{{ .path = \"{s}\" }},\n", .{ key, rel_path });
        } else {
            try w.print("        .@\"{s}\" = .{{ .path = \"{s}\" }},\n", .{ key, rel_path });
        }
    }

    try w.writeAll("    },\n");
    return try aw.toOwnedSlice();
}

/// Copy `source` verbatim, replacing the top-level struct-literal field named by
/// `field_selector` (e.g. ".dependencies", ".paths") with `new_field` (the full
/// `.name = .{...},\n` text).  If the field is absent it is inserted before the
/// closing `}`.  Caller owns the result.
pub fn replaceStructField(
    allocator: std.mem.Allocator,
    source: []const u8,
    field_selector: []const u8,
    new_field: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    if (findFieldSpan(source, field_selector)) |span| {
        try w.writeAll(source[0..span.start]);
        try w.writeAll(new_field);
        try w.writeAll(source[span.end..]);
    } else {
        // Field absent: insert before the final `}`.
        if (std.mem.lastIndexOfScalar(u8, source, '}')) |last_brace| {
            try w.writeAll(source[0..last_brace]);
            try w.writeAll("    ");
            try w.writeAll(new_field);
            try w.writeByte('\n');
            try w.writeAll(source[last_brace..]);
        } else {
            return allocator.dupe(u8, source);
        }
    }

    return try aw.toOwnedSlice();
}

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
        "addrspace",      "align",       "allowzero", "and",      "anyframe",
        "anytype",        "asm",         "async",     "await",    "break",
        "callconv",       "catch",       "comptime",  "const",    "continue",
        "defer",          "else",        "enum",      "errdefer", "error",
        "export",         "extern",      "fn",        "for",      "if",
        "inline",         "linksection", "noalias",   "noinline", "nosuspend",
        "opaque",         "or",          "orelse",    "packed",   "pub",
        "resume",         "return",      "struct",    "suspend",  "switch",
        "test",           "threadlocal", "try",       "union",    "unreachable",
        "usingnamespace", "var",         "volatile",  "while",
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

/// Locate a top-level struct-literal field (e.g. ".dependencies" or ".paths") in
/// a ZON source string and return its byte span [start, end).  `start` is the
/// position of the leading `.`; `end` is just past the `\n` that follows the
/// closing `,`.  Only matches fields whose value is a struct literal (`.{...}`).
///
/// Returns null if the field is absent or the source is malformed.
fn findFieldSpan(source: []const u8, field_selector: []const u8) ?struct { start: usize, end: usize } {
    var search: usize = 0;
    while (search < source.len) {
        const idx = std.mem.indexOfPos(u8, source, search, field_selector) orelse return null;

        // The first non-whitespace character after the field name must be `=`.
        var pos = idx + field_selector.len;
        while (pos < source.len and (source[pos] == ' ' or source[pos] == '\t')) : (pos += 1) {}
        if (pos >= source.len or source[pos] != '=') {
            search = idx + 1;
            continue;
        }

        // Skip past `=` and any surrounding whitespace to reach the value.
        pos += 1;
        while (pos < source.len and (source[pos] == ' ' or source[pos] == '\t' or
            source[pos] == '\n' or source[pos] == '\r')) : (pos += 1)
        {}

        // The value must start with `.{` (a struct literal).
        if (pos < source.len and source[pos] == '.') pos += 1;
        if (pos >= source.len or source[pos] != '{') {
            search = idx + 1;
            continue;
        }

        // Count braces to find the matching `}`.  Skip string contents to avoid
        // treating `{` or `}` inside a path string as structural.
        var depth: usize = 0;
        while (pos < source.len) : (pos += 1) {
            switch (source[pos]) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        pos += 1; // step past `}`
                        while (pos < source.len and (source[pos] == ' ' or source[pos] == '\t')) : (pos += 1) {}
                        if (pos < source.len and source[pos] == ',') pos += 1;
                        if (pos < source.len and source[pos] == '\n') pos += 1;
                        return .{ .start = idx, .end = pos };
                    }
                },
                '"' => {
                    pos += 1;
                    while (pos < source.len) : (pos += 1) {
                        if (source[pos] == '\\') {
                            pos += 1;
                            continue;
                        }
                        if (source[pos] == '"') break;
                    }
                },
                else => {},
            }
        }
        return null; // unclosed brace — malformed ZON
    }
    return null;
}

test "rewriteDependencies preserves all source fields verbatim" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    _ = io;

    const source =
        \\.{
        \\    .name = .hello_app,
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x14ba26c846ee8ffc,
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{
        \\        .old_dep = .{ .path = "old/path" },
        \\    },
        \\    .paths = .{
        \\        "build.zig",
        \\        "src",
        \\    },
        \\}
        \\
    ;

    const dest = "/project/.zpkg/work/debug-native/root";
    var dep_map = DepPathMap.init(allocator);
    defer dep_map.deinit();
    try dep_map.put("hello_lib", "/project/.zpkg/work/debug-native/deps/zpkg.example.hello_lib#target");

    var empty_extra = DepPathMap.init(allocator);
    defer empty_extra.deinit();

    var realizer = SourcePkgRealize.init(allocator, std.testing.io);
    const content = try realizer.rewriteDependencies(source, dest, dep_map, empty_extra);
    defer allocator.free(content);

    // All non-dependencies fields must be preserved exactly.
    try std.testing.expect(std.mem.indexOf(u8, content, ".name = .hello_app") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".version = \"0.1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".fingerprint = 0x14ba26c846ee8ffc") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".minimum_zig_version = \"0.16.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"build.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"src\"") != null);
    // New dep present, old dep gone.
    try std.testing.expect(std.mem.indexOf(u8, content, "hello_lib") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "old_dep") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".path =") != null);
}

test "rewriteDependencies output is deterministic with multiple deps" {
    const allocator = std.testing.allocator;

    const source =
        \\.{
        \\    .name = .mypkg,
        \\    .version = "0.0.0",
        \\    .dependencies = .{},
        \\    .paths = .{"."},
        \\}
        \\
    ;
    const dest = "/project/.zpkg/work/debug-native/root";
    const dep_a = "/project/.zpkg/work/debug-native/deps/zpkg.example.alpha";
    const dep_b = "/project/.zpkg/work/debug-native/deps/zpkg.example.beta";

    var map1 = DepPathMap.init(allocator);
    defer map1.deinit();
    try map1.put("alpha", dep_a);
    try map1.put("beta", dep_b);

    var map2 = DepPathMap.init(allocator);
    defer map2.deinit();
    try map2.put("beta", dep_b);
    try map2.put("alpha", dep_a);

    var empty1 = DepPathMap.init(allocator);
    defer empty1.deinit();
    var empty2 = DepPathMap.init(allocator);
    defer empty2.deinit();

    var r1 = SourcePkgRealize.init(allocator, std.testing.io);
    const out1 = try r1.rewriteDependencies(source, dest, map1, empty1);
    defer allocator.free(out1);

    var r2 = SourcePkgRealize.init(allocator, std.testing.io);
    const out2 = try r2.rewriteDependencies(source, dest, map2, empty2);
    defer allocator.free(out2);

    try std.testing.expectEqualStrings(out1, out2);
    // alpha must appear before beta.
    try std.testing.expect(std.mem.indexOf(u8, out1, "alpha").? < std.mem.indexOf(u8, out1, "beta").?);
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

test "rewriteDependencies quotes dep names that are not bare identifiers" {
    const allocator = std.testing.allocator;

    const source =
        \\.{
        \\    .name = .mypkg,
        \\    .version = "0.0.0",
        \\    .dependencies = .{},
        \\    .paths = .{"."},
        \\}
        \\
    ;
    const dest = "/project/.zpkg/work/debug-native/root";
    var dep_map = DepPathMap.init(allocator);
    defer dep_map.deinit();
    try dep_map.put("hello-lib", "/project/.zpkg/work/debug-native/deps/hello-lib");
    try dep_map.put("hello_lib", "/project/.zpkg/work/debug-native/deps/hello_lib");

    var empty_extra = DepPathMap.init(allocator);
    defer empty_extra.deinit();

    var realizer = SourcePkgRealize.init(allocator, std.testing.io);
    const content = try realizer.rewriteDependencies(source, dest, dep_map, empty_extra);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, ".@\"hello-lib\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".hello_lib") != null);
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
    var resolved = DepPathMap.init(allocator);
    defer resolved.deinit();

    var realizer = SourcePkgRealize.init(allocator, io);
    var extra = try realizer.readExtraDepsFromSource("/fake/src", zon, resolved);
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
    var resolved = DepPathMap.init(allocator);
    defer resolved.deinit();

    var realizer = SourcePkgRealize.init(allocator, io);
    var extra = try realizer.readExtraDepsFromSource("/fake/src", zon, resolved);
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
    // Mark managed_dep as already resolved.
    var resolved = DepPathMap.init(allocator);
    defer resolved.deinit();
    try resolved.put("managed_dep", "/some/path");

    var realizer = SourcePkgRealize.init(allocator, io);
    var extra = try realizer.readExtraDepsFromSource("/fake/src", zon, resolved);
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
