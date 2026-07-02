const std = @import("std");
const diag = @import("../util/diag.zig");

// keep in sync with build.zig.zon
pub const zpkg_version = "0.0.0";

pub const help_text =
    \\zpkg version — Print the zpkg version
    \\
    \\Usage:
    \\  zpkg version
    \\  zpkg --version
    \\  zpkg -V
    \\
;

pub fn run(args: []const []const u8, io: std.Io) !void {
    if (args.len >= 3 and (std.mem.eql(u8, args[2], "--help") or std.mem.eql(u8, args[2], "-h"))) {
        return diag.writeHelp(io, help_text);
    }
    try diag.writeStdoutFmt(io, "zpkg {s}\n", .{zpkg_version});
}
