# Integral PDF crop regression

`python3 Scripts/native-render-parity/pdf-crop/run.py` compiles the actual
`NativePDFCropTests` app test source, production capture helper, and unchanged
`ReaderTranslationGeometry` implementation for host Swift Testing.

Two cases compare all decoded RGBA bytes from real native PDF captures:

- A 100×273 aspect-fit image in 390×700 produces a tiny negative Y origin.
  The frozen integral crop is Y0; flooring it incorrectly moves the artwork 1pt.
- Near-integer positive origins and extents round to integers in Float32 before
  truncation, so the requested page must be 100×40 rather than 99×39.

The production conversion follows
[WebPage::drawToPDF](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/WebPage/Cocoa/WebPageCocoa.mm#L1908-L1922)
and
[IntRect(FloatRect)](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/graphics/IntRect.cpp#L38-L42):
Float32 components, bounded Int32 conversion with truncation toward zero.
The app suite is `NativePDFCropTests`; host success does not claim an iOS run.
