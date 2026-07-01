const std = @import("std");
const lockcmd = @import("lockcmd.zig");

pub const help_text =
    \\zpkg lock — Create an authoritative lockfile (zpkg.lock.zon)
    \\
    \\Usage:
    \\  zpkg lock <pkg-root>
    \\
    \\Arguments:
    \\  <pkg-root>   Path to the package directory containing zpkg.zon
    \\
    \\Example:
    \\  zpkg lock .
    \\
;

pub fn run(args: []const []const u8, io: std.Io) !void {
    return lockcmd.run(.create, args, io, help_text);
}
