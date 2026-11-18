#pragma once
#include <array>
#include <functional>
#include <optional>
#include <string>
#include <opencv2/core.hpp>
namespace aidoku {
struct WeightBandFont {
    std::string path, sha256;
    std::optional<double> weight;
};
struct WeightBandPair { WeightBandFont regular, heavy; };
// Native-pairs glyph: actual EM128, >40 trimmed CV_8U, empty for None.
// Caller must honor reference path, digest and variable weight, without fallback.
using WeightBandGlyph = std::function<cv::Mat(const WeightBandFont &, uint32_t)>;
// Exact glyph_measurement(default_font_paths()[0], char)[4], or nullopt:
// cmap-supported W3/face0 EM256, sqrt(count(ink>=64)/256**2).
using WeightBandAnchor = std::function<std::optional<double>(uint32_t)>;
using WeightBandPoses = std::array<double,192>;
using WeightBands = std::array<double,112>;
struct WeightBandResult { WeightBandPoses poses; WeightBands bands; };
struct WeightBandPolicy {
    double minimumAddedStem, minimumCommonBody, minimumGlyphFit, maximumReconstructionError;
};
// Alpha is the caller's sourceFillAlpha over a bounded source-local crop, not
// bbox-sliced again. bbox is xywh in alpha coordinates (rotate's bbox result
// is discarded by the Python oracle). CV_32F or CV_64F alpha in [0,1].
// Exactly four ordered reference pairs; fixed native_pairs.SCALES. Optional
// poses implement weight_bands.measure(poses=...), otherwise affine is computed.
// All failures throw std::exception; no models, GT or IDs are accepted.
WeightBandResult measureFontWeightBands(const cv::Mat &predictedAlpha,
    const cv::Rect2d &bbox, double angle, double sourceEm, const std::string &text,
    const std::array<WeightBandPair,4> &pairs, const WeightBandGlyph &glyph,
    const WeightBandAnchor &anchor, const WeightBandPoses *poses = nullptr);
std::array<double,24> fitFontWeightAffine(const cv::Mat &alpha32,
    const cv::Mat &regular128, const cv::Mat &heavy128, double unit);
std::array<double,14> fontWeightBandStats(const cv::Mat &source,
    const cv::Mat &regular, const cv::Mat &heavy, double score = 1.);
// First maximum score slot12 wins, inclusive policy boundaries, as runtime.py.
bool confirmFontWeightBands(const WeightBands &bands, const WeightBandPolicy &policy);
}
