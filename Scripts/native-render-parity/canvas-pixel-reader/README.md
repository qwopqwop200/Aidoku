# Actual Canvas / native pixel-reader verification

Run on Apple Silicon macOS:

```sh
python3 Scripts/native-render-parity/canvas-pixel-reader/run.py
```

The host executable creates an offscreen `WKWebView` with a nonpersistent data store. It generates every source locally as a CGImage, encodes PNG with ImageIO, decodes the same PNG independently in CoreGraphics and WebKit, and executes the original Canvas `drawImage`/`getImageData` sampling call. It does not use a JavaScript pixel mock or external image/network inputs. The archived Canvas call source is checked against its frozen SHA-256 manifest.

The runner extracts the current production `NativeSourcePixelReader` and `NativeSpatialSourceCrop.edgePixels` methods verbatim into host compilation units. Only the outer app types are omitted; neither image algorithm is replaced. Compilation uses Swift 6 and strict concurrency. The production reader cache is also checked against its uncached draw output.

The 46 cases compare every RGBA byte without tolerance:

- Asymmetric colored corners and spatial gradients detect row/axis/orientation mistakes.
- Text-like strokes and discontinuous channel patterns detect interpolation/boundary mistakes.
- Opaque pixels, varying alpha including 0/1/31/64/127/200/254/255, and constant translucent pixels.
- Whole images, exact integer crops, cached crops, fractional coordinates, equal-density fractional crops, downsampling, upsampling and differing axis densities.
- Negative source origins and source rectangles extending past the right/bottom image edges.
- The production spatial edge helper's 200×300 source, clamped source rectangle `[0,0,64,174]`, 78×177 destination canvas and rounded destination `[21,21,57,156]`, for opaque and varying-alpha sources.

This verification identified and corrected the native reader's RGBA bitmap interpolation path, texture sampling beyond the source crop, unpremultiplication half-value rounding, and the requested texture extent at clipped image edges. The BGRA CoreGraphics bitmap path now matches the live Canvas oracle for all 46 cases. The requested enclosing crop extent remains the draw transform after CGImage clips backing pixels at image boundaries.

Artifacts under `build/native-render-parity/canvas-pixel-reader/` include complete oracle/native raster arrays, exact-case status, changed-pixel/channel counts, maximum and mean differences, source/raster digests, WebKit user agent, backing density and timing. The runner exits unsuccessfully if any byte differs. These results cover source extraction/resampling; final page text layout and glyph rendering are verified separately by the app rendering suites.
