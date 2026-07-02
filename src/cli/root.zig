const std = @import("std");
const inspect = @import("inspect.zig");
const graph_cmd = @import("graph.zig");
const lock = @import("lock.zig");
const update = @import("update.zig");
const realize_cmd = @import("realize.zig");
const build_cmd = @import("build.zig");
const test_cmd = @import("test_cmd.zig");
const export_cmd = @import("export.zig");
const version_cmd = @import("version.zig");
const clean_cmd = @import("clean.zig");
const workspace = @import("../util/workspace.zig");
const diag = @import("../util/diag.zig");

// keep in sync with build.zig.zon
pub const zpkg_version = version_cmd.zpkg_version;

pub const help_text =
    \\zpkg - Zig package workspace realizer
    \\
    \\Usage:
    \\  zpkg [command]
    \\  zpkg --help
    \\  zpkg <command> --help
    \\
    \\Commands:
    \\  inspect   Inspect package metadata from <pkg-root>/zpkg.zon
    \\  graph     Show resolved package graph from <pkg-root>/zpkg.lock.zon
    \\  lock      Create an authoritative lockfile
    \\  update    Update the authoritative lockfile
    \\  realize   Materialize a generated workspace
    \\  build     Build from an authoritative lockfile
    \\  test      Build and run the test graph
    \\  export    Export a relocatable closure bundle
    \\  clean     Remove generated build artifacts
    \\  version   Print the zpkg version
    \\
    \\Generated workspace root: .zpkg/
    \\
;

pub fn run(args: []const []const u8, io: std.Io) !void {
    if (shouldShowHelp(args) or args.len == 1) {
        return writeHelp(io);
    }

    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-V")) {
        return diag.writeStdoutFmt(io, "zpkg {s}\n", .{zpkg_version});
    }

    if (std.mem.eql(u8, args[1], "inspect")) {
        return inspect.run(args, io);
    } else if (std.mem.eql(u8, args[1], "graph")) {
        return graph_cmd.run(args, io);
    } else if (std.mem.eql(u8, args[1], "lock")) {
        return lock.run(args, io);
    } else if (std.mem.eql(u8, args[1], "update")) {
        return update.run(args, io);
    } else if (std.mem.eql(u8, args[1], "realize")) {
        return realize_cmd.run(args, io);
    } else if (std.mem.eql(u8, args[1], "build")) {
        return build_cmd.run(args, io);
    } else if (std.mem.eql(u8, args[1], "test")) {
        return test_cmd.run(args, io);
    } else if (std.mem.eql(u8, args[1], "export")) {
        return export_cmd.run(args, io);
    } else if (std.mem.eql(u8, args[1], "clean")) {
        return clean_cmd.run(args, io);
    } else if (std.mem.eql(u8, args[1], "version")) {
        return version_cmd.run(args, io);
    }

    return writeUnknownCommand(io, args[1]);
}

pub fn shouldShowHelp(args: []const []const u8) bool {
    if (args.len <= 1) return true;
    return std.mem.eql(u8, args[1], "--help") or
        std.mem.eql(u8, args[1], "-h") or
        std.mem.eql(u8, args[1], "help");
}

fn writeHelp(io: std.Io) !void {
    try diag.writeHelp(io, help_text);
}

fn writeUnknownCommand(io: std.Io, command: []const u8) !void {
    try diag.writeStderrFmt(io, "error: unknown command: {s}\n\n", .{command});
    try diag.writeStderr(io, help_text);
    return error.InvalidArgument;
}

test "help text documents generated workspace root" {
    try std.testing.expect(std.mem.indexOf(u8, help_text, workspace.generated_root_dir_name) != null);
}

test "subcommand help aliases are accepted" {
    const long_args = [_][]const u8{ "zpkg", "--help" };
    const short_args = [_][]const u8{ "zpkg", "-h" };
    const command_args = [_][]const u8{ "zpkg", "help" };

    try std.testing.expect(shouldShowHelp(&long_args));
    try std.testing.expect(shouldShowHelp(&short_args));
    try std.testing.expect(shouldShowHelp(&command_args));
}
