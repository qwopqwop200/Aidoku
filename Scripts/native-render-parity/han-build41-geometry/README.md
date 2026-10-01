# Actual iOS vertical origin evidence and staged source equations

No app/test/project inputs are modified. `FontAssetProbe.swift` reads the exact
recorded iOS font-file URL with public CTFontManager/CTFont APIs on the host.
This identifies the asset, not the actual final iOS shaped font instance.

The immutable BUILD41 Han PDF/font/RGBA proof is independently reproducible in
`../han-ios-position-proof/run.py`. All three embedded native/WK font resources
are identical. At tracking -1/0 native minus WK glyph origin is(-.5,0)pt in
page-top-left coordinates. At +1 it is(-.5,+.5)pt. Snapshot raster scale is2;
screen DPR is3. The export author demonstrated exact original RGBA equality
under diagnostic1pixel translations, without saving replacement outputs.

## Source equations; no fixed font or fixture correction

`NativeVerticalGlyphOrigins.staged.swift` contains two pure, independently
usable source-policy functions, typechecked under Swift6 but NOT promoted:

1. `centeredInlineShift` implements the centered branch of
   `InlineFormattingUtils::horizontalAlignmentOffset`:
   `target = flexStart + max(0,lineWidth-adjustedContentRight)/2`.
   Hanging trailing whitespace is conditionally capped to the line width or
   removed, exactly as the source branch specifies. The output is target minus
   the actual CTFrame line-start position. In particular, the caller must use
   the full CSS run extent, including terminal tracking. Passing tracking/2 as
   a general correction would confuse glyph advance, cursor advance, trailing
   whitespace and the line box. Existing 147/21pt line extents do not prove
   CTFrame centered its first glyph using those same extents.
2. `positions` directly implements
   `FontCascadeCoreText::fillVectorWithVerticalGlyphPositions`:
   `delta = Float((ascent+descent)/2-ascent)`;
   `pen = FloatPoint(input.x,input.y+delta)`;
   `glyph[i] = inverse(textMatrix) * (pen + uprightMatrix*verticalTranslation[i])`;
   `pen += userAdvance[i]`.
   The non-oblique upright matrix is Y-flip then left rotation.

The preceding TextBoxPainter origin is
`(paintRect.x,paintRect.y+integerAlphabeticAscent)`;
vertical text snaps its **logical X** to device pixels **after installing a
context rotation**. A final physical-axis snap is not an equivalent operation.
The physical baseline additionally depends on writing-mode box flipping and
rotation about the paint rectangle. RangeX therefore must stay independent of
this glyph-origin pipeline.

## Why the cross-axis correction remains staged

Current native vertical layout places the ideographic CT baseline at pitch/2.
Actual Range has odd29pt width: its center is62.5 but the CT glyph baseline is62.
This is an observed causal discrepancy, not justification for a blanket+.5.
Pinned FontMetrics stores integer ascent/descent using `lroundf`, while the
native Range adapter uses ceilings. The separate named iOS asset on the host
has ascent21.199951/descent6.799927 but optical advance20.38; actual final iOS
run advances20. Its metric values must not be substituted for the final run.
BUILD42 diagnostics now expose actual run ascent/descent/leading, translations,
positions and line origins. Those are required to map the source paint rectangle
and algebra above to a production baseline without changing already-correct
RangeX.

Primary source checkpoint `dd5fe1011df7e3438ac4889356abcab7681df46d`:

- [FontMetrics](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/FontMetrics.h)
- [TextBoxPainter](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/rendering/TextBoxPainter.cpp)
- [FontCascadeCoreText](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/coretext/FontCascadeCoreText.cpp)
- [InlineFormattingUtils](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/layout/formattingContexts/inline/InlineFormattingUtils.cpp)

These are source-model references. The exact iOS26.5 WebKit build commit was
not established by these public sources; actual iOS controls remain necessary.

## BUILD42 oriented metrics and new independent countercontrols

Actual BUILD42 final CTFrame runs have ascent10/descent10 at20pt with vertical
matrix `[0,1,-1,0,0,0]` and translations `(-10,-17.2)`. These are oriented run
metrics, not the primary alphabetic metrics entering WebKit FontMetrics.

`CenterProbe.swift` has12 public CT-only controls: font19/20, tracking−1/0/+1,
height154/155. Core Text correctly centers *half-integer* coordinates with zero
tracking. Positive spacing still yields+.5 error even when the source center is
integer (font19/H154: source7/67, CT7.5/67.5). This rules out generic integer
centering as the explanation. The helper uses full CSS extent, not a hardcoded
half-spacing rule, so trailing content and line-break scopes remain explicit.

`cross-controls.js` plus the existing WK host Capture.swift captures4 new actual
WK controls atfont19/20/20.5/21. `PrimaryMetricsProbe.swift` queries the actual
original host primary CTFont. Results are in `cross-controls-report.json`:
source ideographic cross positions49.840012,50.200012,50.380013,50.560013. They
all match the source equation within1e-5PDF float serialization:

`B = Float(sourceTextBoxRight - integerAlphabeticAscent - ascentDelta)`.

Here `ascentDelta = Float((primaryAscent+primaryDescent)/2-primaryAscent)`.
Integer alphabetic ascent follows primary FontMetrics `lroundf`. This is a
metric-dependent equation; a midpoint or odd-height+.5 rule fails these controls.
The source text box must be independently reconstructed. In particular the
native Range adapter's ceiling bounds are not necessarily the source paint box
(mac20 native ceil width29, actualWK int metric box28).

These controls prove the general source equation but do not fill the missing
actual iOS pre-frame primary metrics. Applying named-asset21.2/6.8 to actual
RangeRight77 predicts62.2 withceilA22 or63.2 withlroundA21; neither matches62.5.
The named asset is therefore not an admissible replacement for captured primary
metrics/source paint-box placement. Type has published `row.primaryFont` for the
next actual iOS diagnostic capture. Cross-paint promotion remains gated on that
input; no app cross shift is authored by this proof.


## BUILD44 resolves the platform metric policy

The exact pinned `FontCoreText.cpp` is saved as
`build/native-render-parity/han-build41-geometry/primary-source/FontCoreText-pinned.cpp`,
SHA256 `3b2714755af7c98bd666d8b89f21dcd770e310d0d27c27210c7b641e6fbcea4d`.
The previously downloaded `vertical-han-font/primary-source/FontCoreText.cpp`
was a **different, newer source version** (SHA256 `33f8d89a…`) with raw metrics.
Its removed iOS normalization must not be used to interpret the pinned pipeline.

Pinned lines174–180 explicitly normalize metrics under `PLATFORM(IOS_FAMILY)`:

```cpp
CGFloat adjustment = shouldUseAdjustment(getCTFont()) ? ceil((ascent + descent) * kLineHeightAdjustment) : 0;
lineGap = ceilf(lineGap);
float lineSpacing = std::ceil(ascent) + adjustment + std::ceil(descent) + lineGap;
ascent = ceilf(ascent + adjustment);
descent = ceilf(descent);
```

`shouldUseAdjustment` admits only Times, Helvetica, and `.Helvetica NeueUI`
(case insensitive). Its constant is float0.15, multiplied with raw CGFloat
metrics before the `ceil` result. The subsequent `ceilf` narrows its input to
Float before ceiling. OpenType MATH adjustments, when present, occur before this
block; the staged helper accepts that post-MATH input, not an arbitrary run font.

Actual BUILD43 primary PingFang metrics21.2/6.8 therefore become source22/7.
Actual BUILD44 detached Canvas independently reports fontBoundingBox22/7 and
emHeight22/7. Pinned Canvas lines2995–3007 report integer metrics for the former
and floating FontMetrics for the latter. Current WebKit main computes emHeight
differently; that newer implementation is not interchangeable with this pinned
contract. The shipped WebKit source revision is still not identified, but this
older platform policy predicts the measured actual iOS values.

The fixed-pitch root-cell cross baseline follows:

```
intH = intA + intD
intIdeographicA = intH - intH / 2
layoutA = floor(intIdeographicA + (floor(pitch) - intH) / 2)
sourceTextRight = cellRight - layoutA + intIdeographicA
paintBaseline = sourceTextRight - intA - ((floatA + floatD) / 2 - floatA)
```

With cellRight74, pitch24 and normalized22/7 this yields62.5, matching actual
PDF glyph placement. It leaves CSS Range geometry unchanged. The existing
Japanese10.5 control has source height12 and pitch10, yielding the same baseline
as its current exact native paint. Odd-pitch cells are handled by the source
half-leading floor; the helper contains no global half-pixel translation.

`metric-policy-proof.py` compiles the **literal extracted pinned normalization
block** as C++ and compares staged Swift on108 cases (six raw metric triples,
six family choices, three odd/even/fractional pitches). All108 outputs are
identical, including exception adjustment, Float32 ceilings, spacing, and cross
cell calculation. The report records the source hash and extracted block at
`build/native-render-parity/han-build41-geometry/metric-policy/report.json`.
This verifies policy translation, not a new iOS paint run. Typography owns the
actual caller/selected-font adaptation, and Export owns guarded fill-only direct
glyph drawing. Strokes and unsupported mixed run orientations retain their
existing path; Range and font resource bytes remain independent.
