const std = @import("std");

pub fn main() void {
    std.debug.print("hello-app placeholder\n", .{});
}

test "hello-app placeholder builds" {
    try std.testing.expect(true);
}
