# Zig-Based Binary Package Caching Build System

**WARNING: This whole repo is vibe-coded slop!**

This is a toy implementation of a straightforward idea: What if Zig was Nix? (or Conan?)

The point is to enable large (O(1M) LOC) multi-package systems to leverage the zig build system to
replace CMake and Python for the build system & build scripting, while allowing prebuilt binary
package artifacts to be used in place of source builds.

(When your entire codebase takes 3-4 hours to build from source on a beefy laptop, you learn to love
binary package caching).

The basic approach is to provide manifest files, lock files, and a `build.zig` shim to enable one
package to directly use either the source-built outputs or the prebuilt binaries from an upstream
package. All this must be done while allowing the source of the upstream package to be modified in
place, then the system to automatically pick up those changes and rebuild the upstream package for
use by downstream packages.

Conan workflows were clunky, required manual package exports into the cache to propagate
cross-package changes, did not provide a "nice" experience for packaging non-C++ code, and had a lot
of issues related to version resolution and consistency. It also does nothing for compiler caching
directly, and is inflexible for custom cache-hit checks.

Nix works as well, but is more obtuse than Conan, and is yet another tool on top of other build
systems, requiring a similar wrapper tool that `zpkg` tries to offer for `build.zig`. The store is
also not human-friendly to inspect, and will fill up a 1TB hard disk in just a few days of basic
development (seriously, my cache is sitting at 734 GB right now and I nuked it 2 days ago - and
these aren't even Debug builds).
