/// Structured diagnostic helpers for CLI commands.
const std = @import("std");

/// Resolve a user-supplied path (relative or absolute) to an
/// allocator-owned absolute path. Caller must free the result.
pub fn resolveAbsPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    // getcwd syscall — portable within Linux/POSIX targets.
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.GetCwdFailed;
    const cwd = std.mem.sliceTo(&cwd_buf, 0);
    // Use resolve (not join) so that ".", "..", "../../foo" etc. are normalized.
    // join(cwd, ".") would produce "{cwd}/." — the dot is kept as a literal
    // component and throws off relative-path calculations downstream.
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

pub fn writeError(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var wf: std.Io.File.Writer = .init(.stderr(), io, &buf);
    const w = &wf.interface;
    try w.writeAll("error: ");
    try w.print(fmt, args);
    if (fmt.len == 0 or fmt[fmt.len - 1] != '\n') try w.writeAll("\n");
    try w.flush();
}

pub fn writeHint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var wf: std.Io.File.Writer = .init(.stderr(), io, &buf);
    const w = &wf.interface;
    try w.writeAll("hint: ");
    try w.print(fmt, args);
    if (fmt.len == 0 or fmt[fmt.len - 1] != '\n') try w.writeAll("\n");
    try w.flush();
}

pub fn writeBuildSummary(io: std.Io, hits: usize, misses: usize, built: usize) !void {
    var buf: [4096]u8 = undefined;
    var wf: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const w = &wf.interface;
    try w.print(
        "build summary: {d} cache hit(s), {d} cache miss(es), {d} built\n",
        .{ hits, misses, built },
    );
    try w.flush();
}

pub fn writeLockfileMissingError(io: std.Io) !void {
    try writeError(io, "no lockfile found", .{});
    try writeHint(io, "run 'zpkg lock <pkg-root>' to create one", .{});
}

pub fn writeLockfileDriftError(io: std.Io) !void {
    try writeError(io, "lockfile is out of date with zpkg.zon", .{});
    try writeHint(io, "run 'zpkg update <pkg-root>' to refresh it", .{});
}
