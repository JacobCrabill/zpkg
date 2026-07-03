# Phase 13 — Source Hash, Per-Command Help, and Realize Workspace Fix

## Purpose

Three user-facing gaps left from Phase 12:

1. `zpkg lock` writes `source_hash = "0000000000000000000000000000000000000000"` (a
   placeholder) instead of the real content hash of each dependency package.
2. `zpkg <command> --help` is documented in the top-level usage string but not
   implemented — every subcommand ignores `--help` / `-h` and falls through to the
   usage-error path instead.
3. `zpkg realize` produces a workspace in which `zig build` fails with an invalid
   fingerprint error — the generated `build.zig.zon` carries the source package's
   fingerprint but its content has changed, so Zig rejects it.

---

## Feature 1 — Real source hash in `zpkg lock`

### Background

`source_hash` in `zpkg.lock.zon` is intended to pin the exact content of each
resolved dependency so that drift is detectable.  The hash infrastructure already
exists in `src/hash/source_hash.zig` (specifically `hashDirAlloc` /
`hashDirHexAlloc`).  It was never wired into the lock command.

The placeholder `"0000000000000000000000000000000000000000"` was introduced because
`schema/lockfile.zig` calls `parseNonEmptyStringAlloc` for `source_hash` and rejects
`""`, so an empty string would cause `zpkg build` to fail to parse the lockfile it
just wrote.

### What must change

**`src/cli/lock.zig` — `generateLockfile`**

After the resolver walk that builds the `instances` slice, compute the source hash
for each instance:

```
<source_root>/../<basename_of_package_id>/
```

This is the same sibling-directory convention already used in the resolver
(`src/resolve/root.zig:parseDependencyManifest`) and in realize
(`src/cli/realize.zig:145`).

Call `src/hash/source_hash.hashDirHexAlloc(allocator, dir, io, source_dir)` (or
whatever the public API surface is — check `src/hash/source_hash.zig`) and store
the result as `source_hash` on the `model.Instance`.

If the source directory does not exist or hashing fails, return a descriptive error
rather than silently falling back to the placeholder.

**`src/cli/update.zig` — `generateLockfile`**

Same change as `lock.zig`; `update.zig` has its own copy of `generateLockfile`.

### Validation

```
cd examples/diamond/app
rm zpkg.lock.zon
zpkg lock .
# source_hash for each instance must be a 40-char hex string, not all zeros
grep source_hash zpkg.lock.zon   # must show real hashes

# Modifying a source file must cause the hash to change on re-lock
echo "// comment" >> ../libA/src/root.zig
zpkg update .
grep -A1 "libA" zpkg.lock.zon   # source_hash must differ from first run
```

---

## Feature 2 — Per-command `--help` / `-h`

### Background

The top-level `help_text` in `src/cli/root.zig` advertises:

```
  zpkg <command> --help
```

But `src/cli/root.zig:run` dispatches to the subcommand handler unconditionally —
`zpkg lock --help` currently reaches `lock.run`, which treats `--help` as a
positional argument and returns `error.InvalidArgument` with a usage error.

### What must change

**Each subcommand** (`inspect`, `graph`, `lock`, `update`, `realize`, `build`,
`test`, `export`) must check for `--help` / `-h` as the first argument after the
subcommand name and print a per-command usage string, then return without error.

The per-command help text should cover:

- One-line description
- Usage line(s)
- All arguments and flags with brief descriptions
- Example invocation

**Option A (recommended):** add a `pub const help_text` constant to each subcommand
file and a small `shouldShowHelp` check at the top of each `run` function, mirroring
the pattern already used in `src/cli/root.zig`.

**Option B:** handle `<command> --help` centrally in `root.zig` before dispatching,
using a static dispatch table that maps command name → help string.  Keeps the
dispatch logic in one place but requires each file to export `help_text`.

Either option is acceptable; Option A is simpler to implement incrementally.

### Suggested per-command help strings

```
inspect <pkg-root>       Inspect package metadata from <pkg-root>/zpkg.zon
graph   <pkg-root>       Show resolved package graph from <pkg-root>/zpkg.lock.zon
lock    <pkg-root>       Create an authoritative lockfile (zpkg.lock.zon)
update  <pkg-root>       Update an existing lockfile in place
realize <pkg-root>       Materialize the generated workspace (.zpkg/)
build   <pkg-root>       Build all instances from the lockfile
test    <pkg-root>       Build and run all test instances
export  <pkg-root>       Export a relocatable closure bundle
```

### Validation

```
zpkg lock --help     # exits 0, prints usage, no error
zpkg lock -h         # same
zpkg build --help    # exits 0, prints usage, no error
# All 8 subcommands must respond to --help and -h without error
```

---

## Feature 3 — `zpkg realize` workspace fingerprint fix

### Background

`src/realize/source_pkg.zig:generateBuildZigZon` generates a `build.zig.zon` for
each realized workspace package.  It carries the fingerprint from the source
package's `build.zig.zon` (added in Phase 12) and hardcodes `paths = .{"."}`.

The fingerprint in Zig 0.16 is tied to the content of `build.zig.zon` (excluding
the fingerprint field itself).  Because the generated file has:

- different `.dependencies` entries (workspace-local paths instead of source-relative)
- `paths = .{"."}` instead of the source's explicit file list

…the content differs from the original, so the source's fingerprint no longer
matches.  When the user then runs `zig build` directly in the realized workspace,
Zig reports:

```
error: invalid fingerprint: 0x<source_fp>; if this is a new or forked package, use this value: 0x<correct_fp>
```

`zpkg build` never exposes this because `build_fallback.zig` already applies a
two-pass fix (capture stderr → extract suggested fingerprint → patch file → retry).
`zpkg realize` leaves the workspace for the user to run `zig build` directly, so the
broken fingerprint is never corrected.

### Root cause

The fingerprint is **not** a hash of the package's file content.  In normal Zig
projects, updating `.paths` or `.dependencies` does not invalidate the fingerprint
— it is a stable, author-assigned package identity (essentially a UUID), not
derived from what the package contains.

The workspace fingerprint error is most likely a **global cache conflict**.  Zig's
package cache (`~/.cache/zig`) associates each fingerprint with the canonical
identity of the package that first registered it.  The source package (`diamond.libA`
at its source path) registers fingerprint X.  The workspace copy at
`.zpkg/work/.../diamond.libA#target` claims the same fingerprint X but is
a different package at a different path — Zig detects two distinct packages sharing
one fingerprint and rejects it.

The exact mechanism (what Zig treats as "canonical identity" — path, content hash,
or something else) should be verified by reading `zig`'s source or experimenting
before writing the implementation.  The observable fact is: copying the source
fingerprint into the workspace always triggers this error, so the workspace needs
its own fingerprint distinct from the source's.

`paths = .{"."}` is an independent correctness problem with no bearing on the
fingerprint: it tells Zig the package consists of every file in the workspace
directory, including generated scaffolding that was never part of the source package.
Fix A corrects this by copying the source's explicit file list.

### What must change

**`src/realize/source_pkg.zig` — `readFingerprintFromSource` and `generateBuildZigZon`**

Two sub-fixes, both required, addressing separate problems:

**Sub-fix A — copy `.paths` from source (correctness)**

Add a `readPathsFromSource(source_dir)` function alongside
`readFingerprintFromSource`.  It should parse the source `build.zig.zon` and extract
the raw text of the `.paths = .{ ... }` value as a string to be inlined verbatim
into the generated file.  A simple substring extract (from `.paths = ` to the
matching `},`) is sufficient — no need to tokenize.

Pass this string to `generateBuildZigZon` and emit it in place of `"."`:

```zig
// before:
try w.writeAll("    .paths = .{\".\"},\n");

// after (paths_text is the raw extracted string, e.g. `"build.zig", "build.zig.zon", "src"`):
try w.print("    .paths = .{{{s}}},\n", .{paths_text});
```

If the source has no `.paths` field, this is a fatal error - zig does not allow this;
throw an error telling the user to fix their `build.zig.zon` file first.

**Sub-fix B - copy version and minimum_zig_version**

zig requires **all** of the following fields in `build.zig.zon`:

- `name`
- `fingerprint`
- `version`
- `minimum_zig_version`
- `dependencies`
- `paths`

Only the `dependencies` field should change in the `realize` step - all other fields must remain identical.

Note: test that the chosen invocation actually triggers the fingerprint error on
stderr before relying on it; fall back to a bare `zig build` invocation if needed.

### Validation

```
cd examples/diamond/app
zpkg realize .
# For each package dir under .zpkg/work/debug-native/deps/:
#   cat <pkg>/build.zig.zon   → fingerprint must be present and valid
#   zig build --help           → must exit 0 without fingerprint error

# Full manual build must succeed:
cd .zpkg/work/debug-native/root
zig build   # must complete without fingerprint or module errors
```

---

## Phase dependencies

- Requires: Phase 12 (source_hash placeholder introduced there)
- Feature 1 requires: `src/hash/source_hash.zig` (already merged, Phase 02)
- Feature 2 has no code dependencies

## Parallelism

All three features are independent and can be implemented in parallel.  Feature 3
(realize workspace fix) has one internal dependency: sub-fix A (copy `.paths`) should
be done before sub-fix B (fingerprint correction), since the fingerprint depends on
the final file content.

## Completion criteria

- `zpkg lock .` in `examples/diamond/app` writes non-placeholder `source_hash`
  values for all 5 instances
- Mutating a source file and re-running `zpkg update .` changes the affected
  instance's `source_hash`
- Every subcommand exits 0 and prints usage when passed `--help` or `-h`
- `zpkg realize .` in `examples/diamond/app` produces a workspace where
  `zig build` runs without fingerprint errors
- `zig build test` passes with no regressions
