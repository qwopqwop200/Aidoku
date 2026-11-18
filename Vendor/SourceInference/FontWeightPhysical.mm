#import <Foundation/Foundation.h>
#include "FontWeightPhysical.h"
#include "../NativeSourceCV/include/AidokuNativeCV.h"
#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <cmath>
#include <map>
#include <set>
#include <stdexcept>
#include <tuple>

namespace aidoku {
namespace {
constexpr std::array<double, 5> scales = {.85, .95, 1., 1.05, 1.15};
void require(bool value, const char *message) {
    if (!value) throw std::invalid_argument(message);
}
// Python round, independent of the caller's floating-point rounding mode.
int pyround(double x) {
    double base = std::floor(x), fraction = x - base;
    return int(base + (fraction > .5 || (fraction == .5 && std::fmod(base, 2.) != 0)));
}
cv::Mat raster(const PhysicalFontFace &face, uint32_t cp) {
    ACVGlyph glyph{};
    if (acv_glyph(face.path.c_str(), face.faceIndex, cp, 128 * 64, &glyph))
        throw std::runtime_error(acv_last_error());
    cv::Mat result;
    try {
        if (glyph.width && glyph.height) {
            cv::Mat image(glyph.height, glyph.width, CV_8U, glyph.pixels, glyph.pitch);
            cv::Mat support = image > 40;
            if (cv::countNonZero(support)) result = image(cv::boundingRect(support)).clone();
        }
    } catch (...) { acv_glyph_free(&glyph); throw; }
    acv_glyph_free(&glyph);
    return result;
}
std::array<cv::Mat, 2> patterns(const cv::Mat &a, const cv::Mat &b, double unit) {
    std::array<cv::Mat, 2> images, result;
    int width = 0, height = 0, pad = std::max(1, pyround(unit * .08));
    for (int i = 0; i < 2; ++i) {
        const auto &src = i ? b : a;
        cv::Mat resized;
        cv::resize(src, resized, {std::max(2, pyround(src.cols * unit / 128)),
                                 std::max(2, pyround(src.rows * unit / 128))}, 0, 0, cv::INTER_AREA);
        // NumPy astype(float32) / 255: separate cast then float division.
        resized.convertTo(images[i], CV_32F);
        for (int y = 0; y < images[i].rows; ++y)
            for (int x = 0; x < images[i].cols; ++x) images[i].at<float>(y,x) /= 255.f;
        width = std::max(width, images[i].cols); height = std::max(height, images[i].rows);
    }
    width += 2 * pad; height += 2 * pad;
    for (int i = 0; i < 2; ++i) {
        result[i] = cv::Mat::zeros(height, width, CV_32F);
        images[i].copyTo(result[i](cv::Rect((width-images[i].cols)/2,
            (height-images[i].rows)/2, images[i].cols, images[i].rows)));
    }
    return result;
}
std::set<uint32_t> characters(const std::string &text) {
    NSString *s = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding];
    require(s != nil, "Invalid UTF-8 text");
    NSData *data = [s.precomposedStringWithCanonicalMapping dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    std::set<uint32_t> result;
    const uint32_t *p = static_cast<const uint32_t *>(data.bytes);
    // Foundation's alphanumeric set is L/M/N; removing non-base marks keeps
    // precisely the L/N categories used by the Python source observation.
    NSCharacterSet *lettersAndNumbers = NSCharacterSet.alphanumericCharacterSet;
    NSCharacterSet *marks = NSCharacterSet.nonBaseCharacterSet;
    for (size_t i = 0; i < data.length / 4; ++i) {
        if ([lettersAndNumbers longCharacterIsMember:p[i]] && ![marks longCharacterIsMember:p[i]])
            result.insert(p[i]);
    }
    return result;
}
}
std::array<double, 48> measureFontWeightPhysical(const cv::Mat &rgb,
    const cv::Rect2d &bbox, double sourceEm, const std::string &text,
    const std::array<PhysicalFontPair, 3> &pairs) {
    require(rgb.type() == CV_8UC3 && !rgb.empty(), "Expected bounded RGB8 crop");
    require(std::isfinite(sourceEm) && sourceEm > 0, "Invalid source em");
    for (double v : {bbox.x, bbox.y, bbox.width, bbox.height})
        require(std::isfinite(v) && std::abs(v) < 1e8, "Invalid bbox");
    require(bbox.width > 0 && bbox.height > 0, "Empty target");
    // Reject page-sized context; crop bounds are caller-owned, not inferred.
    require(bbox.x >= -1 && bbox.y >= -1 && bbox.x + bbox.width <= rgb.cols + 1 &&
        bbox.y + bbox.height <= rgb.rows + 1 && bbox.x <= .15*bbox.width + 1 &&
        bbox.y <= .15*bbox.height + 1 && rgb.cols-bbox.x-bbox.width <= .15*bbox.width + 1 &&
        rgb.rows-bbox.y-bbox.height <= .15*bbox.height + 1, "RGB context exceeds 15% per side");
    require(pairs[0].available, "Baseline physical reference required");
    for (const auto &pair : pairs) if(pair.available) for (const auto *face : {&pair.regular, &pair.heavy})
        require(!face->path.empty() && face->faceIndex >= 0, "Explicit font path/face required");
    // Collection layouts differ by platform. Validate the actual named face,
    // never a macOS-specific TTC index or a substitute family/weight.
    const char* names[3][2]={{"HiraginoSans-W3","HiraginoSans-W6"},
        {"HiraginoSans-W6","HiraginoSans-W9"},{"HiraMinProN-W3","HiraMinProN-W6"}};
    for(int p=0;p<3;++p)if(pairs[p].available)for(int f=0;f<2;++f) {
        const auto& face=f==0?pairs[p].regular:pairs[p].heavy;int index=-1;
        require(acv_font_face_index(face.path.c_str(),names[p][f],&index)==0&&index==face.faceIndex,
                "Physical reference PostScript face differs");
    }
    int x = std::max(0, int(bbox.x)), y = std::max(0, int(bbox.y));
    int right = std::min(rgb.cols, int(std::ceil(bbox.x+bbox.width)));
    int bottom = std::min(rgb.rows, int(std::ceil(bbox.y+bbox.height)));
    require(right > x && bottom > y, "Empty target");
    cv::Mat target = rgb(cv::Rect(x,y,right-x,bottom-y));
    double scale = std::min(1., 360. / std::max(target.rows,target.cols)), unit = sourceEm * scale;
    require(std::isfinite(unit) && unit <= 1e7, "Source em too large");
    if (scale < 1) cv::resize(target, target, {}, scale, scale, cv::INTER_AREA);
    cv::Mat gray, dark;
    cv::cvtColor(target, gray, cv::COLOR_RGB2GRAY);
    cv::threshold(gray, dark, 0, 1, cv::THRESH_BINARY_INV | cv::THRESH_OTSU);
    std::array<cv::Mat,3> masks;
    dark.convertTo(masks[0], CV_32F);
    masks[1] = cv::Mat::zeros(target.size(), CV_32F); masks[2] = masks[1].clone();
    for (int r = 0; r < target.rows; ++r) for (int c = 0; c < target.cols; ++c) {
        auto pixel = target.at<cv::Vec3b>(r,c);
        int lo = std::min({pixel[0],pixel[1],pixel[2]}), hi = std::max({pixel[0],pixel[1],pixel[2]});
        masks[1].at<float>(r,c) = lo > 180 && hi-lo < 45;
        masks[2].at<float>(r,c) = hi-lo > 70;
    }
    std::map<std::tuple<std::string,int,uint32_t>,cv::Mat> cache;
    auto bitmap = [&](const PhysicalFontFace &f, uint32_t cp) -> cv::Mat {
        auto key = std::make_tuple(f.path,f.faceIndex,cp);
        auto it = cache.find(key);
        if (it == cache.end()) it = cache.emplace(key, raster(f,cp)).first;
        return it->second;
    };
    std::array<std::pair<int,uint32_t>,2> chosen = {{{-1,0},{-1,0}}};
    for (uint32_t cp : characters(text)) {
        auto image = bitmap(pairs[0].regular, cp);
        if (image.empty()) continue;
        int category = cp >= 0x3040 && cp <= 0x30ff ? 0 : 1;
        std::pair<int,uint32_t> item{cv::countNonZero(image > 40),cp};
        chosen[category] = std::max(chosen[category],item);
    }
    std::array<double,48> output{};
    for (int p = 0; p < 3; ++p) for (int g = 0; g < 2; ++g) {
        if(!pairs[p].available)continue; // All eight availability/count fields remain absent/zero.
        if (chosen[g].first < 0) continue;
        auto a = bitmap(pairs[p].regular,chosen[g].second), b = bitmap(pairs[p].heavy,chosen[g].second);
        if (a.empty() || b.empty()) continue;
        bool found = false; double score = 0, ra = 0, rb = 0, factor = 0;
        for (double f : scales) {
            // Avoid allocating a pattern that cannot fit any mask.
            if (std::max(a.cols,b.cols)*unit*f/128 > target.cols+2 ||
                std::max(a.rows,b.rows)*unit*f/128 > target.rows+2) continue;
            auto ab = patterns(a,b,unit*f);
            for (const auto &mask : masks) {
                if (ab[0].rows > mask.rows || ab[0].cols > mask.cols) continue;
                cv::Mat ca, cb, joint;
                cv::matchTemplate(mask,ab[0],ca,cv::TM_CCOEFF_NORMED);
                cv::matchTemplate(mask,ab[1],cb,cv::TM_CCOEFF_NORMED);
                joint = (ca + cb) / 2;
                for (int r = 0; r < joint.rows; ++r) for (int c = 0; c < joint.cols; ++c)
                    if (!std::isfinite(joint.at<float>(r,c))) joint.at<float>(r,c) = -1.f;
                double value; cv::Point loc;
                cv::minMaxLoc(joint,nullptr,&value,nullptr,&loc);
                double ar = ca.at<float>(loc), br = cb.at<float>(loc);
                if (!std::isfinite(ar+br)) continue;
                if (!found || value > score) { found = true; score = value; ra = ar; rb = br; factor = f; }
            }
        }
        if (found) {
            size_t offset = (p*2+g)*8;
            std::array<double,8> row = {score,ra,rb,rb-ra,factor,1.,double(score>.5),double(score>.7)};
            std::copy(row.begin(),row.end(),output.begin()+offset);
        }
    }
    return output;
}
}
