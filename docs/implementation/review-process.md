# Review Process for Subagent Implementation

## Purpose

Every implementation phase must include an explicit code-review loop.

A clean reviewer subagent should verify the output of the developer subagent against:

- the relevant phase/task definition in `docs/implementation/`
- the root implementation plan in `docs/zpkg-implementation-plan.md`
- the architecture in `docs/zpkg-mvp-architecture.md`
- the relevant schema docs:
  - `docs/zpkg-schema.md`
  - `docs/zpkg-lockfile.md`
  - `docs/zpkg-graph-schema.md`
- general code quality, maintainability, and style expectations

A phase is not complete until:

1. the developer lane finishes,
2. a clean reviewer lane reviews the result,
3. required findings are fixed by the developer lane,
4. the reviewer lane re-checks and signs off.

---

## Roles

## Developer subagent

Owns implementation of a lane or work unit.

Responsibilities:
- make the requested changes
- add/update tests
- run validation commands
- report files changed and commands run
- respond to reviewer findings with corrections

## Reviewer subagent

Must be a fresh or otherwise clean subagent not used for the implementation work being reviewed.

Responsibilities:
- compare implementation against the task definition and specifications
- verify tests/validation are appropriate
- inspect code quality and style
- distinguish required fixes from optional suggestions

---

## Review outputs

Reviewer output should be split into two buckets.

### Required findings

These must be sent back to the developer subagent for correction before the lane can be considered complete.

Examples:
- behavior diverges from the phase spec
- missing validation/test coverage for the stated acceptance criteria
- architecture/schema contract violations
- clear bugs or incomplete implementations
- poor error handling for required workflows

### Optional improvements

These should be reported back to the primary Manager agent as possible follow-up tasks.

Examples:
- ergonomic improvements beyond current scope
- extra refactors not needed for correctness
- additional diagnostics or polish
- performance improvements not required for the phase exit criteria

Optional improvements should **not** block lane completion unless they reveal a real correctness or spec-compliance issue.

---

## Standard review loop

### Step 1 - Developer completes lane

Developer subagent reports:
- files changed
- tests/commands run
- known limitations

### Step 2 - Reviewer runs clean review

Reviewer should read:
- `docs/zpkg-mvp-architecture.md`
- `docs/zpkg-implementation-plan.md`
- `docs/implementation/README.md`
- the relevant `docs/implementation/phase-XX-...md`
- any relevant schema docs

Reviewer should then inspect the actual code and tests.

### Step 3 - Reviewer returns findings

Expected format:

```text
Required findings:
1. ...
2. ...

Optional follow-ups for Manager:
1. ...
2. ...

Verdict:
- approve
or
- changes required
```

### Step 4 - Developer addresses required findings

Developer subagent resumes in the same lane and makes the required corrections.

### Step 5 - Reviewer re-checks

Reviewer verifies that required findings are resolved.

Only then may the lane be merged or marked complete.

---

## Review scope checklist

The reviewer should explicitly check:

- task scope completion
- architecture compliance
- schema/contract compliance
- correct file ownership / no unnecessary spillover
- tests added or updated appropriately
- validation commands actually run
- error handling for required user flows
- code clarity and maintainability
- absence of obvious dead code / placeholders left behind

---

## Merge gate rule

For each lane/wave:

- **no merge without review**
- **no next dependent wave without review sign-off**

Parallel lanes may continue independently, but any lane that produces an input required by a dependent lane must be reviewed before that dependent lane starts.

---

## Suggested reviewer prompt skeleton

```text
You are the reviewer for a completed implementation lane.

Read first:
- docs/zpkg-mvp-architecture.md
- docs/zpkg-implementation-plan.md
- docs/implementation/README.md
- docs/implementation/review-process.md
- the specific phase file for this lane
- any relevant schema docs

Review the implementation against:
- the phase task definition
- the architecture and schema docs
- code quality and maintainability expectations
- sufficiency of tests and validation commands

Do not make code changes.

Return:
1. Required findings that must be fixed before approval
2. Optional improvements that should be reported to the Manager for possible follow-up tasks
3. A final verdict: approve or changes required
```

---

## Completion rule

A phase or lane is considered complete only when it is:

- implemented
- validated
- reviewed by a clean reviewer subagent
- corrected if necessary
- re-reviewed and approved
