const std = @import("std");
const build_cmd = @import("build.zig");
const build_fallback = @import("../realize/build_fallback.zig");

pub fn run(args: []const []const u8, io: std.Io) !void {
    var pkg_root: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (pkg_root == null) {
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
        try w.writeAll("error: test expects a package root path\nusage: zpkg test <pkg-root>\n");
        try w.flush();
        return error.InvalidArgument;
    };

    // P07-C stub: mode is passed through but not yet acted upon; zig build test is not yet invoked
    try build_cmd.runBuild(root, .run_tests, io);
}
