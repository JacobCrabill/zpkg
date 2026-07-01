# zpkg Design & Implementation Review

_Date: 2026-07-01_

This review was prompted by fixing a concrete design defect: the realizer used to
**rebuild each `build.zig.zon` field-by-field from a parsed struct**, which dropped
the `.fingerprint` field, which then required a bolted-on *20-pass "patch the
fingerprint" build loop* to repair. The fix was to stop reconstructing the file and
instead **copy the source verbatim and splice only `.dependencies`**.

That defect is a symptom of a recurring pattern in this codebase, and this document
catalogs the related issues, ranked roughly by impact.

---

## 1. The root anti-pattern: reconstruct-from-parts instead of pass-through

The fingerprint bug is the clearest instance of a general habit: **take structured
input apart into fields, then re-emit it**, losing anything the emitter forgot to
carry. This is fragile by construction — every new field in `build.zig.zon`
(`fingerprint`, and tomorrow `.lazy`, `.hash`, custom keys) silently disappears
unless someone edits the emitter.

- **Fixed here:** `SourcePkgRealize` now copy-pastes and splices. Good.
- **Still lurking:** `readSourceFields` still parses `name`/`version`/
  `minimum_zig_version`/`paths`/`fingerprint` into a struct. Its **only remaining
  caller** reads a single field — `fingerprint` — for the binary adapter. It should
  be replaced by a focused `readFingerprint()` (or fold the fingerprint read into a
  single parse), and the `SourceFields` struct + its verbatim-field machinery
  deleted. Keeping it invites the same "reconstruct" pattern to grow back.

**Guiding principle to adopt:** the realizer's job is to *relocate* packages, not to
*author* them. Prefer copy + minimal surgical edit over regenerate-from-model
anywhere a real on-disk artifact already exists.

---

## 2. `cli/realize.zig` is a second, divergent copy of the realization engine

`src/cli/realize.zig` (standalone `realize` command) and
`src/realize/build_fallback.zig` (`BuildExecutor.execute` / `reifyStoreHit` /
`buildInstance`) implement **the same logic twice**:

- iterate lockfile instances,
- build the `alias → deps/<key>` `DepPathMap` from `instance.deps`,
- branch on store-hit → `BinaryAdapter.generate` vs miss → `SourcePkgRealize.realize`,
- read the source fingerprint and thread it into the adapter.

This is not hypothetical duplication — **the fingerprint fix had to be applied in
both files** (see the `source_fp` blocks in `cli/realize.zig:159` and
`build_fallback.zig:485`, which are copy-pasted). Any future realization change must
be made in two places or they drift.

**Recommendation:** extract one `Realizer` type in `src/realize/` that owns
"materialize instance N into its workspace dir" (both the source and adapter paths,
plus dep-map construction). `cli/realize.zig` becomes a thin driver that loops and
calls it; `BuildExecutor` calls the same routine after a build. The dep-map builder
alone appears **5 times** (`build.zig:203`, `realize.zig:122`, `realize.zig:203`,
`build_fallback.zig:463`, `build_fallback.zig:713`) — collapse it to one helper.

---

## 3. `lock` and `update` are ~90% the same file

`cli/lock.zig` and `cli/update.zig`:

- `generateLockfile` is **byte-identical** between them except two comments
  (verified with `diff`).
- The `run()` bodies differ only in: the pre-check (lock refuses if a lockfile
  exists; update doesn't), the `--dry-run` branch (update only), and the success
  string.

**Recommendation:** one `generateLockfile` in a shared module (it belongs next to
the resolver, not in a CLI file), and a single `writeLockfile(mode: .create |
.update, dry_run: bool)` used by both commands.

---

## 4. A shared diagnostics module exists but was abandoned

`src/util/diag.zig` provides `writeError`, `writeHint`, `writeBuildSummary`,
`writeLockfileDriftError` — and **almost none are used** (0 external callers each;
only `resolveAbsPath` and `writeLockfileMissingError` are actually referenced).

Meanwhile **every CLI file redefines its own private** `writeStderr` /
`writeStderrFmt` / `writeHelp`:

| Helper | Copies |
|---|---|
| `writeStderr` | 6 (build, export, graph, inspect, lock, update, realize) |
| `writeStderrFmt` | 7 |
| `writeHelp` | 3 (+ `writeStdout` in graph, `printStderr`/`printRaw` in build_fallback) |

Every copy re-declares a stack buffer, a `File.Writer`, `.interface`, and a flush —
the exact boilerplate `diag.zig` was created to remove.

**Recommendation:** make `diag.zig` (or a small `cli/io.zig`) the single home for
stdout/stderr/help writers and delete the per-file copies. Standardize the help
dispatch too: each command reimplements the `--help/-h` check slightly differently
(and `test_cmd.zig` inlines four separate ad-hoc stderr writers instead of any
helper at all).

---

## 5. Hardcoded platform, profile, and build settings

Reproducibility and cross-platform correctness are undercut by constants:

- **`lock.zig:76` / `update.zig:68`** hardcode the resolution environment to
  `linux` / `x86_64` for both host and target. On macOS or ARM the generated
  lockfile describes the wrong platform. Conditions/domains exist in the model but
  the CLI never detects the real host.
- **`build_fallback.zig:288-289`** hardcode `optimize = .Debug` and
  `linkage = .static` in the store-key derivation, with a `TODO: thread actual
  optimize mode and linkage through BuildPlan`. So `--release` is impossible and all
  profiles would collide on one store key if added.
- **`workspace.defaultProfile()`** returns the constant `"debug-native"`; there is
  no `--profile`/`--release` surface anywhere.

These are acknowledged MVP shortcuts, but they're the top items to design for next
because they change the store-key schema (a migration cost that grows with adoption).

---

## 6. Inconsistent allocator strategy (some commands leak silently)

- `lock`, `update`, `inspect`, `graph`, `realize` use `std.heap.page_allocator` —
  no leak detection, and these commands **do leak** (e.g. `inspect` never frees the
  manifest arena on some error paths; `page_allocator` just hides it).
- `build` and `export` use `DebugAllocator` with `defer _ = gpa.deinit()` (leak
  detection on).

Additionally, `zon_util.zig` reaches for `std.heap.page_allocator` **internally**
(lines 190-214) inside otherwise allocator-parameterized parse helpers, which is a
hidden global-allocator dependency in a supposedly pure module.

**Recommendation:** pick one convention (`DebugAllocator` in debug, arena per
command) and apply it uniformly, so leaks surface in tests instead of being masked.

---

## 7. Smaller items

- **Duplicate `relativePath`**: identical function in `binary_adapter.zig:357` and
  `source_pkg.zig:366`. Move to `util/`.
- **Redundant re-parsing of source `build.zig.zon`**: during a source realization
  the file is read/parsed up to **3×** per instance — once raw in `realize()`, again
  in `readExtraDepsFromSource()`, and a third time via `readSourceFields()` in
  `reifyStoreHit`. Parse once, pass the parsed doc (or the raw bytes + one parse)
  down.
- **Dead parameters:** `SourcePkgRealize.realize` takes `pkg_name` and immediately
  `_ = pkg_name` — threaded uselessly through 3 call sites. `buildInstance` takes
  `lockfile` and does `_ = lockfile` (line 839). Remove them.
- **`inspect.zig` has two near-identical entry points** (`inspectPackageAlloc` for
  the test, `inspectPackageAllocForCli` for the command) differing only in error
  presentation. Collapse to one with a `diagnostics: bool` or an error-context
  return.
- **Adapter test comment `// cache bust` and a trailing stray line** at
  `binary_adapter.zig:458` — leftover debugging noise.
- **Repo hygiene:** a `.zig-cache/` directory is sitting **inside `src/cli/`**
  (untracked but present), which means `zig build` was run with a cwd under `src/`.
  Confirm `.gitignore` covers nested `.zig-cache` and remove it; also `current.env`
  in the repo root looks like a stray artifact.

---

## Suggested order of work

1. **Extract one `Realizer`** and delete the `cli/realize.zig` duplication (#2) —
   highest leverage; directly prevents "fix it in two places" bugs like the
   fingerprint one.
2. **Centralize CLI IO/diagnostics** in `diag.zig` and delete per-file copies (#4).
3. **Merge `lock`/`update`** onto one `generateLockfile` + `writeLockfile` (#3).
4. **Finish removing the reconstruct pattern**: replace `readSourceFields` with
   `readFingerprint`, delete `SourceFields` (#1).
5. **Design the profile/target axis** (host detection + `--release` + store-key
   fields) before the store format is depended upon (#5).
6. Sweep the small items (#6, #7).

None of these are correctness-critical for the current single-profile,
Linux/x86_64, source-only happy path — the tests and the diamond example pass. They
are about removing the structural duplication that made the fingerprint bug possible
and about not baking today's shortcuts into the store-key schema.
