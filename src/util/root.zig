pub const workspace = @import("workspace.zig");
pub const diag = @import("diag.zig");

test "util modules are available" {
    _ = workspace;
    _ = diag;
}
