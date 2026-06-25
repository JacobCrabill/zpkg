pub const cli = @import("cli/root.zig");
pub const model = @import("model/root.zig");
pub const schema = @import("schema/root.zig");
pub const hash = @import("hash/root.zig");
pub const resolve = @import("resolve/root.zig");
pub const realize = @import("realize/root.zig");
pub const store = @import("store/root.zig");
pub const export_pkg = @import("export/root.zig");
pub const util = @import("util/root.zig");

pub const generated_workspace_root = util.workspace.generated_root_dir_name;

test "bootstrap module layout is wired" {
    _ = cli;
    _ = model;
    _ = schema;
    _ = hash;
    _ = resolve;
    _ = realize;
    _ = store;
    _ = export_pkg;
    _ = util;
}

test "generated workspace root stays stable" {
    try std.testing.expectEqualStrings(".zpkg", generated_workspace_root);
}

const std = @import("std");
