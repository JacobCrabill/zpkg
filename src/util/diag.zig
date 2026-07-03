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

/// Overridable stderr sink. Diagnostics normally go to the real stderr (fd 2),
/// but writing to fd 2 inside a unit test corrupts the Zig test runner's
/// `--listen` IPC. Tests point this at a discarding or capturing writer via
/// `setStderrOverride`. null = real stderr.
///
/// Not synchronized, and deliberately so: the real-output path uses a fresh stack
/// buffer per call (so concurrent diagnostics never share mutable state), and this
/// override is only ever set from single-threaded test setup. Don't repurpose it
/// as a shared sink for concurrent production output.
var stderr_override: ?*std.Io.Writer = null;

/// Redirect diagnostic (stderr) output to `w`; pass null to restore the real
/// stderr. Intended for tests (e.g. a `Discarding` or capturing writer).
pub fn setStderrOverride(w: ?*std.Io.Writer) void {
    stderr_override = w;
}

fn rawTo(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll(text);
    try w.flush();
}

fn fmtTo(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try w.print(fmt, args);
    try w.flush();
}

/// `prefix` + formatted message, with a trailing newline appended if missing.
fn labeledTo(w: *std.Io.Writer, prefix: []const u8, comptime fmt: []const u8, args: anytype) !void {
    try w.writeAll(prefix);
    try w.print(fmt, args);
    if (fmt.len == 0 or fmt[fmt.len - 1] != '\n') try w.writeAll("\n");
    try w.flush();
}

/// Write raw text to stdout and flush.
pub fn writeStdout(io: std.Io, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var wf: std.Io.File.Writer = .init(.stdout(), io, &buf);
    try rawTo(&wf.interface, text);
}

/// Write formatted text to stdout and flush.
pub fn writeStdoutFmt(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var wf: std.Io.File.Writer = .init(.stdout(), io, &buf);
    try fmtTo(&wf.interface, fmt, args);
}

/// Write raw text to stderr and flush.
pub fn writeStderr(io: std.Io, text: []const u8) !void {
    if (stderr_override) |w| return rawTo(w, text);
    var buf: [4096]u8 = undefined;
    var wf: std.Io.File.Writer = .init(.stderr(), io, &buf);
    try rawTo(&wf.interface, text);
}

/// Write formatted text to stderr and flush.
pub fn writeStderrFmt(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    if (stderr_override) |w| return fmtTo(w, fmt, args);
    var buf: [4096]u8 = undefined;
    var wf: std.Io.File.Writer = .init(.stderr(), io, &buf);
    try fmtTo(&wf.interface, fmt, args);
}

/// Print a command's help text to stdout.
pub fn writeHelp(io: std.Io, help_text: []const u8) !void {
    try writeStdout(io, help_text);
}

pub fn writeError(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    if (stderr_override) |w| return labeledTo(w, "error: ", fmt, args);
    var buf: [4096]u8 = undefined;
    var wf: std.Io.File.Writer = .init(.stderr(), io, &buf);
    try labeledTo(&wf.interface, "error: ", fmt, args);
}

pub fn writeHint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    if (stderr_override) |w| return labeledTo(w, "hint: ", fmt, args);
    var buf: [4096]u8 = undefined;
    var wf: std.Io.File.Writer = .init(.stderr(), io, &buf);
    try labeledTo(&wf.interface, "hint: ", fmt, args);
}

pub fn writeLockfileMissingError(io: std.Io) !void {
    try writeError(io, "no lockfile found", .{});
    try writeHint(io, "run 'zpkg lock <pkg-root>' to create one", .{});
}

pub fn writeManifestMissingError(io: std.Io, pkg_root: []const u8) !void {
    try writeError(io, "no zpkg.zon found in '{s}'", .{pkg_root});
    try writeHint(io, "is '{s}' a zpkg package? it needs a zpkg.zon", .{pkg_root});
}
