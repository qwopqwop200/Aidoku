# Native Source CV integration contract

Stable C ABI: `Vendor/NativeSourceCV/include/AidokuNativeCV.h`, module
`AidokuNativeCV` (Swift `import AidokuNativeCV`). Primitive code stays in
`Vendor/NativeSourceCV`; parent feature algorithms stay in
`Vendor/SourceInference/Sources`. The standalone build script will compile both
into `libAidokuSourceCV.a` and select platform-specific OpenCV/FreeType archives.
No old-graph fallback is supplied. Errors return -1 with `acv_last_error()`;
success returns 0. Dimensions must be positive; caller owns valid input/output
buffers. OpenCV integer enum values pass through unchanged.

- components: labels w*h; stats capacity*5 (left,top,width,height,area),
  centroids capacity*2, count includes background. Insufficient capacity errors.
- morphology: float32 0=uint8/1=float; OpenCV op/shape/border enums.
- box mean: CV_32F normalize=true, BORDER_REPLICATE.
- distance: OpenCV metric enum DIST_C=3, DIST_L1=1, DIST_L2=2; labels optional,
  DIST_LABEL_PIXEL with mask5 when provided. Input nonzero is outside seeds.
- fill external: RETR_EXTERNAL/CHAIN_APPROX_SIMPLE/drawContours FILLED.
- RGB to Lab preserves OpenCV float vs uint8 encoding (float RGB input 0...1).
- HOG parameters explicitly define square block/stride/cell and bins; signed=false,
  win size w*h, no gamma correction, L2Hys 0.2, derivAperture1, default winSigma.
- glyph raw grayscale bitmap is Pillow BASIC-compatible FT2.14.3 normal hinted
  raster, codepoint input, EM256 via pixelSize26_6=16384, bearings/advances exposed.
  Text shaping/layout, threshold64/tight crop and accepted feature arrays belong
  to template algorithms. Missing glyph and inaccessible font fail explicitly.

Core header namespace agreed with parent: `aidoku::source`, `Vec=vector<double>`,
`SourceInput{cv::Mat rgb8RGB,owned8;cv::Rect2d bbox;double prior;string text;
vector<vector<cv::Point2f>> members;...}`. Parent owns exact typed source paint
contract. SourceFeatureMath.hpp and SourceCoreFeatures.cpp/.hpp belong to parent.

Official OpenCV4.11.0 iOS release is a FAT static framework, **not** XCFramework:
arm64 iOS + x86_64 simulator (legacy archs removed). Repackage those official
slices. Build only missing arm64sim plus macOS core,imgproc,objdetect from exact
4.11.0 source, no full OpenCV build. FreeType exact public VER-2-14-3 matches
`/opt/anaconda3/bin/python3.12` Pillow13 runtime.

READY: macOS SDK `python3 Scripts/native-source-cv/build.py --print-link-info`;
`--core-only` skips root high templates, `--primitives-only` skips all algorithms.
Both optional flags are for focused verification. Production default includes
parent Sources and root FontTemplateFeatures.mm, excludes Tests directories.
Public import is now ONE `AidokuNativeCV` module, including C primitive API,
ACVSourceFeatureBridge and AIDExtractAllSourceSignals. Core-only dictionary
aliases match model names masked65/cadence69/colors100/components75.

NativeOpenCVAppearanceImageOperations now conforms to appearance protocol
(including rgbBoxMean/rgbSobelMagnitude); low-level C minAreaRect remains4.11.
Only this appearance adapter normalizes nondegenerate rectangles to the4.13
[-90,0) convention identified by appearance owner as that artifact's contract.
NativeSegmentationOpenCVOperations.swift is owned by segmentation worker; infra
contains no duplicate segmentation adapter.

`NativeSourceFontResolver.resolveMeasurementSpec` rebases public font paths and
converts pinned system CTFont references into actual file paths + TTC faceIndex.
Accepted eight public TTFs (46MB, unchanged SHA256) and OFL notices live in
SourceReferenceFonts.bundle; proprietary system font files are never copied.
Pinned system faces must exist on the OS; resolver explicitly errors if unavailable.

Resources: app PBX Resources phase now explicitly copies opaque `SourceModels`
folder (not a flattened synchronized group) and SourceReferenceFonts.bundle.
Both are excluded from synchronized automatic membership to avoid duplicates.
Existing loader candidates `bundle.resourceURL/SourceModels` resolve registry and
heads subpaths unchanged. Verified59 head SHA256s and8 public font/OFL SHA256s.
Integrated app bundle build/launch remains parent-owned, not claimed here.

Verification commands:
- `python3 Scripts/native-source-cv/verify_compile.py`: sequential focused native
  archive compile/link plus Swift public import/adapters/font resolver typecheck,
  devicearm64/simulatorarm64/hostarm64. Existing fixed private native caches only.
- `VERIFICATION.json` records completed SDK checks and explicit runtime limits.

## Bounded TRAIN cosine neighbors

`acv_cosine_neighbors(queryFloat32,qCount,referenceFloat32,rCount,dim,
excludedInt32,excludedCount,8,outIndicesQx8,outDistancesFloat32Qx8)` is now ready.
All matrices are C-order float32; outputs are caller-owned, qCount*8 elements.
Exactly8 eligible references are required; zero queries is a successful no-op.
Indices refer to original reference rows, with ascending original index for
identical distances. Missing source-group exclusions pass NULL,0; supplied page
exclusions are range-checked, sorted and deduplicated. Invalid data errors return
-1 with acv_last_error, never silently use same-source prototypes.

Normalizes both query/reference rows with float32 squared norms and NumPy's
pairwise sum tree, flooring the denominator at float32(1e-30). Caller applies
version84 query weighting and its first normalization if using that graph.
Bounded OpenCV GEMM tiles compute clip(1-cosine,0,2). Input TRAIN storage remains
borrowed: no full normalized reference bank or QxR matrix. Query batches cap128,
reference tiles cap1024; normalized tile buffers and squares cap262144 floats
each, and distance tile cap128*1024 floats. Dimension range1...262144.
Swift `NativeCosineNeighbors.search` borrows UnsafeBufferPointer<Float> directly
from NativeFrozenTensor.withUnsafeBytes (caller checks tensor f32 dtype/shape).
The wrapper returns only flattened Qx8 indices/distances and copies no bank data.

`test_cosine_neighbors.py <isolated-host-dylib>` compares to the actual Python
optimized_measurements._neighbors. COSINE-VERIFICATION.json records random259x198
query batching, page exclusions, version84 weighting, stable ties/zero vectors,
exactly8 eligible references,41Kx198 bank and invalid-input cases. Neighbor indices
were exact in tested cases; max distance error1.1920929e-7 (tolerance1e-6).

Host test library can be built without touching any shared MAIN cache:
```
mkdir -p build/native-source-cosine-check
xcrun clang++ -std=c++17 -O2 -dynamiclib \
  -IVendor/NativeSourceCV/include -IVendor/NativeSourceCV/freetype/include \
  Vendor/NativeSourceCV/NativeSourceCV.cpp \
  Vendor/NativeSourceCV/opencv2.xcframework/macos-arm64/libopencv2.a \
  Vendor/NativeSourceCV/FreeType.xcframework/macos-arm64/libfreetype.a \
  -lz -framework Accelerate -framework Foundation \
  -o build/native-source-cosine-check/libCosineCheck.dylib
/opt/anaconda3/bin/python3.12 Scripts/native-source-cv/test_cosine_neighbors.py \
  build/native-source-cosine-check/libCosineCheck.dylib
```
Production build.py automatically incorporates the changed primitive object.
The parent alone owns rebuilding its shared archive/MAIN app and graph callers.

## System font identity across platforms

resolveMeasurementSpec now preserves the original `trainingSHA256` and records
`actualNativeFontSHA256`; runtime `SHA256` is the actual OS file hash used by the
bridge. Exact CoreText PostScript-name and FreeType TTC face lookup are retained.
`systemFontIdentity` is `training-file-match` when unchanged, otherwise
`cross-platform-system-font-variant`; a variant never claims training-file bytes.
Public TTF SHA256 validation remains strict and unchanged. Host regression smoke
is CheckFontIdentity.swift, including idempotence and corrupt-public-font refusal.
