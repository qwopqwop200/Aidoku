# Korean balloon fitting regression checks

The overlay may reduce Korean text by at most 15% (floor 7.5 CSS px) and
reflow it inside a reconstructed balloon. Font and ink cohorts are retained;
this is a bounded per-caption fit, not a page-wide font-size replacement.

A fit requires all of the following:

- Certified erasure of the original core and nearby ruby/lettering.
- Readable reconstructed pixels under the replacement text (contrast >= 4.5).
- No competing opaque backing or neighboring source dependent on this plate.
- Preserved visible text center, measured on the live DOM, within 1.5 CSS px.
- No increase in isolated Korean word fragments or punctuation-only lines.

The erasure image is independent of the readability plate. Trimming the plate
must not change restoration pixels or expose another caption's original text.
When certification fails, retain the existing backing and typography.

Run the helper regressions with:

```sh
node --test Scripts/tests/typography-clusters-regression.cjs
```

`fixtures/panel-erasure-connected-ink.json` contains a real cropped source
whose bold final letter joins surrounding ink. A nonzero erasure count alone
must not certify this crop or allow its old backing to disappear.

For UIKit/WKWebView replay, use `ReaderColumnLayoutTests.capturedPages` in a
Release test build. Resolve the simulator's current app data container and put
the actual source PNGs, `fixtures.json`, a unique `label.txt`, and
`compare-certified-erasure.txt` under `Documents/ColumnLayout`. The fixture
schema is an array of `{name, regions: [{bounds, source, translation,
orientation}]}` with normalized `[x, y, width, height]` bounds. Each page is
rendered in both source-color and white modes, with before/after PNGs and DOM
metadata under the label directory. The opt-in switch disables only the new
certified-erasure compaction and balloon fitting in the before render.

Check the actual source/before/after crops as well as font floors, live center
movement, Korean line breaks, erasure checksums, opaque coverage, and contrast.
Fixed translations isolate rendering; silver annotations are not human balloon
boundaries and this replay does not validate OCR or provider output.
