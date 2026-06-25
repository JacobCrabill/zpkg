const std = @import("std");

pub const domain = @import("domain.zig");
pub const Domain = domain.Domain;

pub const version = @import("version.zig");
pub const Version = version.Version;

pub const package_id = @import("package_id.zig");
pub const PackageId = package_id.PackageId;

pub const options = @import("options.zig");
pub const OptionType = options.Type;
pub const OptionValue = options.Value;
pub const OptionDefinition = options.Definition;
pub const NamedOptionValue = options.NamedValue;

pub const conditions = @import("conditions.zig");
pub const Condition = conditions.Condition;
pub const ConditionEnvironment = conditions.Environment;
pub const ConditionOptionMatch = conditions.OptionMatch;
pub const ConditionOs = conditions.Os;
pub const ConditionArch = conditions.Arch;

test "model core exports are wired" {
    _ = domain;
    _ = version;
    _ = package_id;
    _ = options;
    _ = conditions;
}

test "model root references exported types" {
    _ = Domain;
    _ = Version;
    _ = PackageId;
    _ = OptionType;
    _ = OptionValue;
    _ = OptionDefinition;
    _ = NamedOptionValue;
    _ = Condition;
    _ = ConditionEnvironment;
    _ = ConditionOptionMatch;
    _ = ConditionOs;
    _ = ConditionArch;
}
