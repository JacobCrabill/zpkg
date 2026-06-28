/// Structured diagnostic helpers for CLI commands.
const std = @import("std");

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
