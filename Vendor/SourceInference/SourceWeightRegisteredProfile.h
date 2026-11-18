#pragma once
#include <array>
#include <optional>
#include <opencv2/core.hpp>

namespace aidoku {
struct SourceWeightRegisteredProfileInput {
    // Already aligned, bounded source/regular/heavy alpha: CV_32FC1 or CV_64FC1.
    // No clipping, resampling, registration, font loading or inference occurs.
    cv::Mat source, regular, heavy;
    // CV_8UC1 boolean map, or CV_32FC1/CV_64FC1 cast to uint8 exactly as Python.
    cv::Mat known;
    double unit;
};
struct SourceWeightRegisteredProfileMeasurements {
    double medianWeightFraction, lowerWeightFraction, upperWeightFraction;
    double correspondingSourceSupport;
    double medianNormalRadiusEm, medianSourceRadiusEm;
};
struct SourceWeightRegisteredProfileObservation {
    int correspondingCentres = 0, informativeCentres = 0;
    bool newModelCreated = false, modelTrainingPerformed = false, usable = false;
    // Absent when unusable: do NOT serialize six numeric fields as zeros/nulls.
    std::optional<SourceWeightRegisteredProfileMeasurements> measurements;
    // Present ONLY for soft profiles, including unusable soft profiles.
    std::optional<std::array<double, 9>> alphaLevels;
};
// Exact np.linspace(.1,.9,9), including .30000000000000004/.7000000000000001.
const std::array<double, 9> &sourceWeightSoftProfileLevels();
// Binary CV_8UC1, values 0/1. Returns CV_32FC1, same crop dimensions.
// Inside padded with zero; complement padded with one. These asymmetric pads
// preserve source/reference strokes touching the crop edge and empty-mask DT.
cv::Mat sourceWeightRegisteredSignedDistance(const cv::Mat &binary);
// soft_stroke_profile.depth: float32 alpha-level integration, edge correction
// of +/- .5 and float32 accumulation, not a distance transform at alpha=.5.
cv::Mat sourceWeightSoftProfileDepth(const cv::Mat &alpha);
// Registered binary profile: >.5 threshold and >=.75 radius difference.
// Unit <=0 errors; original NaN/+infinity unit behaviour is retained.
SourceWeightRegisteredProfileObservation measureSourceWeightRegisteredProfile(
    const SourceWeightRegisteredProfileInput &input);
// Soft profile: >= level thresholds and >=.5 integrated radius difference.
// Requires finite positive unit. Both variants need >=8 informative centres.
SourceWeightRegisteredProfileObservation measureSourceWeightSoftStrokeProfile(
    const SourceWeightRegisteredProfileInput &input);
}
