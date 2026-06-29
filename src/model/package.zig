const std = @import("std");
const PackageId = @import("package_id.zig").PackageId;
const Version = @import("version.zig").Version;
const options = @import("options.zig");
const conditions = @import("conditions.zig");
const target = @import("target.zig");

pub const schema_version: u32 = 1;

pub const Backend = enum {
    zig,
};

pub const VersionRequirementParseError = error{
    InvalidFormat,
    InvalidVersion,
};

pub const VersionRequirement = struct {
    exact: Version,

    pub fn parse(text: []const u8) VersionRequirementParseError!VersionRequirement {
        if (text.len < 2 or text[0] != '=') return error.InvalidFormat;
        const version = Version.parse(text[1..]) catch return error.InvalidVersion;
        return .{ .exact = version };
    }

    pub fn format(self: VersionRequirement, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        try writer.print("={}", .{self.exact});
    }
};

pub const PackageInfo = struct {
    name: []const u8,
    id: PackageId,
    version: Version,
    backend: Backend,

    pub fn deinitOwned(self: *PackageInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.id.text);
    }
};

pub const NamedOptionDefinition = struct {
    name: []const u8,
    definition: options.Definition,

    pub fn deinitOwned(self: *NamedOptionDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.definition.default_value.deinitOwned(allocator);
    }
};

pub const Dependency = struct {
    alias: []const u8,
    package: PackageId,
    require: VersionRequirement,
    when: ?conditions.Condition = null,
    /// Relative path to the dependency's source directory, relative to the
    /// declaring package's zpkg.zon file location.
    source_path: ?[]const u8 = null,

    pub fn deinitOwned(self: *Dependency, allocator: std.mem.Allocator) void {
        allocator.free(self.alias);
        allocator.free(self.package.text);
        if (self.when) |condition| {
            condition.deinitOwned(allocator);
            self.when = null;
        }
        if (self.source_path) |sp| allocator.free(sp);
    }
};

pub const Manifest = struct {
    schema: u32,
    package: PackageInfo,
    options: []NamedOptionDefinition,
    deps: []Dependency,
    targets: []target.NamedDeclaration,

    pub fn deinitOwned(self: *Manifest, allocator: std.mem.Allocator) void {
        self.package.deinitOwned(allocator);

        for (self.options) |*option_definition| {
            option_definition.deinitOwned(allocator);
        }
        allocator.free(self.options);

        for (self.deps) |*dep| {
            dep.deinitOwned(allocator);
        }
        allocator.free(self.deps);

        for (self.targets) |*target_declaration| {
            target_declaration.deinitOwned(allocator);
        }
        allocator.free(self.targets);
    }
};

test "exact version requirements normalize to four-component version form" {
    const req = try VersionRequirement.parse("=1.2.3");
    try std.testing.expectEqual(Version.init(1, 2, 3, 0), req.exact);
}

test "manifest owned cleanup releases nested owned values" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var manifest = Manifest{
        .schema = schema_version,
        .package = .{
            .name = try arena.dupe(u8, "hello-lib"),
            .id = try PackageId.parse(try arena.dupe(u8, "zpkg.example.hello_lib")),
            .version = try Version.parse("0.1.0.0"),
            .backend = .zig,
        },
        .options = try arena.dupe(NamedOptionDefinition, &.{
            .{
                .name = try arena.dupe(u8, "shared"),
                .definition = .{
                    .kind = .bool,
                    .default_value = .{ .bool = true },
                    .abi = true,
                },
            },
        }),
        .deps = try arena.dupe(Dependency, &.{
            .{
                .alias = try arena.dupe(u8, "hello_tool"),
                .package = try PackageId.parse(try arena.dupe(u8, "zpkg.example.hello_tool")),
                .require = try VersionRequirement.parse("=0.1.0.0"),
                .when = try (conditions.Condition{
                    .domain = .host,
                }).cloneOwned(arena),
            },
        }),
        .targets = try arena.dupe(target.NamedDeclaration, &.{
            .{
                .name = try arena.dupe(u8, "hello"),
                .declaration = .{
                    .kind = .library,
                    .linkage = .@"default",
                },
            },
        }),
    };

    manifest.deinitOwned(arena);
}
