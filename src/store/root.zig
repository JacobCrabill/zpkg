pub const layout = @import("layout.zig");
pub const manifest = @import("manifest.zig");
pub const archive = @import("archive.zig");
pub const store = @import("store.zig");
pub const Store = store.Store;
pub const StoreStatus = store.StoreStatus;
pub const ArtifactManifest = manifest.ArtifactManifest;

test "store module tree compiles" {
    _ = layout;
    _ = manifest;
    _ = archive;
    _ = store;
    _ = Store;
    _ = StoreStatus;
    _ = ArtifactManifest;
}
