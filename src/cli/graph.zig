const std = @import("std");
const schema = @import("../schema/root.zig");
const model = @import("../model/root.zig");
const diag = @import("../util/diag.zig");

const usage_text =
    \\usage: zpkg graph <pkg-root> [--verbose]
    \\
    \\Show the resolved package graph from zpkg.lock.zon.
    \\
    \\Options:
    \\  --verbose   Also print selected options and dep instance keys per instance
    \\
;

pub fn run(args: []const []const u8, io: std.Io) !void {
    // Parse args
    var pkg_root: ?[]const u8 = null;
    var verbose = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try writeStdout(io, usage_text);
            return;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (pkg_root == null) {
            pkg_root = arg;
        } else {
            try diag.writeError(io, "unexpected argument: {s}", .{arg});
            try diag.writeHint(io, "run 'zpkg graph --help' for usage", .{});
            return error.InvalidArgument;
        }
    }

    const root = pkg_root orelse {
        try diag.writeError(io, "graph expects a package root path", .{});
        try diag.writeHint(io, "usage: zpkg graph <pkg-root> [--verbose]", .{});
        return error.InvalidArgument;
    };

    const allocator = std.heap.page_allocator;

    // Open pkg-root dir
    var pkg_dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch |err| {
        try diag.writeError(io, "cannot open package root '{s}': {s}", .{ root, @errorName(err) });
        return error.InvalidArgument;
    };
    defer pkg_dir.close(io);

    // Read zpkg.lock.zon
    const lockfile_bytes = pkg_dir.readFileAlloc(io, "zpkg.lock.zon", allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            try diag.writeLockfileMissingError(io);
            return error.LockfileNotFound;
        },
        else => return err,
    };
    defer allocator.free(lockfile_bytes);

    const lockfile_sentinel = allocator.dupeZ(u8, lockfile_bytes) catch return error.OutOfMemory;
    defer allocator.free(lockfile_sentinel);

    const lockfile = schema.parseLockfileSourceAlloc(allocator, lockfile_sentinel) catch |err| {
        try diag.writeError(io, "failed to parse zpkg.lock.zon: {s}", .{@errorName(err)});
        try diag.writeHint(io, "run 'zpkg lock <pkg-root>' to regenerate the lockfile", .{});
        return error.InvalidArgument;
    };
    defer lockfile.deinit(allocator);

    // Print graph
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer_file.interface;

    var version_buf: [32]u8 = undefined;

    // Print root
    const root_version = lockfile.root.version.bufPrint(&version_buf) catch "?";
    try stdout.print("{s}#target @ {s}\n", .{ lockfile.root.package_id.asText(), root_version });

    // Find root instance to get its deps
    const root_ref = model.LockfileInstanceRef{
        .package_id = lockfile.root.package_id,
        .domain = .target,
    };
    if (lockfile.findInstance(root_ref)) |root_instance| {
        try printInstanceDeps(stdout, lockfile, root_instance, verbose, 1, &version_buf);
    } else {
        // No instance entry for root; just list all instances flat
        for (lockfile.instances) |*instance| {
            const inst_version = instance.version.bufPrint(&version_buf) catch "?";
            try stdout.print("  {s}#{s} @ {s}\n", .{
                instance.package_id.asText(),
                instance.domain.asText(),
                inst_version,
            });
        }
    }

    try stdout.flush();
}

fn printInstanceDeps(
    stdout: *std.Io.Writer,
    lockfile: model.Lockfile,
    instance: *const model.LockfileInstance,
    verbose: bool,
    depth: usize,
    version_buf: *[32]u8,
) !void {
    if (verbose) {
        if (instance.selected_options.len > 0) {
            try writeIndent(stdout, depth + 1);
            try stdout.writeAll("options:");
            for (instance.selected_options) |opt| {
                try stdout.print(" {s}=", .{opt.name});
                switch (opt.value) {
                    .bool => |b| try stdout.print("{}", .{b}),
                    .int => |n| try stdout.print("{d}", .{n}),
                    .string => |s| try stdout.print("{s}", .{s}),
                }
            }
            try stdout.writeAll("\n");
        }
        if (instance.deps.len > 0) {
            try writeIndent(stdout, depth + 1);
            try stdout.writeAll("deps:\n");
        }
    }

    for (instance.deps, 0..) |dep, idx| {
        const is_last = idx == instance.deps.len - 1;
        const connector = if (is_last) "└─" else "├─";
        try writeIndent(stdout, depth);
        const host_suffix = if (dep.instance.domain == .host) " (host)" else "";
        try stdout.print("{s} {s}: {s}#{s}{s}\n", .{
            connector,
            dep.alias,
            dep.instance.package_id.asText(),
            dep.instance.domain.asText(),
            host_suffix,
        });

        // Recurse — use "│ " continuation prefix for non-last, "  " for last
        if (lockfile.findInstance(dep.instance)) |child| {
            if (verbose) {
                const child_version = child.version.bufPrint(version_buf) catch "?";
                try writeIndent(stdout, depth + 1);
                try stdout.print("@ {s}\n", .{child_version});
            }
            try printInstanceDeps(stdout, lockfile, child, verbose, depth + 1, version_buf);
        }
    }
}

fn writeIndent(writer: *std.Io.Writer, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try writer.writeAll("  ");
    }
}

const writeStdout = diag.writeStdout;
const writeStderr = diag.writeStderr;
const writeStderrFmt = diag.writeStderrFmt;
