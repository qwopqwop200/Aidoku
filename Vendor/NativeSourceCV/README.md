# Native source CV dependencies

This directory provides real OpenCV 4.11.0 and FreeType 2.14.3 to macOS MAIN and
native iOS feature extraction. Read `../../Scripts/native-source-cv/CONTRACT.md`
for public buffer/packet APIs. Swift imports `AidokuNativeCV`; there is no
unavailable-platform substitute or old-feature fallback.

The bootstrap installs `opencv2.xcframework` and `FreeType.xcframework` with static archives for:

- iOS arm64 (minimum15): official OpenCV release binary, thinned without changes.
- iOS simulator x86_64: official OpenCV release binary, thinned without changes.
- iOS simulator arm64 (minimum15): exact4.11.0 source, missing from official binary.
- macOS arm64 (minimum13): exact4.11.0 source.

OpenCV's official release is `opencv-4.11.0-ios-framework.zip`, a FAT framework,
not an XCFramework and lacking arm64 simulator. Only missing platforms are built
from source. `core,imgproc,objdetect` also require `calib3d,features2d,flann`;
DNN, GUI, video, Python, Java, examples and tests are excluded. Archive headers
are shared by symlinks within this vendor directory. The XCFramework manifests
identify each architecture and platform separately; never use the device arm64
archive for simulator arm64.

FreeType public tag `VER-2-14-3` matches Pillow13's FT2.14.3 in the accepted Python
runtime. Build disables optional compression/image/shaping dependencies; the
accepted uncompressed TTF/TTC normal grayscale glyph path uses the same hinted
raster. Glyph bounds include the pen advance as Pillow getmask does. Unsupported
cmap characters can be detected explicitly. High-level shaping/feature arithmetic
is owned by SourceInference, not these primitives.

From a fresh checkout, use Xcode command-line tools, Python 3 and CMake to
provision the platforms you build. For the Apple Silicon host and a
physical iPhone, run the following from the repository root:

```sh
python3 Scripts/native-source-cv/bootstrap.py --platform macos-arm64 --platform ios-arm64
```

Use `--platform ios-arm64-simulator` for an Apple Silicon simulator, or omit
`--platform` to install every supported slice. The three downloads are cached
under `build/native-source-cv-downloads/` and verified against pinned SHA-256
digests on every bootstrap. Ordinary app and host builds use the installed
archives and do not need network access to build the native bridge. Archive
digests are recorded in `PROVENANCE.json`. OpenCV4.11.0 tag
`1d3b34ddd080bbf3e3d3cec58e11038fca21dcfe`; FreeType2.14.3 tag
`c740f0fda4274d6ffd2e5b64a25b06ef69803a07`.

`python3 Scripts/native-source-cv/build.py --print-link-info` builds only changed
bridge/feature objects and prints the standalone host include/link contract.
Xcode invokes the same script using PLATFORM_NAME/ARCHS/DERIVED_FILE_DIR.
It never downloads, cleans, deletes DerivedData, or invokes a full app build.
The archive/cache fingerprint includes source/header bytes, SDK and toolchain.
Production includes the parent SourceInference sources; test mains are excluded.

Licenses: OpenCV uses Apache2.0, with third-party notices in licenses/. FreeType
is distributed under the FreeType License (FTL), copyright The FreeType Project
(www.freetype.org); its upstream alternative GPLv2 notice is also preserved.
The application carries these notices in SourceReferenceFonts.bundle/licenses/
NativeSourceCV. System fonts remain OS resources and are not redistributed.
Eight public accepted reference TTFs and their SIL OFL notices are packaged by
Scripts/native-source-cv/package_fonts.py with unchanged SHA256 identities.

The C ABI also includes bounded float32 TRAIN cosine8 search. It borrows the
mapped bank and uses <=128 query rows plus <=1024 reference rows per GEMM tile;
there is no whole QxR or normalized-bank allocation. See CONTRACT.md and
COSINE-VERIFICATION.json for the Swift borrowed-buffer wrapper and Python parity.
