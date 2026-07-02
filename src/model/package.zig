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
    UnsatisfiableRange,
};

/// One side of a version range. `version` is compared on the `x.y.z` triple.
pub const Bound = struct {
    version: Version,
    inclusive: bool,
};

/// A dependency version requirement.
///
/// - `exact` (`=x.y.z[.t]`) matches on all four components — the only form that
///   honors the release-tweak `revision` digit.
/// - `range` is a bounded interval compared on `x.y.z` only (revision ignored);
///   both bounds absent means "any" (`*`). Operators `>= <= > < ^ ~` and a
///   comma-separated conjunction all normalize into this interval.
pub const VersionRequirement = union(enum) {
    exact: Version,
    range: struct { lower: ?Bound = null, upper: ?Bound = null },

    /// Does concrete version `v` satisfy this requirement?
    pub fn satisfies(self: VersionRequirement, v: Version) bool {
        switch (self) {
            .exact => |e| return e.eql(v),
            .range => |r| {
                if (r.lower) |lo| {
                    const ord = v.cmp3(lo.version);
                    if (ord == .lt) return false;
                    if (ord == .eq and !lo.inclusive) return false;
                }
                if (r.upper) |hi| {
                    const ord = v.cmp3(hi.version);
                    if (ord == .gt) return false;
                    if (ord == .eq and !hi.inclusive) return false;
                }
                return true;
            },
        }
    }

    /// Parse a requirement string: a comma-separated conjunction of comparators.
    /// `=x.y.z[.t]` and `*`/`any` must each appear alone.
    pub fn parse(text: []const u8) VersionRequirementParseError!VersionRequirement {
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0) return error.InvalidFormat;

        if (std.mem.eql(u8, trimmed, "*") or std.mem.eql(u8, trimmed, "any")) {
            return .{ .range = .{} };
        }

        var lower: ?Bound = null;
        var upper: ?Bound = null;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, trimmed, ',');
        while (it.next()) |raw| {
            const c = std.mem.trim(u8, raw, " \t");
            if (c.len == 0) return error.InvalidFormat;
            count += 1;

            // `=` and `*` are only valid as the sole comparator.
            if (c[0] == '=') {
                if (count != 1 or it.next() != null) return error.InvalidFormat;
                return .{ .exact = try parseVersion(c[1..]) };
            }
            if (std.mem.eql(u8, c, "*") or std.mem.eql(u8, c, "any")) return error.InvalidFormat;

            const comp = try parseComparator(c);
            if (comp.lower) |b| lower = tightenLower(lower, b);
            if (comp.upper) |b| upper = tightenUpper(upper, b);
        }

        if (lower) |lo| if (upper) |hi| {
            const ord = lo.version.cmp3(hi.version);
            if (ord == .gt) return error.UnsatisfiableRange;
            if (ord == .eq and !(lo.inclusive and hi.inclusive)) return error.UnsatisfiableRange;
        };

        return .{ .range = .{ .lower = lower, .upper = upper } };
    }

    /// Render the canonical form of this requirement into `buf`. Exact renders as
    /// `=x.y.z.t`; ranges render as normalized comparators on `x.y.z`.
    pub fn bufPrint(self: VersionRequirement, buf: []u8) ![]u8 {
        switch (self) {
            .exact => |e| return std.fmt.bufPrint(buf, "={d}.{d}.{d}.{d}", .{ e.major, e.minor, e.patch, e.revision }),
            .range => |r| {
                if (r.lower == null and r.upper == null) return std.fmt.bufPrint(buf, "*", .{});
                // Build "op x.y.z[, op x.y.z]".
                var len: usize = 0;
                if (r.lower) |lo| {
                    const op = if (lo.inclusive) ">=" else ">";
                    const s = try std.fmt.bufPrint(buf[len..], "{s}{d}.{d}.{d}", .{ op, lo.version.major, lo.version.minor, lo.version.patch });
                    len += s.len;
                }
                if (r.upper) |hi| {
                    const sep = if (r.lower != null) ", " else "";
                    const op = if (hi.inclusive) "<=" else "<";
                    const s = try std.fmt.bufPrint(buf[len..], "{s}{s}{d}.{d}.{d}", .{ sep, op, hi.version.major, hi.version.minor, hi.version.patch });
                    len += s.len;
                }
                return buf[0..len];
            },
        }
    }
};

const Comparator = struct { lower: ?Bound = null, upper: ?Bound = null };

fn parseComparator(c: []const u8) VersionRequirementParseError!Comparator {
    if (std.mem.startsWith(u8, c, ">=")) return .{ .lower = .{ .version = try parseVersion(c[2..]), .inclusive = true } };
    if (std.mem.startsWith(u8, c, "<=")) return .{ .upper = .{ .version = try parseVersion(c[2..]), .inclusive = true } };
    if (std.mem.startsWith(u8, c, ">")) return .{ .lower = .{ .version = try parseVersion(c[1..]), .inclusive = false } };
    if (std.mem.startsWith(u8, c, "<")) return .{ .upper = .{ .version = try parseVersion(c[1..]), .inclusive = false } };
    if (std.mem.startsWith(u8, c, "^")) return caretRange(try parseVersion(c[1..]));
    if (std.mem.startsWith(u8, c, "~")) return tildeRange(try parseVersion(c[1..]));
    // Bare version → caret (Cargo default).
    return caretRange(try parseVersion(c));
}

/// `^v` → `>=v, <` next compatible: bump the leftmost non-zero of major/minor/patch.
fn caretRange(v: Version) Comparator {
    const upper: Version = if (v.major > 0)
        .{ .major = v.major + 1, .minor = 0, .patch = 0, .revision = 0 }
    else if (v.minor > 0)
        .{ .major = 0, .minor = v.minor + 1, .patch = 0, .revision = 0 }
    else
        .{ .major = 0, .minor = 0, .patch = v.patch + 1, .revision = 0 };
    return .{ .lower = .{ .version = v, .inclusive = true }, .upper = .{ .version = upper, .inclusive = false } };
}

/// `~v` → `>=v, <x.(y+1).0`.
fn tildeRange(v: Version) Comparator {
    const upper: Version = .{ .major = v.major, .minor = v.minor + 1, .patch = 0, .revision = 0 };
    return .{ .lower = .{ .version = v, .inclusive = true }, .upper = .{ .version = upper, .inclusive = false } };
}

fn parseVersion(text: []const u8) VersionRequirementParseError!Version {
    if (text.len == 0) return error.InvalidFormat;
    return Version.parse(text) catch return error.InvalidVersion;
}

fn tightenLower(cur: ?Bound, new: Bound) Bound {
    const c = cur orelse return new;
    return switch (new.version.cmp3(c.version)) {
        .gt => new,
        .lt => c,
        .eq => if (!new.inclusive) new else c, // exclusive is tighter
    };
}

fn tightenUpper(cur: ?Bound, new: Bound) Bound {
    const c = cur orelse return new;
    return switch (new.version.cmp3(c.version)) {
        .lt => new,
        .gt => c,
        .eq => if (!new.inclusive) new else c, // exclusive is tighter
    };
}

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

fn expectSatisfies(req_text: []const u8, ver_text: []const u8, want: bool) !void {
    const req = try VersionRequirement.parse(req_text);
    const v = try Version.parse(ver_text);
    try std.testing.expectEqual(want, req.satisfies(v));
}

test "exact matches all four components; revision is a release-tweak pin" {
    try expectSatisfies("=1.2.3", "1.2.3.0", true);
    try expectSatisfies("=1.2.3", "1.2.3.5", false); // =x.y.z means the .0 release
    try expectSatisfies("=1.2.3.5", "1.2.3.5", true);
    try expectSatisfies("=1.2.3.5", "1.2.3.0", false);
}

test "range operators ignore the revision digit" {
    // caret: >=1.2.3, <2.0.0
    try expectSatisfies("^1.2.3", "1.2.3.0", true);
    try expectSatisfies("^1.2.3", "1.2.3.5", true); // revision ignored
    try expectSatisfies("^1.2.3", "1.9.9.0", true);
    try expectSatisfies("^1.2.3", "2.0.0.0", false);
    try expectSatisfies("^1.2.3", "1.2.2.0", false);
    // caret 0.x: >=0.2.3, <0.3.0
    try expectSatisfies("^0.2.3", "0.2.9.0", true);
    try expectSatisfies("^0.2.3", "0.3.0.0", false);
    // caret 0.0.x: >=0.0.3, <0.0.4
    try expectSatisfies("^0.0.3", "0.0.3.7", true);
    try expectSatisfies("^0.0.3", "0.0.4.0", false);
    // tilde: >=1.2.3, <1.3.0
    try expectSatisfies("~1.2.3", "1.2.9.0", true);
    try expectSatisfies("~1.2.3", "1.3.0.0", false);
}

test "comparators, intersections, and any" {
    try expectSatisfies(">=1.2.0", "1.2.0.0", true);
    try expectSatisfies(">1.2.0", "1.2.0.0", false);
    try expectSatisfies("<2.0.0", "1.9.0.0", true);
    try expectSatisfies("<=2.0.0", "2.0.0.0", true);
    try expectSatisfies(">=1.2.0, <2.0.0", "1.5.0.0", true);
    try expectSatisfies(">=1.2.0, <2.0.0", "2.0.0.0", false);
    try expectSatisfies("*", "0.0.1.0", true);
    try expectSatisfies("any", "99.0.0.0", true);
    // bare version means caret
    try expectSatisfies("1.2.3", "1.9.0.0", true);
    try expectSatisfies("1.2.3", "2.0.0.0", false);
}

test "malformed and unsatisfiable requirements are rejected" {
    try std.testing.expectError(error.InvalidFormat, VersionRequirement.parse(""));
    try std.testing.expectError(error.InvalidVersion, VersionRequirement.parse("=1.2.x"));
    try std.testing.expectError(error.InvalidVersion, VersionRequirement.parse("^1.2")); // too few components
    try std.testing.expectError(error.InvalidFormat, VersionRequirement.parse("=1.2.3, <2.0.0")); // = must be alone
    try std.testing.expectError(error.UnsatisfiableRange, VersionRequirement.parse(">=2.0.0, <1.0.0"));
}

test "requirement round-trips through bufPrint" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("=1.2.3.0", try (try VersionRequirement.parse("=1.2.3")).bufPrint(&buf));
    try std.testing.expectEqualStrings("=1.2.3.5", try (try VersionRequirement.parse("=1.2.3.5")).bufPrint(&buf));
    try std.testing.expectEqualStrings(">=1.2.3, <2.0.0", try (try VersionRequirement.parse("^1.2.3")).bufPrint(&buf));
    try std.testing.expectEqualStrings("*", try (try VersionRequirement.parse("*")).bufPrint(&buf));
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
