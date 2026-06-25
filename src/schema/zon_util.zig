const std = @import("std");

pub const ParseError = error{
    ParseZon,
    ExpectedStruct,
    ExpectedArray,
    ExpectedString,
    ExpectedBool,
    ExpectedInt,
    ExpectedEnumLiteral,
    MissingField,
    UnknownField,
    InvalidSchemaVersion,
    InvalidVersion,
    InvalidPackageId,
    InvalidDomain,
    InvalidInstanceRef,
    InstanceKeyMismatch,
    DuplicateIdentity,
    MissingReferencedInstance,
    InvalidOptionValueType,
    InvalidField,
    EmptyString,
};

pub const Document = struct {
    ast: std.zig.Ast,
    zoir: std.zig.Zoir,

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        self.zoir.deinit(allocator);
        self.ast.deinit(allocator);
        self.* = undefined;
    }
};

pub fn parseDocument(allocator: std.mem.Allocator, source: [:0]const u8) !Document {
    var ast = try std.zig.Ast.parse(allocator, source, .zon);
    errdefer ast.deinit(allocator);

    var zoir = try std.zig.ZonGen.generate(allocator, ast, .{ .parse_str_lits = false });
    errdefer zoir.deinit(allocator);

    if (zoir.hasCompileErrors()) return error.ParseZon;

    return .{
        .ast = ast,
        .zoir = zoir,
    };
}

pub const Object = struct {
    doc: *const Document,
    names: []const std.zig.Zoir.NullTerminatedString,
    values: std.zig.Zoir.Node.Index.Range,

    pub fn fromNode(doc: *const Document, node: std.zig.Zoir.Node.Index) ParseError!Object {
        return switch (node.get(doc.zoir)) {
            .empty_literal => .{
                .doc = doc,
                .names = &.{},
                .values = .{ .start = @enumFromInt(1), .len = 0 },
            },
            .struct_literal => |value| .{
                .doc = doc,
                .names = value.names,
                .values = value.vals,
            },
            else => error.ExpectedStruct,
        };
    }

    pub fn fieldCount(self: Object) usize {
        return self.names.len;
    }

    pub fn fieldName(self: Object, index: usize) []const u8 {
        return self.names[index].get(self.doc.zoir);
    }

    pub fn fieldNode(self: Object, index: usize) std.zig.Zoir.Node.Index {
        return self.values.at(@intCast(index));
    }

    pub fn get(self: Object, name: []const u8) ?std.zig.Zoir.Node.Index {
        for (self.names, 0..) |field_name, index| {
            if (std.mem.eql(u8, field_name.get(self.doc.zoir), name)) {
                return self.values.at(@intCast(index));
            }
        }
        return null;
    }

    pub fn require(self: Object, name: []const u8) ParseError!std.zig.Zoir.Node.Index {
        return self.get(name) orelse error.MissingField;
    }

    pub fn validateOnlyFields(self: Object, allowed: []const []const u8) ParseError!void {
        field_loop: for (self.names) |field_name| {
            const text = field_name.get(self.doc.zoir);
            for (allowed) |allowed_name| {
                if (std.mem.eql(u8, text, allowed_name)) continue :field_loop;
            }
            return error.UnknownField;
        }
    }
};

pub const Array = struct {
    doc: *const Document,
    elements: std.zig.Zoir.Node.Index.Range,

    pub fn fromNode(doc: *const Document, node: std.zig.Zoir.Node.Index) ParseError!Array {
        return switch (node.get(doc.zoir)) {
            .empty_literal => .{
                .doc = doc,
                .elements = .{ .start = @enumFromInt(1), .len = 0 },
            },
            .array_literal => |value| .{
                .doc = doc,
                .elements = value,
            },
            else => error.ExpectedArray,
        };
    }

    pub fn len(self: Array) usize {
        return self.elements.len;
    }

    pub fn at(self: Array, index: usize) std.zig.Zoir.Node.Index {
        return self.elements.at(@intCast(index));
    }
};

pub fn parseNodeAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    doc: *const Document,
    node: std.zig.Zoir.Node.Index,
) !T {
    return std.zon.parse.fromZoirNodeAlloc(T, allocator, doc.ast, doc.zoir, node, null, .{}) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseZon => return error.ParseZon,
    };
}

pub fn parseStringAlloc(
    allocator: std.mem.Allocator,
    doc: *const Document,
    node: std.zig.Zoir.Node.Index,
) ![]const u8 {
    return parseNodeAlloc([]const u8, allocator, doc, node) catch |err| switch (err) {
        error.ParseZon => return error.ExpectedString,
        else => |e| return e,
    };
}

pub fn parseNonEmptyStringAlloc(
    allocator: std.mem.Allocator,
    doc: *const Document,
    node: std.zig.Zoir.Node.Index,
) ![]const u8 {
    const value = try parseStringAlloc(allocator, doc, node);
    if (value.len == 0) return error.EmptyString;
    return value;
}

pub fn parseBool(doc: *const Document, node: std.zig.Zoir.Node.Index) !bool {
    return parseNodeAlloc(bool, std.heap.page_allocator, doc, node) catch |err| switch (err) {
        error.ParseZon => return error.ExpectedBool,
        error.OutOfMemory => unreachable,
        else => |e| return e,
    };
}

pub fn parseInt(doc: *const Document, node: std.zig.Zoir.Node.Index) !i64 {
    return parseNodeAlloc(i64, std.heap.page_allocator, doc, node) catch |err| switch (err) {
        error.ParseZon => return error.ExpectedInt,
        error.OutOfMemory => unreachable,
        else => |e| return e,
    };
}

pub fn parseEnum(comptime T: type, doc: *const Document, node: std.zig.Zoir.Node.Index) !T {
    return parseNodeAlloc(T, std.heap.page_allocator, doc, node) catch |err| switch (err) {
        error.ParseZon => return error.ExpectedEnumLiteral,
        error.OutOfMemory => unreachable,
        else => |e| return e,
    };
}

pub fn parseOptionValueAlloc(
    allocator: std.mem.Allocator,
    doc: *const Document,
    node: std.zig.Zoir.Node.Index,
) !@import("../model/options.zig").Value {
    return switch (node.get(doc.zoir)) {
        .true => .{ .bool = true },
        .false => .{ .bool = false },
        .string_literal => .{ .string = try parseStringAlloc(allocator, doc, node) },
        .int_literal => .{ .int = try parseInt(doc, node) },
        else => error.InvalidOptionValueType,
    };
}

pub fn writeIndent(writer: *std.Io.Writer, depth: usize) !void {
    for (0..depth) |_| {
        try writer.writeAll("    ");
    }
}

pub fn writeQuotedFieldName(writer: *std.Io.Writer, name: []const u8) !void {
    if (isBareIdentifier(name)) {
        try writer.print(".{s}", .{name});
    } else {
        try writer.print(".@\"{s}\"", .{name});
    }
}

fn isBareIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    }
    return true;
}

pub fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.zon.stringify.serialize(value, .{}, writer);
}

pub fn writeOptionValue(writer: *std.Io.Writer, value: @import("../model/options.zig").Value) !void {
    switch (value) {
        .bool => |v| try writer.print("{}", .{v}),
        .int => |v| try writer.print("{d}", .{v}),
        .string => |v| try writeString(writer, v),
    }
}

pub fn compareOptionValue(a: @import("../model/options.zig").Value, b: @import("../model/options.zig").Value) std.math.Order {
    const a_tag = std.meta.activeTag(a);
    const b_tag = std.meta.activeTag(b);
    if (a_tag != b_tag) return std.math.order(@intFromEnum(a_tag), @intFromEnum(b_tag));
    return switch (a) {
        .bool => |value| std.math.order(@intFromBool(value), @intFromBool(b.bool)),
        .int => |value| std.math.order(value, b.int),
        .string => |value| std.mem.order(u8, value, b.string),
    };
}
