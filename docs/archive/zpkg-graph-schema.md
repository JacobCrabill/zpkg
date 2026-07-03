# zpkg.graph.zon Schema

## Purpose

`zpkg.graph.zon` is the configure-time target graph emitted by mandatory `zpkg-build` wrappers.

It is the bridge between:

- the static package contract in `zpkg.zon`
- the actual build graph registered from `build.zig`

It records the target graph needed for:

- validation against `zpkg.zon`
- realized-workspace inspection
- binary adapter generation
- verbose graph/debug commands

---

## Status

This document defines the intended **MVP schema**.

- File format: **ZON only**
- Schema version: `1`
- Emitted at **configure time**
- Lives in the realized package root

---

## Emission model

### Produced by

- `build.zig`
- mandatory `zpkg-build` wrappers

### Produced when

- during configure / graph construction
- before compilation is required

### Stored at

- realized package root as:
  - `zpkg.graph.zon`

---

## Relationship to `zpkg.zon`

`zpkg.zon` declares the public contract.

`zpkg.graph.zon` records the actual registered target graph.

### Validation rules

At minimum:

- every exported target declared in `zpkg.zon` must exist in `zpkg.graph.zon`
- every exported target registered in `zpkg.graph.zon` must be declared in `zpkg.zon`
- every registered dependency edge must reference a dependency alias declared in `zpkg.zon`
- target kind/linkage mismatches are errors
- declared-vs-registered public metadata mismatches are errors

Internal helper targets are allowed in `zpkg.graph.zon` even if they do not appear in `zpkg.zon`, provided they are not exported.

---

## High-level structure

```zig
.{
    .schema = 1,
    .package = .{ ... },
    .selected_options = .{ ... },
    .dependency_aliases = .{ ... },
    .targets = .{ ... },
}
```

### Top-level fields

- `.schema` — required schema version
- `.package` — required metadata for the resolved package instance
- `.selected_options` — required normalized option values for this configure/build
- `.dependency_aliases` — required dependency alias resolution metadata
- `.targets` — required registered target graph

---

## `.package`

Example:

```zig
.package = .{
    .name = "object_tracker",
    .id = "sai.pilot.object_tracker",
    .version = "1.2.3.0",
    .domain = .target,
}
```

### Fields

- `.name: string`
- `.id: string`
- `.version: string`
- `.domain: .host | .target`

This block identifies the resolved package instance whose target graph is being emitted.

---

## `.selected_options`

Example:

```zig
.selected_options = .{
    .shared = true,
    .with_cuda = false,
    .build_tests = true,
}
```

This records the normalized option values active for the graph emission.

---

## `.dependency_aliases`

This table connects package-local dependency aliases to resolved package/domain identities.

Example:

```zig
.dependency_aliases = .{
    .protobuf = .{
        .package = "sai.upstream.protobuf",
        .domain = .target,
    },
    .gtest = .{
        .package = "sai.upstream.gtest",
        .domain = .host,
    },
}
```

### Fields

- alias name: local dependency alias
- `.package: string`
  - canonical package id
- `.domain: .host | .target`
  - resolved domain for that dependency instance

Build registration refers to dependency aliases, not raw package ids.

---

## `.targets`

`targets` contains all registered targets for the package instance.

This includes:

- exported/public targets
- internal helper targets

Each target entry states whether it is exported.

Example:

```zig
.targets = .{
    .tracker = .{ ... },
    .tracker_headers = .{ ... },
    .tracker_models = .{ ... },
    .internal_codegen = .{ ... },
}
```

---

## Target entry schema

Example:

```zig
.tracker = .{
    .kind = .library,
    .linkage = .shared,
    .exported = true,
    .test_only = false,

    .include_dirs = .{
        .{ .path = "include", .visibility = .public },
        .{ .path = "src", .visibility = .private },
    },

    .compile_definitions = .{
        .{ .key = "USE_SSL", .value = true, .visibility = .public },
        .{ .key = "INTERNAL_MODE", .value = 1, .visibility = .private },
    },

    .system_libs = .{
        .{ .name = "pthread", .visibility = .public },
        .{ .name = "dl", .visibility = .private },
    },

    .artifacts = .{
        .{ .kind = .library, .path = "lib/libtracker.so" },
    },

    .deps = .{
        .protobuf_runtime = .{
            .dep = "protobuf",
            .target = "protobuf",
            .role = .link,
            .visibility = .public,
        },
        .protoc = .{
            .dep = "protobuf",
            .target = "protoc",
            .role = .tool,
            .visibility = .private,
        },
    },
}
```

### Common fields

- `.kind`
  - `.library`
  - `.executable`
  - `.zig_module`
  - `.headers`
  - `.resource_set`
- `.exported: bool`
  - `true` if part of the external/public package contract
  - `false` for internal helper targets
- `.test_only: bool`
  - whether the target belongs only to test workflows

### Library-only fields

- `.linkage: .shared | .static`
  - resolved linkage for this emitted graph
  - MVP expects `.shared`

### Target field rules

- target names must be unique within the package
- `.linkage` is valid only for `.library`
- `.headers` targets have no binary artifacts
- `.headers` targets are consumed through `.link` edges

---

## Include directories

Include directories are modeled as directories with visibility.

Example:

```zig
.include_dirs = .{
    .{ .path = "include", .visibility = .public },
    .{ .path = "generated", .visibility = .private },
}
```

### Fields

- `.path: string`
  - path to the include directory
  - should be relative to the realized package root where practical
- `.visibility: .public | .private`

### Meaning

- public include dirs propagate across public `.link` edges
- private include dirs do not

---

## Compile definitions

Compile definitions use structured key/value entries with visibility.

Example:

```zig
.compile_definitions = .{
    .{ .key = "USE_SSL", .value = true, .visibility = .public },
    .{ .key = "API_LEVEL", .value = 2, .visibility = .public },
    .{ .key = "MODE", .value = "internal", .visibility = .private },
}
```

### Allowed value types

- string
- int
- bool

### Fields

- `.key: string`
- `.value: string | int | bool`
- `.visibility: .public | .private`

---

## System libraries

System libraries may also carry visibility.

Example:

```zig
.system_libs = .{
    .{ .name = "pthread", .visibility = .public },
    .{ .name = "dl", .visibility = .private },
}
```

### Meaning

Public system libs participate in propagation across public `.link` edges.

---

## Artifacts

`artifacts` describe concrete binary outputs for targets that produce them.

Example:

```zig
.artifacts = .{
    .{ .kind = .library, .path = "lib/libtracker.so" },
}
```

### Fields

- `.kind`
  - `.library`
  - `.executable`
- `.path: string`
  - path to the produced artifact relative to install/prefix view or realized workspace, depending on emission mode

### Rules

- `.headers` targets should not emit binary artifacts
- `.resource_set` targets typically do not emit binary artifacts
- `.zig_module` targets generally do not emit binary artifacts

---

## Dependency edges

Actual target edges are registered here.

Example:

```zig
.deps = .{
    .protobuf_runtime = .{
        .dep = "protobuf",
        .target = "protobuf",
        .role = .link,
        .visibility = .public,
    },
    .protoc = .{
        .dep = "protobuf",
        .target = "protoc",
        .role = .tool,
        .visibility = .private,
    },
}
```

### Fields

- edge name: local edge identifier
- `.dep: string`
  - dependency alias from `zpkg.zon`
- `.target: string`
  - explicit target name inside the dependent package
- `.role`
  - `.link`
  - `.tool`
  - `.build`
  - `.test`
- `.visibility`
  - `.public`
  - `.private`

### Rules

- build registration uses explicit target names everywhere in the MVP
- `.dep` must refer to a declared dependency alias
- `.headers` targets are consumed using `.role = .link`
- visibility belongs on the edge

---

## Resources and resource targets

Resources are first-class targets of kind `.resource_set`.

A resource target may carry explicit install entries.

Example:

```zig
.tracker_models = .{
    .kind = .resource_set,
    .exported = true,
    .test_only = false,
    .installs = .{
        .{
            .source = "models/default.bin",
            .dir = .share,
            .subdir = "sai/pilot/object_tracker/models",
            .dest = "default.bin",
        },
    },
}
```

### Install entry fields

- `.source: string`
  - source path
- `.dir: .share`
  - MVP resource installs target `share`
- `.subdir: string`
  - install subdirectory under `share/`
- `.dest: string`
  - destination file name

### Notes

- developers specify the install file(s) and `share/` subdir
- a helper may provide a default namespaced path
- collision policy is enforced at export time, not registration time

---

## Zig module targets

A `.zig_module` target may record module metadata.

Example:

```zig
.build_helpers = .{
    .kind = .zig_module,
    .exported = true,
    .test_only = false,
    .module = .{
        .name = "build_helpers",
        .root_source_file = "src/build_helpers.zig",
    },
}
```

### Module fields

- `.name: string`
- `.root_source_file: string`

---

## Example complete graph file

```zig
.{
    .schema = 1,

    .package = .{
        .name = "object_tracker",
        .id = "sai.pilot.object_tracker",
        .version = "1.2.3.0",
        .domain = .target,
    },

    .selected_options = .{
        .shared = true,
        .with_cuda = false,
        .build_tests = false,
    },

    .dependency_aliases = .{
        .protobuf = .{
            .package = "sai.upstream.protobuf",
            .domain = .target,
        },
    },

    .targets = .{
        .tracker = .{
            .kind = .library,
            .linkage = .shared,
            .exported = true,
            .test_only = false,
            .include_dirs = .{
                .{ .path = "include", .visibility = .public },
                .{ .path = "src", .visibility = .private },
            },
            .compile_definitions = .{
                .{ .key = "USE_SSL", .value = true, .visibility = .public },
            },
            .system_libs = .{
                .{ .name = "pthread", .visibility = .public },
            },
            .artifacts = .{
                .{ .kind = .library, .path = "lib/libtracker.so" },
            },
            .deps = .{
                .protobuf_runtime = .{
                    .dep = "protobuf",
                    .target = "protobuf",
                    .role = .link,
                    .visibility = .public,
                },
            },
        },

        .tracker_headers = .{
            .kind = .headers,
            .exported = true,
            .test_only = false,
            .include_dirs = .{
                .{ .path = "include", .visibility = .public },
            },
            .compile_definitions = .{},
            .deps = .{},
        },

        .internal_codegen = .{
            .kind = .executable,
            .exported = false,
            .test_only = false,
            .artifacts = .{
                .{ .kind = .executable, .path = "bin/internal_codegen" },
            },
            .deps = .{},
        },
    },
}
```

---

## Summary

`zpkg.graph.zon` answers:

- what targets actually exist for this resolved package instance?
- which are exported vs internal?
- what include dirs, compile definitions, system libs, and artifacts do they expose?
- what target-to-target dependency edges were registered?
- how do those edges map back to dependency aliases from `zpkg.zon`?

It is the configure-time truth for the concrete target graph.
