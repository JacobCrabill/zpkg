# Plan: Profile / Target Axis

_Status: proposed. Addresses design-review.md item #5._

## Goal

Let zpkg build for more than one hardcoded configuration. Today everything is
pinned to **Debug / native (linux-x86_64) / static**:

- `src/cli/lockcmd.zig` hardcodes the resolution `conditions.Environment` to
  `linux` / `x86_64` (host and target).
- `src/realize/build_fallback.zig` derives store keys with `.optimize = .Debug`
  and `.linkage = .static` (with a `TODO: thread actual optimize mode and linkage`).
- `src/hash/toolchain_fingerprint.zig` sets `target_triple = host_triple` (native only).
- `src/realize/workspace.zig` `defaultProfile()` returns the constant `"debug-native"`.
- `zig build` is invoked in 4 places, none passing `-Doptimize` / `-Dtarget`.

The good news: **the store-key derivation already hashes `optimize`, `linkage`,
and the toolchain fingerprint's `host_triple` + `target_triple`** (see
`instance_key.zig:Input`). So distinct profiles already map to distinct store
keys for free — we only need to feed real values in and keep per-profile
workspaces separate.

## Two axes, kept separate

There are two conceptually different things people mean by "target":

1. **Resolution environment** — which packages/versions/conditional-deps are
   *selected*. Driven by `conditions.Environment` (host+target OS/arch + options)
   and consumed by the resolver at **lock** time. Affects the **lockfile**.
2. **Build profile** — how the selected sources are *compiled*: optimize mode,
   target triple, linkage. Consumed at **build** time. Affects **store keys** and
   the **workspace layout**, not the lockfile.

These are produced at different times (lock vs build), which forces a design
decision for cross-target builds (below).

### Decision to confirm: how does `--target` interact with resolution?

- **(A) Resolution is native-only; profile affects only the build. [Recommended]**
  `lock`/`update` detect the real host and resolve for native. `--target` /
  `--release` at build time change only compilation + store key, never which deps
  are selected. Simple, unlocks `--release` immediately. **Limitation:** a
  dependency gated on a *target*-specific `when` condition won't be re-selected
  for a cross `--target`. For the current examples (no target-conditional deps)
  this is invisible; we document it.
- **(B) Re-resolve per target at build time.** Correct for target-conditional
  deps, but the build stops being a pure function of the lockfile.
- **(C) Lockfile stores resolution per environment.** Most correct, most complex
  (lockfile schema change).

This plan implements **(A)** and lists (B)/(C) as future work. It fixes the
concrete bug (hardcoded host) and delivers the most-wanted capability
(`--release`) without a lockfile-schema change.

## The `Profile` type

New `src/model/profile.zig` (or under `realize/`):

```zig
pub const Profile = struct {
    optimize: std.builtin.OptimizeMode = .Debug,   // Debug|ReleaseSafe|ReleaseFast|ReleaseSmall
    linkage: model.GraphLinkage = .static,          // static|shared
    /// null = native (host); otherwise a Zig target triple, e.g. "x86_64-linux-gnu".
    target: ?[]const u8 = null,

    /// Stable directory slug for `.zpkg/work/<slug>/`.
    /// e.g. "debug-native", "releasefast-native", "releasefast-x86_64-linux-gnu-shared".
    pub fn slug(self: Profile, allocator, host_triple) ![]u8 { ... }
};
```

`slug()` = `"{optimize-lower}-{target-or-native}"`, with `-{linkage}` appended
only when non-default (`.shared`) so the current `"debug-native"` slug is
preserved for the default profile (keeps existing store/workspaces valid).

## Phased implementation

### Phase 1 — Detect the real host (resolution env) — independent, ship first
- Add `conditions.detectHost() Environment` using `@import("builtin").target`
  (`.os.tag`, `.cpu.arch`), target defaulting to host.
- Replace the hardcoded `Environment` literal in `lockcmd.zig` with it.
- Fixes the "wrong lockfile platform on macOS/ARM" bug on its own. No store-key
  change. Small, low-risk.

### Phase 2 — Profile model + slug
- Add `Profile` + `slug()`; unit-test slug formatting.
- Replace `workspace.defaultProfile()` with `Profile{}` (the default), and make
  `WorkspaceLayout.init` take a slug string derived from the profile.

### Phase 3 — CLI surface (`build` and `test`)
- New flags parsed in `cli/build.zig` (shared by `test` via `runBuild`):
  - `--release[=safe|fast|small]` (bare `--release` ⇒ `ReleaseFast`) and/or
    `--optimize <Mode>`.
  - `--target <triple>` (native if omitted).
  - `--linkage static|shared` (default `static`).
- Build a `Profile` from the flags; thread it into `runBuild`.
- `test` + cross `--target`: reject (or warn+skip run) — running foreign-target
  test binaries needs an emulator; out of scope. Native `test` unaffected.

### Phase 4 — Thread the profile through the build
- `toolchain_fingerprint.detect(allocator, io, requested_target: ?[]const u8)`:
  set `target_triple` to the requested triple (normalized) or `host_triple` when
  null. (MVP: record the triple for the key; do **not** attempt to re-detect a
  cross sysroot/libc — those stay sentinels, documented.)
- `planBuild` / `deriveHex`: replace the hardcoded `.optimize = .Debug` /
  `.linkage = .static` with `profile.optimize` / `profile.linkage` (the
  fingerprint already carries the target).
- `WorkspaceLayout`: use `profile.slug(...)`.
- Pass flags to every `zig build` invocation (4 sites: `build_fallback`
  install + test, `cli/build.zig` root build + test):
  `-Doptimize={Mode}` always, and `-Dtarget={triple}` when non-native.
  Each instance is built in isolation, so each must receive the flags; the store
  key + per-profile workspace keep variants from colliding, and binary adapters
  keep handing back whichever `.a` matches the realized profile.

### Phase 5 — Tests
- Unit: `profile.slug` cases; `conditions.detectHost` returns current host;
  `deriveHex` yields different keys for Debug vs ReleaseFast and static vs shared
  (extend `instance_key.zig` tests — trivial, inputs already supported).
- Integration (`test/integration/diamond.sh`): add a `--release` build and assert
  it is a *fresh* build (5 to build, not store hits against the Debug run), the
  app still prints `= 24`, and a second `--release` build is all store hits.
  Confirms profiles get independent store slots and the app is correct in both.

## Store-key & workspace impact
- Existing default (`Debug`/native/static) keeps the same store keys and the
  `"debug-native"` slug ⇒ **no invalidation** of already-built artifacts.
- New profiles occupy new store keys and new `.zpkg/work/<slug>/` trees; they
  coexist with the default. No migration needed.

## Explicitly out of scope (future work)
- **(B)/(C)** target-aware resolution / per-target lockfiles.
- Real cross-compilation sysroot/libc/ABI detection in the toolchain
  fingerprint (kept as sentinels; only the triple varies for now).
- Running cross-target test binaries (needs an emulator/runner).
- Multi-profile in one invocation (e.g. build Debug+Release together).

## Risks / watch-items
- `-Dtarget`/`-Doptimize` must actually reach dependency sub-builds. Each zpkg
  instance is built standalone, so this is per-instance and already isolated —
  but verify the generated adapter `build.zig` (which uses
  `standardTargetOptions`/`standardOptimizeOption`) tolerates receiving
  `-Dtarget` for a cross build while just returning the prebuilt `.a`.
- Cross-target C compilation via `zig build` needs `zig cc` as the C compiler in
  the example build scripts; the diamond libs compile C, so a cross `--target`
  integration case may surface toolchain gaps. Keep the integration cross-case
  behind a capability check (skip if the target can't build) so CI stays green.

## Suggested landing order
Phase 1 (host detection) and Phase 2 (profile model) can land independently and
low-risk. Phases 3–5 land together as "`--release` / `--target` support". This
sequence delivers the lockfile-portability fix first, then the build-profile
capability, without ever changing the store-key schema for the existing default.
```
