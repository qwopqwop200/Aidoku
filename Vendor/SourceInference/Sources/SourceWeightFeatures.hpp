#pragma once
#include "SourceFeatureMath.hpp"

namespace aidoku { namespace source {
// Isolated numeric prerequisites only. No model, font lookup, page context,
// private alpha predictor, Swift bridge or production caller is installed here.
Vec weightEstimatorExtra40(const cv::Mat& rgb, const cv::Rect2d& bbox, double ocrPrior);
Vec weightStroke55(const cv::Mat& rgb, const cv::Rect2d& bbox, double ocrPrior);
Vec weightGrouped144(const cv::Mat& rgb, const cv::Rect2d& bbox, double ocrPrior);

// Python features.measure layout: [native156 with first6zero, extra40,
// stroke55, grouped144, glyphBody56, fontMetrics146]. All supplied shared
// vectors must be Python-equivalent for this SAME RGB/bbox/OCR prior/text.
// In particular glyphBody56 MUST use ALL-ONES ownership over the entire RGB
// crop, NOT the current native OWN body signal. Font metrics must be computed
// using first6zero native156. Length/finiteness checks cannot verify provenance.
Vec composeWeightRaw597(const cv::Mat& rgb, const cv::Rect2d& bbox, double ocrPrior,
                        const Vec& native156, const Vec& allOnesGlyphBody56,
                        const Vec& fontMetrics146);
struct WeightDirectObservation {
    // source_runtime.DIRECT_KEYS order: quality, glyphCount, bodyThickness,
    // thinStroke, broadStroke, hollowFraction, occupancy.
    Vec features;
    std::string mask;
};
// Palette count ties follow the accepted NumPy 2.2.6 ARM default argsort.
// Other NumPy versions/SIMD backends may choose different tied palette modes.
WeightDirectObservation weightDirect7(const cv::Mat& rgb, const cv::Rect2d& bbox, double ocrPrior);

struct WeightFillStyle {
    cv::Vec3d fillRGB, backgroundRGB;
    bool outlinePresent = false;
    double outlineWidthPx = 0;
};
// line_weights.qualified_analyze: source palette qualification plus projection
// line separation and within-owner body contrast. Mixed stays whole-render
// regular until translated-span alignment exists. No lexical/region identity.
bool qualifiedWeightMixed(const cv::Mat& rgb, const cv::Rect2d& bbox, double sourceEm,
                          const WeightFillStyle& style);
// fill_body.measure(version=1): caller supplies the already predicted alpha
// (full crop coordinates, CV_32F or CV_64F, finite [0,1]) and full-crop ownership
// (CV_8U boolean 0/1). Re-crops alpha to bbox; uses source_em, not OCR prior if
// the caller's fill head uses an estimated em. Does NOT implement version 2.
Vec weightFill71V1(const cv::Mat& predictedAlpha, const cv::Rect2d& bbox, double sourceEm,
                   const cv::Mat& ownership, const WeightFillStyle& style);
}}
