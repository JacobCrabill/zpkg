const std = @import("std");

pub const generated_root_dir_name = ".zpkg";

test "generated workspace root convention is stable" {
    try std.testing.expectEqualStrings(".zpkg", generated_root_dir_name);
}
