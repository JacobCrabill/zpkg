const std = @import("std");
const store = @import("../store/root.zig");
const source_pkg = @import("source_pkg.zig");

const build_zig_template =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    _ = b;
    \\    // Binary adapter: all artifacts are pre-built in the store.
    \\    // Consumers reference paths directly via the adapter's exported paths.
    \\}
    \\pub fn includePath(b: *std.Build) std.Build.LazyPath {
    \\    return .{ .cwd_relative = b.pathFromRoot("include") };
    \\}
    \\pub fn libPath(b: *std.Build) std.Build.LazyPath {
    \\    return .{ .cwd_relative = b.pathFromRoot("lib") };
    \\}
    \\pub fn binPath(b: *std.Build) std.Build.LazyPath {
    \\    return .{ .cwd_relative = b.pathFromRoot("bin") };
    \\}
    \\pub fn sharePath(b: *std.Build) std.Build.LazyPath {
    \\    return .{ .cwd_relative = b.pathFromRoot("share") };
    \\}
    \\
;

const prefix_dirs = [_][]const u8{ "include", "lib", "bin", "share" };

pub const BinaryAdapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) BinaryAdapter {
        return .{ .allocator = allocator, .io = io };
    }

    /// Generate a binary adapter package at `dest_dir`.
    pub fn generate(
        self: *BinaryAdapter,
        dest_dir: []const u8,
        expanded_prefix: []const u8,
        manifest: store.ArtifactManifest,
        dep_realized_paths: source_pkg.DepPathMap,
    ) !void {
        _ = dep_realized_paths;

        // Write build.zig
        try self.writeFile(dest_dir, "build.zig", build_zig_template);

        // Write build.zig.zon
        const adapter_name = manifest.instance.package_id.asText();
        const rel_prefix = try relativePath(self.allocator, dest_dir, expanded_prefix);
        defer self.allocator.free(rel_prefix);
        const zon_content = try self.generateBuildZigZon(adapter_name, rel_prefix);
        defer self.allocator.free(zon_content);
        try self.writeFile(dest_dir, "build.zig.zon", zon_content);

        // Create symlinks/ subdir with symlinks into expanded_prefix
        const symlinks_dir_path = try std.Io.Dir.path.join(self.allocator, &.{ dest_dir, "symlinks" });
        defer self.allocator.free(symlinks_dir_path);
        std.Io.Dir.createDirAbsolute(self.io, symlinks_dir_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        for (prefix_dirs) |sub| {
            const target = try std.Io.Dir.path.join(self.allocator, &.{ expanded_prefix, sub });
            defer self.allocator.free(target);
            const link = try std.Io.Dir.path.join(self.allocator, &.{ symlinks_dir_path, sub });
            defer self.allocator.free(link);
            std.Io.Dir.symLinkAbsolute(self.io, target, link, .{}) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }

    fn generateBuildZigZon(self: *BinaryAdapter, adapter_name: []const u8, rel_prefix: []const u8) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;

        try w.writeAll(".{\n");
        try w.print("    .name = .@\"{s}\",\n", .{adapter_name});
        try w.writeAll("    .version = \"0.0.0\",\n");
        try w.writeAll("    .paths = .{\".\"},\n");
        try w.writeAll("    .dependencies = .{\n");
        try w.print("        .prefix = .{{ .path = \"{s}\" }},\n", .{rel_prefix});
        try w.writeAll("    },\n");
        try w.writeAll("}\n");

        return try aw.toOwnedSlice();
    }

    fn writeFile(self: *BinaryAdapter, dir_path: []const u8, sub_path: []const u8, content: []const u8) !void {
        const dir = try std.Io.Dir.openDirAbsolute(self.io, dir_path, .{});
        defer dir.close(self.io);
        try dir.writeFile(self.io, .{ .sub_path = sub_path, .data = content });
    }
};

/// Compute a relative path from `from_dir` to `to_path`.
/// Both must be absolute.  Caller owns the returned slice.
fn relativePath(allocator: std.mem.Allocator, from_dir: []const u8, to_path: []const u8) ![]u8 {
    var from_it = std.mem.splitScalar(u8, from_dir, '/');
    var to_it = std.mem.splitScalar(u8, to_path, '/');

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

test "BinaryAdapter generate produces correct build.zig content" {
    // Just test the template content directly without filesystem ops
    try std.testing.expect(std.mem.indexOf(u8, build_zig_template, "pub fn build(b: *std.Build) void") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_template, "includePath") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_template, "libPath") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_template, "binPath") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_template, "sharePath") != null);
    try std.testing.expect(std.mem.indexOf(u8, build_zig_template, "cwd_relative") != null);
}

test "BinaryAdapter generateBuildZigZon embeds adapter name and prefix path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var adapter = BinaryAdapter.init(allocator, io);
    const zon = try adapter.generateBuildZigZon("zpkg.example.hello_lib", "../../store/expanded/zpkg.example.hello_lib#target");
    defer allocator.free(zon);

    try std.testing.expect(std.mem.indexOf(u8, zon, ".name = .@\"zpkg.example.hello_lib\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".prefix = .{ .path =") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, "store/expanded") != null);
}
