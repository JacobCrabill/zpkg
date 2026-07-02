const std = @import("std");
const diag = @import("../util/diag.zig");

pub const help_text =
    \\zpkg clean — Remove generated build artifacts for a package
    \\
    \\Usage:
    \\  zpkg clean <pkg-root> [--store]
    \\
    \\Arguments:
    \\  <pkg-root>   Path to the package directory
    \\
    \\Options:
    \\  --store      Also remove the content-addressed store cache (.zpkg/store)
    \\
    \\Default removes:
    \\  <pkg-root>/.zpkg/work
    \\  <pkg-root>/zig-out
    \\
    \\Example:
    \\  zpkg clean .
    \\  zpkg clean . --store
    \\
;

pub fn run(args: []const []const u8, io: std.Io) !void {
    var pkg_root: ?[]const u8 = null;
    var remove_store = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            return diag.writeHelp(io, help_text);
        } else if (std.mem.eql(u8, args[i], "--store")) {
            remove_store = true;
        } else if (pkg_root == null) {
            pkg_root = args[i];
        } else {
            try diag.writeStderrFmt(io, "error: unexpected argument: {s}\n", .{args[i]});
            return error.InvalidArgument;
        }
    }

    const root = pkg_root orelse {
        try diag.writeStderr(io, "error: clean expects a package root path\nusage: zpkg clean <pkg-root> [--store]\n");
        return error.InvalidArgument;
    };

    const allocator = std.heap.page_allocator;

    const abs_root = diag.resolveAbsPath(allocator, root) catch |err| {
        try diag.writeStderrFmt(io, "error: cannot resolve path '{s}': {s}\n", .{ root, @errorName(err) });
        return error.InvalidArgument;
    };

    var root_dir = std.Io.Dir.openDirAbsolute(io, abs_root, .{}) catch |err| {
        try diag.writeStderrFmt(io, "error: cannot open package root '{s}': {s}\n", .{ abs_root, @errorName(err) });
        return error.InvalidArgument;
    };
    defer root_dir.close(io);

    var removed: usize = 0;
    removed += try removeDirRel(io, root_dir, abs_root, ".zpkg/work");
    removed += try removeDirRel(io, root_dir, abs_root, "zig-out");
    if (remove_store) {
        removed += try removeDirRel(io, root_dir, abs_root, ".zpkg/store");
    }

    if (removed == 0) {
        try diag.writeStdout(io, "nothing to clean\n");
    }
}

fn removeDirRel(io: std.Io, dir: std.Io.Dir, root: []const u8, sub: []const u8) !usize {
    // Check existence before deleting; openDir returns FileNotFound when absent.
    var check = dir.openDir(io, sub, .{}) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    check.close(io);
    try dir.deleteTree(io, sub);
    try diag.writeStdoutFmt(io, "removed {s}/{s}\n", .{ root, sub });
    return 1;
}
