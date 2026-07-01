# Integration Tests

End-to-end tests that drive the real `zpkg` CLI against example package graphs.

## `diamond.sh`

Drives the full pipeline (`lock → build → run → rebuild → realize`) against the
committed `examples/diamond` graph and asserts on exact outputs. Run it with:

```sh
zig build integration        # builds zpkg first, then runs the script
# or, after `zig build`:
bash test/integration/diamond.sh
```

It is kept out of `zig build test` (which stays fast and toolchain-light) because
it shells out to `zig build` and requires a C toolchain. The script header
documents precisely which features are deterministically validated and which are
intentionally out of scope; keep that contract up to date when extending it.

The script only ever writes zpkg-generated, git-ignored artifacts
(`.zpkg/`, `zig-out/`, `zpkg.lock.zon`, `.zig-cache/`) into the example tree and
cleans them up on exit — the committed sources are never modified.

## Reserved subdirectories

- `fixtures/` — checked-in input package graphs and malformed cases
- `store/` — fake artifact-store layouts used by tests
- `workspaces/` — expected realized-workspace layouts or scratch conventions
