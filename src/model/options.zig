const std = @import("std");

pub const Type = enum {
    bool,
    int,
    string,

    pub fn parse(text: []const u8) ?Type {
        return std.meta.stringToEnum(Type, text);
    }
};

pub const Value = union(Type) {
    bool: bool,
    int: i64,
    string: []const u8,

    pub fn kind(self: Value) Type {
        return std.meta.activeTag(self);
    }

    pub fn matchesType(self: Value, expected: Type) bool {
        return self.kind() == expected;
    }

    pub fn eql(self: Value, other: Value) bool {
        if (self.kind() != other.kind()) return false;
        return switch (self) {
            .bool => |value| value == other.bool,
            .int => |value| value == other.int,
            .string => |value| std.mem.eql(u8, value, other.string),
        };
    }

    pub fn cloneOwned(self: Value, allocator: std.mem.Allocator) !Value {
        return switch (self) {
            .bool, .int => self,
            .string => |value| .{ .string = try allocator.dupe(u8, value) },
        };
    }

    pub fn deinitOwned(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |value| allocator.free(value),
            .bool, .int => {},
        }
    }

    pub fn format(self: Value, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
        switch (self) {
            .bool => |value| try writer.print("{}", .{value}),
            .int => |value| try writer.print("{d}", .{value}),
            .string => |value| try writer.print("\"{s}\"", .{value}),
        }
    }
};

pub const DefinitionError = error{DefaultTypeMismatch};

pub const Definition = struct {
    kind: Type,
    default_value: Value,
    abi: bool,

    pub fn validate(self: Definition) DefinitionError!void {
        if (!self.default_value.matchesType(self.kind)) {
            return error.DefaultTypeMismatch;
        }
    }
};

pub const NamedValue = struct {
    name: []const u8,
    value: Value,
};

pub fn lookup(values: []const NamedValue, name: []const u8) ?Value {
    for (values) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

test "option value kind and equality" {
    const bool_value: Value = .{ .bool = true };
    const int_value: Value = .{ .int = 42 };
    const string_value: Value = .{ .string = "cuda" };
    const same_string: Value = .{ .string = "cuda" };
    const other_string: Value = .{ .string = "cpu" };

    try std.testing.expect(bool_value.matchesType(.bool));
    try std.testing.expect(int_value.matchesType(.int));
    try std.testing.expect(string_value.matchesType(.string));
    try std.testing.expect(string_value.eql(same_string));
    try std.testing.expect(!string_value.eql(other_string));
    try std.testing.expect(!int_value.eql(bool_value));
}

test "option definition validates default type" {
    const ok = Definition{
        .kind = .bool,
        .default_value = .{ .bool = true },
        .abi = true,
    };
    try ok.validate();

    const bad = Definition{
        .kind = .int,
        .default_value = .{ .string = "oops" },
        .abi = false,
    };
    try std.testing.expectError(error.DefaultTypeMismatch, bad.validate());
}

test "lookup option value by name" {
    const values = [_]NamedValue{
        .{ .name = "shared", .value = .{ .bool = true } },
        .{ .name = "api_level", .value = .{ .int = 2 } },
    };

    try std.testing.expect(lookup(values[0..], "shared").?.eql(.{ .bool = true }));
    try std.testing.expect(lookup(values[0..], "api_level").?.eql(.{ .int = 2 }));
    try std.testing.expectEqual(@as(?Value, null), lookup(values[0..], "missing"));
}

test "owned string option value can be cloned and released" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const borrowed: Value = .{ .string = "cuda" };
    const owned = try borrowed.cloneOwned(arena);

    try std.testing.expect(owned.eql(borrowed));
    try std.testing.expect(borrowed.string.ptr != owned.string.ptr);

    owned.deinitOwned(arena);
}
