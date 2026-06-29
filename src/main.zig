const std = @import("std");
const zpkg = @import("zpkg");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    zpkg.cli.run(args, init.io) catch |err| switch (err) {
        // These errors have already printed a user-facing message; exit
        // cleanly without a backtrace.
        error.InvalidArgument,
        error.LockfileNotFound,
        error.LockfileExists,
        error.LockfileMismatch,
        error.TestsFailed,
        error.SourceDrift,
        => std.process.exit(1),
        else => return err,
    };
}

test "help flags are recognized" {
    const args = [_][]const u8{ "zpkg", "--help" };
    try std.testing.expect(zpkg.cli.shouldShowHelp(&args));
}
