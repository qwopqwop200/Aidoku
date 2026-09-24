#!/bin/bash
# Pull Documents/EquivalenceRuns/<label> from the test iPhone.
# Usage: pull.sh <label> [destDir]   (destDir defaults to $EQUIV_DIR or ./equiv-runs)
# Result: <destDir>/<label>/{results.json, translations.json, *.ocr.json, *.lines.json, *.layout.json, *.render.png, ...}
set -euo pipefail
label="${1:?usage: pull.sh <label> [destDir]}"
dest="${2:-${EQUIV_DIR:-./equiv-runs}}"
device="${EQUIV_DEVICE:-A6DD4676-9E0D-5EC2-BD63-2428CCF5D536}"
bundle="${EQUIV_BUNDLE:-dev.junjae.Aidoku}"
mkdir -p "$dest"
rm -rf "${dest:?}/$label"
xcrun devicectl device copy from --device "$device" \
  --domain-type appDataContainer --domain-identifier "$bundle" \
  --source "Documents/EquivalenceRuns/$label" --destination "$dest/$label"
# Some devicectl versions nest the source folder name inside the destination.
if [ -d "$dest/$label/$label" ] && [ ! -f "$dest/$label/results.json" ]; then
  mv "$dest/$label/$label"/* "$dest/$label/" && rmdir "$dest/$label/$label"
fi
ls -1 "$dest/$label"
