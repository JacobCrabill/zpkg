const std = @import("std");

pub const ParseError = error{
    Empty,
    MissingNamespace,
    EmptySegment,
};

pub const PackageId = struct {
    text: []const u8,

    pub fn parse(text: []const u8) ParseError!PackageId {
        try validate(text);
        return .{ .text = text };
    }

    pub fn validate(text: []const u8) ParseError!void {
        if (text.len == 0) return error.Empty;

        var segments = std.mem.splitScalar(u8, text, '.');
        var segment_count: usize = 0;
        while (segments.next()) |segment| {
            if (segment.len == 0) return error.EmptySegment;
            segment_count += 1;
        }

        if (segment_count < 2) return error.MissingNamespace;
    }

    pub fn eql(self: PackageId, other: PackageId) bool {
        return std.mem.eql(u8, self.text, other.text);
    }

    pub fn asText(self: PackageId) []const u8 {
        return self.text;
    }

    pub fn format(self: PackageId, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        try writer.writeAll(self.text);
    }
};

test "parse canonical package id" {
    const id = try PackageId.parse("sai.pilot.object_tracker");
    try std.testing.expectEqualStrings("sai.pilot.object_tracker", id.asText());
}

test "package ids compare by canonical text" {
    const a = try PackageId.parse("sai.upstream.libyaml");
    const b = try PackageId.parse("sai.upstream.libyaml");
    const c = try PackageId.parse("sai.upstream.protobuf");

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "package id validation stays aligned with documented contract" {
    _ = try PackageId.parse("SAI.Pilot.Object-Tracker");
    _ = try PackageId.parse("sai.9foo");
    _ = try PackageId.parse("sai.foo-bar");

    try std.testing.expectError(error.Empty, PackageId.parse(""));
    try std.testing.expectError(error.MissingNamespace, PackageId.parse("foo"));
    try std.testing.expectError(error.EmptySegment, PackageId.parse("sai..foo"));
    try std.testing.expectError(error.EmptySegment, PackageId.parse(".sai.foo"));
    try std.testing.expectError(error.EmptySegment, PackageId.parse("sai.foo."));
}
