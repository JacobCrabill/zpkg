const std = @import("std");
const root = @import("root.zig");

pub const TargetKind = root.TargetKind;
pub const Linkage = root.Linkage;
pub const RegisteredTarget = root.RegisteredTarget;

pub const ValidationError = error{
    DeclaredTargetNotRegistered,
    RegisteredExportNotDeclared,
    TargetKindMismatch,
    LinkageMismatch,
    UndeclaredDependencyAlias,
};

pub const ValidationIssue = struct {
    kind: ValidationError,
    target_name: []const u8,
    message: []const u8,
};

pub const ValidationResult = struct {
    errors: []ValidationIssue,

    pub fn deinit(self: *ValidationResult, allocator: std.mem.Allocator) void {
        for (self.errors) |issue| {
            allocator.free(issue.target_name);
            allocator.free(issue.message);
        }
        allocator.free(self.errors);
    }

    pub fn hasErrors(self: ValidationResult) bool {
        return self.errors.len > 0;
    }
};

pub const DeclaredTarget = struct {
    name: []const u8,
    kind: TargetKind,
    linkage: Linkage,
    exported: bool,
};

/// Validate registered targets against declared exports and dep aliases.
/// Pure function — no IO.
pub fn validate(
    allocator: std.mem.Allocator,
    declared_exports: []const DeclaredTarget,
    declared_dep_aliases: []const []const u8,
    registered: []const RegisteredTarget,
) !ValidationResult {
    var issues: std.ArrayList(ValidationIssue) = .empty;
    errdefer {
        for (issues.items) |issue| {
            allocator.free(issue.target_name);
            allocator.free(issue.message);
        }
        issues.deinit(allocator);
    }

    // 1. Every declared exported target must be registered.
    for (declared_exports) |decl| {
        if (!decl.exported) continue;
        const reg = findRegistered(registered, decl.name) orelse {
            try issues.append(allocator, .{
                .kind = ValidationError.DeclaredTargetNotRegistered,
                .target_name = try allocator.dupe(u8, decl.name),
                .message = try std.fmt.allocPrint(
                    allocator,
                    "declared target '{s}' was not registered in build.zig",
                    .{decl.name},
                ),
            });
            continue;
        };
        // 2. Kind must match.
        if (reg.kind != decl.kind) {
            try issues.append(allocator, .{
                .kind = ValidationError.TargetKindMismatch,
                .target_name = try allocator.dupe(u8, decl.name),
                .message = try std.fmt.allocPrint(
                    allocator,
                    "target '{s}': declared kind .{s} but registered as .{s}",
                    .{ decl.name, decl.kind.asText(), reg.kind.asText() },
                ),
            });
        }
        // 3. Linkage must match (when declared is not .default).
        if (decl.linkage != .default and reg.linkage != decl.linkage) {
            try issues.append(allocator, .{
                .kind = ValidationError.LinkageMismatch,
                .target_name = try allocator.dupe(u8, decl.name),
                .message = try std.fmt.allocPrint(
                    allocator,
                    "target '{s}': declared linkage .{s} but registered as .{s}",
                    .{ decl.name, decl.linkage.asText(), reg.linkage.asText() },
                ),
            });
        }
    }

    // 4. Every registered exported target must appear in declared_exports.
    for (registered) |reg| {
        if (!reg.exported) continue;
        const found = for (declared_exports) |decl| {
            if (std.mem.eql(u8, decl.name, reg.name)) break true;
        } else false;
        if (!found) {
            try issues.append(allocator, .{
                .kind = ValidationError.RegisteredExportNotDeclared,
                .target_name = try allocator.dupe(u8, reg.name),
                .message = try std.fmt.allocPrint(
                    allocator,
                    "registered export '{s}' is not declared in zpkg.zon",
                    .{reg.name},
                ),
            });
        }
    }

    // 5. Every edge dep_alias must appear in declared_dep_aliases.
    for (registered) |reg| {
        for (reg.edges.items) |edge| {
            const found = for (declared_dep_aliases) |alias| {
                if (std.mem.eql(u8, alias, edge.dep_alias)) break true;
            } else false;
            if (!found) {
                try issues.append(allocator, .{
                    .kind = ValidationError.UndeclaredDependencyAlias,
                    .target_name = try allocator.dupe(u8, reg.name),
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "target '{s}' references undeclared dep alias '{s}'",
                        .{ reg.name, edge.dep_alias },
                    ),
                });
            }
        }
    }

    return ValidationResult{ .errors = try issues.toOwnedSlice(allocator) };
}

fn findRegistered(registered: []const RegisteredTarget, name: []const u8) ?RegisteredTarget {
    for (registered) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

// ---- Unit tests ----

test "validate: no errors on matching declared and registered" {
    const allocator = std.testing.allocator;

    const declared = [_]DeclaredTarget{
        .{ .name = "hello", .kind = .library, .linkage = .dynamic, .exported = true },
    };
    const aliases = [_][]const u8{};

    const reg = [_]RegisteredTarget{.{
        .name = "hello",
        .kind = .library,
        .linkage = .dynamic,
        .exported = true,
        .edges = .empty,
        .include_dirs = .empty,
        .compile_defs = .empty,
        .artifacts = .empty,
        .system_libs = .empty,
        .resources = .empty,
    }};

    var result = try validate(allocator, &declared, &aliases, &reg);
    defer result.deinit(allocator);

    try std.testing.expect(!result.hasErrors());
}

test "validate: detects declared target not registered" {
    const allocator = std.testing.allocator;

    const declared = [_]DeclaredTarget{
        .{ .name = "missing_lib", .kind = .library, .linkage = .default, .exported = true },
    };
    const aliases = [_][]const u8{};
    const reg = [_]RegisteredTarget{};

    var result = try validate(allocator, &declared, &aliases, &reg);
    defer result.deinit(allocator);

    try std.testing.expect(result.hasErrors());
    try std.testing.expect(result.errors[0].kind == ValidationError.DeclaredTargetNotRegistered);
}

test "validate: detects linkage mismatch" {
    const allocator = std.testing.allocator;

    const declared = [_]DeclaredTarget{
        .{ .name = "mylib", .kind = .library, .linkage = .static, .exported = true },
    };
    const aliases = [_][]const u8{};
    const reg = [_]RegisteredTarget{.{
        .name = "mylib",
        .kind = .library,
        .linkage = .dynamic,
        .exported = true,
        .edges = .empty,
        .include_dirs = .empty,
        .compile_defs = .empty,
        .artifacts = .empty,
        .system_libs = .empty,
        .resources = .empty,
    }};

    var result = try validate(allocator, &declared, &aliases, &reg);
    defer result.deinit(allocator);

    try std.testing.expect(result.hasErrors());
    try std.testing.expect(result.errors[0].kind == ValidationError.LinkageMismatch);
}
