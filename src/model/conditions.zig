const std = @import("std");
const domain_model = @import("domain.zig");
const options = @import("options.zig");

pub const Domain = domain_model.Domain;
pub const Os = std.Target.Os.Tag;
pub const Arch = std.Target.Cpu.Arch;

pub const ParseError = error{
    UnknownOs,
    UnknownArch,
};

pub const Environment = struct {
    domain: Domain,
    host_os: Os,
    host_arch: Arch,
    target_os: Os,
    target_arch: Arch,
};

/// Resolution environment for the machine zpkg is running on.
///
/// `domain` is `.target` and the target OS/arch mirror the host: this iteration
/// resolves for the native target only (see docs/profile-target-axis-plan.md).
/// Cross-target resolution is deferred future work; the build profile
/// (optimize/target/linkage) is a separate axis handled at build time.
pub fn detectHost() Environment {
    const builtin = @import("builtin");
    const host_os: Os = builtin.os.tag;
    const host_arch: Arch = builtin.cpu.arch;
    return .{
        .domain = .target,
        .host_os = host_os,
        .host_arch = host_arch,
        .target_os = host_os,
        .target_arch = host_arch,
    };
}

pub const OptionMatch = struct {
    name: []const u8,
    value: options.Value,

    pub fn cloneOwned(self: OptionMatch, allocator: std.mem.Allocator) !OptionMatch {
        const owned_name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(owned_name);

        return .{
            .name = owned_name,
            .value = try self.value.cloneOwned(allocator),
        };
    }

    pub fn deinitOwned(self: OptionMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.value.deinitOwned(allocator);
    }
};

pub const Condition = struct {
    domain: ?Domain = null,
    host_os: ?Os = null,
    host_arch: ?Arch = null,
    target_os: ?Os = null,
    target_arch: ?Arch = null,
    options: []const OptionMatch = &.{},

    pub fn cloneOwned(self: Condition, allocator: std.mem.Allocator) !Condition {
        const owned_options = try allocator.alloc(OptionMatch, self.options.len);
        errdefer allocator.free(owned_options);

        var initialized: usize = 0;
        errdefer {
            for (owned_options[0..initialized]) |owned_entry| {
                owned_entry.deinitOwned(allocator);
            }
        }

        for (self.options, 0..) |entry, index| {
            owned_options[index] = try entry.cloneOwned(allocator);
            initialized += 1;
        }

        return .{
            .domain = self.domain,
            .host_os = self.host_os,
            .host_arch = self.host_arch,
            .target_os = self.target_os,
            .target_arch = self.target_arch,
            .options = owned_options,
        };
    }

    pub fn isEmpty(self: Condition) bool {
        return self.domain == null and
            self.host_os == null and
            self.host_arch == null and
            self.target_os == null and
            self.target_arch == null and
            self.options.len == 0;
    }

    pub fn matches(self: Condition, environment: Environment, option_values: []const options.NamedValue) bool {
        if (self.domain) |value| {
            if (environment.domain != value) return false;
        }
        if (self.host_os) |value| {
            if (environment.host_os != value) return false;
        }
        if (self.host_arch) |value| {
            if (environment.host_arch != value) return false;
        }
        if (self.target_os) |value| {
            if (environment.target_os != value) return false;
        }
        if (self.target_arch) |value| {
            if (environment.target_arch != value) return false;
        }
        for (self.options) |expected| {
            const actual = options.lookup(option_values, expected.name) orelse return false;
            if (!actual.eql(expected.value)) return false;
        }
        return true;
    }

    pub fn deinitOwned(self: Condition, allocator: std.mem.Allocator) void {
        for (self.options) |entry| {
            entry.deinitOwned(allocator);
        }
        allocator.free(self.options);
    }
};

pub fn parseOs(text: []const u8) ParseError!Os {
    return std.meta.stringToEnum(Os, text) orelse error.UnknownOs;
}

pub fn parseArch(text: []const u8) ParseError!Arch {
    return std.meta.stringToEnum(Arch, text) orelse error.UnknownArch;
}

test "condition matches all configured axes" {
    const condition = Condition{
        .domain = .host,
        .host_os = .linux,
        .target_arch = .x86_64,
        .options = &.{
            .{ .name = "build_tests", .value = .{ .bool = true } },
            .{ .name = "shared", .value = .{ .bool = false } },
        },
    };
    const environment = Environment{
        .domain = .host,
        .host_os = .linux,
        .host_arch = .x86_64,
        .target_os = .linux,
        .target_arch = .x86_64,
    };
    const option_values = [_]options.NamedValue{
        .{ .name = "build_tests", .value = .{ .bool = true } },
        .{ .name = "shared", .value = .{ .bool = false } },
    };

    try std.testing.expect(condition.matches(environment, option_values[0..]));
}

test "condition fails on mismatched or missing option values" {
    const condition = Condition{
        .target_os = .linux,
        .options = &.{
            .{ .name = "shared", .value = .{ .bool = true } },
        },
    };
    const environment = Environment{
        .domain = .target,
        .host_os = .linux,
        .host_arch = .x86_64,
        .target_os = .linux,
        .target_arch = .aarch64,
    };
    const mismatched_values = [_]options.NamedValue{
        .{ .name = "shared", .value = .{ .bool = false } },
    };

    try std.testing.expect(!condition.matches(environment, mismatched_values[0..]));
    try std.testing.expect(!condition.matches(environment, &.{}));
}

test "parse supported platform identifiers" {
    try std.testing.expectEqual(.linux, try parseOs("linux"));
    try std.testing.expectEqual(.x86_64, try parseArch("x86_64"));
    try std.testing.expectError(error.UnknownOs, parseOs("not_an_os"));
    try std.testing.expectError(error.UnknownArch, parseArch("not_an_arch"));
}

test "borrowed condition can be cloned into owned storage and released" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const borrowed = Condition{
        .domain = .target,
        .target_os = .linux,
        .options = &.{
            .{ .name = "mode", .value = .{ .string = "cuda" } },
            .{ .name = "shared", .value = .{ .bool = true } },
        },
    };

    const owned = try borrowed.cloneOwned(arena);
    try std.testing.expect(owned.matches(
        .{
            .domain = .target,
            .host_os = .linux,
            .host_arch = .x86_64,
            .target_os = .linux,
            .target_arch = .x86_64,
        },
        &.{
            .{ .name = "mode", .value = .{ .string = "cuda" } },
            .{ .name = "shared", .value = .{ .bool = true } },
        },
    ));
    try std.testing.expect(borrowed.options[0].name.ptr != owned.options[0].name.ptr);
    try std.testing.expect(borrowed.options[0].value.string.ptr != owned.options[0].value.string.ptr);

    owned.deinitOwned(arena);
}

test "detectHost mirrors the compiled-in host and resolves native" {
    const builtin = @import("builtin");
    const env = detectHost();
    try std.testing.expectEqual(builtin.os.tag, env.host_os);
    try std.testing.expectEqual(builtin.cpu.arch, env.host_arch);
    // Native: target mirrors host, domain is target.
    try std.testing.expectEqual(env.host_os, env.target_os);
    try std.testing.expectEqual(env.host_arch, env.target_arch);
    try std.testing.expectEqual(Domain.target, env.domain);
}
