#pragma once
#include <array>
#include <map>
#include <optional>
#include <string>
#include <vector>
#include <opencv2/core.hpp>

namespace aidoku {
using SourceInkRGB = std::array<double, 3>;
struct SourceInkPaint {
    bool present = false;
    std::optional<SourceInkRGB> rgb;
    std::vector<SourceInkRGB> colors;
    std::vector<double> observedContextWeights;
    double widthPx = 0;
};
struct SourceInkStyle { SourceInkPaint fill, background, outline, shadow; };
struct SourceWeightInkInput {
    // Original predicted RGB, CV_8UC3, RGB order, bounded source-local crop.
    // No crop expansion, resampling, model loading, font or ID lookup occurs.
    cv::Mat rgb;
    // CV_8UC1 boolean maps (nonzero=true), same size as RGB.
    cv::Mat ownership, valid;
    // Existing primary/boundary/native CV_32FC1; RF CV_32FC(27).
    // native > 0 corroborates weak primary, never a new classifier.
    cv::Mat primary, boundary, native, rf;
    SourceInkStyle style;
    double cutoff = .5;
    std::optional<double> sourceEm;
};
struct SourceInkObservation {
    cv::Mat alpha; // CV_32FC1, including unobserved values, exactly as Python.
    cv::Mat known; // CV_8UC1, 0/1. Unknown MUST NOT be interpreted as background.
};
struct SourceWeightInkResult {
    cv::Mat alpha, observed; // float32 alpha and 0/1 valid | palette-known.
    std::map<std::string, double> audit;
};
enum class SourceWeightInkRule { Segmented, ColorConsistent };
// clean_fill_style + observe_palette. nullopt means no contrasting fill.
std::optional<SourceInkStyle> cleanSourceInkStyle(const SourceInkStyle &style);
SourceInkObservation observeSourceInkPalette(const cv::Mat &rgb,
    const cv::Mat &ownership, const SourceInkStyle &cleanedStyle);
// Exact segmented_ink_geometry.reconstruct: default maximumComponentEm=1.7.
// nullopt explicitly retains long seeded components (not a global dilation).
SourceWeightInkResult reconstructSegmentedSourceWeightInk(const SourceWeightInkInput &input,
    std::optional<double> maximumComponentEm = 1.7);
// color_consistent_ink.reconstruct: no component length cap; known direct
// colour overrides segmentation, including known-background veto.
SourceWeightInkResult reconstructSourceWeightInk(const SourceWeightInkInput &input,
    SourceWeightInkRule rule = SourceWeightInkRule::ColorConsistent);
}
