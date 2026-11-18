#pragma once
#include "FontWeightBands.h"
#include <memory>
#include <vector>
namespace aidoku::source {
struct WordReferencePair {
    std::string family; // Only groups supplied reference intervals, never a feature.
    WeightBandPair faces;
    std::optional<WeightBandPair> frame;
};
using WordReferenceMasks = std::array<cv::Mat,2>; // CV_32F /255, same bounds.
// One bounded operation/session owns all SHA, cmap, raster and rendering caches.
// Reference faces are public face0 TTFs. No font resolver, substitution or globals.
// Returned Mat headers share immutable session cache; clone before any mutation.
class SourceWeightReferenceGrid {
    struct Impl;
    std::unique_ptr<Impl> impl;
public:
    SourceWeightReferenceGrid();
    ~SourceWeightReferenceGrid();
    SourceWeightReferenceGrid(const SourceWeightReferenceGrid &) = delete;
    SourceWeightReferenceGrid &operator=(const SourceWeightReferenceGrid &) = delete;
    // Exact text supplied; normalization/filtering belongs to prepared input.
    // word_masks: per-pair advances, >32 union trim, trimmed vertical cells.
    std::optional<WordReferenceMasks> wordMasks(const WordReferencePair &, const std::u32string &text,
                                               bool vertical=false, double tracking=1.);
    // reference_grid: shared frame advances/baseline, >0 FRAME union trim.
    std::optional<WordReferenceMasks> masks(const WordReferencePair &, const std::u32string &text,
                                           bool vertical=false, double tracking=1.);
    // Explicit axis weight, otherwise actual OS/2 usWeightClass. SHA validated.
    double nominalWeight(const WeightBandFont &);
};
// Same word_pairs.transform, including Python rounding, pad and rigid rotation.
WordReferenceMasks transformSourceWeightWord(const WordReferenceMasks &, double scale,
                                             double cross, double angle, bool vertical);
}
