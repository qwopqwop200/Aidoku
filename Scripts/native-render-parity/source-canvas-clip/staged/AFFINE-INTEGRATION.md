# Bounded live affine canvas contract

This candidate is external staging, not a production or complete-parity claim.
`NativeCanvasTextureResampler+AffineCandidate.swift` replaces the module only after
root authorizes promotion. PDF and saved-mask paths remain independent.

```swift
let geometry = try NativeCanvasTextureResampler.affineCanvasGeometry(
    domRect: patch.rect, userToPixelTransform: userToTopLeftDevice)
let crop = geometry.samplingCrop(viewportPixelSize: bitmapPixels)
let image = try NativeCanvasTextureResampler.affineCanvasImage(
    image: patch.image, domRect: patch.rect,
    userToPixelTransform: userToTopLeftDevice,
    viewportPixelSize: bitmapPixels, cropPixels: crop,
    backgroundRGBA: canonicalAttestedCropOrNil, session: renderSession)
```

`domRect` is the retained **DOM used box**, before parent/context transform, not
its transformed bounding box. The helper follows the literal local
`HTMLCanvasElement::paint` snapped integer rectangle, then pinned
`cgRoundToDevicePixelsNonIdentity` column-length rounding; translation does not
enter that local rounding. It then paints two triangles through the live parent
transform. Each basis column and translation is supplied in device pixels.

Derive the top-left-device basis from three `CGContext.convertToDeviceSpace`
point conversions: zero, `(1,0)`, `(0,1)`. UIKit's raw bitmap CTM has a base Y flip
which those point conversions already strip. Do not pass the raw CTM or apply an
extra device-Y reflection. `viewportPixelSize` is the actual full bitmap extent.
`pixelQuad` exposes the four Float-projected corners. `samplingCrop` returns a
conservative integer window, including a one-pixel guard, bounded by that bitmap.
It is **not** proof of rectangular clipping, absence of foreign paint, backing
identity, or permission to overwrite destination bytes.

The output CGImage is encoded-sRGB **premultiplied RGBA8, top row first**, its
size exactly `cropPixels.size`. Place its origin at that device crop origin, with
one image pixel per device pixel and interpolation disabled. Preserve the real
current clip; do not apply the parent transform again. Root owns the exact
inverse-basis consumer integration. Whole-canvas snapshot reduction remains a
separate operation after painting at actual screen scale.

## Actual source opacity preflight

```swift
let opaque = try NativeCanvasTextureResampler.isOpaqueSource(
    image: patch.image, session: renderSession)
```

This Bool comes from scanning **actual normalized sRGB PMA8 alpha bytes**, not
CGImage alpha-info or file format. It checks cancellation before/after decode and
per scan row. Opaque first-use normalization uploads and caches its texture;
subsequent affine filtering reuses that very Session entry. A translucent
first-use result returns before source texture upload and caches only bounded
image identity/opacity metadata in the same aggregate-12MP Session entries. No
separate normalized-byte cache or extra image cache is retained. An explicit
later translucent-filtering request can populate that entry's texture without
double-counting pixels. Closed sessions reject even cached opacity access.
Cancellation throws; it must never silently admit the raw-source path.

## Backing and blending

- `backgroundRGBA == nil`: return filtered PMA8 source with transparent texels
  outside the quad. This permits the opaque-source transform controls without
  claiming a new `NativeCanvasBacking` capability. A caller must have actual
  opaque-source/opacity-1 evidence for the known exact raw-source route. Merely
  seeing a PNG or a premultiplied alpha-info enum does not prove all texels opaque.
- Nonnil: bytes must be a fresh, canonical encoded-sRGB PMA8 destination crop with
  exactly `crop.width * crop.height * 4` bytes. Float filtering and source-over
  happen once; caller must copy, not blend a second time. Existing uniform fresh
  backing/clip attestation does **not** become valid for affine merely because a
  bbox can be calculated.
- Translucent affine without genuine device-crop backing capability, partial
  layer opacity, fractional/complex-AA clips, unsupported formats and unknown
  source opacity must retain qualified CG fallback. No bbox-based widening of
  trust is authorized.
- Minification is still unclosed by actual alpha captures. A caller should retain
  the current minification restriction unless a separate source-backed proof
  closes it; the pure helper accepting a transform is not a parity assertion.
- `CancellationError` aborts paint; never restart with CG fallback. Typed ordinary
  `Failure` may take the established qualified fallback. Result publication
  happens only after every tile has completed and cancellation is rechecked.

## Bounds and resources

Full device plane may be at most 16384 per axis; only the visible integer crop
(up to 12MP) is allocated. Source is separately capped at 12MP / 16384 per axis.
Those existing caps are not silently increased. Sources use the same render-owned
Session (aggregate cached base textures <=12MP), shared locked pipelines/queue,
and `defer session.close()` lifecycle. No new result or whole-frame cache exists.

Global 256x256 grid anchoring prevents a caller's crop origin from changing
raster interpolation. Scratch is one 1MiB RGBA32Float render texture, one 256KiB
RGBA8 output texture, and bounded 256KiB CPU upload/readback tiles; final crop data
is <=48MB. Source upload can transiently hold CPU bitmap + base texture as in the
existing API. It processes only cells intersecting the crop; UVs and GPU viewport
remain in the full device plane. Nil-backing processing has no destination read.

## Evidence and limitations

`affine-module52-proof/report.json` replays immutable actual iOS52 canonical
source bytes, DOM boxes and literal matrices using this compiled staged module.
Identity/nonuniform/fractional-origin at both 320/160 captures are 6/6 zero-diff.
Rotation remains **FAIL**: full 8 pixels, half 3 pixels, max channel delta 1.
Full-vs-crop byte equality and PMA assertions are explicit in that driver.

`affine-module-tests/report.json` runs the staged module against all six existing
production primitive tests plus seven new focused test declarations (three
parameter cases in one): 13 declarations / 15 cases. Coverage includes raw vs
one-pass blending, fractional-alpha full/crop across tile boundaries, geometry
producer/negative transform controls, invalid-before-source, closed session,
12MP crop bound, and cancellation. This is optimized strict Swift6 **host**
evidence; actual iOS consumer integration remains pending.

Rejected, unmodified-reference controls are retained: CPU-projected vertices,
opposite diagonal, half fragment output, normalized-to-pixel sampler, and pixel
varyings. None resolves rotation while retaining all other captured results.
The eight residual full-resolution pixels lie inside the quad, not on its outer
edges; red-only deltas are not justification for fitted color compensation.
