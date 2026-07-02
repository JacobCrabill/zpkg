pub const workspace = @import("workspace.zig");
pub const diag = @import("diag.zig");
pub const status = @import("status.zig");

test "util modules are available" {
    _ = workspace;
    _ = diag;
    _ = status;
}
