const std = @import("std");

const work_subdir = "work";
const root_subdir = "root";
const deps_subdir = "deps";

pub fn defaultProfile() []const u8 {
    return "debug-native";
}

pub const WorkspaceLayout = struct {
    allocator: std.mem.Allocator,
    workspace_root: []const u8, // path to .zpkg/work/<profile>/
    profile: []const u8,

    /// `workspace_root_dir` is the absolute path to the project root (containing .zpkg/).
    /// `profile` is a short slug like "debug-native".
    /// Both slices are copied and owned by WorkspaceLayout.
    pub fn init(allocator: std.mem.Allocator, workspace_root_dir: []const u8, profile: []const u8) !WorkspaceLayout {
        const workspace_root = try std.Io.Dir.path.join(
            allocator,
            &.{ workspace_root_dir, ".zpkg", work_subdir, profile },
        );
        errdefer allocator.free(workspace_root);
        const profile_copy = try allocator.dupe(u8, profile);
        errdefer allocator.free(profile_copy);
        return .{
            .allocator = allocator,
            .workspace_root = workspace_root,
            .profile = profile_copy,
        };
    }

    pub fn deinit(self: *WorkspaceLayout) void {
        self.allocator.free(self.workspace_root);
        self.allocator.free(self.profile);
        self.* = undefined;
    }

    /// Returns path to the realized root package dir.
    /// Caller owns the returned slice.
    pub fn rootPkgDir(self: WorkspaceLayout, allocator: std.mem.Allocator) ![]u8 {
        return std.Io.Dir.path.join(allocator, &.{ self.workspace_root, root_subdir });
    }

    /// Returns path to a realized dep by instance key.
    /// Caller owns the returned slice.
    pub fn depPkgDir(self: WorkspaceLayout, allocator: std.mem.Allocator, instance_key: []const u8) ![]u8 {
        return std.Io.Dir.path.join(allocator, &.{ self.workspace_root, deps_subdir, instance_key });
    }

    /// Ensure all workspace directories exist.
    pub fn ensureDirs(self: WorkspaceLayout, io: std.Io) !void {
        try ensureDirAbsolute(io, self.workspace_root);
        const root_dir = try self.rootPkgDir(self.allocator);
        defer self.allocator.free(root_dir);
        try ensureDirAbsolute(io, root_dir);
        const deps_dir = try std.Io.Dir.path.join(self.allocator, &.{ self.workspace_root, deps_subdir });
        defer self.allocator.free(deps_dir);
        try ensureDirAbsolute(io, deps_dir);
    }
};

fn ensureDirAbsolute(io: std.Io, path: []const u8) !void {
    std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

test "WorkspaceLayout derives correct paths" {
    const allocator = std.testing.allocator;

    var layout = try WorkspaceLayout.init(allocator, "/project", "debug-native");
    defer layout.deinit();

    try std.testing.expectEqualStrings("/project/.zpkg/work/debug-native", layout.workspace_root);
    try std.testing.expectEqualStrings("debug-native", layout.profile);

    const root = try layout.rootPkgDir(allocator);
    defer allocator.free(root);
    try std.testing.expectEqualStrings("/project/.zpkg/work/debug-native/root", root);

    const dep = try layout.depPkgDir(allocator, "zpkg.example.hello_lib#target");
    defer allocator.free(dep);
    try std.testing.expectEqualStrings("/project/.zpkg/work/debug-native/deps/zpkg.example.hello_lib#target", dep);
}

test "defaultProfile returns stable value" {
    try std.testing.expectEqualStrings("debug-native", defaultProfile());
}
