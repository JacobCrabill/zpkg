const std = @import("std");

pub fn greeting() []const u8 {
    return "hello-lib";
}

pub export fn helloNumber() i32 {
    return 42;
}

test "hello-lib greeting stays stable" {
    try std.testing.expectEqualStrings("hello-lib", greeting());
}
