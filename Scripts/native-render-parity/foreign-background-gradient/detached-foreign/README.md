# Detached foreign background diagnostic

This is an external/test-ready diagnostic, not a production implementation.
Root owns promotion, capture selectors, fixture resource membership, and all device runs.

- Wrapper: `NativeForeignBackgroundDetachedMetalDiagnosticCapture.swift`, `run()` async.
- Shared helper: the unchanged actual BUILD59 `AidokuTests/Translation/NativeDetachedLayerMetalCapture.swift`.
- Resource: `NativeForeign54References.bin` (JSON, exact original four literal inputs and immutable54 PNG/DOM provenance).
- Output: Documents/NativeForeignBackgroundDetachedMetalDiagnostic, four scenes; full RGBA zero tolerance.
- The wrapper does not create a WKWebView, window, or fresh reference.
- Add the wrapper as test source and the `.bin` as fixture resource only when Root authorizes promotion.

Graph: opaque source page color -> source-derived snapped radius-zero base border -> reverse-order CSS background declaration wrappers. Each wrapper clips the existing production BackgroundPainter destination; its CAGradientLayer has the preserved tile-local bounds and equal Float-promoted sRGB stops. The owner-move scene retains the same declared local positions/sizes and never reconstructs them from old absolute source bounds. Negative-position and overlapping cases retain their original inputs. Unsupported repeating/pattern geometry is reported as a failure, not coerced.

The existing public CPU geometry helper is intentionally called here so a strict failure remains observable if that mapping or the CA destination/tile clip realization differs from actual WK. We do not claim that graph construction is sufficient before device capture. No glyph shaping, source image filtering, or whole-page resizing occurs in this diagnostic.

Source provenance: existing NativeForeignBackgroundGradient geometry follows pinned WebKit BackgroundPainter -> Image::drawTiled -> GradientImage destination clip / image-local fill. Existing NativeTranslationPDFCapture.snappedRect is the previously source-derived device snapping primitive. The new backend choice is only public CAGradientLayer -> CARenderer target, using explicit output sRGB and the shared supplied-queue resource readback. No fixture-specific numeric offsets or tolerance changes.

Separate off-worker feasibility observation: QuartzCore's public CARenderer/CALayer API has no observed MainActor annotation in the iOS26.5 SDK. CATransaction.h documents per-thread explicit transactions and flush for a blocked/no-runloop thread. A nonisolated Swift6 strict-concurrency source probe typechecked without UIKit. This is a source/SDK feasibility observation, not runtime worker-thread equality proof. A wholly private tree could remain on the existing serial worker; do not pass it across actors or infer general shared-layer thread safety.
