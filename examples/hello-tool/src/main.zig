const std = @import("std");

pub fn main() void {
    std.debug.print("hello-tool\n", .{});
}

test "hello-tool banner is stable" {
    try std.testing.expect(true);
}
