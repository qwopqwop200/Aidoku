#pragma once
#include "SourceWeightInk.h"

namespace aidoku {
struct SourceStrokeOpposedWidths {
    std::vector<double> widths; // distance / unit, in distance-major ray order.
    double pairSupport = 0;
};
struct SourceStrokeDirectionalGroup {
    int count = 0;
    std::array<double, 4> quantiles{}; // .1, .25, .5, .75
};
struct SourceStrokeDirectionalObservation {
    // Same group names as Python: verticalStems, horizontalStems, diagonalStems.
    std::map<std::string, SourceStrokeDirectionalGroup> groups;
    int components = 0;
    std::optional<double> directionContrast;
    double minimumDirectionalMedian = 0;
    bool newModelCreated = false, modelTrainingPerformed = false;
};
struct SourceStrokeGeometryStage {
    double cutoff = 0;
    int components = 0, pairedRays = 0;
    double pairSupport = 0;
    std::array<double, 4> pairedQuantiles{}; // .25, .5, .75, .9
    std::array<double, 8> componentMedian{}, componentUpper{};
    double observedFraction = 0;
};
struct SourceStrokeGeometryObservation {
    std::array<SourceStrokeGeometryStage, 3> stages; // .25, .5, .75 cutoffs
    std::string method = "source fill palette + opposed-edge SWT + component-balanced medial widths";
    bool sourcePaletteQualified = false, learnedModelUsed = false;
};
// Alpha is CV_32FC1; observed/mask/ownership are CV_8UC1, nonzero=true.
// All inputs are aligned, bounded source-local crops, never whole-page images.
// No classifier, trained head, models, fonts, IDs, policy promotion or file I/O.
// Errors throw std::exception; empty measurements retain zero arrays/null contrast.
SourceStrokeOpposedWidths sourceWeightOpposedWidths(const cv::Mat &alpha,
    const cv::Mat &observed, const cv::Mat &mask, double unit, int maximumEdges = 6000);
SourceStrokeDirectionalObservation measureSourceWeightDirectional(const cv::Mat &alpha,
    const cv::Mat &known, double unit, std::optional<double> maximumComponentEm = 1.7);
// Old source directional path: clean palette -> color*ownership, known -> measure.
// It must not silently consume reconstructed alpha instead of colour-backed alpha.
SourceStrokeDirectionalObservation measureColorBackedSourceWeightDirectional(const cv::Mat &rgb,
    const cv::Mat &ownership, const SourceInkStyle &style, double em);
// ink_weight_geometry.observe: source RGB + cleaned palette, exact <=800 resize,
// bbox overlap/component/ridge/contour qualification and opposed-edge statistics.
// The observe component upper bound is always the original 1.7em.
SourceStrokeGeometryObservation observeSourceWeightStrokeGeometry(const cv::Mat &rgb,
    const cv::Rect2d &bbox, double em, const cv::Mat &ownership, const SourceInkStyle &style);
// Explicit source alpha/observed entry: applies observe's resize and geometry
// stages, WITHOUT reobserving/quantizing alpha. qualified is provenance only.
SourceStrokeGeometryObservation observeSourceWeightStrokeAlpha(const cv::Mat &alpha,
    const cv::Mat &observed, const cv::Rect2d &bbox, double em,
    const cv::Mat &ownership, bool sourcePaletteQualified);
// Exact segmented_ink_geometry.measure bridge after reconstruction: quantized
// in-memory RGB signal rint(255*(1-alpha)), neutral black fill/white background,
// and ownership & observed. The returned stages are NOT direct-alpha stages.
SourceStrokeGeometryObservation observeReconstructedSourceWeightStrokeGeometry(const cv::Mat &alpha,
    const cv::Mat &observed, const cv::Rect2d &bbox, double em, const cv::Mat &ownership);
}
