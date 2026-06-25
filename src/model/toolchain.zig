const std = @import("std");

pub const schema_version: u32 = 1;

pub const ValidationError = error{
    EmptyText,
    AbsolutePathIdentity,
};

pub const Identity = struct {
    id: []const u8,
    version: ?[]const u8 = null,

    pub fn validate(self: Identity) ValidationError!void {
        try validateIdentityText(self.id);
        if (self.version) |version| try validateIdentityText(version);
    }
};

pub const Fingerprint = struct {
    schema: u32 = schema_version,
    zig_version: []const u8,
    host_triple: []const u8,
    target_triple: []const u8,
    c_compiler: ?Identity = null,
    cxx_compiler: ?Identity = null,
    sysroot: ?Identity = null,
    libc: ?Identity = null,
    cxx_stdlib: ?Identity = null,
    cxx_abi_mode: ?[]const u8 = null,

    pub fn validate(self: Fingerprint) ValidationError!void {
        try validateIdentityText(self.zig_version);
        try validateIdentityText(self.host_triple);
        try validateIdentityText(self.target_triple);
        if (self.c_compiler) |value| try value.validate();
        if (self.cxx_compiler) |value| try value.validate();
        if (self.sysroot) |value| try value.validate();
        if (self.libc) |value| try value.validate();
        if (self.cxx_stdlib) |value| try value.validate();
        if (self.cxx_abi_mode) |value| try validateIdentityText(value);
    }
};

pub fn validateIdentityText(text: []const u8) ValidationError!void {
    if (text.len == 0) return error.EmptyText;
    if (std.fs.path.isAbsolute(text)) return error.AbsolutePathIdentity;
}

test "toolchain fingerprint rejects empty identity fields" {
    const bad = Fingerprint{
        .zig_version = "",
        .host_triple = "x86_64-linux-gnu",
        .target_triple = "x86_64-linux-gnu",
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
