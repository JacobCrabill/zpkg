pub const toolchain_fingerprint = @import("toolchain_fingerprint.zig");
pub const serializeToolchainFingerprintAlloc = toolchain_fingerprint.serializeAlloc;
pub const hashToolchainFingerprint = toolchain_fingerprint.addToHash;
pub const digestToolchainFingerprintHex = toolchain_fingerprint.digestHex;

pub const instance_key = @import("instance_key.zig");
pub const InstanceKeyInput = instance_key.Input;
pub const InstanceKeyDependency = instance_key.Dependency;
pub const addInstanceKeyToHash = instance_key.addToHash;
pub const deriveInstanceKeyHex = instance_key.deriveHex;

pub const source_hash = @import("source_hash.zig");
pub const hashPackageSource = source_hash.hashPackageSource;
pub const hashFileContent = source_hash.hashFileContent;

test "hash exports are wired" {
    _ = toolchain_fingerprint;
    _ = serializeToolchainFingerprintAlloc;
    _ = hashToolchainFingerprint;
    _ = digestToolchainFingerprintHex;
    _ = instance_key;
    _ = InstanceKeyInput;
    _ = InstanceKeyDependency;
    _ = addInstanceKeyToHash;
    _ = deriveInstanceKeyHex;
    _ = source_hash;
    _ = hashPackageSource;
    _ = hashFileContent;
}
