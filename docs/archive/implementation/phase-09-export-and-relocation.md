# Phase 09 - Export and Relocation

## Purpose

Implement `zpkg export` and relocatable closure bundles.

Export semantics are intentionally separate from the internal local store.

## Phase dependencies

- Requires: Phases 04, 06, 07
- Benefits from: Phase 08 diagnostics and graph UX
- Unlocks: final MVP portability and deployment workflows

## Parallelism

- `P09-A` and `P09-B` can overlap once core export interfaces are agreed.
- `P09-C` follows after those exist.

## Work units

### P09-A - Export closure planner

**Goal**
- Decide which instances and files belong in an exported bundle.

**Likely files**
- `src/export/export.zig`

**Requirements**
- Default export domain is target only
- Exclude host-only tool/build/test deps by default
- Support:
  - `zpkg export <package>`
  - `zpkg export <package_id>:<target_name>`
- Root package export defaults to all exported, non-test, target-domain targets

**Validation**
- Unit tests for closure planning from sample graphs

**Exit criteria**
- Export roots and dependency closure rules are deterministic and documented in code/tests

---

### P09-B - Relocatable bundle assembly

**Goal**
- Create relocatable tarballs from resolved closures.

**Likely files**
- `src/export/export.zig`
- `src/cli/export.zig`

**Requirements**
- Produce a closure containing only:
  - `bin/`
  - `lib/`
  - `include/`
  - `share/`
- Prefer environment/dev-shell activation as the primary runtime workflow
- Support direct execution after unpack where practical
- Export requires an authoritative lockfile

**Validation**
- Export sample closure
- Unpack in a different location
- Activate environment and use resulting bundle

**Exit criteria**
- Exported closure works after relocation without re-linking

---

### P09-C - Collision policy and resources

**Goal**
- Implement resource/file collision handling at export time.

**Likely files**
- `src/export/export.zig`

**Requirements**
- Byte-identical collisions are allowed
- Differing-content collisions are errors
- Diagnostics identify both colliding sources and target paths
- Respect developer-specified `share/` subdirectories from resource targets

**Validation**
- Integration tests with identical and non-identical collision cases

**Exit criteria**
- Export is safe and deterministic in the presence of overlapping resource layouts

## Phase completion criteria

This phase is complete when:

- `zpkg export` can produce a relocatable package or target closure
- exported bundles honor target-domain defaults
- environment/wrapper activation works
- collision handling matches the documented policy
