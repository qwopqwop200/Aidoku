# Bundled upscalers

In Settings → Reader, enable Upscale Images, open Upscaling Models, tap Get, then select the installed model. The five bundled models install offline. The official online catalog remains available. Installation alone does not change the selected model or enable upscaling. The reader's maximum source image height still applies.

| Model | Scale | Uncompressed package | Intended input |
|---|---:|---:|---|
| SwinUNet V3 Art | 2× | 15,135,037 B | Illustrations; conservative linework |
| IllustrationJaNai V3 Detail FDAT M | 4× | 8,462,269 B | Color illustrations and covers |
| UltraSharp V2 Lite | 4× | 15,231,957 B | Mixed/general artwork; stronger sharpening |
| AnimeSharp V4 | 2× | 32,396,262 B | Anime, manga, color pages |
| MangaJaNai V1 1200p | 4× | 34,108,631 B | Black-and-white manga, original page height around 1200 px |

MangaJaNai is the specific 1200p checkpoint, not automatic selection among all training resolutions. Its `grayscaleOnly` setting leaves pages with channel differences above 8/255 unchanged, including color covers. Other source heights remain permitted but may produce less suitable textures.

## Resources and installation

`Aidoku/Resources/Upscaling/UpscaleModels.json` contains filenames, SHA-256 checksums, Core ML configuration, descriptions, authors, and original source URLs. The five ZIP files total 94,390,928 bytes (about 94.4 MB / 90 MiB). They contain package contents directly: `Manifest.json` and `Data/`, without an enclosing `.mlpackage` directory. Xcode copies the ZIP files as resources, so it does not precompile all five models at app build time.

Get validates the archive checksum, extracts into a hidden staging directory, compiles and validates the model, then installs the package and metadata. Failed installs leave no partial selectable model. The installed original package and compiled Core ML cache use additional storage; the displayed size is the original uncompressed package size, not total runtime memory or compiled-cache size. Removing a model also clears its compiled cache and enabled preference. OS-invalidated compiled caches rebuild from the retained original package.

## Tensor contract

All models use Float32 RGB NCHW input/output in [0, 1]. SwinUNet retains FP32 internal precision. The other four have FP16 internal weights/operations.

- SwinUNet: input 128, shrink 8, scale 2, output 224.
- AnimeSharp: input 256, shrink 32, scale 2, output 384.
- MangaJaNai, IllustrationJaNai, UltraSharp: input 256, shrink 32, scale 4, output 768.

The model itself produces the center crop. Do not crop its output again. The wrapper edge-pads inputs, handles images smaller than one tile, clips the final partial tiles, and writes disjoint output rectangles sequentially. It validates the tensor contract and returns failure on invalid predictions/nonfinite values. The reader retains the original image on failure. Legacy waifu2x models with unspecified output shape are validated against the runtime output shape.

One input tensor is reused per page. The output bitmap is limited to 256 MiB before allocation; this is a safety ceiling, not an iPhone memory guarantee. Model changes are included in the Nuke processing identity together with the maximum source height, preventing stale results after selection changes.

## Attribution

See `Aidoku/Resources/Upscaling/UPSCALER-NOTICES.txt` and the accompanying license texts. AnimeSharp and UltraSharp are Kim2091's CC BY-NC-SA 4.0 models. IllustrationJaNai V3 is the-database's CC BY-NC 4.0 model. MangaJaNai V1 retains the CC BY-NC-SA 4.0 notice from its V1 release. SwinUNet comes from nagadomi/nunif with its MIT repository notice. The notices describe local conversion and cropping modifications. These are not uniformly permissive commercial-use assets.

## Verification (2026-09-16)

- Debug iOS Simulator app build succeeded; all five archives and the catalog were present in the built app.
- `UpscaleModelTests`: 3 passed, 0 failed, iPhone 17 Pro simulator / iOS 26.5. Exercises all five offline installs, actual Core ML predictions on 17×29 images, partial edge tiles (227×117), MangaJaNai color bypass, deletion/availability/selection cleanup, tampered metadata rejection, and Nuke identity changes. No network is used by these tests.
- Actual revised Swift wrapper on macOS M4 Pro: all five models produced full real-manga pages successfully (nine outputs: two per color-capable model and one MangaJaNai black-and-white page). Existing RealESRGAN x2plus and waifu2x photo also produced full pages successfully. Representative AnimeSharp black-and-white and IllustrationJaNai color outputs were visually inspected for coherent layout/color and conspicuous tile failures.
- These are not physical-iPhone latency, thermal, battery, or memory measurements. The simulator emits Core ML backend fallback diagnostics but completed every test.

Run the focused suite with a dedicated simulator and DerivedData directory:

```sh
xcodebuild -project Aidoku.xcodeproj -scheme Aidoku \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UUID>' \
  -derivedDataPath /tmp/Aidoku-Upscalers-DD \
  -skipPackagePluginValidation -parallel-testing-enabled NO \
  -only-testing:AidokuTests/UpscaleModelTests test CODE_SIGNING_ALLOWED=NO
```
