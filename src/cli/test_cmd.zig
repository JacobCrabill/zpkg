const std = @import("std");
const build_cmd = @import("build.zig");
const build_fallback = @import("../realize/build_fallback.zig");
const realize = @import("../realize/root.zig");
const status_mod = @import("../util/status.zig");
const diag = @import("../util/diag.zig");

pub const help_text =
    \\zpkg test — Build and run all test instances
    \\
    \\Usage:
    \\  zpkg test <pkg-root> [options]
    \\
    \\Arguments:
    \\  <pkg-root>        Path to the package directory containing zpkg.lock.zon
    \\
    \\Options:
    \\  --jobs N                Maximum number of parallel build jobs (default: CPU count; 1 for serial)
    \\  --strict-lockfile       Treat source drift as a hard error (default: warn and rebuild)
    \\  --release[=safe|fast|small]  Optimized build (bare --release = ReleaseFast; default is Debug)
    \\  --progress auto|plain|live   Status display (default: auto — live on a TTY, plain otherwise)
    \\
    \\Note: --target is not supported for 'test' (running foreign-target binaries needs an emulator).
    \\
    \\Example:
    \\  zpkg test .
    \\  zpkg test . --jobs 1
    \\  zpkg test . --release
    \\
;

pub fn run(args: []const []const u8, io: std.Io) !void {
    var pkg_root: ?[]const u8 = null;
    var max_jobs: ?usize = null;
    var strict_lockfile = false;
    var profile: realize.Profile = .{};
    var progress_mode: status_mod.Mode = .auto;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            try diag.writeHelp(io, help_text);
            return;
        } else if (std.mem.eql(u8, args[i], "--strict-lockfile")) {
            strict_lockfile = true;
        } else if (std.mem.eql(u8, args[i], "--jobs")) {
            i += 1;
            if (i >= args.len) {
                try diag.writeStderr(io, "error: --jobs requires a number\n");
                return error.InvalidArgument;
            }
            const n = std.fmt.parseInt(usize, args[i], 10) catch {
                try diag.writeStderrFmt(io, "error: --jobs value must be a positive integer: {s}\n", .{args[i]});
                return error.InvalidArgument;
            };
            if (n == 0) {
                try diag.writeStderr(io, "error: --jobs must be at least 1\n");
                return error.InvalidArgument;
            }
            max_jobs = n;
        } else if (try build_cmd.tryParseProgressFlag(args, &i, &progress_mode, io)) {
            // handled
        } else if (try build_cmd.tryParseProfileFlag(args, &i, &profile, io)) {
            // handled
        } else if (pkg_root == null) {
            pkg_root = args[i];
        } else {
            try diag.writeStderrFmt(io, "error: unexpected argument: {s}\n", .{args[i]});
            return error.InvalidArgument;
        }
    }

    const root = pkg_root orelse {
        try diag.writeStderr(io, "error: test expects a package root path\nusage: zpkg test <pkg-root> [--jobs N] [--release[=safe|fast|small]]\n");
        return error.InvalidArgument;
    };

    // 'zpkg test' with a cross --target is rejected inside runBuild (needs an emulator).
    try build_cmd.runBuild(root, .run_tests, io, max_jobs, strict_lockfile, profile, progress_mode);
}
