#!/bin/bash
# Builds the overlay pixel kernels (Rust -> wasm32, no_std, no allocator) and embeds them as base64 between the
# `// BEGIN/END aidokuPixelKernelBytes` markers of BrowserSourceTextColor.swift. Needs a Rust toolchain with the
# wasm32-unknown-unknown target (rustup target add wasm32-unknown-unknown).
set -euo pipefail
cd "$(dirname "$0")"
kernel_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidoku-overlay-kernels.XXXXXX")
trap 'rm -rf "$kernel_dir"' EXIT
rustc --target wasm32-unknown-unknown -C opt-level=3 -C panic=abort -C strip=symbols -C debuginfo=0 --crate-type cdylib \
  -C link-arg=-zstack-size=16384 -C link-arg=--initial-memory=131072 kernels.rs -o "$kernel_dir/kernels.wasm"
python3 embed.py "$kernel_dir/kernels.wasm" ../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserSourceTextColor.swift
