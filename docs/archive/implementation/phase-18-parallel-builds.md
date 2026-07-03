# Phase 18 — Parallel Builds

## Problem

`BuildExecutor.execute` (`realize/build_fallback.zig:195`) iterates the topological
order and calls `buildInstance` serially.  Packages at the same graph level (e.g.,
`libA` and `libB` in the diamond, which have no dependency on each other) are built
one at a time:

```zig
for (plan.build_order) |key| {
    ...
    self.buildInstance(instance, key, lockfile, plan.mode) catch ...;
}
```

For a repository with N independent leaf packages, this means N sequential compiler
invocations.  Each `zig build` invocation typically uses all available CPU cores
itself, but between invocations the machine is idle.  For medium-scale repos (20–50
leaf packages), serial builds add several minutes of avoidable wait.

---

## Design

### Wave-based parallelism

Segment the topological order into *waves*: sets of nodes where no node in a wave
depends on any other node in the same wave.  Dispatch all nodes in a wave concurrently;
wait for the wave to complete before starting the next one.

```
Wave 0: [libA, libB]        ← independent leaves
Wave 1: [libC, libD]        ← each depends on Wave 0 only
Wave 2: [libE]              ← depends on Wave 1
Wave 3: [app]               ← depends on Wave 2
```

### Wave construction

A simple way to compute waves from the existing topological order:

1. Assign each node a *level*: the maximum level of its deps, plus one.  Leaves get
   level 0.
2. Group nodes by level.
3. Within a level, all nodes are independent (by construction of the topo sort and the
   dep graph).

The level can be computed during the DFS in `planBuild` by tracking the max dep level.

### Concurrency mechanism

Use `std.Thread` to spawn one thread per node in a wave.  Each thread calls
`buildInstance` for its assigned node.  The executor waits for all threads in a wave
to finish before proceeding.

Alternatively, use a thread pool (one global pool sized to CPU count) and submit each
wave's nodes as tasks.

**Constraint:** Each `buildInstance` call spawns a `zig build` child process, which
itself saturates available cores.  For waves with more than ~`cpu_count / 2` nodes,
running all nodes simultaneously may cause thrashing.  A configurable parallelism limit
(`--jobs N`, defaulting to `cpu_count` or a fraction of it) is desirable.

### Error handling

If any node in a wave fails, mark the failure but continue building the rest of the
wave (to surface multiple independent failures in one pass).  After the wave completes,
if any node failed, do not start the next wave — downstream packages cannot be built
with missing deps.

Report all failures at the end:

```
[done]  diamond.libA
[fail]  diamond.libB  (exit code 1)
[done]  diamond.libC  (skipped — wave aborted after failure)

error: 1 package(s) failed to build:
  diamond.libB  (see workspace for build log)
```

### Store hits in parallel

Store hits (`plan.store_hits`) require no work beyond logging.  They can remain in the
serial loop before launching the parallel wave, or be handled concurrently with the
first wave.  Either way is correct; concurrent handling is a minor optimization.

---

## Required changes

### 1. Extend `BuildPlan` with wave information

**File:** `realize/build_fallback.zig`

Add a `waves: [][]const []u8` field (or `waves: [][]usize` indexing into
`build_order`) so the executor can iterate waves rather than individual nodes.

Change `planBuild` to compute levels during the DFS and group nodes into waves.

### 2. Change `BuildExecutor.execute` to dispatch waves

Replace the serial loop with:

```zig
for (plan.waves) |wave| {
    var threads = try allocator.alloc(std.Thread, wave.len);
    defer allocator.free(threads);
    for (threads, wave) |*thread, key| {
        thread.* = try std.Thread.spawn(.{}, buildWorker, .{ self, key, ... });
    }
    for (threads) |t| t.join();
    // Check for failures; abort if any
}
```

A thread-safe error accumulator is needed since multiple threads may fail
simultaneously.  Use an `AtomicBool` for the "any failure" flag and a `Mutex`-protected
list for error details.

### 3. Add `--jobs` flag to `zpkg build`

**File:** `cli/build.zig`

Add an optional `--jobs N` argument (default: number of logical CPU cores, or
`std.Thread.getCpuCount()`) that caps the number of concurrent `buildInstance` calls.
Pass this limit into `BuildExecutor`.

If `N == 1`, disable threading entirely and use the original serial loop (useful for
debugging).

### 4. Thread-safe stdout output

Individual `[hit]`, `[build]`, `[done]`, `[fail]` log lines must not interleave.
Wrap the stdout writer in a `std.Thread.Mutex` for the duration of the parallel build
or buffer each thread's output and flush atomically when the node completes.

---

## Files to change

| File | Change |
|---|---|
| `realize/build_fallback.zig` | `BuildPlan` gains wave structure; `planBuild` computes levels; `execute` dispatches waves |
| `cli/build.zig` | Add `--jobs N` flag; pass to executor |
| `cli/test_cmd.zig` | Same `--jobs` flag for `zpkg test` |

---

## Validation

- In the diamond example, `libA` and `libB` must be built in the same wave (confirmed
  by log timestamps or a `--jobs 1` vs default comparison).
- With `--jobs 1`, behavior is identical to the current serial implementation.
- If `libB` fails to build, `libA`'s build is still attempted (intra-wave failure
  isolation), but `libC`, `libD`, `libE`, and `app` are not started.
- Log output contains no interleaved partial lines when multiple threads print
  simultaneously.
- `zig build test` passes with no regressions.

---

## Exit criteria

- `BuildExecutor` dispatches independent packages in parallel.
- `--jobs N` controls maximum concurrency.
- `--jobs 1` gives identical behavior to the current serial path.
- Build time for the diamond example (all cache misses) is measurably reduced compared
  to serial execution (at least `libA` and `libB` overlap).
- Failures in one wave do not cascade to incorrect builds of downstream packages.
- `zig build test` passes with no regressions.
