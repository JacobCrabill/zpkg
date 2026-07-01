const std = @import("std");
const store = @import("../store/root.zig");
const source_pkg = @import("source_pkg.zig");

const prefix_dirs = [_][]const u8{ "include", "lib", "bin", "share" };

const LibEntry = struct {
    name: []u8,     // artifact name derived from filename (e.g., "A" from "libA.a")
    filename: []u8, // original filename (e.g., "libA.a")
};

pub const BinaryAdapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) BinaryAdapter {
        return .{ .allocator = allocator, .io = io };
    }

    /// Generate a binary adapter package at `dest_dir`.
    ///
    /// Creates:
    ///   - `dest_dir/build.zig`     — exposes prebuilt artifacts as Zig library steps
    ///   - `dest_dir/build.zig.zon` — declares dep paths; uses source_fingerprint if provided
    ///   - `dest_dir/{include,lib,bin,share}` — symlinks into the expanded store prefix
    pub fn generate(
        self: *BinaryAdapter,
        dest_dir: []const u8,
        expanded_prefix: []const u8,
        manifest: store.ArtifactManifest,
        dep_realized_paths: source_pkg.DepPathMap,
        source_fingerprint: ?u64,
    ) !void {
        const adapter_name = manifest.instance.package_id.asText();

        // Generate and write build.zig (delete any existing symlink to source first).
        const build_zig_abs = try std.Io.Dir.path.join(self.allocator, &.{ dest_dir, "build.zig" });
        defer self.allocator.free(build_zig_abs);
        std.Io.Dir.cwd().deleteFile(self.io, build_zig_abs) catch {};

        const build_zig_content = try self.generateBuildZig(expanded_prefix, dep_realized_paths);
        defer self.allocator.free(build_zig_content);
        try self.writeFile(dest_dir, "build.zig", build_zig_content);

        // Generate and write build.zig.zon.
        const build_zig_zon_abs = try std.Io.Dir.path.join(self.allocator, &.{ dest_dir, "build.zig.zon" });
        defer self.allocator.free(build_zig_zon_abs);
        std.Io.Dir.cwd().deleteFile(self.io, build_zig_zon_abs) catch {};

        const zon_content = try self.generateBuildZigZon(adapter_name, dep_realized_paths, dest_dir, source_fingerprint);
        defer self.allocator.free(zon_content);
        try self.writeFile(dest_dir, "build.zig.zon", zon_content);

        // Create symlinks at adapter root pointing into expanded_prefix subdirs.
        for (prefix_dirs) |sub| {
            const target = try std.Io.Dir.path.join(self.allocator, &.{ expanded_prefix, sub });
            defer self.allocator.free(target);

            // Only symlink if the target dir exists in the expanded prefix.
            std.Io.Dir.accessAbsolute(self.io, target, .{}) catch continue;

            const link = try std.Io.Dir.path.join(self.allocator, &.{ dest_dir, sub });
            defer self.allocator.free(link);

            // Delete any existing entry (may be a symlink from a previous source realization).
            std.Io.Dir.cwd().deleteFile(self.io, link) catch {};
            try std.Io.Dir.symLinkAbsolute(self.io, target, link, .{});
        }
    }

    /// Generate the build.zig that exposes prebuilt artifacts.
    ///
    /// For each .a file found in expanded_prefix/lib/:
    ///   - creates a b.addLibrary step backed by b.path("lib/<file>")
    ///   - links against each dep that has library artifacts
    fn generateBuildZig(
        self: *BinaryAdapter,
        expanded_prefix: []const u8,
        dep_realized_paths: source_pkg.DepPathMap,
    ) ![]u8 {
        const allocator = self.allocator;

        // Collect own library entries from expanded_prefix/lib/.
        var own_libs: std.ArrayList(LibEntry) = .empty;
        defer {
            for (own_libs.items) |e| {
                allocator.free(e.name);
                allocator.free(e.filename);
            }
            own_libs.deinit(allocator);
        }
        try scanLibDir(allocator, self.io, expanded_prefix, &own_libs);

        // Collect dep entries: only deps that have at least one .a file.
        const DepEntry = struct {
            alias: []u8,
            artifact_names: [][]u8,
        };
        var dep_entries: std.ArrayList(DepEntry) = .empty;
        defer {
            for (dep_entries.items) |e| {
                allocator.free(e.alias);
                for (e.artifact_names) |n| allocator.free(n);
                allocator.free(e.artifact_names);
            }
            dep_entries.deinit(allocator);
        }

        var dep_it = dep_realized_paths.iterator();
        while (dep_it.next()) |entry| {
            const alias = entry.key_ptr.*;
            const dep_path = entry.value_ptr.*;

            var dep_libs: std.ArrayList(LibEntry) = .empty;
            defer {
                for (dep_libs.items) |e| {
                    allocator.free(e.name);
                    allocator.free(e.filename);
                }
                dep_libs.deinit(allocator);
            }
            try scanLibDir(allocator, self.io, dep_path, &dep_libs);
            if (dep_libs.items.len == 0) continue;

            const artifact_names = try allocator.alloc([]u8, dep_libs.items.len);
            for (dep_libs.items, 0..) |lib, i| {
                artifact_names[i] = try allocator.dupe(u8, lib.name);
            }

            try dep_entries.append(allocator, .{
                .alias = try allocator.dupe(u8, alias),
                .artifact_names = artifact_names,
            });
        }

        // Generate build.zig content.
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const w = &aw.writer;

        try w.writeAll("const std = @import(\"std\");\n");
        try w.writeAll("pub fn build(b: *std.Build) void {\n");

        if (own_libs.items.len > 0 or dep_entries.items.len > 0) {
            try w.writeAll("    const target = b.standardTargetOptions(.{});\n");
            try w.writeAll("    const optimize = b.standardOptimizeOption(.{});\n");
        } else {
            try w.writeAll("    _ = b;\n");
        }

        // Dep variable declarations.
        for (dep_entries.items) |dep| {
            const var_name = try sanitizeAlias(allocator, dep.alias);
            defer allocator.free(var_name);
            try w.print(
                "    const {s}_dep = b.dependency(\"{s}\", .{{ .target = target, .optimize = optimize }});\n",
                .{ var_name, dep.alias },
            );
        }

        // Own library declarations.
        // We create a Compile step per library but bypass its make function, pointing
        // generated_bin directly at the prebuilt archive from the store. This avoids
        // both the archive-of-archive problem (llvm-ar cannot nest .a files) and any
        // disk duplication — the store's .a is used verbatim by the linker.
        for (own_libs.items) |lib| {
            const lib_name = try libVarName(allocator, lib.name);
            defer allocator.free(lib_name);
            const mod_name = try modVarName(allocator, lib.name);
            defer allocator.free(mod_name);

            try w.print(
                "    const {s} = b.createModule(.{{ .target = target, .optimize = optimize }});\n",
                .{mod_name},
            );

            for (dep_entries.items) |dep| {
                const dep_var = try sanitizeAlias(allocator, dep.alias);
                defer allocator.free(dep_var);
                for (dep.artifact_names) |aname| {
                    try w.print(
                        "    {s}.linkLibrary({s}_dep.artifact(\"{s}\"));\n",
                        .{ mod_name, dep_var, aname },
                    );
                }
            }

            try w.print(
                "    const {s} = b.addLibrary(.{{ .name = \"{s}\", .root_module = {s}, .linkage = .static }});\n",
                .{ lib_name, lib.name, mod_name },
            );
            // installArtifact allocates generated_bin via getEmittedBin(); must come before
            // we set generated_bin.?.path. The path is then redirected to the prebuilt archive
            // so no compilation is needed, and noopMake prevents the normal make from
            // overwriting it with a Zig cache path.
            try w.print("    b.installArtifact({s});\n", .{lib_name});
            try w.print(
                "    {s}.generated_bin.?.path = b.pathFromRoot(\"lib/{s}\");\n",
                .{ lib_name, lib.filename },
            );
            try w.print("    {s}.step.makeFn = noopMake;\n", .{lib_name});
        }

        try w.writeAll("}\n\n");
        try w.writeAll("fn noopMake(_: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {}\n");

        return try aw.toOwnedSlice();
    }

    /// Generate the build.zig.zon for the binary adapter.
    fn generateBuildZigZon(
        self: *BinaryAdapter,
        adapter_name: []const u8,
        dep_realized_paths: source_pkg.DepPathMap,
        dest_dir: []const u8,
        source_fingerprint: ?u64,
    ) ![]u8 {
        const allocator = self.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const w = &aw.writer;

        try w.writeAll(".{\n");
        const bare_name = try packageIdToBareIdent(allocator, adapter_name);
        defer allocator.free(bare_name);
        try w.print("    .name = .{s},\n", .{bare_name});
        try w.writeAll("    .version = \"0.0.0\",\n");
        if (source_fingerprint) |fp| {
            try w.print("    .fingerprint = 0x{x:0>16},\n", .{fp});
        }
        try w.writeAll("    .paths = .{\".\"},\n");
        try w.writeAll("    .dependencies = .{\n");

        // Include only deps that have library artifacts.
        var dep_it = dep_realized_paths.iterator();
        while (dep_it.next()) |entry| {
            const alias = entry.key_ptr.*;
            const dep_path = entry.value_ptr.*;

            var dep_libs: std.ArrayList(LibEntry) = .empty;
            defer {
                for (dep_libs.items) |e| {
                    allocator.free(e.name);
                    allocator.free(e.filename);
                }
                dep_libs.deinit(allocator);
            }
            try scanLibDir(allocator, self.io, dep_path, &dep_libs);
            if (dep_libs.items.len == 0) continue;

            const rel = try relativePath(allocator, dest_dir, dep_path);
            defer allocator.free(rel);
            try w.print("        .{s} = .{{ .path = \"{s}\" }},\n", .{ alias, rel });
        }

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

/// Scan `base_dir/lib/` for `.a` files and append LibEntry items to `libs`.
fn scanLibDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    libs: *std.ArrayList(LibEntry),
) !void {
    const lib_path = try std.Io.Dir.path.join(allocator, &.{ base_dir, "lib" });
    defer allocator.free(lib_path);

    const lib_dir = std.Io.Dir.openDirAbsolute(io, lib_path, .{ .iterate = true }) catch return;
    defer lib_dir.close(io);

    var iter = lib_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".a")) continue;

        const filename = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(filename);
        const art_name = try libArtifactName(allocator, entry.name);
        errdefer allocator.free(art_name);
        try libs.append(allocator, .{ .name = art_name, .filename = filename });
    }
}

/// Derive an artifact name from a static archive filename.
/// Examples: "libA.a" → "A", "libfoo_bar.a" → "foo_bar", "baz.a" → "baz"
fn libArtifactName(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    const without_ext = if (std.mem.endsWith(u8, filename, ".a"))
        filename[0 .. filename.len - 2]
    else
        filename;
    const name = if (std.mem.startsWith(u8, without_ext, "lib"))
        without_ext[3..]
    else
        without_ext;
    return allocator.dupe(u8, name);
}

/// Sanitize a dep alias for use as a Zig identifier.
/// Replaces non-alphanumeric/non-underscore chars with `_`.
fn sanitizeAlias(allocator: std.mem.Allocator, alias: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, alias);
    for (result) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '_') c.* = '_';
    }
    if (result.len > 0 and std.ascii.isDigit(result[0])) result[0] = '_';
    return result;
}

/// Convert a package ID (e.g. "diamond.libE") to a valid bare Zig identifier
/// suitable for the `.name` field in `build.zig.zon` (e.g. "diamond_libe").
/// Dots → underscores, all lowercase.
fn packageIdToBareIdent(allocator: std.mem.Allocator, package_id: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, package_id);
    for (result) |*c| {
        if (c.* == '.') {
            c.* = '_';
        } else {
            c.* = std.ascii.toLower(c.*);
        }
    }
    return result;
}

/// Build a Zig variable name for a module: "mod_" + lowercase(artifact_name).
fn modVarName(allocator: std.mem.Allocator, artifact_name: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("mod_");
    for (artifact_name) |c| try w.writeByte(std.ascii.toLower(c));
    return try aw.toOwnedSlice();
}

/// Build a Zig variable name for a library: "lib_" + lowercase(artifact_name).
fn libVarName(allocator: std.mem.Allocator, artifact_name: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("lib_");
    for (artifact_name) |c| try w.writeByte(std.ascii.toLower(c));
    return try aw.toOwnedSlice();
}

/// Compute a relative path from `from_dir` to `to_path`.
/// Both must be absolute. Caller owns the returned slice.
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

test "libArtifactName strips lib prefix and .a suffix" {
    const allocator = std.testing.allocator;

    const a = try libArtifactName(allocator, "libA.a");
    defer allocator.free(a);
    try std.testing.expectEqualStrings("A", a);

    const foo = try libArtifactName(allocator, "libfoo_bar.a");
    defer allocator.free(foo);
    try std.testing.expectEqualStrings("foo_bar", foo);

    const baz = try libArtifactName(allocator, "baz.a");
    defer allocator.free(baz);
    try std.testing.expectEqualStrings("baz", baz);
}

test "sanitizeAlias replaces special chars with underscore" {
    const allocator = std.testing.allocator;

    const simple = try sanitizeAlias(allocator, "libC");
    defer allocator.free(simple);
    try std.testing.expectEqualStrings("libC", simple);

    const dotted = try sanitizeAlias(allocator, "lib.c");
    defer allocator.free(dotted);
    try std.testing.expectEqualStrings("lib_c", dotted);
}

test "libVarName produces lib_lower form" {
    const allocator = std.testing.allocator;

    const name = try libVarName(allocator, "A");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("lib_a", name);

    const name2 = try libVarName(allocator, "FooBar");
    defer allocator.free(name2);
    try std.testing.expectEqualStrings("lib_foobar", name2);
}

test "generateBuildZigZon has no fingerprint and no prefix dep" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var adapter = BinaryAdapter.init(allocator, io);
    var empty_deps = source_pkg.DepPathMap.init(allocator);
    defer empty_deps.deinit();

    const zon = try adapter.generateBuildZigZon("zpkg.example.hello_lib", empty_deps, "/fake/dest", null);
    defer allocator.free(zon);

    try std.testing.expect(std.mem.indexOf(u8, zon, ".name = .zpkg_example_hello_lib") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".fingerprint") == null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".dependencies = .{") != null);
    // No prefix dep in new format.
    try std.testing.expect(std.mem.indexOf(u8, zon, ".prefix") == null);
}
// cache bust
