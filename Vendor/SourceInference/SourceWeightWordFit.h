#pragma once
#include "SourceWeightReferenceGrid.h"
namespace aidoku::source {
struct PreparedSourceWeightWord {
    std::u32string text; // Exact masked_word_pairs.prepare NFC, whitespace-removed text.
    cv::Mat alpha;      // Prepared observation VALUES, CV_32F, not frozen pose alpha.
    cv::Mat known;      // CV_8U, boolean 0/1. Unknown is excluded, never background.
    bool vertical=false;
    double longExtent=0,crossExtent=0,boxLong=0,boxCross=0,unit=0;
};
struct SourceWeightWordMatch {
    double score,regular,heavy;
    int x,y;
};
using SourceWeightWordFit = std::array<double,32>;
enum class SourceWeightWordRenderer { WordMasks, SharedFrame };
// Complete masked correlation map; empty means pattern cannot fit.
cv::Mat correlateSourceWeightWord(const cv::Mat &values,const cv::Mat &known,const cv::Mat &pattern);
std::optional<SourceWeightWordMatch> locateSourceWeightWord(const cv::Mat &values,const cv::Mat &known,
                                                          const WordReferenceMasks &);
// Exact masked_word_pairs.fit. No crop/alpha producer/profile or word splitting.
SourceWeightWordFit fitSourceWeightWord(const PreparedSourceWeightWord &,const WordReferencePair &,
    SourceWeightReferenceGrid &,bool refine=false,
    SourceWeightWordRenderer renderer=SourceWeightWordRenderer::WordMasks);
struct FairSourceWeightFaceFit {
    SourceWeightWordFit fit;
    WordReferencePair reference;
    double nominalWeight;
};
// Exact reference_ink_weight.fair_face_fits: metadata intervals, one common
// normal/heaviest frame per family, stable face deduplication, independently
// refine up to TWO valid normal and TWO valid heavy candidates. Returns normal
// class first, then heavy, score-sorted stably within each class, as Python.
std::vector<FairSourceWeightFaceFit> fairSourceWeightFaceFits(const PreparedSourceWeightWord &,
    const std::vector<WordReferencePair> &pairs);
}
