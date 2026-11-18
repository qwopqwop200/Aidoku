#pragma once
#include <array>
#include <string>
#include <opencv2/core.hpp>

namespace aidoku {
struct PhysicalFontFace {
    std::string path;
    int faceIndex;
};
struct PhysicalFontPair {
    PhysicalFontFace regular, heavy;
    bool available = true;
};
// Caller supplies exactly W3/0-W6/0, W6/0-W9/0, Mincho/0-Mincho/2,
// in that order. No resolver, fallback, font substitution, IDs or learned data.
// RGB CV_8UC3 is a bounded source crop (<=15% context per side); bbox is
// xywh within that crop. Text is UTF-8; sourceEm is in original crop pixels.
// Throws std::exception for invalid input/font errors. Returns pair-major,
// kana then non-kana, each [joint, regular, heavy, delta, scale, n, >.5, >.7].
// Uses actual EM128 acv_glyph and fixed source_runtime scales only.
std::array<double, 48> measureFontWeightPhysical(
    const cv::Mat &rgb, const cv::Rect2d &bbox, double sourceEm,
    const std::string &text, const std::array<PhysicalFontPair, 3> &pairs);
}
