// Source-only high-order font measurements. No model, label, page or prediction lookup.
#pragma once

#ifdef __cplusplus
#include <array>
#include <cstdint>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <opencv2/core.hpp>
#include <string>
#include <vector>

namespace aidoku::source {

struct SourcePaintPart {
    cv::Vec3d rgb{0, 0, 0};
    bool hasRGB = false;
    bool present = false;
    double widthPx = 0;
    double probability = 0;
    std::vector<cv::Vec3d> colors;
};

struct SourcePaintStyle {
    SourcePaintPart fill, outline, background, shadow;
    std::array<double, 4> roleProbabilities{0, 0, 0, 0};
};

struct FontTemplateInputs {
    cv::Mat rgb;            // CV_8UC3, RGB, bounded at <=15% context per side.
    cv::Mat ownership;      // CV_8UC1, nonzero = predicted glyph ownership.
    cv::Rect2d bbox;        // Target xywh in the bounded crop, original px.
    double prior = 0;       // Original source em, never a model prediction.
    std::u32string text;    // Original OCR; normalized to NFC by extraction.
    SourcePaintStyle style; // Source-predicted paint, not display overrides.
    std::vector<std::vector<cv::Point2f>> memberPolygons;
    std::vector<std::string> fonts;               // Four baseline faces, pinned order.
    std::vector<std::string> extendedFonts;       // Eight faces, first four = baseline.
    std::vector<std::string> nativeFonts;         // Four native166 faces, pinned order.
    std::map<std::string, int> fontFaceIndices;   // Explicit TTC face; absent = pinned face0.
    std::map<std::string, std::string> fontFiles; // Opaque face key -> actual font file.
    std::map<std::string, double> fontWeights;    // Opaque key -> optional explicit OpenType wght.
    std::vector<double> native156;                // Optional, for fontMetrics146 only.
    double confidence = std::numeric_limits<double>::quiet_NaN();
    std::string role;                   // dialogue/narration/story_text.
    cv::Point2d normalizedCenter{0, 0}; // Source bbox center / pageSize.
};
using SourceGlyphInputs = FontTemplateInputs;

// Raw untrimmed Pillow-compatible getmask(mode=L), at em256. The string is the
// opaque face key from the font vectors (fontFiles/fontFaceIndices/fontWeights resolve it).
// Empty Mat means unsupported/empty glyph. Must return CV_8UC1 owned storage.
using SourceGlyphRasterizer = std::function<cv::Mat(const std::string &, char32_t)>;

struct FontTemplateSignals {
    std::map<std::string, std::vector<double>> arrays;
    double angle131 = 0;
    double priorRatio131 = 1;
    bool remeasured158 = false;
};

// All arrays are measured from supplied RGB/ownership/paint/OCR. No artifact I/O.
// Throws std::invalid_argument or cv::Exception for invalid inputs.
FontTemplateSignals extractFontTemplateFeatures(const FontTemplateInputs &input,
                                                const SourceGlyphRasterizer &rasterize);
FontTemplateSignals extractFontTemplateFeatures(const FontTemplateInputs &input);
// Adds the parent's native156/65/69/100 and freshly extracted glyph components.
FontTemplateSignals extractAllSourceSignals(const FontTemplateInputs &input);

// Minimal same-crop weight prerequisites. Always measures native156 afresh,
// zeroes its first six, uses ALL-ONES ownership for glyphBody56, and normalizes
// fontMetrics146 using that native156 and original OCR prior/text. No templates.
struct SourceWeightBasics {
    std::vector<double> native156, allOnesGlyphBody56, fontMetrics146;
};
SourceWeightBasics extractSourceWeightBasics(const FontTemplateInputs &input);
// Dedicated raw597 numeric inputs only. No invented style/ownership/font-bank
// observations are needed to satisfy the unrelated legacy template validator.
struct SourceWeightRawInputs {
    cv::Mat rgb;
    cv::Rect2d bbox;
    double prior = 0;
    std::u32string text;
    std::vector<std::string> fonts;
    std::map<std::string, int> fontFaceIndices;
    std::map<std::string, std::string> fontFiles;
    std::map<std::string, double> fontWeights;
    std::map<std::string, std::string> authenticatedFontSHA256;
    std::shared_ptr<class SourceWeightGlyphMetricsCache> glyphMetricsCache;
};
struct SourceWeightGlyphMetricsCacheStats {
    size_t entries = 0, capacity = 0, storageBytes = 0;
    uint64_t hits = 0, misses = 0, evictions = 0;
};
std::shared_ptr<SourceWeightGlyphMetricsCache> makeSourceWeightGlyphMetricsCache(size_t maxEntries = 4096,
                                                                               size_t maxBytes = 1024 * 1024);
SourceWeightGlyphMetricsCacheStats sourceWeightGlyphMetricsCacheStats(const std::shared_ptr<SourceWeightGlyphMetricsCache> &cache);
SourceWeightBasics extractSourceWeightRawBasics(const SourceWeightRawInputs &input);
// Exact legacy weight residual for its own recognized-word geometry. Does not
// execute models or unrelated high-order font measurements. Returns style187
// (262) and angle131 using original prior and source-predicted paint/ownership.
FontTemplateSignals extractSourceWeightResidual(const FontTemplateInputs &input);

// Auxiliary public kernels used to compare raster/matching/alpha behavior.
cv::Mat sourceGlyphBitmap(const cv::Mat &rawMask);
std::array<double, 6> sourceGlyphMetrics(const cv::Mat &rawMask);
cv::Mat sourceFillAlpha(const FontTemplateInputs &input);

} // namespace aidoku::source
#endif

#ifdef __OBJC__
#import <Foundation/Foundation.h>
FOUNDATION_EXPORT
NSDictionary<NSString *, id> *_Nullable AIDExtractAllSourceSignals(NSDictionary *_Nonnull packet,
                                                                   NSError *_Nullable *_Nullable error);
#ifdef __cplusplus
namespace aidoku::source {
// Adapter only decodes source observations; callers supply the rasterizer.
FontTemplateInputs fontTemplateInputsFromDictionary(NSDictionary *_Nonnull packet);
SourceWeightRawInputs sourceWeightRawInputsFromDictionary(NSDictionary *_Nonnull packet);
NSDictionary<NSString *, id> *_Nonnull fontTemplateSignalsDictionary(const FontTemplateSignals &signals);
} // namespace aidoku::source
#endif
#endif
