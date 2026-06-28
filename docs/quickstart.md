# zpkg Quickstart

Use `examples/hello-lib` as the sample package throughout.

## 1. Create a lockfile

```
zpkg lock examples/hello-lib
```

Reads `zpkg.zon`, resolves the dependency graph, and writes `zpkg.lock.zon`.
Run this once per package root. Use `zpkg update` for subsequent changes.

## 2. Inspect a package

```
zpkg inspect examples/hello-lib
```

Prints the normalized package contract from `zpkg.zon` — identity, version,
declared options, and dependencies.

## 3. View the resolved graph

```
zpkg graph examples/hello-lib
zpkg graph examples/hello-lib --verbose
```

Default: shows the resolved instance tree from `zpkg.lock.zon`.
`--verbose`: also prints selected options and dep keys per instance.

## 4. Build

```
zpkg build examples/hello-lib
```

Reads `zpkg.lock.zon`, realizes the workspace under `.zpkg/`, and builds all
targets.

## 5. Build with tests

```
zpkg build examples/hello-lib --with-tests
```

Includes test targets in the build graph.

## 6. Run tests

```
zpkg test examples/hello-lib
```

Builds and runs the test graph for the package.

## 7. Realize workspace (debug)

```
zpkg realize examples/hello-lib
```

Materializes the generated workspace at `.zpkg/` without building. Useful for
inspecting generated `build.zig` files or debugging resolution output.

## 8. Export (coming soon)

```
zpkg export examples/hello-lib
```

Exports a relocatable closure bundle. Not yet implemented.
