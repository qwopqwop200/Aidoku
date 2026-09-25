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

Reuse the default `build/device` DerivedData directory across installations.
Do not clean it or create a dated cache for each installation. An existing cache
can instead be selected with `--derived-data <path>`; keep using that same path.
Keep signing settings and build options consistent to avoid invalidating outputs.
The first build, changed sources, SDK changes, and dependency changes still cost
time. This helper preserves Release whole-module optimization and dSYM output;
editing Swift can still trigger compilation of the entire affected module.

Use separate caches for simulator tests, audits, and builds with different options.
Do not run direct Xcode/xcodebuild builds concurrently against this cache. The
helper rejects overlapping helper builds against the same cache. Parallel jobs
default to 2; override with `--jobs` only when machine load/memory permit it.
Package versions must already be resolved, as in the existing device workflow.
