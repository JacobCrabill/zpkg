pub const zpkg = @import("zpkg.zig");
pub const ZpkgManifest = zpkg.Manifest;
pub const parseZpkgSourceAlloc = zpkg.parseSliceAlloc;

pub const lockfile = @import("lockfile.zig");
pub const Lockfile = @import("../model/lockfile.zig").Lockfile;
pub const parseLockfileSourceAlloc = lockfile.parseSourceAlloc;

pub const graph = @import("graph.zig");
pub const Graph = @import("../model/graph.zig").Graph;
pub const parseGraphSourceAlloc = graph.parseSourceAlloc;

pub const manifest = @import("manifest.zig");
pub const ManifestMetadata = @import("../model/manifest.zig").Manifest;
pub const parseManifestSourceAlloc = manifest.parseSourceAlloc;

test "schema exports schema parsers" {
    _ = zpkg;
    _ = ZpkgManifest;
    _ = parseZpkgSourceAlloc;
    _ = lockfile;
    _ = Lockfile;
    _ = parseLockfileSourceAlloc;
    _ = graph;
    _ = Graph;
    _ = parseGraphSourceAlloc;
    _ = manifest;
    _ = ManifestMetadata;
    _ = parseManifestSourceAlloc;
}
