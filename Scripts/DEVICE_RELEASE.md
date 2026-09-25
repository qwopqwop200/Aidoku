# Repeated device Release builds

Run from the repository root:

```sh
python3 Scripts/build_device_release.py \
  --device <connected-device-UDID> \
  --team <development-team-ID> \
  --app-id-prefix <existing-installation-prefix>
```

The helper builds only; installation and device-data backup/verification remain
separate steps. It prints the app path, elapsed time, and Xcode task timing.
Use `--dry-run` to inspect the command without building.

Reuse the default `build/device-fast` DerivedData directory across installations.
Do not clean it or create a dated cache for each installation. An existing cache
can instead be selected with `--derived-data <path>`; keep using that same path.
Keep signing settings and build options consistent to avoid invalidating outputs.
The first build, changed sources, SDK changes, and dependency changes still cost
time. The default uses incremental Swift compilation (`singlefile`) with Release `-O`
and dSYM output. Changed files and their affected dependents may be rebuilt.
The first build after switching modes needs to populate the new cache.

Only when whole-module optimization is specifically needed (performance validation,
whole-module-specific diagnostics, or final distribution optimization), pass
`--full-optimization`. That mode uses a separate `build/device-wmo` cache by default.
Whole-module and incremental builds can differ in runtime performance; use the
appropriate mode when reporting performance. Routine Release installation uses
these fast defaults and installs the app path printed by the helper.

Use separate caches for simulator tests, audits, and builds with different options.
Do not run direct Xcode/xcodebuild builds concurrently against this cache. The
helper rejects overlapping helper builds against the same cache. Parallel jobs
default to 2; override with `--jobs` only when machine load/memory permit it.
Package versions must already be resolved, as in the existing device workflow.
