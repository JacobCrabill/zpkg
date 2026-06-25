const std = @import("std");

pub const schema_version: u32 = 1;

pub const ValidationError = error{
    EmptyText,
    AbsolutePathIdentity,
};

pub const Identity = struct {
    id: []const u8,
    version: []const u8,

    pub fn validate(self: Identity) ValidationError!void {
        try validateIdentityText(self.id);
        try validateIdentityText(self.version);
    }
};

pub const Fingerprint = struct {
    schema: u32 = schema_version,
    zig_version: []const u8,
    host_triple: []const u8,
    target_triple: []const u8,
    c_compiler: Identity,
    cxx_compiler: Identity,
    sysroot: Identity,
    libc: Identity,
    cxx_stdlib: Identity,
    cxx_abi_mode: []const u8,

    pub fn validate(self: Fingerprint) ValidationError!void {
        try validateIdentityText(self.zig_version);
        try validateIdentityText(self.host_triple);
        try validateIdentityText(self.target_triple);
        try self.c_compiler.validate();
        try self.cxx_compiler.validate();
        try self.sysroot.validate();
        try self.libc.validate();
        try self.cxx_stdlib.validate();
        try validateIdentityText(self.cxx_abi_mode);
    }
};

pub fn validateIdentityText(text: []const u8) ValidationError!void {
    if (text.len == 0) return error.EmptyText;
    if (std.fs.path.isAbsolute(text)) return error.AbsolutePathIdentity;
}

test "toolchain fingerprint rejects empty required identity fields" {
    const bad = Fingerprint{
        .zig_version = "0.16.0",
        .host_triple = "x86_64-linux-gnu",
        .target_triple = "x86_64-linux-gnu",
        .c_compiler = .{ .id = "clang", .version = "" },
        .cxx_compiler = .{ .id = "clang++", .version = "18.1.8" },
        .sysroot = .{ .id = "ubuntu-22.04-sdk", .version = "2024.06" },
        .libc = .{ .id = "glibc", .version = "2.35" },
        .cxx_stdlib = .{ .id = "libstdc++", .version = "13.2.0" },
        .cxx_abi_mode = "gnu",
    };

    try std.testing.expectError(error.EmptyText, bad.validate());
}

test "toolchain fingerprint rejects absolute path identity inputs" {
    const bad = Fingerprint{
        .zig_version = "0.16.0",
        .host_triple = "x86_64-linux-gnu",
        .target_triple = "x86_64-linux-gnu",
        .c_compiler = .{
            .id = "/usr/bin/clang",
            .version = "18.1.8",
        },
        .cxx_compiler = .{ .id = "clang++", .version = "18.1.8" },
        .sysroot = .{ .id = "ubuntu-22.04-sdk", .version = "2024.06" },
        .libc = .{ .id = "glibc", .version = "2.35" },
        .cxx_stdlib = .{ .id = "libstdc++", .version = "13.2.0" },
        .cxx_abi_mode = "gnu",
    };

    try std.testing.expectError(error.AbsolutePathIdentity, bad.validate());
}

test "toolchain fingerprint accepts stable non path identity fields" {
    const fingerprint = Fingerprint{
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

    try fingerprint.validate();
}
