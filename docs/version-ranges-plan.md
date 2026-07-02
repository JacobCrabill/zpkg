# Plan: Version-Range Support on Dependencies

_Status: proposed._

## Current state (facts)

- **Versions** (`src/model/version.zig`) are a 4-component tuple
  `major.minor.patch.revision` with `cmp`/`eql`. `Version.parse` accepts 3 or 4
  components (3 → revision 0).
- **Requirements** (`src/model/package.zig::VersionRequirement`) are **exact-only**:
  `parse` requires a leading `=` and stores a single `exact: Version`. The ZON
  surface is `.deps.<alias>.require = .{ .version = "=<version>" }`
  (schema errors `MissingDependencyVersionRequirement` / `UnknownRequirementField`).
- **The resolver never enforces `require`.** `src/resolve/root.zig` parses each
  dependency's `zpkg.zon` from its `source_path` and uses that manifest's
  `package.version`, but never checks it against `dep.require`. So today the
  requirement is dead metadata — parsed and syntactically validated, never applied.
- **One instance per `package_id#domain`.** The resolver dedupes by package id
  (`resolved.get(instance_key)`, first-resolved wins) and records one source dir
  per `package_id#target`. There is no representation for multiple candidate
  versions of the same package.
- **Path-based, no registry.** Every dependency has exactly one `source_path`
  providing exactly one version. There is no pool of versions to choose among.
- The **lockfile** already pins each instance's concrete `version` + `source_hash`
  + `source_path`; the **store key** already hashes the concrete version. Neither
  needs to change to *express* ranges — ranges live in `zpkg.zon`, resolved
  concrete versions live in the lockfile.

## The core split

"Version ranges" means two very different things here:

1. **Constraint checking** — a dep declares a range; the resolver verifies the
   (single, path-provided) version satisfies it, and reports conflicts when two
   dependents demand incompatible ranges of the same package. **Fully feasible
   today** on the path model, and it's where most of the near-term value is.
2. **Version selection** — given *many* available versions of a package, pick the
   best set satisfying all constraints across the graph. This **requires a package
   source that enumerates versions** (a registry, git tags, or a version-indexed
   local layout) — which zpkg does not have. It's a much larger feature.

This plan delivers (1) now and designs (2) behind a package-source abstraction.

---

## Phase 1 — Range grammar + constraint checking (deliverable now)

### 1a. Requirement model (`model/package.zig`, `model/version.zig`)
Replace the exact-only `VersionRequirement` with a normalized bounded range:

```zig
pub const Bound = struct { version: Version, inclusive: bool };
pub const VersionRequirement = struct {
    lower: ?Bound = null, // e.g. >=1.2.0
    upper: ?Bound = null, // e.g. <2.0.0
    pub fn satisfies(self: VersionRequirement, v: Version) bool { ... }
    pub fn parse(text: []const u8) !VersionRequirement { ... } // grammar below
    pub fn format(...) ...                                     // canonical rendering
};
```

`satisfies(v)` = (lower absent or `v` ≥/> lower) and (upper absent or `v` </≤ upper).
Every operator desugars to `lower`/`upper`, so `satisfies` stays trivial. Add
`Version.nextMajor()` / `nextMinor()` helpers for caret/tilde upper bounds.

### 1b. Grammar (`VersionRequirement.parse`)
Accept a comma-separated conjunction of comparators (all must hold):

| Syntax | Meaning (desugared) |
|---|---|
| `=1.2.3` | `[1.2.3.0, 1.2.3.0]` (exact — backward compatible) |
| `>=1.2.3` / `>1.2.3` | lower bound (incl / excl), no upper |
| `<=1.2.3` / `<1.2.3` | upper bound (incl / excl), no lower |
| `^1.2.3` | `>=1.2.3, <` next-major (see 0.x rule) |
| `~1.2.3` | `>=1.2.3, <1.3.0` |
| `*` / `any` | no bounds |
| `>=1.2, <2.0` | intersection of comparators |

**Caret + the 0.x rule** (adopt Cargo's, adapted to 4 components):
- `^1.2.3` → `>=1.2.3.0, <2.0.0.0`
- `^0.2.3` → `>=0.2.3.0, <0.3.0.0` (leading zero major ⇒ minor is the compat axis)
- `^0.0.3` → `>=0.0.3.0, <0.0.4.0`
The `revision` (4th) component participates in ordering/lower-bounds but never
forms its own caret compat axis. This is a **decision to confirm** (below).

Multiple comparators intersect into a single `{lower, upper}` (take the tightest
lower and tightest upper); an empty intersection (lower > upper) is a parse-time
"unsatisfiable requirement" error.

### 1c. Schema surface (`schema/zpkg.zig`)
`.require = .{ .version = "<range>" }` — same field, richer string. Update
`parseDependency` to call the new `parse` and refresh the diagnostic text
(`each .deps.<alias>.require must declare .version = "<range>"`, with examples).
Existing `=0.1.0.0` manifests keep parsing unchanged.

### 1d. Enforce in the resolver (`resolve/root.zig`)
When a dependency manifest is resolved (`resolveManifests`/`parseDependencyManifest`),
check `dep.require.satisfies(dep_manifest.package.version)`. On failure, a new
`ResolverError.UnsatisfiedRequirement` with an actionable message:
`dependency 'libA' requires ^0.2 but the source at '../libA' is 0.1.0.0`.

**Diamond conflict detection.** Because a package id resolves to a single version,
accumulate the requirements seen for each `package_id` across the graph. When the
same package is reached by a second dependent, verify the already-resolved version
also satisfies the new requirement; if not, emit a `VersionConflict` naming both
requesters and the version:
`package 'diamond.libA' @ 0.1.0.0 satisfies 'libC' (^0.1) but not 'libD' (^0.2)`.
This makes ranges genuinely useful on the path model — expressing compatibility
and catching incompatibilities — without any multi-version machinery.

### 1e. Lockfile / store key
No changes. Requirements stay in `zpkg.zon`; the lockfile keeps pinning the
resolved concrete version; the store key is unchanged (it already hashes the
concrete version, not the requirement).

### 1f. Tests
- Unit: `VersionRequirement.parse`/`satisfies` for every operator incl. 0.x caret,
  compound intersection, and unsatisfiable-parse errors; `nextMajor`/`nextMinor`.
- Resolver: a satisfied range resolves; an unsatisfied one errors; a diamond with
  a compatible pair resolves and an incompatible pair conflicts.
- Integration: extend the diamond example so a lib requires `^0.1` (still resolves
  to 0.1.0.0 → unchanged build), plus a negative fixture asserting the conflict
  message. Keep the happy path green.

---

## Phase 2 — Version selection (designed; gated on a package source)

True range *selection* needs a source that can enumerate/fetch versions. Introduce
a `PackageSource` abstraction the resolver consumes instead of a bare path:

```zig
pub const PackageSource = struct {
    // e.g. a version-indexed local dir, git tags, or a registry
    availableVersions(pkg: PackageId) ![]Version,
    locate(pkg: PackageId, v: Version) ![]u8, // → source dir (fetch/cache as needed)
};
```

- **Selection strategy** (decision to confirm): recommend **newest-compatible**
  (Cargo-style) — for each package, pick the highest version satisfying the
  intersection of all its requirements. Alternative: **Minimal Version Selection**
  (Go-style) — lowest version satisfying all — which is more reproducible without a
  lockfile. Since zpkg already pins via the lockfile, either works; newest-compatible
  is the more familiar default.
- **Single version per package id** stays the invariant: unify to one selected
  version; an empty intersection across the graph is a hard `VersionConflict`.
  (Allowing two majors of one package side-by-side — Cargo-style — is a distinct,
  much larger feature: separate instance identities, symbol namespacing. **Deferred.**)
- **Where selection runs:** at `lock`/`update` time only. `build` keeps reading the
  pinned lockfile and never re-resolves — consistent with the lockfile-as-pin model
  (and the auto-lock feature already in `build`). The lockfile continues to record
  the *selected* concrete version + its resolved source location.
- Path deps become a trivial `PackageSource` with exactly one version, so Phase 1
  behavior is the degenerate case of Phase 2 — no rework, just a wider source set.

## Phase 3 — Registry & fetching (future, orthogonal)

Remote sources, integrity hashes, and a fetch cache. Not part of the range feature
itself, but it's what makes selection matter at scale. Out of scope here.

---

## Store-key & lockfile impact (summary)
- Phase 1: **none** — ranges are expressed in `zpkg.zon`; resolved versions already
  flow to the lockfile and store key.
- Phase 2: still none to the *schema* — the lockfile keeps pinning selected concrete
  versions; selection is a `lock`-time computation, not new persisted state (beyond
  possibly recording the per-instance source origin, which path deps already do via
  `source_path`).

## Decisions to confirm
1. **Operator set** — adopt `= >= <= > < ^ ~ *` + comma-AND? (Recommended.)
2. **Caret 0.x semantics** — adopt Cargo's `^0.2.3 ⇒ <0.3.0`, `^0.0.3 ⇒ <0.0.4`,
   with the 4th `revision` component ordering-only (no compat axis)? (Recommended.)
3. **Phase 2 selection** — newest-compatible (Cargo) vs MVS (Go)? (Recommend
   newest-compatible, computed at lock time.)
4. **Side-by-side majors** — confirm deferring (keep one version per package id).

## Suggested landing order
Phase 1 lands as one self-contained change (grammar + model + schema + resolver
enforcement + conflict detection + tests) with **no lockfile/store-key migration**
and full backward compatibility for existing `=x.y.z` manifests. It immediately
turns `require` from dead metadata into an enforced, conflict-checked constraint —
the highest-value step. Phase 2 waits until there's a real multi-version source to
select from; its design (the `PackageSource` seam + lock-time selection) is fixed
now so Phase 1's resolver enforcement is written against that seam and doesn't need
reworking later.
