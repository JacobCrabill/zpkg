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

pub const target = @import("target.zig");
pub const TargetKind = target.Kind;
pub const TargetLinkage = target.Linkage;
pub const TargetDeclaration = target.Declaration;
pub const NamedTargetDeclaration = target.NamedDeclaration;

pub const package = @import("package.zig");
pub const PackageSchemaVersion = package.schema_version;
pub const PackageBackend = package.Backend;
pub const PackageVersionRequirement = package.VersionRequirement;
pub const PackageInfo = package.PackageInfo;
pub const NamedOptionDefinition = package.NamedOptionDefinition;
pub const Dependency = package.Dependency;
pub const PackageManifest = package.Manifest;

pub const lockfile = @import("lockfile.zig");
pub const Lockfile = lockfile.Lockfile;
pub const LockfileRoot = lockfile.Root;
pub const LockfileGeneratedBy = lockfile.GeneratedBy;
pub const LockfileInstanceRef = lockfile.InstanceRef;
pub const LockfileInstance = lockfile.Instance;
pub const LockfileDependency = lockfile.Dependency;

pub const graph = @import("graph.zig");
pub const Graph = graph.Graph;
pub const GraphPackage = graph.Package;
pub const GraphDependencyAlias = graph.DependencyAlias;
pub const GraphTarget = graph.Target;
pub const GraphTargetKind = graph.TargetKind;
pub const GraphLinkage = graph.Linkage;
pub const GraphVisibility = graph.Visibility;
pub const GraphDependencyRole = graph.DependencyRole;
pub const GraphArtifactKind = graph.ArtifactKind;
pub const GraphResourceDir = graph.ResourceDir;

pub const manifest = @import("manifest.zig");
pub const ArtifactManifest = manifest.Manifest;
pub const ManifestDependency = manifest.Dependency;

test "model core exports are wired" {
    _ = domain;
    _ = version;
    _ = package_id;
    _ = options;
    _ = conditions;
    _ = target;
    _ = package;
    _ = lockfile;
    _ = graph;
    _ = manifest;
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
    _ = TargetKind;
    _ = TargetLinkage;
    _ = TargetDeclaration;
    _ = NamedTargetDeclaration;
    _ = PackageSchemaVersion;
    _ = PackageBackend;
    _ = PackageVersionRequirement;
    _ = PackageInfo;
    _ = NamedOptionDefinition;
    _ = Dependency;
    _ = PackageManifest;
    _ = Lockfile;
    _ = LockfileRoot;
    _ = LockfileGeneratedBy;
    _ = LockfileInstanceRef;
    _ = LockfileInstance;
    _ = LockfileDependency;
    _ = Graph;
    _ = GraphPackage;
    _ = GraphDependencyAlias;
    _ = GraphTarget;
    _ = GraphTargetKind;
    _ = GraphLinkage;
    _ = GraphVisibility;
    _ = GraphDependencyRole;
    _ = GraphArtifactKind;
    _ = GraphResourceDir;
    _ = ArtifactManifest;
    _ = ManifestDependency;
}
