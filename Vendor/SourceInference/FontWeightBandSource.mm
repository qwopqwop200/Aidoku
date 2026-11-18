#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include "FontWeightBandSource.h"
#include "../NativeSourceCV/include/AidokuNativeCV.h"
#include <opencv2/imgproc.hpp>
#include <cmath>
#include <map>
#include <stdexcept>
#include <tuple>

namespace aidoku::source {
namespace {
void requireBandSource(bool ok, const char *why) {
    if (!ok) throw std::invalid_argument(why);
}
void nativeBandCheck(int status) {
    if (status) throw std::runtime_error(acv_last_error());
}
struct BandGlyphStorage {
    ACVGlyph glyph{};
    ~BandGlyphStorage() { acv_glyph_free(&glyph); }
};
// Empty means no visible bitmap, not unsupported. Reference fitting deliberately
// uses same-font .notdef, while the anchor separately requires cmap coverage.
cv::Mat bandRawGlyph(const std::string &path, int face, uint32_t cp, int em,
                     const std::optional<double> &weight, bool reference, bool pillowCoordinate = true) {
    BandGlyphStorage storage;
    auto *g = &storage.glyph;
    // Pillow13 setvaraxes converts each Python coordinate to an integer before
    // making its FT_Fixed coordinate. Preserve that reference-font behavior
    // here; the existing native design-coordinate APIs remain unchanged.
    double effectiveWeight = weight ? (pillowCoordinate ? std::trunc(*weight) : *weight) : 0;
    if (!weight) nativeBandCheck(acv_glyph(path.c_str(), face, cp, em*64, g));
    else if (reference)
        nativeBandCheck(acv_reference_glyph_with_weight(path.c_str(), face, cp, em*64, effectiveWeight, g));
    else nativeBandCheck(acv_glyph_with_weight(path.c_str(), face, cp, em*64, effectiveWeight, g));
    if (!g->pixels || !g->width || !g->height) return {};
    return cv::Mat(g->height, g->width, CV_8U, g->pixels, g->pitch).clone();
}
void validBandPath(const std::string &path) {
    requireBandSource(!path.empty() && path.find('\0') == std::string::npos, "Explicit source font path required");
}
class BandSourceResources {
    std::string anchorPath;
    int anchorFace = 0;
    std::optional<double> anchorWeight;
    std::map<std::string,std::string> digests;
    using FontKey = std::tuple<std::string,std::optional<double>>;
    std::map<FontKey,std::map<uint32_t,cv::Mat>> rasters;
    std::map<uint32_t,std::optional<double>> anchorMetrics;

    std::string digest(const std::string &path) {
        auto it = digests.find(path);
        if (it != digests.end()) return it->second;
        validBandPath(path);
        NSString *file = [[NSString alloc] initWithBytes:path.data() length:path.size() encoding:NSUTF8StringEncoding];
        requireBandSource(file != nil, "Invalid source font path encoding");
        NSData *data = [NSData dataWithContentsOfFile:file options:NSDataReadingMappedIfSafe error:nil];
        requireBandSource(data && data.length && data.length <= UINT32_MAX, "Reference font bytes unavailable");
        unsigned char hash[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(data.bytes, static_cast<CC_LONG>(data.length), hash);
        std::string hex;
        constexpr char alphabet[] = "0123456789abcdef";
        for (auto byte : hash) { hex += alphabet[byte >> 4]; hex += alphabet[byte & 15]; }
        digests.emplace(path,hex);
        return hex;
    }
public:
    BandSourceResources(const FontTemplateInputs &input, const std::array<WeightBandPair,4> &pairs) {
        requireBandSource(!input.fonts.empty(), "Original baseline anchor font required");
        const auto &key = input.fonts[0];
        auto file = input.fontFiles.find(key);
        anchorPath = file == input.fontFiles.end() ? key : file->second;
        auto face = input.fontFaceIndices.find(key);
        anchorFace = face == input.fontFaceIndices.end() ? 0 : face->second;
        auto weight = input.fontWeights.find(key);
        if (weight != input.fontWeights.end()) anchorWeight = weight->second;
        validBandPath(anchorPath);
        requireBandSource(anchorFace >= 0, "Invalid baseline anchor face");
        requireBandSource(!anchorWeight || std::isfinite(*anchorWeight), "Invalid baseline anchor wght");
        // Validate baseline path/face/axis even for an empty-alpha/text call.
        // Reference mode is used only for this .notdef resource probe.
        (void)bandRawGlyph(anchorPath,anchorFace,0,256,anchorWeight,true,false);
        for (const auto &pair : pairs) for (const auto *font : {&pair.regular,&pair.heavy}) {
            requireBandSource(font->sha256.size() == 64 &&
                font->sha256.find_first_not_of("0123456789abcdef") == std::string::npos,
                "Invalid reference font SHA256");
            requireBandSource(!font->weight || std::isfinite(*font->weight), "Invalid reference font wght");
            requireBandSource(digest(font->path) == font->sha256, "Reference font SHA256 differs");
            FontKey key{font->path,font->weight};
            if (!rasters.count(key)) {
                // Also validates face0/axis/range for references not selected by
                // this crop; no silent fallback or unused-invalid descriptors.
                (void)bandRawGlyph(font->path,0,0,128,font->weight,true,false);
                rasters.emplace(key,std::map<uint32_t,cv::Mat>{});
            }
        }
    }
    cv::Mat glyph(const WeightBandFont &font, uint32_t cp) {
        auto &cache = rasters.at({font.path,font.weight});
        auto it = cache.find(cp);
        if (it != cache.end()) return it->second;
        cv::Mat raw = bandRawGlyph(font.path,0,cp,128,font.weight,true), trimmed;
        if (!raw.empty()) {
            cv::Mat ink = raw > 40;
            if (cv::countNonZero(ink)) trimmed = raw(cv::boundingRect(ink)).clone();
        }
        cache.emplace(cp,trimmed);
        return trimmed;
    }
    std::optional<double> anchor(uint32_t cp) {
        auto it = anchorMetrics.find(cp);
        if (it != anchorMetrics.end()) return it->second;
        int supported = 0;
        nativeBandCheck(acv_font_has_glyph(anchorPath.c_str(),anchorFace,cp,&supported));
        std::optional<double> metric;
        if (supported) {
            cv::Mat raw = bandRawGlyph(anchorPath,anchorFace,cp,256,anchorWeight,false);
            if (!raw.empty()) {
                int area = cv::countNonZero(raw >= 64);
                if (area) metric = std::sqrt(double(area)/(256.*256.));
            }
        }
        anchorMetrics.emplace(cp,metric);
        return metric;
    }
};
std::string bandUTF8(const std::u32string &text) {
    std::string out;
    for (uint32_t cp : text) {
        requireBandSource(cp <= 0x10ffff && !(cp >= 0xd800 && cp <= 0xdfff), "Invalid original OCR scalar");
        if (cp < 0x80) out += char(cp);
        else if (cp < 0x800) { out += char(0xc0 | (cp>>6)); out += char(0x80 | (cp&63)); }
        else if (cp < 0x10000) {
            out += char(0xe0 | (cp>>12)); out += char(0x80 | ((cp>>6)&63)); out += char(0x80 | (cp&63));
        } else {
            out += char(0xf0 | (cp>>18)); out += char(0x80 | ((cp>>12)&63));
            out += char(0x80 | ((cp>>6)&63)); out += char(0x80 | (cp&63));
        }
    }
    return out;
}
}
WeightBandResult measureSourceWeightBands(const FontTemplateInputs &input,
    const cv::Mat &alpha, double em, double angle, const std::array<WeightBandPair,4> &pairs) {
    requireBandSource(input.rgb.type() == CV_8UC3 && !input.rgb.empty() && alpha.size() == input.rgb.size(),
                      "Source alpha must match the already parsed RGB crop");
    BandSourceResources resources(input,pairs);
    return measureFontWeightBands(alpha,input.bbox,angle,em,bandUTF8(input.text),pairs,
        [&](const WeightBandFont &font,uint32_t cp){return resources.glyph(font,cp);},
        [&](uint32_t cp){return resources.anchor(cp);});
}
}
