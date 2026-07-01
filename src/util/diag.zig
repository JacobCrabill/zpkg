/// Structured diagnostic and IO helpers for CLI commands.
///
/// This is the single home for CLI stdout/stderr writing. Command modules should
/// route all their output through `writeStdout`/`writeStderr`(`Fmt`)/`writeHelp`
/// rather than reconstructing a `File.Writer` + buffer + flush in each file.
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

// --- Low-level writers: single source of truth for CLI stdout/stderr. ---------

fn emit(file: std.Io.File, io: std.Io, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var wf: std.Io.File.Writer = .init(file, io, &buf);
    const w = &wf.interface;
    try w.writeAll(text);
    try w.flush();
}

fn emitFmt(file: std.Io.File, io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var wf: std.Io.File.Writer = .init(file, io, &buf);
    const w = &wf.interface;
    try w.print(fmt, args);
    try w.flush();
}

/// Write raw text to stdout and flush.
pub fn writeStdout(io: std.Io, text: []const u8) !void {
    try emit(.stdout(), io, text);
}

/// Write formatted text to stdout and flush.
pub fn writeStdoutFmt(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    try emitFmt(.stdout(), io, fmt, args);
}

/// Write raw text to stderr and flush.
pub fn writeStderr(io: std.Io, text: []const u8) !void {
    try emit(.stderr(), io, text);
}

/// Write formatted text to stderr and flush.
pub fn writeStderrFmt(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    try emitFmt(.stderr(), io, fmt, args);
}

/// Print a command's help text to stdout.
pub fn writeHelp(io: std.Io, help_text: []const u8) !void {
    try writeStdout(io, help_text);
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

pub fn writeLockfileMissingError(io: std.Io) !void {
    try writeError(io, "no lockfile found", .{});
    try writeHint(io, "run 'zpkg lock <pkg-root>' to create one", .{});
}
