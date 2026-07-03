# Phase 02 - Hashing and Identity

## Purpose

Implement deterministic source identity and build-instance identity.

This phase defines:

- how package contents are hashed
- how toolchain/profile inputs are serialized
- how the binary artifact instance key is derived

## Phase dependencies

- Requires: Phase 01
- Unlocks: Phases 03, 04, 07, 10

## Parallelism

- `P02-A` and `P02-B` can run in parallel.
- `P02-C` depends on both.
- `P02-D` can follow once outputs are stable.

## Work units

### P02-A - In-process source hashing

**Goal**
- Compute source identity in process while matching Zig package semantics as closely as practical.

**Likely files**
- `src/hash/source_hash.zig`
- `src/util/fs.zig`

**Requirements**
- Use `build.zig.zon.paths` as the package boundary
- Traverse files deterministically
- Exclude non-package files from the hash
- Keep hash behavior inspectable for debugging

**Validation**
- Edit included file -> hash changes
- Edit excluded file -> hash does not change
- Repeat hash on unchanged package -> identical output

**Exit criteria**
- Example packages produce stable source identities

---

### P02-B - Toolchain/profile fingerprint model

**Goal**
- Define the structured inputs that participate in binary identity.

**Likely files**
- `src/hash/toolchain_fingerprint.zig`
- `src/model/toolchain.zig`

**Requirements**
- Include at minimum:
  - Zig version
  - host triple
  - target triple
  - C/C++ compiler identity and version
  - sysroot/libc identity
  - C++ stdlib / ABI mode
- Use canonical serialization order

**Validation**
- Snapshot tests for serialized fingerprints
- Stable output across repeated runs

**Exit criteria**
- Toolchain identity is deterministic and reusable by later phases

---

### P02-C - Instance key derivation

**Goal**
- Compute deterministic binary instance keys.

**Likely files**
- `src/hash/instance_key.zig`

**Requirements**
- Use `std.Build.Cache.HashHelper`
- Include:
  - package id
  - normalized version
  - domain
  - source hash
  - selected ABI-affecting options
  - toolchain fingerprint
  - resolved dependency instance keys
- Exclude non-ABI options from binary identity

**Validation**
- ABI option changes key
- non-ABI option does not
- host/target domain differences affect key when appropriate
- dependency instance changes propagate upward

**Exit criteria**
- Instance key generation is stable and explainable

---

### P02-D - Debug visibility for identity inputs

**Goal**
- Make hash and instance-key reasoning visible through CLI or structured diagnostics.

**Likely files**
- `src/cli/inspect.zig`

**Requirements**
- Verbose inspect mode shows:
  - source hash inputs
  - selected options
  - toolchain fingerprint inputs
  - dependency instance references
- Output should be human-readable and stable enough for snapshots

**Validation**
- `zig build run -- inspect <pkg> --verbose`

**Exit criteria**
- Developers can explain why a particular instance key changed

## Phase completion criteria

This phase is complete when:

- source identity is deterministic
- binary identity is deterministic
- identity behavior is inspectable enough to debug cache misses and unexpected rebuilds
