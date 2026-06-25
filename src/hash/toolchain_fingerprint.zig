const std = @import("std");
const model = @import("../model/root.zig");
const zon_util = @import("../schema/zon_util.zig");

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
