const std = @import("std");

pub const ArchiveError = error{
    OutOfMemory,
    SourceDirNotFound,
    ArchiveCreateFailed,
    ArchiveExtractFailed,
    FileOpenFailed,
    FileStatFailed,
    DirCreateFailed,
};

/// Create a .tar archive of all files under `prefix_dir_path` and write to `archive_path`.
/// Both paths must be absolute. The archive preserves directory structure relative to
/// `prefix_dir_path`.
pub fn createArchive(
    allocator: std.mem.Allocator,
    io: std.Io,
    prefix_dir_path: []const u8,
    archive_path: []const u8,
) !void {
    // Open the source directory for iteration.
    const prefix_dir = std.Io.Dir.openDirAbsolute(io, prefix_dir_path, .{ .iterate = true }) catch
        return error.SourceDirNotFound;
    defer prefix_dir.close(io);

    // Create (or overwrite) the archive file.
    const archive_file = std.Io.Dir.createFileAbsolute(io, archive_path, .{}) catch
        return error.ArchiveCreateFailed;
    defer archive_file.close(io);

    // Set up the tar writer backed by a file writer.
    var write_buf: [4096]u8 = undefined;
    var file_writer = archive_file.writer(io, &write_buf);
    var archiver: std.tar.Writer = .{ .underlying_writer = &file_writer.interface };

    // Walk the prefix directory recursively.
    var walker = try prefix_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        // Convert native path separators to '/' for tar compatibility.
        const tar_path = try toTarPath(allocator, entry.path);
        defer allocator.free(tar_path);

        switch (entry.kind) {
            .directory => {
                archiver.writeDir(tar_path, .{}) catch
                    return error.ArchiveCreateFailed;
            },
            .file => {
                // Stat the file to get its size for the tar header.
                const stat = entry.dir.statFile(io, entry.basename, .{}) catch
                    return error.FileStatFailed;

                const file = entry.dir.openFile(io, entry.basename, .{}) catch
                    return error.FileOpenFailed;
                defer file.close(io);

                var read_buf: [4096]u8 = undefined;
                var file_reader: std.Io.File.Reader = .initSize(file, io, &read_buf, stat.size);
                archiver.writeFile(tar_path, &file_reader, @intCast(stat.mtime.toSeconds())) catch
                    return error.ArchiveCreateFailed;
            },
            .sym_link => {
                var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const link_len = entry.dir.readLink(io, entry.basename, &link_buf) catch continue;
                archiver.writeLink(tar_path, link_buf[0..link_len], .{}) catch
                    return error.ArchiveCreateFailed;
            },
            else => {
                // Skip special files (devices, sockets, etc.).
            },
        }
    }

    archiver.finishPedantically() catch
        return error.ArchiveCreateFailed;
    file_writer.interface.flush() catch
        return error.ArchiveCreateFailed;
}

/// Extract a .tar archive to `dest_dir_path` (creates dir if needed).
/// Both paths must be absolute.
/// Idempotent: if `dest_dir_path` already exists, returns immediately without re-extracting.
pub fn extractArchive(
    allocator: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,
    dest_dir_path: []const u8,
) !void {
    _ = allocator;

    // Idempotency: if the destination directory already exists, skip.
    if (std.Io.Dir.accessAbsolute(io, dest_dir_path, .{})) |_| {
        return; // already extracted
    } else |_| {}

    // Create the destination directory.
    std.Io.Dir.createDirAbsolute(io, dest_dir_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // concurrent creation; safe to proceed
        else => return error.DirCreateFailed,
    };

    const dest_dir = std.Io.Dir.openDirAbsolute(io, dest_dir_path, .{}) catch
        return error.DirCreateFailed;
    defer dest_dir.close(io);

    // Open the archive for reading.
    const archive_file = std.Io.Dir.openFileAbsolute(io, archive_path, .{}) catch
        return error.ArchiveExtractFailed;
    defer archive_file.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = archive_file.reader(io, &read_buf);

    std.tar.extract(io, dest_dir, &file_reader.interface, .{}) catch
        return error.ArchiveExtractFailed;
}

/// Convert a native path to a tar-safe `/`-separated path.
/// Caller owns the returned slice.
fn toTarPath(allocator: std.mem.Allocator, native_path: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, native_path);
    if (std.fs.path.sep != '/') {
        std.mem.replaceScalar(u8, result, std.fs.path.sep, '/');
    }
    return result;
}

/// Returns the current working directory as a heap-allocated string.
/// Caller owns the returned slice.
fn getCwdAlloc(allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&buf, buf.len);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.GetCwdFailed;
    return allocator.dupe(u8, std.mem.sliceTo(&buf, 0));
}

test "archive round-trip: create then extract" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cwd = try getCwdAlloc(allocator);
    defer allocator.free(cwd);

    // Create source directory with test files.
    const src_rel = ".zig-cache/tmp/zpkg_archive_test_src";
    const src_path = try std.Io.Dir.path.join(allocator, &.{ cwd, src_rel });
    defer allocator.free(src_path);

    // Clean up any leftover state from a prior run.
    std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, src_rel) catch {};
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, src_rel) catch {};

    const src_dir = try std.Io.Dir.cwd().createDirPathOpen(io, src_rel, .{});
    defer src_dir.close(io);

    // Populate source directory.
    try src_dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "Hello, world!\n" });
    try src_dir.writeFile(io, .{ .sub_path = "data.bin", .data = &[_]u8{ 0x01, 0x02, 0x03 } });
    try src_dir.createDir(io, "subdir", .default_dir);
    try src_dir.writeFile(io, .{ .sub_path = "subdir/nested.txt", .data = "nested content\n" });

    // Create and extract archive.
    const arch_rel = ".zig-cache/tmp/zpkg_archive_test.tar";
    const arch_path = try std.Io.Dir.path.join(allocator, &.{ cwd, arch_rel });
    defer allocator.free(arch_path);
    defer std.Io.Dir.cwd().deleteFile(io, arch_rel) catch {};

    try createArchive(allocator, io, src_path, arch_path);

    const dest_rel = ".zig-cache/tmp/zpkg_archive_test_dest";
    const dest_path = try std.Io.Dir.path.join(allocator, &.{ cwd, dest_rel });
    defer allocator.free(dest_path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, dest_rel) catch {};

    try extractArchive(allocator, io, arch_path, dest_path);

    // Verify extracted files.
    const dest_dir = try std.Io.Dir.openDirAbsolute(io, dest_path, .{});
    defer dest_dir.close(io);

    const hello = try dest_dir.readFileAlloc(io, "hello.txt", allocator, .unlimited);
    defer allocator.free(hello);
    try std.testing.expectEqualStrings("Hello, world!\n", hello);

    const data = try dest_dir.readFileAlloc(io, "data.bin", allocator, .unlimited);
    defer allocator.free(data);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, data);

    const nested = try dest_dir.readFileAlloc(io, "subdir/nested.txt", allocator, .unlimited);
    defer allocator.free(nested);
    try std.testing.expectEqualStrings("nested content\n", nested);
}

test "extractArchive is idempotent" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const cwd = try getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const src_rel = ".zig-cache/tmp/zpkg_idem_src";
    const src_path = try std.Io.Dir.path.join(allocator, &.{ cwd, src_rel });
    defer allocator.free(src_path);

    std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, src_rel) catch {};
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, src_rel) catch {};

    const src_dir = try std.Io.Dir.cwd().createDirPathOpen(io, src_rel, .{});
    defer src_dir.close(io);
    try src_dir.writeFile(io, .{ .sub_path = "a.txt", .data = "aaa" });

    const arch_rel = ".zig-cache/tmp/zpkg_idem.tar";
    const arch_path = try std.Io.Dir.path.join(allocator, &.{ cwd, arch_rel });
    defer allocator.free(arch_path);
    defer std.Io.Dir.cwd().deleteFile(io, arch_rel) catch {};

    try createArchive(allocator, io, src_path, arch_path);

    const dest_rel = ".zig-cache/tmp/zpkg_idem_dest";
    const dest_path = try std.Io.Dir.path.join(allocator, &.{ cwd, dest_rel });
    defer allocator.free(dest_path);
    defer std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, dest_rel) catch {};

    // First extraction.
    try extractArchive(allocator, io, arch_path, dest_path);

    // Second call must succeed without error.
    try extractArchive(allocator, io, arch_path, dest_path);

    const dest_dir = try std.Io.Dir.openDirAbsolute(io, dest_path, .{});
    defer dest_dir.close(io);

    const content = try dest_dir.readFileAlloc(io, "a.txt", allocator, .unlimited);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("aaa", content);
}
