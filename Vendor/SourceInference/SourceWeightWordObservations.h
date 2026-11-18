#pragma once
#include "SourceWeightInk.h"
#include "SourceWeightRegisteredProfile.h"
#include "SourceWeightWordFit.h"
#include "SourceWeightOrderedGlyph.h"

namespace aidoku::source {
struct SourceWeightRecognizedWord {
    cv::Rect2d bbox;              // Original xywh in the supplied RGB crop.
    std::u32string text;          // Original recognized whole word; no splitting.
    std::vector<cv::Point2f> polygon; // Same crop coordinates; empty means angle0.
};
enum class SourceWeightWordObservationPaths { Reference = 1, Soft = 2, Both = 3 };

// Field names intentionally match reference_ink_weight.measure word keys.
struct SourceWeightReferenceWordObservation {
    double templateFit, estimatedVisualWeight, matchedReferenceWeight;
    double bestRegularTemplateFit, normalTemplateMargin, weightFraction, fractionSpread;
    SourceWeightRegisteredProfileObservation registeredStrokeProfile;
    std::array<double,4> sourceWidthsPx, regularWidthsPx, heavyWidthsPx;
    double visibleSourceFraction;
    std::string referenceFamily;
};
// Python soft_ink_source.observe flattens this profile's keys into each word.
// Serialize only present profile.measurements fields; retain alphaLevels and
// unusable counts/flags exactly as SourceWeightRegisteredProfile's contract.
struct SourceWeightSoftWordObservation {
    SourceWeightRegisteredProfileObservation profile;
    std::optional<SourceWeightOrderedObservation> orderedGlyphs; // Absent unless includeOrdered.
    double matchedWeight, templateFit, normalTemplateMargin;
    std::string referenceFamily;
};
struct SourceWeightWordObservations {
    std::vector<SourceWeightReferenceWordObservation> referenceWords;
    std::vector<SourceWeightSoftWordObservation> softWords;
    // Reference selects spread indices (np.linspace -> int); soft selects first6.
    size_t expectedReferenceWordCount = 0, expectedSoftWordCount = 0;
    bool orderedGlyphsImplemented = true;
};

// Main bridge entry. input MUST carry existing native/primary/boundary/RF27,
// ownership/valid/paint and finite positive FINAL sourceEm; cutoff must be .5.
// Uses reconstructSourceWeightInk(ColorConsistent) once, no model/glyph/RF rerun.
// Members are original word records in original order, never source IDs or GT.
// Explicit reference intervals are the same inputs as fairSourceWeightFaceFits.
// Typed output only: parent owns ObjC dictionary bridge, mixed/policy/Swift.
// For reference dictionary: {words:referenceWords}; standard Python metadata
// may be added by the bridge. For soft: {words:softWords,
// expectedWordCount:expectedSoftWordCount}; flatten soft profile keys per word.
// includeOrdered adds parent-owned ordered glyph measurements to soft words,
// using the complete aligned word signal and winning common family frame.
// It never performs policy/conflict-veto decisions.
SourceWeightWordObservations observeSourceWeightWords(const SourceWeightInkInput &input,
    const std::vector<SourceWeightRecognizedWord> &words,
    const std::vector<WordReferencePair> &pairs,
    SourceWeightWordObservationPaths paths = SourceWeightWordObservationPaths::Both,
    bool includeOrdered = false);

// Exact palette_word_pairs.prepare_palette for a bounded already cropped word.
// cleanedStyle must be cleanSourceInkStyle's result; returns nullopt for no valid
// whole-string/predicted-fill geometry. It does not reconstruct new glyph/RF data.
std::optional<PreparedSourceWeightWord> prepareSourceWeightPaletteWord(
    const cv::Mat &rgb, const cv::Rect2d &bbox, double sourceEm,
    const std::u32string &text, const cv::Mat &ownership,
    const SourceInkStyle &cleanedStyle, double angle = 0);
}
