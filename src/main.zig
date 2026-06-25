const std = @import("std");
const zpkg = @import("zpkg");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    try zpkg.cli.run(args, init.io);
}

test "help flags are recognized" {
    const args = [_][]const u8{ "zpkg", "--help" };
    try std.testing.expect(zpkg.cli.shouldShowHelp(&args));
}
