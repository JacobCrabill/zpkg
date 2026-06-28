const std = @import("std");

const store_subdir = "store";
const artifacts_subdir = "artifacts";
const expanded_subdir = "expanded";
const archive_filename = "archive.tar";
const manifest_filename = "manifest.zon";

/// Returns the store root path: `<workspace_root>/.zpkg/store`.
/// Caller owns the returned slice.
pub fn storeRoot(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return std.Io.Dir.path.join(allocator, &.{ workspace_root, ".zpkg", store_subdir });
}

/// Returns the artifacts directory for an instance: `<store_root>/artifacts/<instance_key>`.
/// Caller owns the returned slice.
pub fn artifactsDir(allocator: std.mem.Allocator, store_root: []const u8, instance_key: []const u8) ![]u8 {
    return std.Io.Dir.path.join(allocator, &.{ store_root, artifacts_subdir, instance_key });
}

/// Returns the archive path: `<store_root>/artifacts/<instance_key>/archive.tar`.
/// Caller owns the returned slice.
pub fn archivePath(allocator: std.mem.Allocator, store_root: []const u8, instance_key: []const u8) ![]u8 {
    const dir = try artifactsDir(allocator, store_root, instance_key);
    defer allocator.free(dir);
    return std.Io.Dir.path.join(allocator, &.{ dir, archive_filename });
}

/// Returns the manifest path: `<store_root>/artifacts/<instance_key>/manifest.zon`.
/// Caller owns the returned slice.
pub fn manifestPath(allocator: std.mem.Allocator, store_root: []const u8, instance_key: []const u8) ![]u8 {
    const dir = try artifactsDir(allocator, store_root, instance_key);
    defer allocator.free(dir);
    return std.Io.Dir.path.join(allocator, &.{ dir, manifest_filename });
}

/// Returns the expanded prefix directory: `<store_root>/expanded/<instance_key>`.
/// Caller owns the returned slice.
pub fn expandedDir(allocator: std.mem.Allocator, store_root: []const u8, instance_key: []const u8) ![]u8 {
    return std.Io.Dir.path.join(allocator, &.{ store_root, expanded_subdir, instance_key });
}

test "layout paths are correctly derived" {
    const allocator = std.testing.allocator;

    const root = try storeRoot(allocator, "/workspace");
    defer allocator.free(root);
    try std.testing.expectEqualStrings("/workspace/.zpkg/store", root);

    const art = try artifactsDir(allocator, root, "zpkg.example.hello_lib#target");
    defer allocator.free(art);
    try std.testing.expectEqualStrings("/workspace/.zpkg/store/artifacts/zpkg.example.hello_lib#target", art);

    const arch = try archivePath(allocator, root, "zpkg.example.hello_lib#target");
    defer allocator.free(arch);
    try std.testing.expectEqualStrings("/workspace/.zpkg/store/artifacts/zpkg.example.hello_lib#target/archive.tar", arch);

    const mani = try manifestPath(allocator, root, "zpkg.example.hello_lib#target");
    defer allocator.free(mani);
    try std.testing.expectEqualStrings("/workspace/.zpkg/store/artifacts/zpkg.example.hello_lib#target/manifest.zon", mani);

    const exp = try expandedDir(allocator, root, "zpkg.example.hello_lib#target");
    defer allocator.free(exp);
    try std.testing.expectEqualStrings("/workspace/.zpkg/store/expanded/zpkg.example.hello_lib#target", exp);
}

test "layout paths handle nested package ids" {
    const allocator = std.testing.allocator;

    const root = try storeRoot(allocator, "/home/user/project");
    defer allocator.free(root);

    const arch = try archivePath(allocator, root, "zpkg.deep.nested.pkg#host");
    defer allocator.free(arch);
    try std.testing.expectEqualStrings(
        "/home/user/project/.zpkg/store/artifacts/zpkg.deep.nested.pkg#host/archive.tar",
        arch,
    );
}
