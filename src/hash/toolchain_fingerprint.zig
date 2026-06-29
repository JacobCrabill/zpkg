const std = @import("std");
const model = @import("../model/root.zig");
const zon_util = @import("../schema/zon_util.zig");

/// Detect the toolchain fingerprint from the current environment.
///
/// Runs `zig version`, `zig env`, `cc --version`, and `c++ --version`.
/// Fields that cannot be determined precisely use non-empty sentinel values
/// so that `validate()` always passes.
///
/// All string fields of the returned fingerprint are heap-allocated and
/// owned by the caller.  Free them with `deinitOwned`.
pub fn detect(allocator: std.mem.Allocator, io: std.Io) !model.ToolchainFingerprint {
    // 1. zig version
    const zig_version = detectZigVersion(allocator, io) catch |err| blk: {
        warnStderr(io, "warning: failed to detect zig version ({s}); using sentinel\n", .{@errorName(err)});
        break :blk try allocator.dupe(u8, "unknown");
    };
    errdefer allocator.free(zig_version);

    // 2. host triple from `zig env`; target triple = host for native builds.
    const host_triple = detectHostTriple(allocator, io) catch |err| blk: {
        warnStderr(io, "warning: failed to detect host triple ({s}); using sentinel\n", .{@errorName(err)});
        break :blk try allocator.dupe(u8, "unknown-unknown-unknown");
    };
    errdefer allocator.free(host_triple);

    const target_triple = try allocator.dupe(u8, host_triple);
    errdefer allocator.free(target_triple);

    // 3. C compiler.
    const c_compiler = try detectCompilerIdentity(allocator, io, "cc");
    errdefer allocator.free(c_compiler.id);
    errdefer allocator.free(c_compiler.version);

    // 4. C++ compiler.
    const cxx_compiler = try detectCompilerIdentity(allocator, io, "c++");
    errdefer allocator.free(cxx_compiler.id);
    errdefer allocator.free(cxx_compiler.version);

    // 5. Hard-to-detect fields: use stable sentinels.
    //    Allocate each individually so errdefer can free partial work.
    const sysroot_id = try allocator.dupe(u8, "system");
    errdefer allocator.free(sysroot_id);
    const sysroot_ver = try allocator.dupe(u8, "unknown");
    errdefer allocator.free(sysroot_ver);

    const libc_id = try allocator.dupe(u8, "system");
    errdefer allocator.free(libc_id);
    const libc_ver = try allocator.dupe(u8, "unknown");
    errdefer allocator.free(libc_ver);

    const cxx_stdlib_id = try allocator.dupe(u8, "system");
    errdefer allocator.free(cxx_stdlib_id);
    const cxx_stdlib_ver = try allocator.dupe(u8, "unknown");
    errdefer allocator.free(cxx_stdlib_ver);

    const cxx_abi_mode = try allocator.dupe(u8, "unknown");
    errdefer allocator.free(cxx_abi_mode);

    return .{
        .zig_version = zig_version,
        .host_triple = host_triple,
        .target_triple = target_triple,
        .c_compiler = c_compiler,
        .cxx_compiler = cxx_compiler,
        .sysroot = .{ .id = sysroot_id, .version = sysroot_ver },
        .libc = .{ .id = libc_id, .version = libc_ver },
        .cxx_stdlib = .{ .id = cxx_stdlib_id, .version = cxx_stdlib_ver },
        .cxx_abi_mode = cxx_abi_mode,
    };
}

/// Free all heap-allocated fields of a fingerprint produced by `detect`.
pub fn deinitOwned(allocator: std.mem.Allocator, fp: model.ToolchainFingerprint) void {
    allocator.free(fp.zig_version);
    allocator.free(fp.host_triple);
    allocator.free(fp.target_triple);
    allocator.free(fp.c_compiler.id);
    allocator.free(fp.c_compiler.version);
    allocator.free(fp.cxx_compiler.id);
    allocator.free(fp.cxx_compiler.version);
    allocator.free(fp.sysroot.id);
    allocator.free(fp.sysroot.version);
    allocator.free(fp.libc.id);
    allocator.free(fp.libc.version);
    allocator.free(fp.cxx_stdlib.id);
    allocator.free(fp.cxx_stdlib.version);
    allocator.free(fp.cxx_abi_mode);
}

// ——— Private detection helpers ———

fn detectZigVersion(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "zig", "version" } });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyOutput;
    return allocator.dupe(u8, trimmed);
}

/// Run `zig env`, extract the `.target` field, and normalise it to a stable triple.
fn detectHostTriple(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "zig", "env" } });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    const raw = extractZigEnvTarget(result.stdout) orelse return error.TargetNotFound;
    return normalizeTriple(allocator, raw);
}

/// Locate the value of `.target = "…"` in `zig env` ZON output.
/// Returns a sub-slice of `env_output` (no allocation).
fn extractZigEnvTarget(env_output: []const u8) ?[]const u8 {
    const needle = ".target = \"";
    const start = std.mem.indexOf(u8, env_output, needle) orelse return null;
    const value_start = start + needle.len;
    const value_end = std.mem.indexOfScalarPos(u8, env_output, value_start, '"') orelse return null;
    return env_output[value_start..value_end];
}

/// Convert `x86_64-linux.6.17...6.17-gnu.2.39` → `x86_64-linux-gnu`.
///
/// Strategy:
///   arch = text before first '-'
///   os   = text after arch-dash, up to the first '.' or '-'
///   abi  = text after last '-', up to the first '.'
fn normalizeTriple(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const first_dash = std.mem.indexOfScalar(u8, raw, '-') orelse {
        return allocator.dupe(u8, raw);
    };
    const arch = raw[0..first_dash];
    const after_arch = raw[first_dash + 1 ..];

    // os: up to first '.' or '-'
    const os_end = for (after_arch, 0..) |ch, i| {
        if (ch == '.' or ch == '-') break i;
    } else after_arch.len;
    const os = after_arch[0..os_end];

    // abi: after last '-', before first '.'
    if (std.mem.lastIndexOfScalar(u8, after_arch, '-')) |last_dash| {
        const abi_with_ver = after_arch[last_dash + 1 ..];
        const abi_end = std.mem.indexOfScalar(u8, abi_with_ver, '.') orelse abi_with_ver.len;
        const abi = abi_with_ver[0..abi_end];
        if (abi.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ arch, os, abi });
        }
    }

    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ arch, os });
}

/// Run `<compiler> --version` and parse its first output line.
/// On any failure returns `.{ .id = "unknown", .version = "0" }` (both allocated).
fn detectCompilerIdentity(
    allocator: std.mem.Allocator,
    io: std.Io,
    compiler: []const u8,
) !model.ToolchainIdentity {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ compiler, "--version" },
    }) catch |err| {
        warnStderr(io, "warning: failed to run '{s} --version' ({s}); using sentinel identity\n", .{ compiler, @errorName(err) });
        return makeOwnedIdentity(allocator, "unknown", "0");
    };
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        warnStderr(io, "warning: '{s} --version' exited with error; using sentinel identity\n", .{compiler});
        return makeOwnedIdentity(allocator, "unknown", "0");
    }

    return parseCompilerFirstLine(allocator, result.stdout) catch {
        warnStderr(io, "warning: could not parse '{s} --version' output; using sentinel identity\n", .{compiler});
        return makeOwnedIdentity(allocator, "unknown", "0");
    };
}

/// Parse a line like `cc (Ubuntu 13.3.0-6ubuntu2~24.04) 13.3.0`.
///   id      = first word inside the parentheses (rejected if it is an absolute path)
///   version = first `X.Y[.Z…]` token after the closing paren
fn parseCompilerFirstLine(allocator: std.mem.Allocator, output: []const u8) !model.ToolchainIdentity {
    const line_end = std.mem.indexOfScalar(u8, output, '\n') orelse output.len;
    const line = output[0..line_end];

    const open = std.mem.indexOfScalar(u8, line, '(') orelse return error.NoParen;
    const close = std.mem.indexOfScalarPos(u8, line, open + 1, ')') orelse return error.NoParen;

    const inside = std.mem.trim(u8, line[open + 1 .. close], " \t");
    const id_end = std.mem.indexOfAny(u8, inside, " \t") orelse inside.len;
    const id_raw = inside[0..id_end];

    if (id_raw.len == 0) return error.EmptyId;
    // Absolute paths would fail validate(); caller falls back to sentinel.
    if (std.fs.path.isAbsolute(id_raw)) return error.AbsolutePathId;

    const id = try allocator.dupe(u8, id_raw);
    errdefer allocator.free(id);

    const version = try extractSemverToken(allocator, line[close + 1 ..]);
    return .{ .id = id, .version = version };
}

/// Extract the first `X.Y[.Z…]` token from `text`. Caller owns the returned slice.
fn extractSemverToken(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!std.ascii.isDigit(text[i])) continue;
        var j = i;
        var dot_count: usize = 0;
        while (j < text.len) : (j += 1) {
            const ch = text[j];
            if (std.ascii.isDigit(ch)) continue;
            if (ch == '.') {
                dot_count += 1;
                continue;
            }
            break;
        }
        if (dot_count >= 1) {
            // Strip any trailing dot.
            var end = j;
            while (end > i and text[end - 1] == '.') end -= 1;
            return allocator.dupe(u8, text[i..end]);
        }
        i = j;
    }
    return error.NoVersion;
}

fn makeOwnedIdentity(
    allocator: std.mem.Allocator,
    id: []const u8,
    ver: []const u8,
) !model.ToolchainIdentity {
    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    const owned_ver = try allocator.dupe(u8, ver);
    return .{ .id = owned_id, .version = owned_ver };
}

fn warnStderr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var f: std.Io.File.Writer = .init(.stderr(), io, &buf);
    f.interface.print(fmt, args) catch {};
    f.interface.flush() catch {};
}

pub fn writeCanonical(writer: *std.Io.Writer, fingerprint: model.ToolchainFingerprint) !void {
    try fingerprint.validate();

    try writer.writeAll(".{\n");
    try zon_util.writeIndent(writer, 1);
    try writer.print(".schema = {d},\n", .{fingerprint.schema});
    try zon_util.writeIndent(writer, 1);
    try writer.writeAll(".zig_version = ");
    try zon_util.writeString(writer, fingerprint.zig_version);
    try writer.writeAll(",\n");
    try zon_util.writeIndent(writer, 1);
    try writer.writeAll(".host_triple = ");
    try zon_util.writeString(writer, fingerprint.host_triple);
    try writer.writeAll(",\n");
    try zon_util.writeIndent(writer, 1);
    try writer.writeAll(".target_triple = ");
    try zon_util.writeString(writer, fingerprint.target_triple);
    try writer.writeAll(",\n");
    try writeIdentity(writer, 1, ".c_compiler", fingerprint.c_compiler);
    try writeIdentity(writer, 1, ".cxx_compiler", fingerprint.cxx_compiler);
    try writeIdentity(writer, 1, ".sysroot", fingerprint.sysroot);
    try writeIdentity(writer, 1, ".libc", fingerprint.libc);
    try writeIdentity(writer, 1, ".cxx_stdlib", fingerprint.cxx_stdlib);
    try writeStringField(writer, 1, ".cxx_abi_mode", fingerprint.cxx_abi_mode);
    try writer.writeAll("}\n");
}

pub fn serializeAlloc(allocator: std.mem.Allocator, fingerprint: model.ToolchainFingerprint) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try writeCanonical(&aw.writer, fingerprint);
    return try aw.toOwnedSlice();
}

pub fn addToHash(hash_helper: *std.Build.Cache.HashHelper, fingerprint: model.ToolchainFingerprint) !void {
    try fingerprint.validate();

    hash_helper.addBytes("zpkg.toolchain_fingerprint.v1");
    hash_helper.add(fingerprint.schema);
    addLabeledBytes(hash_helper, "zig_version", fingerprint.zig_version);
    addLabeledBytes(hash_helper, "host_triple", fingerprint.host_triple);
    addLabeledBytes(hash_helper, "target_triple", fingerprint.target_triple);
    addLabeledIdentity(hash_helper, "c_compiler", fingerprint.c_compiler);
    addLabeledIdentity(hash_helper, "cxx_compiler", fingerprint.cxx_compiler);
    addLabeledIdentity(hash_helper, "sysroot", fingerprint.sysroot);
    addLabeledIdentity(hash_helper, "libc", fingerprint.libc);
    addLabeledIdentity(hash_helper, "cxx_stdlib", fingerprint.cxx_stdlib);
    addLabeledBytes(hash_helper, "cxx_abi_mode", fingerprint.cxx_abi_mode);
}

pub fn digestHex(fingerprint: model.ToolchainFingerprint) !std.Build.Cache.HexDigest {
    var hash_helper: std.Build.Cache.HashHelper = .{};
    try addToHash(&hash_helper, fingerprint);
    return hash_helper.final();
}

fn writeIdentity(writer: *std.Io.Writer, depth: usize, field_name: []const u8, identity: model.ToolchainIdentity) !void {
    try zon_util.writeIndent(writer, depth);
    try writer.print("{s} = .{{\n", .{field_name});
    try zon_util.writeIndent(writer, depth + 1);
    try writer.writeAll(".id = ");
    try zon_util.writeString(writer, identity.id);
    try writer.writeAll(",\n");
    try zon_util.writeIndent(writer, depth + 1);
    try writer.writeAll(".version = ");
    try zon_util.writeString(writer, identity.version);
    try writer.writeAll(",\n");
    try zon_util.writeIndent(writer, depth);
    try writer.writeAll("},\n");
}

fn writeStringField(writer: *std.Io.Writer, depth: usize, field_name: []const u8, value: []const u8) !void {
    try zon_util.writeIndent(writer, depth);
    try writer.print("{s} = ", .{field_name});
    try zon_util.writeString(writer, value);
    try writer.writeAll(",\n");
}

fn addLabeledBytes(hash_helper: *std.Build.Cache.HashHelper, label: []const u8, value: []const u8) void {
    hash_helper.addBytes(label);
    hash_helper.addBytes(value);
}

fn addLabeledIdentity(hash_helper: *std.Build.Cache.HashHelper, label: []const u8, identity: model.ToolchainIdentity) void {
    hash_helper.addBytes(label);
    hash_helper.addBytes(identity.id);
    hash_helper.addBytes(identity.version);
}

fn sampleFingerprint() model.ToolchainFingerprint {
    return .{
        .zig_version = "0.16.0",
        .host_triple = "x86_64-linux-gnu",
        .target_triple = "aarch64-linux-gnu",
        .c_compiler = .{ .id = "clang", .version = "18.1.8" },
        .cxx_compiler = .{ .id = "clang++", .version = "18.1.8" },
        .sysroot = .{ .id = "ubuntu-22.04-sdk", .version = "2024.06" },
        .libc = .{ .id = "glibc", .version = "2.35" },
        .cxx_stdlib = .{ .id = "libstdc++", .version = "13.2.0" },
        .cxx_abi_mode = "gnu",
    };
}

test "toolchain fingerprint canonical serialization is stable" {
    const expected =
        \\.{
        \\    .schema = 1,
        \\    .zig_version = "0.16.0",
        \\    .host_triple = "x86_64-linux-gnu",
        \\    .target_triple = "aarch64-linux-gnu",
        \\    .c_compiler = .{
        \\        .id = "clang",
        \\        .version = "18.1.8",
        \\    },
        \\    .cxx_compiler = .{
        \\        .id = "clang++",
        \\        .version = "18.1.8",
        \\    },
        \\    .sysroot = .{
        \\        .id = "ubuntu-22.04-sdk",
        \\        .version = "2024.06",
        \\    },
        \\    .libc = .{
        \\        .id = "glibc",
        \\        .version = "2.35",
        \\    },
        \\    .cxx_stdlib = .{
        \\        .id = "libstdc++",
        \\        .version = "13.2.0",
        \\    },
        \\    .cxx_abi_mode = "gnu",
        \\}
        \\
    ;

    const serialized = try serializeAlloc(std.testing.allocator, sampleFingerprint());
    defer std.testing.allocator.free(serialized);

    try std.testing.expectEqualStrings(expected, serialized);
}

test "toolchain fingerprint digest is stable across repeated derivation" {
    const fingerprint = sampleFingerprint();
    const a = try digestHex(fingerprint);
    const b = try digestHex(fingerprint);

    try std.testing.expectEqualStrings(a[0..], b[0..]);
}

test "toolchain fingerprint serialization rejects empty required binary identity fields" {
    try std.testing.expectError(error.EmptyText, serializeAlloc(std.testing.allocator, .{
        .zig_version = "0.16.0",
        .host_triple = "x86_64-linux-gnu",
        .target_triple = "x86_64-linux-gnu",
        .c_compiler = .{ .id = "clang", .version = "18.1.8" },
        .cxx_compiler = .{ .id = "clang++", .version = "18.1.8" },
        .sysroot = .{ .id = "ubuntu-22.04-sdk", .version = "2024.06" },
        .libc = .{ .id = "glibc", .version = "2.35" },
        .cxx_stdlib = .{ .id = "libstdc++", .version = "13.2.0" },
        .cxx_abi_mode = "",
    }));
}
