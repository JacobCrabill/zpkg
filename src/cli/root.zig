const std = @import("std");
const inspect = @import("inspect.zig");
const lock = @import("lock.zig");
const update = @import("update.zig");
const realize_cmd = @import("realize.zig");
const workspace = @import("../util/workspace.zig");

pub const help_text =
    \\zpkg - Zig package workspace realizer
    \\
    \\Status: package schema, resolution, and lockfile authority implemented.
    \\
    \\Usage:
    \\  zpkg [command]
    \\  zpkg --help
    \\
    \\Commands:
    \\  inspect   Inspect package metadata from <pkg-root>/zpkg.zon
    \\  graph     Show resolved package graph (placeholder)
    \\  lock      Create an authoritative lockfile
    \\  update    Update the authoritative lockfile
    \\  realize   Materialize a generated workspace
    \\  build     Build from an authoritative lockfile (placeholder)
    \\  test      Build and run the test graph (placeholder)
    \\  export    Export a relocatable closure bundle (placeholder)
    \\
    \\Generated workspace root: .zpkg/
    \\
;

pub fn run(args: []const []const u8, io: std.Io) !void {
    if (shouldShowHelp(args) or args.len == 1) {
        return writeHelp(io);
    }

    if (std.mem.eql(u8, args[1], "inspect")) {
        return inspect.run(args, io);
    } else if (std.mem.eql(u8, args[1], "lock")) {
        return lock.run(args, io);
    } else if (std.mem.eql(u8, args[1], "update")) {
        return update.run(args, io);
    } else if (std.mem.eql(u8, args[1], "realize")) {
        return realize_cmd.run(args, io);
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
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer_file.interface;
    try stdout.writeAll(help_text);
    try stdout.flush();
}

fn writeUnknownCommand(io: std.Io, command: []const u8) !void {
    var stderr_buffer: [2048]u8 = undefined;
    var stderr_writer_file: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_writer_file.interface;
    try stderr.print("error: unknown command: {s}\n\n", .{command});
    try stderr.writeAll(help_text);
    try stderr.flush();
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
