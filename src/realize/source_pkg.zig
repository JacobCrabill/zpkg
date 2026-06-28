const std = @import("std");

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
        pkg_name: []const u8,
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

        // Write build.zig.zon
        const zon_content = try self.generateBuildZigZon(pkg_name, dest_dir, dep_realized_paths);
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

    /// Generate the build.zig.zon content.  Caller owns the returned slice.
    ///
    /// Determinism guarantee: dependency entries are emitted in lexicographic
    /// order of the dep name key.  HashMap iteration order is NOT used directly
    /// because it is not stable across runs.
    pub fn generateBuildZigZon(
        self: *SourcePkgRealize,
        pkg_name: []const u8,
        dest_dir: []const u8,
        dep_realized_paths: DepPathMap,
    ) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;

        try w.writeAll(".{\n");
        try w.print("    .name = .@\"{s}\",\n", .{pkg_name});
        try w.writeAll("    .version = \"0.0.0\",\n");
        try w.writeAll("    .paths = .{\".\"},\n");
        try w.writeAll("    .dependencies = .{\n");

        // Collect and sort dep keys to guarantee stable output regardless of
        // HashMap insertion or iteration order.
        var keys = std.ArrayList([]const u8).empty;
        defer keys.deinit(self.allocator);
        var key_iter = dep_realized_paths.keyIterator();
        while (key_iter.next()) |k| {
            try keys.append(self.allocator, k.*);
        }
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (keys.items) |key| {
            const value = dep_realized_paths.get(key).?;
            const rel_path = try relativePath(self.allocator, dest_dir, value);
            defer self.allocator.free(rel_path);
            try w.print("        .{s} = .{{ .path = \"{s}\" }},\n", .{ key, rel_path });
        }

        try w.writeAll("    },\n");
        try w.writeAll("}\n");

        return try aw.toOwnedSlice();
    }
};

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

    const content = try realizer.generateBuildZigZon(
        "zpkg.example.hello_app",
        "/project/.zpkg/work/debug-native/root",
        dep_map,
    );
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, ".name = .@\"zpkg.example.hello_app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".version = \"0.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".paths = .{\".\"") != null);
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

    var r1 = SourcePkgRealize.init(allocator, io);
    const out1 = try r1.generateBuildZigZon("mypkg", dest, map1);
    defer allocator.free(out1);

    var r2 = SourcePkgRealize.init(allocator, io);
    const out2 = try r2.generateBuildZigZon("mypkg", dest, map2);
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
