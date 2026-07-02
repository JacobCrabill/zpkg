#!/usr/bin/env bash
#
# Diamond end-to-end integration test for zpkg.
#
# Exercises the real CLI (lock → build → run → rebuild → realize) against the
# committed `examples/diamond` package graph:
#
#         app ── libE ─┬─ libC ── libA
#                      └─ libD ─┬─ libA        (libA reached via two paths)
#                               └─ libB
#
# ─────────────────────────────────────────────────────────────────────────────
# DETERMINISTICALLY VALIDATED (each assertion below is exact, not fuzzy):
#
#   1. Lockfile generation        `zpkg lock` succeeds and writes zpkg.lock.zon.
#   2. Graph resolution + dedup   A cold build plans exactly "5 instances
#                                 (0 store hits, 5 to build)". Five, not six:
#                                 libA is shared by libC and libD yet resolves
#                                 to a single instance — this proves diamond
#                                 dependency de-duplication.
#   3. Transitive C linking       The built app binary runs and prints exactly
#                                 "e_transform(3, 4, 8) = 24" — i.e. the whole
#                                 diamond of static C libraries links and the
#                                 arithmetic threaded through all five libs is
#                                 correct (not merely "artifacts exist").
#   4. Content-addressed store    A second build with no source change plans
#                                 exactly "5 instances (5 store hits, 0 to
#                                 build)" — store keys are stable/deterministic
#                                 across runs and nothing rebuilds.
#   5. Binary-adapter correctness The app rebuilt from store hits still prints
#                                 "= 24" — the deps linked as prebuilt adapters
#                                 (the exact path that carried the fingerprint
#                                 bug) produce a correct binary.
#   6. Fingerprint preservation   The realized dep's build.zig.zon carries the
#                                 *same* .fingerprint as its source package's
#                                 build.zig.zon — regression guard for the fix
#                                 that stopped zpkg from rewriting fingerprints.
#   7. Standalone `realize`       With the store populated but the work tree
#                                 wiped, `zpkg realize` produces a binary adapter
#                                 for a dep (generated build.zig + lib/ symlink
#                                 into the store) and a NON-empty root dep map —
#                                 regression guard for the two bugs fixed when
#                                 the realize command was unified with build
#                                 (wrong store key + always-empty root deps).
#   8. Build profile axis         `--release` is a *distinct* store slot: a cold
#                                 build (not Debug hits), correct app output,
#                                 cached on its own second run, in a separate
#                                 releasefast-native workspace, and it leaves the
#                                 Debug slot's store hits intact. Confirms the
#                                 profile is folded into the content-addressed key.
#   9. Auto-lock                  `zpkg build` with no lockfile resolves and
#                                 creates one, then proceeds; the regenerated
#                                 lockfile is deterministic (identical store keys
#                                 → all hits), i.e. equivalent to `zpkg lock`.
#
# NOT COVERED (intentionally out of scope for this test):
#   - Cross-compilation targets (--target): only native profiles are built here;
#     a cross case needs a target-capable toolchain and is gated out for CI.
#   - Non-Zig backends (all diamond packages use the .zig backend).
#   - Build options and conditional dependencies (the diamond has none).
#   - Source-drift detection and --strict-lockfile behavior.
#   - Incremental partial rebuilds (change one lib → rebuild only its subtree).
#   - Other subcommands: update, export, graph, inspect, test.
#   - Registry/network fetching (all deps are local path deps).
#   - Windows (bash + symlink-based workspaces).
#   - Parallel-build output ordering is deliberately NOT asserted on; only the
#     plan summary lines, exit codes, file contents, and app output are checked.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# --- Locate repo root, zpkg binary, and the example ---------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ZPKG_BIN="${ZPKG_BIN:-$ROOT/zig-out/bin/zpkg}"
APP="$ROOT/examples/diamond/app"

# Colors (only when stdout is a TTY).
if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; BOLD=""; RESET=""
fi

pass_count=0
fail_count=0

ok()   { echo "  ${GREEN}✓${RESET} $1"; pass_count=$((pass_count + 1)); }
bad()  { echo "  ${RED}✗ $1${RESET}"; fail_count=$((fail_count + 1)); }

assert_contains() { # haystack needle label
    if [[ "$1" == *"$2"* ]]; then ok "$3"; else
        bad "$3"; echo "      expected to contain: $2"; echo "      actual: $1";
    fi
}
assert_eq() { # actual expected label
    if [[ "$1" == "$2" ]]; then ok "$3"; else
        bad "$3"; echo "      expected: $2"; echo "      actual:   $1";
    fi
}
assert_file() { # path label
    if [[ -e "$1" ]]; then ok "$2"; else bad "$2"; echo "      missing: $1"; fi
}
assert_symlink() { # path label
    if [[ -L "$1" ]]; then ok "$2"; else bad "$2"; echo "      not a symlink: $1"; fi
}

# Remove all zpkg-generated (gitignored) artifacts from the example so each run
# starts cold. The committed sources under examples/diamond are never touched.
clean_generated() {
    rm -rf "$APP/.zpkg" "$APP/zig-out" "$APP/zpkg.lock.zon"
    local d
    for d in app libA libB libC libD libE; do
        rm -rf "$ROOT/examples/diamond/$d/.zig-cache" "$ROOT/examples/diamond/$d/zig-out"
    done
}

trap clean_generated EXIT

# --- Build zpkg if the binary is not present ----------------------------------
if [[ ! -x "$ZPKG_BIN" ]]; then
    echo "zpkg binary not found at $ZPKG_BIN; running 'zig build'..."
    (cd "$ROOT" && zig build)
fi

# Extract the hex value of the `.fingerprint` field from a build.zig.zon.
fingerprint_of() { grep -oE '\.fingerprint = 0x[0-9a-fA-F]+' "$1" | grep -oE '0x[0-9a-fA-F]+'; }

echo "${BOLD}zpkg diamond integration test${RESET}"
echo "  zpkg:    $ZPKG_BIN"
echo "  example: $APP"
echo

clean_generated

# --- 1. Lock ------------------------------------------------------------------
echo "${BOLD}[1] zpkg lock${RESET}"
lock_out="$("$ZPKG_BIN" lock "$APP" 2>&1)"
assert_contains "$lock_out" "Lockfile created" "lock reports success"
assert_file "$APP/zpkg.lock.zon" "zpkg.lock.zon written"
echo

# --- 2. Cold build: resolution + dedup ---------------------------------------
echo "${BOLD}[2] zpkg build (cold — expect 5 built)${RESET}"
build1_out="$("$ZPKG_BIN" build "$APP" 2>&1)"
assert_contains "$build1_out" "5 instances (0 store hits, 5 to build)" \
    "plans 5 instances, all misses (libA deduped across two paths)"
assert_contains "$build1_out" "Build complete" "build completes"
echo

# --- 3. Runtime correctness: transitive C linking ----------------------------
echo "${BOLD}[3] run app binary${RESET}"
assert_file "$APP/zig-out/bin/app" "app binary produced"
app_out="$("$APP/zig-out/bin/app" 2>&1)"
assert_eq "$app_out" "e_transform(3, 4, 8) = 24" "app output correct (diamond links + computes)"
echo

# --- 4. Warm build: content-addressed store hits -----------------------------
echo "${BOLD}[4] zpkg build (warm — expect 5 store hits)${RESET}"
build2_out="$("$ZPKG_BIN" build "$APP" 2>&1)"
assert_contains "$build2_out" "5 instances (5 store hits, 0 to build)" \
    "second build is all store hits (stable content-addressed keys)"
echo

# --- 5. Binary-adapter correctness -------------------------------------------
echo "${BOLD}[5] run app after warm rebuild${RESET}"
app_out2="$("$APP/zig-out/bin/app" 2>&1)"
assert_eq "$app_out2" "e_transform(3, 4, 8) = 24" "app still correct when deps come from store adapters"
echo

# --- 6. Fingerprint preservation ---------------------------------------------
echo "${BOLD}[6] fingerprint preserved through realization${RESET}"
src_fp="$(fingerprint_of "$ROOT/examples/diamond/libC/build.zig.zon")"
realized_zon="$APP/.zpkg/work/debug-native/deps/diamond.libC#target/build.zig.zon"
realized_fp="$(fingerprint_of "$realized_zon")"
assert_eq "$realized_fp" "$src_fp" "realized libC fingerprint matches source ($src_fp)"
echo

# --- 7. Standalone realize (store populated, work tree wiped) -----------------
echo "${BOLD}[7] zpkg realize (from populated store)${RESET}"
rm -rf "$APP/.zpkg/work"
realize_out="$("$ZPKG_BIN" realize "$APP" 2>&1)"
assert_contains "$realize_out" "Workspace realized" "realize reports success"
dep_dir="$APP/.zpkg/work/debug-native/deps/diamond.libC#target"
assert_file "$dep_dir/build.zig" "libC realized as binary adapter (generated build.zig)"
assert_symlink "$dep_dir/lib" "adapter lib/ symlinks into the store"
root_zon="$APP/.zpkg/work/debug-native/root/build.zig.zon"
root_deps="$(awk '/\.dependencies = \.\{/,/^    \},/' "$root_zon")"
assert_contains "$root_deps" "libE" "root dep map is non-empty (references libE)"
echo

# --- 8. Build profile axis: --release is a distinct store slot ----------------
# The Debug store is already populated (steps 2/4). A --release build must be a
# fresh build (different keys), still correct, cached on its own, and must not
# disturb the Debug slot.
echo "${BOLD}[8] zpkg build --release (distinct profile)${RESET}"
rel1_out="$("$ZPKG_BIN" build "$APP" --release 2>&1)"
assert_contains "$rel1_out" "5 instances (0 store hits, 5 to build)" \
    "--release is a cold build (Debug artifacts don't collide)"
assert_contains "$rel1_out" "(releasefast-native)" "reports the releasefast-native profile"
assert_file "$APP/.zpkg/work/releasefast-native/root/build.zig.zon" "separate releasefast-native workspace exists"
rel_app_out="$("$APP/zig-out/bin/app" 2>&1)"
assert_eq "$rel_app_out" "e_transform(3, 4, 8) = 24" "release app output correct"

rel2_out="$("$ZPKG_BIN" build "$APP" --release 2>&1)"
assert_contains "$rel2_out" "5 instances (5 store hits, 0 to build)" "second --release is all store hits"

dbg_out="$("$ZPKG_BIN" build "$APP" 2>&1)"
assert_contains "$dbg_out" "5 instances (5 store hits, 0 to build)" \
    "Debug slot still intact after building --release"
echo

# --- 9. Auto-lock: build with no lockfile regenerates it ----------------------
# Removing the lockfile and building must recreate it and proceed. Because the
# regenerated lockfile is deterministic (identical to the original), the Debug
# store keys still match — so the plan is all hits, proving the auto-generated
# lockfile is byte-for-byte equivalent to a manual `zpkg lock`.
echo "${BOLD}[9] zpkg build auto-creates a missing lockfile${RESET}"
rm -f "$APP/zpkg.lock.zon"
auto_out="$("$ZPKG_BIN" build "$APP" 2>&1)"
assert_contains "$auto_out" "No lockfile found" "build reports the missing lockfile"
assert_file "$APP/zpkg.lock.zon" "lockfile recreated by build"
assert_contains "$auto_out" "5 instances (5 store hits, 0 to build)" \
    "auto-generated lockfile matches the original (identical store keys → all hits)"
echo

# --- Summary ------------------------------------------------------------------
echo "${BOLD}Result: ${pass_count} passed, ${fail_count} failed${RESET}"
if [[ "$fail_count" -ne 0 ]]; then
    echo "${RED}INTEGRATION TEST FAILED${RESET}"
    exit 1
fi
echo "${GREEN}INTEGRATION TEST PASSED${RESET}"
