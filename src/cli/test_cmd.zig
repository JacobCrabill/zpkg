const std = @import("std");
const build_cmd = @import("build.zig");
const build_fallback = @import("../realize/build_fallback.zig");

pub const help_text =
    \\zpkg test — Build and run all test instances
    \\
    \\Usage:
    \\  zpkg test <pkg-root> [--jobs N] [--strict-lockfile]
    \\
    \\Arguments:
    \\  <pkg-root>        Path to the package directory containing zpkg.lock.zon
    \\
    \\Options:
    \\  --jobs N          Maximum number of parallel build jobs (default: CPU count; 1 for serial)
    \\  --strict-lockfile Treat source drift as a hard error (default: warn and rebuild)
    \\
    \\Example:
    \\  zpkg test .
    \\  zpkg test . --jobs 1
    \\  zpkg test . --strict-lockfile
    \\
;

pub fn run(args: []const []const u8, io: std.Io) !void {
    var pkg_root: ?[]const u8 = null;
    var max_jobs: ?usize = null;
    var strict_lockfile = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            var buf: [2048]u8 = undefined;
            var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
            const w = &fw.interface;
            try w.writeAll(help_text);
            try w.flush();
            return;
        } else if (std.mem.eql(u8, args[i], "--strict-lockfile")) {
            strict_lockfile = true;
        } else if (std.mem.eql(u8, args[i], "--jobs")) {
            i += 1;
            if (i >= args.len) {
                var buf: [256]u8 = undefined;
                var f: std.Io.File.Writer = .init(.stderr(), io, &buf);
                try f.interface.writeAll("error: --jobs requires a number\n");
                try f.interface.flush();
                return error.InvalidArgument;
            }
            const n = std.fmt.parseInt(usize, args[i], 10) catch {
                var buf: [256]u8 = undefined;
                var f: std.Io.File.Writer = .init(.stderr(), io, &buf);
                try f.interface.print("error: --jobs value must be a positive integer: {s}\n", .{args[i]});
                try f.interface.flush();
                return error.InvalidArgument;
            };
            if (n == 0) {
                var buf: [256]u8 = undefined;
                var f: std.Io.File.Writer = .init(.stderr(), io, &buf);
                try f.interface.writeAll("error: --jobs must be at least 1\n");
                try f.interface.flush();
                return error.InvalidArgument;
            }
            max_jobs = n;
        } else if (pkg_root == null) {
            pkg_root = args[i];
        } else {
            var buf: [2048]u8 = undefined;
            var f: std.Io.File.Writer = .init(.stderr(), io, &buf);
            const w = &f.interface;
            try w.print("error: unexpected argument: {s}\n", .{args[i]});
            try w.flush();
            return error.InvalidArgument;
        }
    }

    const root = pkg_root orelse {
        var buf: [2048]u8 = undefined;
        var f: std.Io.File.Writer = .init(.stderr(), io, &buf);
        const w = &f.interface;
        try w.writeAll("error: test expects a package root path\nusage: zpkg test <pkg-root> [--jobs N]\n");
        try w.flush();
        return error.InvalidArgument;
    };

    try build_cmd.runBuild(root, .run_tests, io, max_jobs, strict_lockfile);
}
