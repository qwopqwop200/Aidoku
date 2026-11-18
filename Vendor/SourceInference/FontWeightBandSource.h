#pragma once
#include "FontTemplateFeatures.h"
#include "FontWeightBands.h"

namespace aidoku::source {
// Adapter for already parsed same-crop source inputs and already computed fill
// alpha. The caller supplies final em, SAME-CALL angle131 and exactly four
// accepted face0 public-TTF pairs (path/SHA256/optional OpenType weight).
// Baseline anchor resolves input.fonts[0] through its exact opaque key in
// fontFiles/fontFaceIndices/fontWeights; no resolver or alternate font is used.
// Uses real EM128 native_pairs rasters (including same-face .notdef), and
// cmap-supported EM256 >=64 anchors. Explicit fractional weights follow Pillow13
// integer-coordinate conversion after axis/range validation. Existing native
// design-coordinate APIs are unchanged. All resource caches are same-call only.
// Returns poses192/bands112; throws std::exception on invalid resources/input.
// Does not extract alpha/angle, infer a model, or change old strict glyph APIs.
WeightBandResult measureSourceWeightBands(const FontTemplateInputs &input,
    const cv::Mat &sourceFillAlpha, double finalSourceEm, double sameCallAngle131,
    const std::array<WeightBandPair,4> &pairs);
}
