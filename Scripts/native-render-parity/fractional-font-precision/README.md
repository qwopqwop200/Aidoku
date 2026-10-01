# Fractional font size transport

Run `python3 Scripts/native-render-parity/fractional-font-precision/run.py` on the host. No app, simulator or Xcode work is performed. Actual BUILD40 inputs remain untouched.

Eight independent fractional sizes (including both actual real1 values) and Korean/Latin text produce 16 actual macOS WK controls. Requested Double text versus explicit `Math.fround` text gives identical WK Canvas widths in all 16. Actual PDF text matrices match CoreText fonts created with `CGFloat(Float(size))` in 16/16 controls; original Double CTFont creation matches 14/16. The difference is visible at 8.162790697674419: WK/Float32 PDF 8.16279 versus Double PDF 8.162791.

Primary pinned WebKit source stores `FontDescription::computedSize` as `float` and sends float size to CoreText in `FontPlatformDataCoreText::createCTFont`:

- https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/FontDescription.h
- https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/coretext/FontPlatformDataCoreText.cpp
- https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/cocoa/FontCacheCoreText.cpp

This does **not** infer the size from six-digit CSSOM strings: inline `8.162791px` roundtrip chooses the adjacent Float32, whereas original/computed font Float32 is 8.162790298461914. Source numeric transport and actual PDF control are independent evidence.

BUILD40 real1 native/WK embedded AppleSDGothicNeo-Bold CFF programs are identical (5681 bytes, SHA256 `7aa8497f76b30a638da09023a37da4a0712ec7519de7178ee2aed7160aada548`). Their row rectangles differ by less than 0.000008 points. All glyph-position/raster output is **not** proved by this precision control; glyph advance accumulation and other text state may still differ. The source-background PNG residual is independently larger and is not attributed to font precision here. Serif font-face size-adjust multiplication order is outside this control; no blanket production patch is made.

Artifacts: `build/native-render-parity/fractional-font-precision/report.json`, actual PDFs, captured metrics and source hashes.
