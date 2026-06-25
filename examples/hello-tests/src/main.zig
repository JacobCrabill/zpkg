const std = @import("std");

pub fn main() void {
    std.debug.print("hello-tests placeholder\n", .{});
}

test "hello-tests placeholder succeeds" {
    try std.testing.expectEqual(@as(i32, 2), 1 + 1);
}
