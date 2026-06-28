#!/usr/bin/env bash
set -euo pipefail

echo "Building first time..."
zig build
cp zig-out/bin/zpkg /tmp/zpkg_run1

echo "Building second time..."
zig build
cp zig-out/bin/zpkg /tmp/zpkg_run2

echo "Diffing artifacts..."
if diff -q /tmp/zpkg_run1 /tmp/zpkg_run2 > /dev/null 2>&1; then
    echo "Determinism check passed: zig-out/bin/zpkg is byte-identical across two builds"
else
    echo "FAIL: zig-out/bin/zpkg differs between build runs" >&2
    exit 1
fi
