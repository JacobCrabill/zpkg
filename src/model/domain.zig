const std = @import("std");

pub const ParseError = error{InvalidDomain};

pub const Domain = enum {
    host,
    target,

    pub fn parse(text: []const u8) ParseError!Domain {
        return std.meta.stringToEnum(Domain, text) orelse error.InvalidDomain;
    }

    pub fn fromRoleText(text: []const u8) ParseError!Domain {
        if (std.mem.eql(u8, text, "tool")) return .host;
        if (std.mem.eql(u8, text, "build")) return .host;
        if (std.mem.eql(u8, text, "test")) return .host;
        if (std.mem.eql(u8, text, "link")) return .target;
        return error.InvalidDomain;
    }

    pub fn asText(self: Domain) []const u8 {
        return @tagName(self);
    }

    pub fn format(self: Domain, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        try writer.writeAll(self.asText());
    }
};

test "parse domain text" {
    try std.testing.expectEqual(.host, try Domain.parse("host"));
    try std.testing.expectEqual(.target, try Domain.parse("target"));
    try std.testing.expectError(error.InvalidDomain, Domain.parse("runtime"));
}

test "map role text to resolution domain" {
    try std.testing.expectEqual(.host, try Domain.fromRoleText("tool"));
    try std.testing.expectEqual(.host, try Domain.fromRoleText("build"));
    try std.testing.expectEqual(.host, try Domain.fromRoleText("test"));
    try std.testing.expectEqual(.target, try Domain.fromRoleText("link"));
    try std.testing.expectError(error.InvalidDomain, Domain.fromRoleText("run"));
}
