# zpkg.zon Schema

## Purpose

`zpkg.zon` is the **package contract and dependency constraints** file for a first-party package.

It is the source of truth for:

- canonical package identity
- package version
- package-wide options
- package-level dependency constraints
- exported/public target declarations

It is **not** the full target graph.

The full target graph is registered from `build.zig` through mandatory `zpkg-build` wrappers and emitted as `zpkg.graph.zon`.

---

## Status

This document defines the intended **MVP schema**.

- File format: **ZON**
- Schema version: `1`
- Backward-incompatible changes should increment `.schema`

---

## High-level structure

```zig
.{
    .schema = 1,

    .package = .{ ... },
    .options = .{ ... },
    .deps = .{ ... },
    .targets = .{ ... },
}
```

### Top-level fields

- `.schema` — required, integer schema version
- `.package` — required, package identity and metadata
- `.options` — optional, package-wide options
- `.deps` — optional, package-level dependency constraint universe
- `.targets` — required, exported/public target declarations

---

## `.package`

Example:

```zig
.package = .{
    .name = "object_tracker",
    .id = "sai.pilot.object_tracker",
    .version = "1.2.3.0",
    .backend = .zig,
}
```

### Fields

- `.name: string`
  - human-facing package display name
- `.id: string`
  - canonical machine identity
  - examples:
    - `sai.pilot.object_tracker`
    - `sai.upstream.libyaml`
- `.version: string`
  - normalized semantic version string
- `.backend: enum`
  - MVP supported value:
    - `.zig`
  - reserved for future:
    - `.cmake`
    - `.custom`

### Validation rules

- `.id` is required and must be non-empty
- `.name` is required and must be non-empty
- `.version` is required and must parse as a valid package version
- changing `.package.id` creates a logically different package

---

## Version format

Supported version forms:

- `1.2.3`
- `1.2.3.0`
- `1.2.3.4`

### Normalization

Internally, versions normalize to a 4-component tuple:

- `1.2.3` -> `1.2.3.0`
- `1.2.3.0` -> `1.2.3.0`

### Ordering

Comparison is lexicographic over the normalized tuple:

- `1.2.3 < 1.2.3.1 < 1.2.3.2`

### Future extensions

Reserved for post-MVP:

- prerelease forms such as `2.2.0-rc1`
- full version-range grammar

---

## `.options`

`options` define package-wide user-visible knobs.

These are used for:

- build configuration
- constraint conditions via `.when.options`
- instance-key derivation
- lockfile selected-option recording

Example:

```zig
.options = .{
    .shared = .{
        .kind = .bool,
        .default = true,
        .abi = true,
    },
    .with_cuda = .{
        .kind = .bool,
        .default = false,
        .abi = true,
    },
    .build_tests = .{
        .kind = .bool,
        .default = false,
        .abi = false,
    },
    .api_level = .{
        .kind = .int,
        .default = 2,
        .abi = true,
    },
    .install_flavor = .{
        .kind = .string,
        .default = "default",
        .abi = false,
    },
}
```

### Option schema

```zig
.<option_name> = .{
    .kind = .bool | .int | .string,
    .default = <value>,
    .abi = true | false,
}
```

### MVP rules

- supported option kinds:
  - `.bool`
  - `.int`
  - `.string`
- enum-like behavior can be modeled as `.string` in the MVP
- `.abi = true` means the option affects the resolved package instance / binary compatibility
- `.abi = false` means it does not participate in ABI identity

### Recommended convention

Keep the package-wide `shared` option in the schema even though MVP is shared-library-oriented. This keeps the schema forward-compatible with static support later.

---

## `.deps`

`deps` declare the **allowed dependency universe** for the package.

These are package-level constraints only.

They do **not** describe:

- target-to-target edges
- roles
- visibility
- concrete dependent target names

Those are emitted from `build.zig` registration via `zpkg-build`.

Example:

```zig
.deps = .{
    .protobuf = .{
        .package = "sai.upstream.protobuf",
        .require = .{
            .version = "=4.1.2.0",
        },
    },
    .gtest = .{
        .package = "sai.upstream.gtest",
        .require = .{
            .version = "=1.14.0.0",
        },
        .when = .{
            .domain = .host,
            .options = .{
                .build_tests = true,
            },
        },
    },
}
```

### Dependency entry schema

```zig
.<alias> = .{
    .package = "<canonical package id>",
    .require = .{
        .version = "=<version>",
    },
    .when = .{ ... }, // optional
}
```

### Fields

- dependency alias: local field name used by `build.zig` / `zpkg-build`
- `.package: string`
  - canonical package id
- `.require.version: string`
  - version requirement
- `.when`
  - optional condition block

### MVP rules

- `.required` does not exist
- if a dependency entry is active under its condition, it is required
- dependency aliases must be unique within the package
- build registration must reference dependency aliases, not raw package ids

### MVP version requirement grammar

MVP validators should accept exact requirements only:

- `=1.2.3`
- `=1.2.3.0`

### Future/post-MVP grammar

Reserved for later:

- `^1.2.0`
- `~1.2.0`
- `>=1.2.0 <2.0.0`

---

## `.when`

Conditions are AND-only in the MVP.

Example:

```zig
.when = .{
    .domain = .host,
    .host_os = .linux,
    .target_arch = .x86_64,
    .options = .{
        .shared = true,
        .build_tests = false,
    },
}
```

### Allowed MVP condition axes

- `.domain = .host | .target`
- `.host_os`
- `.host_arch`
- `.target_os`
- `.target_arch`
- `.options = .{ ... }`
  - equality checks against package option values

### MVP placement

`when` is allowed on:

- dependency entries
- target declarations
- target export/resource declarations, when needed later

### Not supported in MVP

- OR expressions
- NOT expressions
- arbitrary nested boolean logic

---

## `.targets`

`targets` declare the exported/public targets of the package.

Only externally consumable/exported targets must appear here.

Internal helper targets may exist in `build.zig` registration only and do not need to appear in `zpkg.zon`.

Example:

```zig
.targets = .{
    .tracker = .{
        .kind = .library,
        .linkage = .default,
    },
    .tracker_headers = .{
        .kind = .headers,
    },
    .tracker_models = .{
        .kind = .resource_set,
    },
    .tracker_tests = .{
        .kind = .executable,
        .test_only = true,
        .when = .{
            .options = .{
                .build_tests = true,
            },
        },
    },
}
```

### Supported target kinds

- `.library`
- `.executable`
- `.zig_module`
- `.headers`
- `.resource_set`

### Target declaration schema

```zig
.<target_name> = .{
    .kind = .library | .executable | .zig_module | .headers | .resource_set,
    .linkage = .default | .shared | .static, // library only
    .test_only = true | false,               // optional
    .when = .{ ... },                        // optional
}
```

### Target field rules

- target names must be unique within the package
- `.linkage` is only valid for `.library`
- `.linkage = .default` means: follow the package-wide `shared` option
- `.test_only = true` marks a target as belonging only to test-oriented workflows
- `.headers` is a first-class target kind
  - it has no binary artifact
  - it is consumed through `.link` edges

### Target-name stability

- target names are package-scoped stable identifiers
- renaming an exported target is a compatibility/signature change
- external reference syntax is `package_id:target_name`

---

## Relationship to `build.zig` and `zpkg-build`

`zpkg.zon` is only one half of the model.

### `zpkg.zon` declares

- public package identity
- options
- allowed dependency aliases
- exported/public targets

### `build.zig` + `zpkg-build` register

- actual target creation
- target-to-target dependency edges
- edge roles
- edge visibility
- include directories
- compile definitions
- resources and tools

### Validation contract

Validation must be strict:

- declared exported target missing from registration -> error
- registered exported target missing from `zpkg.zon` -> error
- registered edge referencing undeclared dependency alias -> error
- target kind/linkage mismatch -> error

---

## Complete example

```zig
.{
    .schema = 1,

    .package = .{
        .name = "object_tracker",
        .id = "sai.pilot.object_tracker",
        .version = "1.2.3.0",
        .backend = .zig,
    },

    .options = .{
        .shared = .{
            .kind = .bool,
            .default = true,
            .abi = true,
        },
        .with_cuda = .{
            .kind = .bool,
            .default = false,
            .abi = true,
        },
        .build_tests = .{
            .kind = .bool,
            .default = false,
            .abi = false,
        },
    },

    .deps = .{
        .protobuf = .{
            .package = "sai.upstream.protobuf",
            .require = .{
                .version = "=4.1.2.0",
            },
        },
        .gtest = .{
            .package = "sai.upstream.gtest",
            .require = .{
                .version = "=1.14.0.0",
            },
            .when = .{
                .domain = .host,
                .options = .{
                    .build_tests = true,
                },
            },
        },
    },

    .targets = .{
        .tracker = .{
            .kind = .library,
            .linkage = .default,
        },
        .tracker_headers = .{
            .kind = .headers,
        },
        .tracker_models = .{
            .kind = .resource_set,
        },
        .tracker_tests = .{
            .kind = .executable,
            .test_only = true,
            .when = .{
                .options = .{
                    .build_tests = true,
                },
            },
        },
    },
}
```

---

## Summary

`zpkg.zon` is deliberately concise.

It answers:

- who is this package?
- what version is it?
- what knobs does it expose?
- what other packages may it depend on?
- what exported/public targets does it promise?

It does **not** answer the full target graph question; that belongs to `zpkg.graph.zon` emitted from `build.zig` registration.
