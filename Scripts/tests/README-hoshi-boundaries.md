# Native dictionary boundary probes

Run every maintained source, reader and C API boundary probe with:

```sh
python3 Scripts/tests/run-hoshi-boundaries-regression.py
```

The runner uses the current vendored Hoshi C/C++ sources and headers, bundled
libdeflate and utf8proc, and the exact Zstd revision in the app's
`Package.resolved`. A matching, unchanged SwiftPM checkout is reused. If none is
available, only that pinned revision is fetched into the fixed runner cache.
`--zstd-source /path/to/zstd` selects an existing clean checkout of the same pin;
it never accepts a different dependency version or a system/Homebrew library.

Compilation and test execution are sequential. The fixed
`build/hoshi-boundaries-host` cache is locked across each invocation, and object
fingerprints include the native source/header closure, SDK, architecture,
compiler version and flags. Only changed inputs are recompiled. The flags retain
`-O2`, C++23, assertions (`-UNDEBUG`), AddressSanitizer and UndefinedBehaviorSanitizer.
There is no default deadline or filtered/skip mode.

The three existing `.cpp` programs keep their assertions and input loops. Each
must contain an executable `main` and nonzero assertion sites, and each must
actually exit successfully. Assertion-site counts identify source locations,
not dynamic loop iterations or line coverage. Runtime files use a temporary
directory; no user dictionary is read or modified. Results are written to
`build/hoshi-boundaries-host/results.json`, with build and execution times
reported separately. A compiler failure or fewer than three successful
executions is a failure.

The storage stress and ZIP corruption probe has its own maintained runner:
`python3 Scripts/tests/run-hoshi-storage-regression.py`. Import parser/integration
probes are documented in `Vendor/HoshiDicts/Tests/ImportRegression/README.md`.
