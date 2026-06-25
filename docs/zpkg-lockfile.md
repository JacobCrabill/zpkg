# zpkg.lock.zon Schema

## Purpose

`zpkg.lock.zon` is the **authoritative exact resolution** for a workspace.

It records the fully resolved transitive graph used by `zpkg build`, `zpkg test`, `zpkg realize`, and `zpkg export`.

It is the source of truth for:

- resolved package version
- resolved package domain (`host` / `target`)
- source identity/hash
- selected package options
- direct resolved dependency edges

---

## Status

This document defines the intended **MVP schema**.

- File format: **ZON**
- Schema version: `1`
- The lockfile is authoritative; normal build/export commands should not silently rewrite it.

---

## Authority and lifecycle

### Authority rules

If `zpkg.lock.zon` is missing or incompatible with `zpkg.zon`:

- `zpkg build` should fail
- `zpkg test` should fail
- `zpkg export` should fail
- the tool should provide a detailed message and suggest the appropriate command

### Commands

- `zpkg lock`
  - create a new lockfile
  - error if one already exists
- `zpkg update`
  - update the lockfile explicitly
- `zpkg update --dry-run`
  - show proposed changes without modifying files

---

## High-level structure

```zig
.{
    .schema = 1,
    .root = .{ ... },
    .generated_by = .{ ... },
    .instances = .{ ... },
}
```

### Top-level fields

- `.schema` — required schema version
- `.root` — required metadata about the root package/workspace
- `.generated_by` — optional generator metadata
- `.instances` — required map of resolved package instances

---

## `.root`

Example:

```zig
.root = .{
    .package = "sai.pilot.object_tracker",
    .version = "1.2.3.0",
}
```

### Fields

- `.package: string`
  - canonical package id of the root package
- `.version: string`
  - root package version

This block is informational and helps validate that the lockfile belongs to the expected workspace.

---

## `.generated_by`

Example:

```zig
.generated_by = .{
    .zpkg_version = "0.1.0",
    .zig_version = "0.16.0",
}
```

This block is optional in the MVP but recommended for diagnostics and debugging.

---

## `.instances`

`instances` contains the exact resolved graph.

Each entry represents one resolved package instance keyed by:

- `package_id`
- `domain`

### Canonical instance key

Suggested instance key form:

- `<package_id>#host`
- `<package_id>#target`

Example:

```zig
.instances = .{
    .@"sai.pilot.object_tracker#target" = .{ ... },
    .@"sai.upstream.protobuf#target" = .{ ... },
    .@"sai.upstream.protobuf#host" = .{ ... },
}
```

This key is a lockfile-local identity string, not the binary artifact instance hash.

---

## Resolved instance schema

Example:

```zig
.@"sai.upstream.protobuf#target" = .{
    .package = "sai.upstream.protobuf",
    .domain = .target,
    .version = "4.1.2.0",
    .source_hash = "pkg_hash_here",
    .selected_options = .{
        .shared = true,
        .build_tests = false,
    },
    .deps = .{
        .zlib = "sai.upstream.zlib#target",
    },
}
```

### Fields

- `.package: string`
  - canonical package id
- `.domain: enum`
  - `.host` or `.target`
- `.version: string`
  - exact resolved version
- `.source_hash: string`
  - exact chosen source identity/hash
- `.selected_options: table`
  - normalized option values selected for this instance
- `.deps: table`
  - direct resolved dependency edges by package-local alias
  - values are canonical lockfile instance references

### Important rule

Package options are resolved **per package instance**, and therefore effectively per `(package_id, domain)` entry.

This means the same package may appear in both:

- `sai.upstream.protobuf#host`
- `sai.upstream.protobuf#target`

with different selected options if necessary.

---

## Direct dependency edges

The `deps` table inside a resolved instance preserves package-local dependency aliases.

Example:

```zig
.deps = .{
    .protobuf = "sai.upstream.protobuf#target",
    .gtest = "sai.upstream.gtest#host",
}
```

### Rules

- keys are aliases from the package's `zpkg.zon`
- values are canonical resolved instance references
- only direct dependencies belong here
- the lockfile as a whole stores the full transitive graph by virtue of all `.instances`

---

## Validation rules

A valid lockfile must satisfy at least:

- every `.instances` entry has a unique `(package, domain)` identity
- every referenced dependency instance exists in `.instances`
- every resolved version satisfies the corresponding constraint in `zpkg.zon`
- every resolved source hash is present
- selected options are valid for the package schema
- the root package matches the current workspace package identity

### Drift detection

The lockfile should be considered incompatible if, for example:

- root package id or version changes incompatibly
- a dependency alias changes in `zpkg.zon`
- a version constraint changes such that the locked version no longer satisfies it
- a required dependency is added or removed
- selected option values are no longer valid under current option definitions

---

## Example complete lockfile

```zig
.{
    .schema = 1,

    .root = .{
        .package = "sai.pilot.object_tracker",
        .version = "1.2.3.0",
    },

    .generated_by = .{
        .zpkg_version = "0.1.0",
        .zig_version = "0.16.0",
    },

    .instances = .{
        .@"sai.pilot.object_tracker#target" = .{
            .package = "sai.pilot.object_tracker",
            .domain = .target,
            .version = "1.2.3.0",
            .source_hash = "root_hash",
            .selected_options = .{
                .shared = true,
                .with_cuda = false,
                .build_tests = false,
            },
            .deps = .{
                .protobuf = "sai.upstream.protobuf#target",
            },
        },

        .@"sai.upstream.protobuf#target" = .{
            .package = "sai.upstream.protobuf",
            .domain = .target,
            .version = "4.1.2.0",
            .source_hash = "protobuf_target_hash",
            .selected_options = .{
                .shared = true,
            },
            .deps = .{},
        },

        .@"sai.upstream.protobuf#host" = .{
            .package = "sai.upstream.protobuf",
            .domain = .host,
            .version = "4.1.2.0",
            .source_hash = "protobuf_host_hash",
            .selected_options = .{
                .shared = true,
            },
            .deps = .{},
        },
    },
}
```

---

## Relationship to artifact identity

The lockfile does **not** store the final binary artifact instance hash as its primary identity.

Instead it stores the inputs needed to derive it:

- package id
- domain
- version
- source hash
- selected options
- dependency closure

The binary instance key/hash can then be computed deterministically from this information plus toolchain/profile inputs.

---

## Summary

`zpkg.lock.zon` answers:

- exactly which packages were chosen?
- in which domain?
- at which versions?
- from which source identities?
- with which selected options?
- with which direct dependency bindings?

It is the authoritative resolved graph that makes builds and exports reproducible.
