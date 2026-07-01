const std = @import("std");
const lockcmd = @import("lockcmd.zig");

pub const help_text =
    \\zpkg update — Update an existing lockfile in place
    \\
    \\Usage:
    \\  zpkg update <pkg-root> [--dry-run]
    \\
    \\Arguments:
    \\  <pkg-root>   Path to the package directory containing zpkg.zon
    \\
    \\Options:
    \\  --dry-run    Print the updated lockfile to stdout without writing to disk
    \\
    \\Example:
    \\  zpkg update .
    \\
;

pub fn run(args: []const []const u8, io: std.Io) !void {
    return lockcmd.run(.update, args, io, help_text);
}
