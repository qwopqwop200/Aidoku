# Repeated device Release builds

```sh
python3 Scripts/build_device_release.py \
  --device <connected-device-UDID> \
  --team <development-team-ID> \
  --app-id-prefix <existing-installation-prefix>
```

The helper only builds (incremental `singlefile` Swift with Release `-O` and dSYMs) and
prints the app path, elapsed time and Xcode task timing; install that app separately.
`--dry-run` prints the command. Reuse the default `build/device-fast` cache (or one fixed
`--derived-data <path>`) with consistent signing and options; never clean it or run other
builds against it concurrently. `--full-optimization` (whole-module, separate
`build/device-wmo` cache) is only for performance validation, whole-module diagnostics or
final distribution. `--jobs` defaults to 2. Packages must already be resolved.
