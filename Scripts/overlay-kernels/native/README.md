# Native overlay pixel kernels

The app compiles the same `../kernels.rs` source used by the native renderer. The 25 pixel functions keep their C ABI and algorithm order. Native-only panic and exception metadata terminate with `abort`; native `sqrt` uses Apple's system implementation. No WASM runtime is involved in the app's pixel rendering.

Install a Rust toolchain and the Apple target libraries once:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
```

The app's **Build native overlay kernels** phase runs `build.py` before Swift compilation. It creates `libAidokuOverlayKernels.a` in `DERIVED_FILE_DIR`, compiling only when the Rust source, compiler, target, flags, or deployment target changes. Simulator builds can combine arm64 and x86_64 through `lipo`. The app links this archive and imports the checked-in Clang module through `module.modulemap`.

`generate-bindings.py` regenerates `kernels.h` and `NativeTranslationPixelKernels.swift` from the Rust export declarations. Run it after a signature change and update its per-kernel buffer capacity rules. Swift callers use zeroed `NativeKernelBuffer` values; the wrappers validate dimensions, pointer lengths, scalar finiteness, RGB ranges, and indexes before invoking native code. Keep raw C imports confined to this bridge.

A standalone macOS static build is available without Xcode:

```sh
python3 Scripts/overlay-kernels/native/build.py
```

It uses the fixed `build/native-overlay-kernels-host` cache. Swift host tools need `-Xcc -fmodule-map-file=Scripts/overlay-kernels/native/module.modulemap -Lbuild/native-overlay-kernels-host -lAidokuOverlayKernels`. A Rust-only host dynamic library additionally needs `-l System`.

Validate kernel behavior and buffer safety with `NativeTranslationPixelKernelBridgeTests`; the historical WASM comparison harness has been removed.
