const std = @import("std");
const model = @import("../model/root.zig");
const toolchain_fingerprint = @import("toolchain_fingerprint.zig");

pub const DeriveError = model.ToolchainValidationError || error{
    EmptySourceHash,
    OutOfMemory,
};

pub const Dependency = struct {
    instance_ref: model.LockfileInstanceRef,
    instance_key: []const u8,
};

pub const Input = struct {
    package_schema_version: u32 = model.PackageSchemaVersion,
    package_id: model.PackageId,
    version: model.Version,
    domain: model.Domain,
    source_hash: []const u8,
    abi_option_names: []const []const u8 = &.{},
    selected_options: []const model.NamedOptionValue = &.{},
    optimize: std.builtin.OptimizeMode,
    linkage: model.GraphLinkage,
    toolchain_fingerprint: model.ToolchainFingerprint,
    dependencies: []const Dependency = &.{},
};

pub fn addToHash(
    allocator: std.mem.Allocator,
    hash_helper: *std.Build.Cache.HashHelper,
    input: Input,
) DeriveError!void {
    if (input.source_hash.len == 0) return error.EmptySourceHash;
    try input.toolchain_fingerprint.validate();

    hash_helper.addBytes("zpkg.instance_key.v1");
    hash_helper.addBytes("package_schema_version");
    hash_helper.add(input.package_schema_version);
    hash_helper.addBytes("package_id");
    hash_helper.addBytes(input.package_id.asText());
    hash_helper.addBytes("version");
    var version_buf: [32]u8 = undefined;
    hash_helper.addBytes(input.version.bufPrint(&version_buf) catch unreachable);
    hash_helper.addBytes("domain");
    hash_helper.addBytes(input.domain.asText());
    hash_helper.addBytes("source_hash");
    hash_helper.addBytes(input.source_hash);

    const sorted_abi_options = try sortedAbiOptionsAlloc(allocator, input.abi_option_names, input.selected_options);
    defer allocator.free(sorted_abi_options);
    hash_helper.addBytes("abi_options");
    hash_helper.add(sorted_abi_options.len);
    for (sorted_abi_options) |entry| {
        hash_helper.addBytes(entry.name);
        addOptionValue(hash_helper, entry.value);
    }

    hash_helper.addBytes("optimize");
    hash_helper.addBytes(@tagName(input.optimize));
    hash_helper.addBytes("linkage");
    hash_helper.addBytes(input.linkage.asText());

    hash_helper.addBytes("toolchain_fingerprint");
    try toolchain_fingerprint.addToHash(hash_helper, input.toolchain_fingerprint);

    const sorted_dependencies = try sortedDependenciesAlloc(allocator, input.dependencies);
    defer allocator.free(sorted_dependencies);
    hash_helper.addBytes("dependencies");
    hash_helper.add(sorted_dependencies.len);
    for (sorted_dependencies) |dependency| {
        hash_helper.addBytes(dependency.instance_ref.package_id.asText());
        hash_helper.addBytes(dependency.instance_ref.domain.asText());
        hash_helper.addBytes(dependency.instance_key);
    }
}

pub fn deriveHex(allocator: std.mem.Allocator, input: Input) DeriveError!std.Build.Cache.HexDigest {
    var hash_helper: std.Build.Cache.HashHelper = .{};
    try addToHash(allocator, &hash_helper, input);
    return hash_helper.final();
}

fn sortedAbiOptionsAlloc(
    allocator: std.mem.Allocator,
    abi_option_names: []const []const u8,
    selected_options: []const model.NamedOptionValue,
) ![]const model.NamedOptionValue {
    var abi_count: usize = 0;
    for (selected_options) |entry| {
        if (containsString(abi_option_names, entry.name)) abi_count += 1;
    }

    const filtered = try allocator.alloc(model.NamedOptionValue, abi_count);
    var index: usize = 0;
    for (selected_options) |entry| {
        if (!containsString(abi_option_names, entry.name)) continue;
        filtered[index] = entry;
        index += 1;
    }

    sortSlice(model.NamedOptionValue, filtered, namedOptionValueLessThan);
    return filtered;
}

fn sortedDependenciesAlloc(allocator: std.mem.Allocator, dependencies: []const Dependency) ![]const Dependency {
    const sorted = try allocator.dupe(Dependency, dependencies);
    sortSlice(Dependency, sorted, dependencyLessThan);
    return sorted;
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |candidate| {
        if (std.mem.eql(u8, candidate, needle)) return true;
    }
    return false;
}

fn addOptionValue(hash_helper: *std.Build.Cache.HashHelper, value: model.OptionValue) void {
    const tag = std.meta.activeTag(value);
    hash_helper.addBytes(@tagName(tag));
    switch (value) {
        .bool => |v| hash_helper.add(v),
        .int => |v| hash_helper.add(v),
        .string => |v| hash_helper.addBytes(v),
    }
}

fn namedOptionValueLessThan(a: model.NamedOptionValue, b: model.NamedOptionValue) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn dependencyLessThan(a: Dependency, b: Dependency) bool {
    const package_order = std.mem.order(u8, a.instance_ref.package_id.asText(), b.instance_ref.package_id.asText());
    if (package_order != .eq) return package_order == .lt;
    if (a.instance_ref.domain != b.instance_ref.domain) {
        return @intFromEnum(a.instance_ref.domain) < @intFromEnum(b.instance_ref.domain);
    }
    return std.mem.order(u8, a.instance_key, b.instance_key) == .lt;
}

fn sortSlice(comptime T: type, items: []T, lessThan: fn (T, T) bool) void {
    if (items.len <= 1) return;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const value = items[i];
        var j = i;
        while (j > 0 and lessThan(value, items[j - 1])) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = value;
    }
}

fn sampleToolchain() model.ToolchainFingerprint {
    return .{
        .zig_version = "0.16.0",
        .host_triple = "x86_64-linux-gnu",
        .target_triple = "x86_64-linux-gnu",
        .c_compiler = .{ .id = "clang", .version = "18.1.8" },
        .cxx_compiler = .{ .id = "clang++", .version = "18.1.8" },
        .sysroot = .{ .id = "ubuntu-22.04-sdk", .version = "2024.06" },
        .libc = .{ .id = "glibc", .version = "2.35" },
        .cxx_stdlib = .{ .id = "libstdc++", .version = "13.2.0" },
        .cxx_abi_mode = "gnu",
    };
}

fn sampleSelectedOptions() [3]model.NamedOptionValue {
    return .{
        .{ .name = "shared", .value = .{ .bool = true } },
        .{ .name = "with_cuda", .value = .{ .bool = false } },
        .{ .name = "build_tests", .value = .{ .bool = false } },
    };
}

fn dependencyRef(package_id: []const u8, domain: model.Domain) Dependency {
    return .{
        .instance_ref = .{
            .package_id = model.PackageId.parse(package_id) catch unreachable,
            .domain = domain,
        },
        .instance_key = "dep-key-a",
    };
}

fn sampleInput(selected_options: []const model.NamedOptionValue, dependencies: []const Dependency) Input {
    return .{
        .package_schema_version = model.PackageSchemaVersion,
        .package_id = model.PackageId.parse("zpkg.example.root") catch unreachable,
        .version = model.Version.parse("1.2.3") catch unreachable,
        .domain = .target,
        .source_hash = "source-hash-001",
        .abi_option_names = &.{ "shared", "with_cuda" },
        .selected_options = selected_options,
        .optimize = .ReleaseFast,
        .linkage = .shared,
        .toolchain_fingerprint = sampleToolchain(),
        .dependencies = dependencies,
    };
}

test "instance key derivation is stable" {
    const options = sampleSelectedOptions();
    const deps = [_]Dependency{dependencyRef("zpkg.example.dep", .target)};
    const input = sampleInput(options[0..], deps[0..]);

    const a = try deriveHex(std.testing.allocator, input);
    const b = try deriveHex(std.testing.allocator, input);

    try std.testing.expectEqualStrings(a[0..], b[0..]);
}

test "abi option flip changes instance key" {
    var options_a = sampleSelectedOptions();
    var options_b = sampleSelectedOptions();
    options_b[1] = .{ .name = "with_cuda", .value = .{ .bool = true } };

    const key_a = try deriveHex(std.testing.allocator, sampleInput(options_a[0..], &.{}));
    const key_b = try deriveHex(std.testing.allocator, sampleInput(options_b[0..], &.{}));

    try std.testing.expect(!std.mem.eql(u8, key_a[0..], key_b[0..]));
}

test "non abi option flip does not change instance key" {
    var options_a = sampleSelectedOptions();
    var options_b = sampleSelectedOptions();
    options_b[2] = .{ .name = "build_tests", .value = .{ .bool = true } };

    const key_a = try deriveHex(std.testing.allocator, sampleInput(options_a[0..], &.{}));
    const key_b = try deriveHex(std.testing.allocator, sampleInput(options_b[0..], &.{}));

    try std.testing.expectEqualStrings(key_a[0..], key_b[0..]);
}

test "host versus target domain changes instance key" {
    const options = sampleSelectedOptions();
    var host_input = sampleInput(options[0..], &.{});
    host_input.domain = .host;
    var target_input = sampleInput(options[0..], &.{});
    target_input.domain = .target;

    const host_key = try deriveHex(std.testing.allocator, host_input);
    const target_key = try deriveHex(std.testing.allocator, target_input);

    try std.testing.expect(!std.mem.eql(u8, host_key[0..], target_key[0..]));
}

test "dependency instance key change propagates upward" {
    const options = sampleSelectedOptions();
    const deps_a = [_]Dependency{.{
        .instance_ref = .{
            .package_id = model.PackageId.parse("zpkg.example.dep") catch unreachable,
            .domain = .target,
        },
        .instance_key = "dep-key-a",
    }};
    const deps_b = [_]Dependency{.{
        .instance_ref = .{
            .package_id = model.PackageId.parse("zpkg.example.dep") catch unreachable,
            .domain = .target,
        },
        .instance_key = "dep-key-b",
    }};

    const key_a = try deriveHex(std.testing.allocator, sampleInput(options[0..], deps_a[0..]));
    const key_b = try deriveHex(std.testing.allocator, sampleInput(options[0..], deps_b[0..]));

    try std.testing.expect(!std.mem.eql(u8, key_a[0..], key_b[0..]));
}

test "option and dependency ordering does not matter" {
    const options_a = [_]model.NamedOptionValue{
        .{ .name = "shared", .value = .{ .bool = true } },
        .{ .name = "build_tests", .value = .{ .bool = false } },
        .{ .name = "with_cuda", .value = .{ .bool = false } },
    };
    const options_b = [_]model.NamedOptionValue{
        .{ .name = "with_cuda", .value = .{ .bool = false } },
        .{ .name = "shared", .value = .{ .bool = true } },
        .{ .name = "build_tests", .value = .{ .bool = false } },
    };

    const deps_a = [_]Dependency{
        .{
            .instance_ref = .{
                .package_id = model.PackageId.parse("zpkg.example.b") catch unreachable,
                .domain = .host,
            },
            .instance_key = "dep-b",
        },
        .{
            .instance_ref = .{
                .package_id = model.PackageId.parse("zpkg.example.a") catch unreachable,
                .domain = .target,
            },
            .instance_key = "dep-a",
        },
    };
    const deps_b = [_]Dependency{
        .{
            .instance_ref = .{
                .package_id = model.PackageId.parse("zpkg.example.a") catch unreachable,
                .domain = .target,
            },
            .instance_key = "dep-a",
        },
        .{
            .instance_ref = .{
                .package_id = model.PackageId.parse("zpkg.example.b") catch unreachable,
                .domain = .host,
            },
            .instance_key = "dep-b",
        },
    };

    const key_a = try deriveHex(std.testing.allocator, sampleInput(options_a[0..], deps_a[0..]));
    const key_b = try deriveHex(std.testing.allocator, sampleInput(options_b[0..], deps_b[0..]));

    try std.testing.expectEqualStrings(key_a[0..], key_b[0..]);
}

test "instance key derivation rejects absolute path toolchain identity inputs" {
    const options = sampleSelectedOptions();
    var input = sampleInput(options[0..], &.{});
    input.toolchain_fingerprint.c_compiler = .{ .id = "/usr/bin/clang", .version = "18.1.8" };

    try std.testing.expectError(error.AbsolutePathIdentity, deriveHex(std.testing.allocator, input));
}
