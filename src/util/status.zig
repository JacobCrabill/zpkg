//! A live status reporter for concurrent child jobs.
//!
//! zpkg runs many child `zig build` processes (one per store-miss instance, plus
//! the root build). On a TTY this renders a single refreshing status line showing
//! the running jobs with elapsed time, while completed jobs scroll out above it as
//! permanent lines. On a non-TTY (CI, pipes) it degrades to one line per
//! transition — no threads, no escape codes — so logs stay clean and stable.
//!
//! All state and terminal writes are guarded by one mutex; `begin`/`succeed`/
//! `fail`/`log` are safe to call from parallel build workers and the ticker thread.
const std = @import("std");

const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const max_shown_jobs = 3;
const tick_ms = 125;
/// Monotonic-while-awake clock: good for elapsed timers and the tick interval.
const clock: std.Io.Clock = .awake;

/// ANSI SGR codes, applied only in live (TTY) mode via `Status.c`.
const ansi = struct {
    const reset = "\x1b[0m";
    const green = "\x1b[32m";
    const red = "\x1b[31m";
    const cyan = "\x1b[36m";
    const dim = "\x1b[2m";
};

pub const Mode = enum { auto, plain, live };

pub const Status = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Resolved rendering mode: true = live refreshing line, false = plain lines.
    live: bool,
    /// Verb shown in the live header (e.g. "building").
    verb: []const u8,
    /// Best-effort total job count for the "[done/total]" counter.
    total: usize,
    completed: usize = 0,
    frame: u64 = 0,
    /// Whether a live line is currently on screen (needs clearing before other output).
    line_shown: bool = false,
    /// Terminal width used to truncate the live line (avoids wrap artifacts).
    cols: usize,
    active: std.ArrayListUnmanaged(Job) = .empty,
    ticker: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// One persistent stdout writer so the file offset advances monotonically
    /// (a fresh writer per call would pwrite from 0 and clobber seekable files).
    /// Lazily initialized once `Status` is at its final address.
    out: ?std.Io.File.Writer = null,
    out_buf: [4096]u8 = undefined,

    const Job = struct { name: []u8, start: std.Io.Timestamp };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, verb: []const u8, total: usize, mode: Mode) Status {
        // Progress/status is written to stderr (leaving stdout for results), so the
        // live vs plain decision follows whether *stderr* is a terminal.
        const live = switch (mode) {
            .plain => false,
            .live => true,
            .auto => std.Io.File.stderr().isTty(io) catch false,
        };
        return .{
            .allocator = allocator,
            .io = io,
            .live = live,
            .verb = verb,
            .total = total,
            // Fixed default width; the live line is a single truncated row, so an
            // over-wide terminal just yields a short line. (Querying the real width
            // can come later — env/ioctl access is threaded from std.process.Init.)
            .cols = 100,
        };
    }

    pub fn deinit(self: *Status) void {
        for (self.active.items) |job| self.allocator.free(job.name);
        self.active.deinit(self.allocator);
        self.* = undefined;
    }

    /// Spawn the refresh ticker (live mode only). Safe to call once.
    pub fn start(self: *Status) void {
        if (!self.live) return;
        self.running.store(true, .release);
        self.ticker = std.Thread.spawn(.{}, tickerLoop, .{self}) catch null;
    }

    /// Stop the ticker and clear the live line, leaving the terminal clean.
    pub fn stop(self: *Status) void {
        if (self.ticker) |t| {
            self.running.store(false, .release);
            t.join();
            self.ticker = null;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearLive();
    }

    /// Mark a job as running. In plain mode this prints a "[build] name" line.
    pub fn begin(self: *Status, name: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const owned = self.allocator.dupe(u8, name) catch return;
        self.active.append(self.allocator, .{ .name = owned, .start = self.now() }) catch {
            self.allocator.free(owned);
            return;
        };
        if (self.live) {
            self.clearLive();
            self.drawLive();
        } else {
            self.emitFmt("[build] {s}\n", .{name});
        }
    }

    /// Mark a running job as finished successfully; prints a permanent line.
    pub fn succeed(self: *Status, name: []const u8, detail: []const u8) void {
        self.finishJob(name, "[done]", ansi.green, detail, true);
    }

    /// Mark a running job as failed; prints a permanent line.
    pub fn fail(self: *Status, name: []const u8, detail: []const u8) void {
        self.finishJob(name, "[fail]", ansi.red, detail, false);
    }

    fn finishJob(self: *Status, name: []const u8, tag: []const u8, tag_color: []const u8, detail: []const u8, ok: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const elapsed_ms = self.removeActive(name);
        self.completed += 1;

        self.clearLive();
        if (ok and elapsed_ms != null) {
            self.emitFmt("{s}{s}{s} {s}  {s}  {s}{d:.1}s{s}\n", .{
                self.c(tag_color),  tag,    self.c(ansi.reset),
                name,               detail, self.c(ansi.dim),
                msToSecs(elapsed_ms.?), self.c(ansi.reset),
            });
        } else {
            self.emitFmt("{s}{s}{s} {s}  {s}\n", .{ self.c(tag_color), tag, self.c(ansi.reset), name, detail });
        }
        self.drawLive();
    }

    /// Print a permanent line above the live view (store hits, warnings, notes).
    pub fn log(self: *Status, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearLive();
        self.emitFmt(fmt, args);
        if (fmt.len == 0 or fmt[fmt.len - 1] != '\n') self.emit("\n");
        self.drawLive();
    }

    /// Print raw bytes (e.g. a failed child's captured stderr) above the live view.
    pub fn logRaw(self: *Status, bytes: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearLive();
        self.emit(bytes);
        self.drawLive();
    }

    // ——— internals (call with mutex held) ———

    fn now(self: *Status) std.Io.Timestamp {
        return std.Io.Timestamp.now(self.io, clock);
    }

    /// Remove the named active job; returns its elapsed milliseconds if found.
    fn removeActive(self: *Status, name: []const u8) ?i64 {
        for (self.active.items, 0..) |job, idx| {
            if (std.mem.eql(u8, job.name, name)) {
                const elapsed = job.start.durationTo(self.now()).toMilliseconds();
                self.allocator.free(job.name);
                _ = self.active.orderedRemove(idx);
                return elapsed;
            }
        }
        return null;
    }

    fn clearLive(self: *Status) void {
        if (!self.live or !self.line_shown) return;
        self.emit("\r\x1b[K");
        self.line_shown = false;
    }

    fn drawLive(self: *Status) void {
        if (!self.live) return;
        const content = self.formatLiveContent() catch return;
        defer self.allocator.free(content);
        self.emit("\r\x1b[K");
        self.emit(truncate(content, self.cols));
        self.line_shown = true;
    }

    fn formatLiveContent(self: *Status) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;

        const spin = spinner_frames[self.frame % spinner_frames.len];
        try w.print("{s}{s}{s} {s} [{d}/{d}]", .{ self.c(ansi.cyan), spin, self.c(ansi.reset), self.verb, self.completed, self.displayedTotal() });

        const current = self.now();
        for (self.active.items, 0..) |job, idx| {
            if (idx >= max_shown_jobs) {
                try w.print(" (+{d})", .{self.active.items.len - max_shown_jobs});
                break;
            }
            const secs = job.start.durationTo(current).toSeconds();
            try w.print("{s} {s} {d}s", .{ if (idx == 0) ":" else ",", stripDomain(job.name), secs });
        }
        return aw.toOwnedSlice();
    }

    fn displayedTotal(self: *Status) usize {
        return @max(self.total, self.completed + self.active.items.len);
    }

    /// A color code, or "" when not in live (TTY) mode.
    fn c(self: *Status, code: []const u8) []const u8 {
        return if (self.live) code else "";
    }

    fn writer(self: *Status) *std.Io.Writer {
        if (self.out == null) self.out = .init(.stderr(), self.io, &self.out_buf);
        return &self.out.?.interface;
    }

    fn emit(self: *Status, bytes: []const u8) void {
        const w = self.writer();
        w.writeAll(bytes) catch return;
        w.flush() catch return;
    }

    fn emitFmt(self: *Status, comptime fmt: []const u8, args: anytype) void {
        const w = self.writer();
        w.print(fmt, args) catch return;
        w.flush() catch return;
    }
};

fn tickerLoop(self: *Status) void {
    while (self.running.load(.acquire)) {
        self.io.sleep(std.Io.Duration.fromMilliseconds(tick_ms), clock) catch {};
        self.mutex.lockUncancelable(self.io);
        self.frame +%= 1;
        self.clearLive();
        self.drawLive();
        self.mutex.unlock(self.io);
    }
}

fn msToSecs(ms: i64) f64 {
    return @as(f64, @floatFromInt(ms)) / 1000.0;
}

/// Drop the "#domain" suffix from a display key for a compact live-line name.
fn stripDomain(name: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, name, '#')) |i| name[0..i] else name;
}

/// Truncate `s` to at most `cols` bytes. The braille spinner (the only multibyte
/// rune) sits at the front and is never cut, since truncation only trims the tail.
fn truncate(s: []const u8, cols: usize) []const u8 {
    if (s.len <= cols) return s;
    const cut = if (cols > 3) cols - 3 else cols;
    return s[0..@min(cut, s.len)];
}

test "plain mode selected when forced" {
    var s = Status.init(std.testing.allocator, std.testing.io, "building", 3, .plain);
    defer s.deinit();
    try std.testing.expect(!s.live);
}

test "displayedTotal never shrinks below in-flight work" {
    var s = Status.init(std.testing.allocator, std.testing.io, "building", 2, .plain);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 2), s.displayedTotal());
    s.completed = 2;
    try s.active.append(s.allocator, .{ .name = try s.allocator.dupe(u8, "x#target"), .start = .zero });
    try std.testing.expectEqual(@as(usize, 3), s.displayedTotal());
}

test "stripDomain drops the domain suffix" {
    try std.testing.expectEqualStrings("diamond.libC", stripDomain("diamond.libC#target"));
    try std.testing.expectEqualStrings("diamond.app (root)", stripDomain("diamond.app (root)"));
}

test "truncate trims to the column budget" {
    try std.testing.expectEqualStrings("abc", truncate("abc", 10)); // fits, unchanged
    try std.testing.expectEqualStrings("abcde", truncate("abcdefghij", 8)); // 8-3=5
}
