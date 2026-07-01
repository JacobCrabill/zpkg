const std = @import("std");
const model = @import("../model/root.zig");

/// A build configuration: *how* sources are compiled, as opposed to *which*
/// sources are resolved (which the lockfile pins). A Profile feeds two things:
/// the content-addressed store key (via optimize/linkage/target) and the
/// workspace directory slug. It never enters the lockfile.
///
/// See docs/profile-target-axis-plan.md.
pub const Profile = struct {
    optimize: std.builtin.OptimizeMode = .Debug,
    linkage: model.GraphLinkage = .static,
    /// null = native (host); otherwise a Zig target triple, e.g. "x86_64-linux-gnu".
    target: ?[]const u8 = null,

    /// Stable directory slug for `.zpkg/work/<slug>/`.
    ///
    /// Format: `<optimize>-<target-or-native>[-shared]`, lowercased. The `-shared`
    /// suffix appears only for non-default (shared) linkage, so the default profile
    /// yields exactly `"debug-native"` — preserving existing workspace/store paths.
    /// Examples: `"debug-native"`, `"releasefast-native"`,
    /// `"releasefast-x86_64-linux-gnu-shared"`. Caller owns the result.
    pub fn slug(self: Profile, allocator: std.mem.Allocator) ![]u8 {
        const linkage_suffix = if (self.linkage == .shared) "-shared" else "";
        const raw = try std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{
            @tagName(self.optimize),
            self.target orelse "native",
            linkage_suffix,
        });
        // Lowercase for a stable, predictable slug (target triples are lowercase).
        for (raw) |*c| c.* = std.ascii.toLower(c.*);
        return raw;
    }
};

test "default profile slug is debug-native" {
    const allocator = std.testing.allocator;
    const s = try (Profile{}).slug(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("debug-native", s);
}

test "optimize mode is reflected and lowercased" {
    const allocator = std.testing.allocator;
    const s = try (Profile{ .optimize = .ReleaseFast }).slug(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("releasefast-native", s);
}

test "explicit target triple appears in slug" {
    const allocator = std.testing.allocator;
    const s = try (Profile{ .optimize = .ReleaseSafe, .target = "x86_64-linux-gnu" }).slug(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("releasesafe-x86_64-linux-gnu", s);
}

test "shared linkage adds a suffix; static does not" {
    const allocator = std.testing.allocator;

    const shared = try (Profile{ .linkage = .shared, .target = "aarch64-macos" }).slug(allocator);
    defer allocator.free(shared);
    try std.testing.expectEqualStrings("debug-aarch64-macos-shared", shared);

    const static = try (Profile{ .linkage = .static }).slug(allocator);
    defer allocator.free(static);
    try std.testing.expectEqualStrings("debug-native", static);
}
