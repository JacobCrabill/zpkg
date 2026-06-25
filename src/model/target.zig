const std = @import("std");
const conditions = @import("conditions.zig");

pub const Kind = enum {
    library,
    executable,
    zig_module,
    headers,
    resource_set,
};

pub const Linkage = enum {
    default,
    shared,
    static,
};

pub const Declaration = struct {
    kind: Kind,
    linkage: ?Linkage = null,
    test_only: bool = false,
    when: ?conditions.Condition = null,

    pub fn deinitOwned(self: *Declaration, allocator: std.mem.Allocator) void {
        if (self.when) |condition| {
            condition.deinitOwned(allocator);
            self.when = null;
        }
    }
};

pub const NamedDeclaration = struct {
    name: []const u8,
    declaration: Declaration,

    pub fn deinitOwned(self: *NamedDeclaration, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.declaration.deinitOwned(allocator);
    }
};

test "target declaration owned cleanup handles optional condition" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var target = NamedDeclaration{
        .name = try arena.dupe(u8, "hello"),
        .declaration = .{
            .kind = .executable,
            .when = try (conditions.Condition{
                .options = &.{
                    .{ .name = "build_tests", .value = .{ .bool = true } },
                },
            }).cloneOwned(arena),
        },
    };

    target.deinitOwned(arena);
}
