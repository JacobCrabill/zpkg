const std = @import("std");

pub const ParseError = error{
    InvalidFormat,
    MissingComponent,
    TooManyComponents,
    EmptyComponent,
    Overflow,
};

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    revision: u32,

    pub fn init(major: u32, minor: u32, patch: u32, revision: u32) Version {
        return .{
            .major = major,
            .minor = minor,
            .patch = patch,
            .revision = revision,
        };
    }

    pub fn parse(text: []const u8) ParseError!Version {
        if (text.len == 0) return error.InvalidFormat;

        var values = [_]u32{ 0, 0, 0, 0 };
        var count: usize = 0;
        var parts = std.mem.splitScalar(u8, text, '.');
        while (parts.next()) |part| {
            if (count >= values.len) return error.TooManyComponents;
            if (part.len == 0) return error.EmptyComponent;
            values[count] = std.fmt.parseUnsigned(u32, part, 10) catch |err| switch (err) {
                error.InvalidCharacter => return error.InvalidFormat,
                error.Overflow => return error.Overflow,
            };
            count += 1;
        }

        if (count < 3) return error.MissingComponent;

        return .init(values[0], values[1], values[2], values[3]);
    }

    pub fn cmp(self: Version, other: Version) std.math.Order {
        if (self.major < other.major) return .lt;
        if (self.major > other.major) return .gt;
        if (self.minor < other.minor) return .lt;
        if (self.minor > other.minor) return .gt;
        if (self.patch < other.patch) return .lt;
        if (self.patch > other.patch) return .gt;
        if (self.revision < other.revision) return .lt;
        if (self.revision > other.revision) return .gt;
        return .eq;
    }

    pub fn eql(self: Version, other: Version) bool {
        return self.cmp(other) == .eq;
    }

    pub fn bufPrint(self: Version, buf: []u8) ![]u8 {
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ self.major, self.minor, self.patch, self.revision });
    }

    pub fn format(self: Version, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        try writer.print("{d}.{d}.{d}.{d}", .{ self.major, self.minor, self.patch, self.revision });
    }
};

test "normalize three-component version to four-component form" {
    const version = try Version.parse("1.2.3");
    var buf: [32]u8 = undefined;
    try std.testing.expectEqual(Version.init(1, 2, 3, 0), version);
    try std.testing.expectEqualStrings("1.2.3.0", try version.bufPrint(&buf));
}

test "parse explicit revision component" {
    const version = try Version.parse("1.2.3.4");
    try std.testing.expectEqual(Version.init(1, 2, 3, 4), version);
}

test "version ordering is lexicographic across normalized tuple" {
    const a = try Version.parse("1.2.3");
    const b = try Version.parse("1.2.3.0");
    const c = try Version.parse("1.2.3.1");
    const d = try Version.parse("1.2.4");

    try std.testing.expectEqual(std.math.Order.eq, a.cmp(b));
    try std.testing.expectEqual(std.math.Order.lt, a.cmp(c));
    try std.testing.expectEqual(std.math.Order.lt, c.cmp(d));
}

test "reject malformed version strings" {
    try std.testing.expectError(error.InvalidFormat, Version.parse(""));
    try std.testing.expectError(error.MissingComponent, Version.parse("1.2"));
    try std.testing.expectError(error.EmptyComponent, Version.parse("1..3"));
    try std.testing.expectError(error.TooManyComponents, Version.parse("1.2.3.4.5"));
    try std.testing.expectError(error.InvalidFormat, Version.parse("1.2.x"));
}
