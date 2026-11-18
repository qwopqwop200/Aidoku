#pragma once
#include "SourceWeightWordFit.h"
#include "SourceWeightRegisteredProfile.h"
namespace aidoku::source {
struct SourceWeightOrderedGlyph {
    SourceWeightRegisteredProfileObservation profile;
    double templateFit,normalFit,heavyFit,heavyMargin,referencePerimeterEm,referenceKnownSupport;
    std::array<int,2> sourceInterval;
};
struct SourceWeightOrderedObservation {
    bool usable=false,completePartition=false;
    size_t orderedGlyphCount=0;
    std::vector<SourceWeightOrderedGlyph> glyphs;
};
std::vector<std::array<int,2>> partitionSourceWeightGlyphs(const cv::Mat& alpha,const cv::Mat& known,
    const std::vector<double>& expected,bool vertical);
// Source-local alpha and known arrays are the SAME reconstructed word signal
// used by soft measurement. OCR order fixes glyph intervals; no radical search.
SourceWeightOrderedObservation measureSourceWeightOrderedGlyphs(const cv::Mat& alpha,const cv::Mat& known,
    const std::u32string& text,bool vertical,const WordReferencePair& family,double unit,
    bool softProfile=false);
}
