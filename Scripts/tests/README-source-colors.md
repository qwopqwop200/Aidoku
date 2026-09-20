# Source color regressions

Run from the repository root with Node.js 18 or newer (no npm dependencies):

```sh
node Scripts/tests/source-color-regression.cjs
node Scripts/tests/source-color-sampler-regression.cjs
node Scripts/tests/source-color-readability-regression.cjs
```

The runners extract the actual JavaScript from `BrowserSourceTextColor.swift`.
They do not maintain a separate implementation of the estimator. The pull
request workflow runs them when the source or runners change.

The estimator suite checks explicit RGBA fixtures: glyph colors, antialiasing,
border/art contamination, faint lettering, noise rejection, panel-side
agreement, gradients, enclosed ink diluted by white antialias fringes, and
bright-mode bias inside translucent panels. Some controls reuse the deterministic pixels or
palette expectations in `ReaderSourceTextColorTests` and
`ReaderOCRPreviewColorTests`.
Captured antialiased outline fixtures also guard against returning the stroke
as the fill. Their compressed RGBA bytes decode with Node's built-in zlib;
no font or canvas dependency is needed to replay them.

The sampler suite uses deterministic area averaging to exercise actual source
cropping, long horizontal and vertical lines, outlined interiors, independent
detail samples, page budgets, cache isolation, and read failures. Focused budget
and geometry tests stub the color helpers; color assertions run the production
helpers. A captured translucent balloon checks panel-informed black/white role
assignment at three scales in both orientations, with genuine white-fill
controls. The same fixture exercises production inpainting: dense Kanji
ownership, removal of every dark source stroke, source immutability, and smaller
masks based on observed halo thickness. The area filter is not a replica of
WebKit's image resampler.

The readability suite also executes the production initial style block and
final caption pass in `BrowserOverlayView.swift`, using a minimal DOM with
fixed geometry. It checks exact observed chromatic and neutral RGB when source preservation is enabled,
contrast adjustment for manual/default fallback ink, flattened colored outlines, zero display strokes and shadows, opaque source
color boxes, and settings changes. Its DOM does not implement WebKit layout or
rasterization. Caption width and word-flow regressions run in iOS WKWebView in
`ReaderAdaptiveRenderingTests`, including neighboring text, image edges, manual
font sizing, and explicit line breaks. Text reflow is limited to the existing
box interior. Before/after assertions require every panel position and size to
remain identical; it must never enlarge or regenerate a panel after text reflow.

To compare estimator behavior against an earlier revision:

```sh
git show REV:Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourceTextColor.swift \
  | node Scripts/tests/source-color-regression.cjs --source /dev/stdin
```

`--baseline` selects existing-behavior controls. `--filter TEXT` selects case
names. All color expectations remain the same when replaying an older source.

These checks do not replace the iOS tests. On a Mac, also run the
`ReaderSourceTextColorTests`, `ReaderOCRPreviewColorTests`,
`ReaderSourcePanelRestorationTests`, `ReaderSourceInkRestorationTests`,
`ReaderAdaptiveRenderingTests`, and `ReaderTranslationDiskCacheTests` suites
in the Aidoku scheme. They cover UIKit/WKWebView rendering, actual font
rasterization, overlay settings, and restoration. Real-page replay tests that
require `Documents/MangaQuality` fixtures need those inputs on the simulator.
