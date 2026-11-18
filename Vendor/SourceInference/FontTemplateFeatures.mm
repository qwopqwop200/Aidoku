// Native source-only glyph, paint and template measurements for font198.
// Algorithms mirror Scripts/font_size_estimation/optimized_features; no learned
// state, source identity, labels or stored predictions enter this translation unit.
#import "FontTemplateFeatures.h"
#include "Sources/SourceCoreFeatures.hpp"
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <numeric>
#include <mutex>
#include <opencv2/imgproc.hpp>
#include <set>
#include <stdexcept>
#include <tuple>
#include <unordered_map>
#include <sys/attr.h>
#include <sys/mount.h>
#if __has_include("AidokuNativeCV.h")
#include "AidokuNativeCV.h"
#define AIDOKU_HAS_NATIVE_GLYPH 1
#else
#define AIDOKU_HAS_NATIVE_GLYPH 0
#endif

namespace aidoku::source {
// Bounded BASE4-consumer reuse only. No path, bitmap or FT face is retained.
class SourceWeightGlyphMetricsCache {
  public:
    struct Key {
        std::array<uint8_t, 32> sha{};
        uint64_t weightBits = 0;
        uint32_t codepoint = 0, face = 0;
        bool hasWeight = false;
        // Backend/metric identity: FreeType2.14.3, em256, normal target/render,
        // sourceGlyphBitmap/metrics threshold64 + six-metric v1.
        uint32_t backendABI = 0x02140301;
        bool operator==(const Key &o) const {
            return sha == o.sha && weightBits == o.weightBits && codepoint == o.codepoint &&
                face == o.face && hasWeight == o.hasWeight && backendABI == o.backendABI;
        }
    };
    struct Value { std::array<double, 6> metrics{}; bool hasInk = false; };
  private:
    struct Slot { Key key; Value value; size_t previous = SIZE_MAX, next = SIZE_MAX; bool used = false; };
    std::vector<Slot> slots;
    // Fixed open addressing index: -1=empty, -2=tombstone. No per-entry allocation.
    std::vector<int32_t> index;
    std::mutex mutex;
    size_t used = 0, head = SIZE_MAX, tail = SIZE_MAX, deleted = 0;
    uint64_t hits = 0, misses = 0, evictions = 0;
    static size_t hash(const Key &key) {
        uint64_t value = 1469598103934665603ULL;
        auto add = [&](uint64_t word, int bytes) { for (int i = 0; i < bytes; ++i) { value ^= (word >> (i * 8)) & 255; value *= 1099511628211ULL; } };
        for (auto b : key.sha) add(b, 1);
        add(key.weightBits, 8); add(key.codepoint, 4); add(key.face, 4);
        add(key.hasWeight, 1); add(key.backendABI, 4); return size_t(value);
    }
    size_t bucket(const Key &key) const {
        size_t firstDeleted = SIZE_MAX, mask = index.size() - 1, p = hash(key) & mask;
        for (size_t n = 0; n < index.size(); ++n, p = (p + 1) & mask) {
            if (index[p] == -1) return firstDeleted == SIZE_MAX ? p : firstDeleted;
            if (index[p] == -2) { if (firstDeleted == SIZE_MAX) firstDeleted = p; }
            else if (slots[size_t(index[p])].key == key) return p;
        }
        if (firstDeleted == SIZE_MAX) throw std::logic_error("Glyph metric index exhausted");
        return firstDeleted;
    }
    void unlink(size_t i) {
        auto &s = slots[i];
        if (s.previous == SIZE_MAX) head = s.next; else slots[s.previous].next = s.next;
        if (s.next == SIZE_MAX) tail = s.previous; else slots[s.next].previous = s.previous;
    }
    void newest(size_t i) {
        auto &s = slots[i]; s.previous = SIZE_MAX; s.next = head;
        if (head != SIZE_MAX) slots[head].previous = i; else tail = i;
        head = i;
    }
    void rebuildIndex() {
        std::fill(index.begin(), index.end(), -1);
        for (size_t i = 0; i < used; ++i) index[bucket(slots[i].key)] = int32_t(i);
        deleted = 0;
    }
  public:
    SourceWeightGlyphMetricsCache(size_t maxEntries, size_t maxBytes) {
        size_t count = std::min(size_t(4096), maxEntries), table = 1;
        while (count) {
            table = 1; while (table < count * 2) table *= 2;
            if (sizeof(*this) + count * sizeof(Slot) + table * sizeof(int32_t) <= maxBytes) break;
            --count;
        }
        if (!count) throw std::invalid_argument("Glyph metric cache budget too small");
        slots.resize(count); index.assign(table, -1);
        if (sizeof(*this) + slots.capacity() * sizeof(Slot) + index.capacity() * sizeof(int32_t) > maxBytes)
            throw std::invalid_argument("Glyph metric cache backing storage exceeds budget");
    }
    bool find(const Key &key, Value &value) {
        std::lock_guard<std::mutex> lock(mutex);
        size_t p = bucket(key);
        if (index[p] < 0) { ++misses; return false; }
        size_t i = size_t(index[p]); value = slots[i].value;
        unlink(i); newest(i); ++hits; return true;
    }
    void insert(const Key &key, const Value &value) {
        std::lock_guard<std::mutex> lock(mutex);
        size_t p = bucket(key);
        if (index[p] >= 0) { size_t i = size_t(index[p]); unlink(i); newest(i); return; }
        size_t i;
        if (used < slots.size()) i = used++;
        else {
            i = tail; size_t oldBucket = bucket(slots[i].key); index[oldBucket] = -2; ++deleted;
            unlink(i); ++evictions; p = bucket(key);
        }
        slots[i].key = key; slots[i].value = value; slots[i].used = true;
        if (index[p] == -2) --deleted;
        index[p] = int32_t(i); newest(i);
        if (deleted > index.size() / 4) rebuildIndex();
    }
    SourceWeightGlyphMetricsCacheStats stats() {
        std::lock_guard<std::mutex> lock(mutex);
        return {used, slots.size(), sizeof(*this) + slots.capacity() * sizeof(Slot) + index.capacity() * sizeof(int32_t), hits, misses, evictions};
    }
};
std::shared_ptr<SourceWeightGlyphMetricsCache> makeSourceWeightGlyphMetricsCache(size_t entries, size_t bytes) {
    return std::make_shared<SourceWeightGlyphMetricsCache>(entries, bytes);
}
SourceWeightGlyphMetricsCacheStats sourceWeightGlyphMetricsCacheStats(const std::shared_ptr<SourceWeightGlyphMetricsCache> &cache) {
    return cache ? cache->stats() : SourceWeightGlyphMetricsCacheStats{};
}
namespace {
using FontDigest = std::array<unsigned char, CC_SHA256_DIGEST_LENGTH>;

bool readOnlySystemFont(NSString *path) {
    if (![path hasPrefix:@"/System/Library/Fonts/"]) return false;
    char resolved[PATH_MAX];
    const char *original = path.fileSystemRepresentation;
    if (!realpath(original, resolved) || strcmp(resolved, original) != 0) return false;
    // macOS presents a merged System/Data volume through Foundation. Ask the
    // kernel for the mount flags of the file itself, including on iOS.
    struct attrlist request{};
    request.bitmapcount = ATTR_BIT_MAP_COUNT;
    request.volattr = ATTR_VOL_INFO | ATTR_VOL_MOUNTFLAGS;
    struct { uint32_t length, flags; } volume{};
    // A plain read-only mount can later become writable. A mounted root
    // snapshot fixes the font bytes for this OS boot and process lifetime.
    constexpr uint32_t required = MNT_ROOTFS | MNT_RDONLY | MNT_SNAPSHOT;
    return getattrlist(resolved, &request, &volume, sizeof(volume), 0) == 0 &&
        volume.length == sizeof(volume) && (volume.flags & required) == required;
}

FontDigest fontDigest(NSString *path, bool allowSystemReuse) {
    static std::mutex mutex;
    static std::map<std::string, FontDigest> verified;
    const bool immutable = allowSystemReuse && readOnlySystemFont(path);
    std::string key;
    if (immutable) {
        key = path.fileSystemRepresentation;
        std::lock_guard<std::mutex> guard(mutex);
        auto found = verified.find(key);
        if (found != verified.end()) return found->second;
    }
    NSData *bytes = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!bytes || bytes.length > UINT32_MAX) throw std::invalid_argument("Pinned source font unavailable");
    FontDigest digest;
    CC_SHA256(bytes.bytes, static_cast<CC_LONG>(bytes.length), digest.data());
    if (immutable) {
        std::lock_guard<std::mutex> guard(mutex);
        if (verified.size() < 4) verified.emplace(key, digest);
    }
    return digest;
}

constexpr double kEm = 256.;
const Vec kScales{.4, .55, .7, .85, 1., 1.15, 1.3, 1.5};
int pyRound(double value) {
    return static_cast<int>(std::nearbyint(value));
}
double clamp(double x, double lo, double hi) {
    return std::max(lo, std::min(hi, x));
}
double ftMean(const Vec &v) {
    return v.empty() ? 0 : std::accumulate(v.begin(), v.end(), 0.) / v.size();
}
double ftQuantile(Vec v, double q) {
    if (v.empty())
        return 0;
    std::sort(v.begin(), v.end());
    double p = q * (v.size() - 1);
    size_t a = std::floor(p), b = std::ceil(p);
    return v[a] + (v[b] - v[a]) * (p - a);
}
double ftStddev(const Vec &v) {
    if (v.empty())
        return 0;
    double m = ftMean(v), s = 0;
    for (double x : v)
        s += (x - m) * (x - m);
    return std::sqrt(s / v.size());
}
void ftAppend(Vec &v, const Vec &x) {
    v.insert(v.end(), x.begin(), x.end());
}
void ftAppend(Vec &v, std::initializer_list<double> x) {
    v.insert(v.end(), x.begin(), x.end());
}
Vec linspace(double a, double b, int n) {
    Vec v;
    for (int i = 0; i < n; i++)
        v.push_back(i == n - 1 ? b : a + (b - a) * i / (n - 1));
    return v;
}
Vec uniqueSorted(Vec v) {
    std::sort(v.begin(), v.end());
    v.erase(std::unique(v.begin(), v.end()), v.end());
    return v;
}
cv::Rect ftTargetRect(cv::Size size, const cv::Rect2d &b) {
    int l = std::max(0, int(b.x)), t = std::max(0, int(b.y));
    int r = std::min(size.width, int(std::ceil(b.x + b.width))),
        d = std::min(size.height, int(std::ceil(b.y + b.height)));
    if (l >= r || t >= d)
        throw std::invalid_argument("Empty source bbox");
    return {l, t, r - l, d - t};
}
cv::Mat padded(const cv::Mat &x, int pad) {
    cv::Mat y;
    cv::copyMakeBorder(x, y, pad, pad, pad, pad, cv::BORDER_CONSTANT, cv::Scalar(0));
    return y;
}
cv::Mat resizeBy(const cv::Mat &x, double scale, int interpolation = cv::INTER_AREA) {
    if (scale >= 1)
        return x;
    cv::Mat y;
    cv::resize(x, y, cv::Size(), scale, scale, interpolation);
    return y;
}
NSString *stringFromUTF32(const std::u32string &text) {
    if (text.empty())
        return @"";
    return [[NSString alloc] initWithBytes:text.data()
                                    length:text.size() * 4
                                  encoding:NSUTF32LittleEndianStringEncoding];
}
std::u32string utf32(NSString *s) {
    if (!s)
        return {};
    NSData *data = [s dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    std::u32string value(data.length / 4, 0);
    if (data.length)
        memcpy(value.data(), data.bytes, data.length);
    return value;
}
std::u32string normalize(const std::u32string &text) {
    NSString *s = stringFromUTF32(text);
    if (!s)
        throw std::invalid_argument("Invalid source Unicode");
    return utf32([s precomposedStringWithCanonicalMapping]);
}
bool member(NSCharacterSet *s, char32_t c) {
    return [s longCharacterIsMember:static_cast<UTF32Char>(c)];
}
bool whitespace(char32_t c) {
    return member(NSCharacterSet.whitespaceAndNewlineCharacterSet, c) || (c >= 0x1c && c <= 0x1f);
}
bool mark(char32_t c) {
    return member(NSCharacterSet.nonBaseCharacterSet, c);
}
bool control(char32_t c) {
    return member(NSCharacterSet.controlCharacterSet, c) || member(NSCharacterSet.illegalCharacterSet, c) ||
           (c >= 0xe000 && c <= 0xf8ff) || (c >= 0xf0000 && c <= 0xffffd) || (c >= 0x100000 && c <= 0x10fffd);
}
bool punctuation(char32_t c) {
    return member(NSCharacterSet.punctuationCharacterSet, c);
}
bool symbol(char32_t c) {
    return member(NSCharacterSet.symbolCharacterSet, c);
}
bool number(char32_t c) {
    return member(NSCharacterSet.decimalDigitCharacterSet, c) ||
           (member(NSCharacterSet.alphanumericCharacterSet, c) &&
            !member(NSCharacterSet.letterCharacterSet, c) && !mark(c));
}
bool smallKana(char32_t c, bool extended = false) {
    const std::u32string a = extended ? U"ぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶ"
                                      : U"ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮ";
    return a.find(c) != std::u32string::npos;
}
bool han(char32_t c) {
    return (c >= 0x3400 && c <= 0x9fff) || (c >= 0xf900 && c <= 0xfaff) || (c >= 0x20000 && c <= 0x2fa1f);
}
bool kana(char32_t c) {
    return (c >= 0x3040 && c <= 0x30ff) || (c >= 0xff65 && c <= 0xff9f);
}

struct Glyph {
    cv::Mat raw, bitmap;
    std::array<double, 6> metrics{};
    double area = 0;
};
class Glyphs {
    const SourceGlyphRasterizer &rasterize;
    std::map<std::pair<std::string, char32_t>, Glyph> cache;

  public:
    explicit Glyphs(const SourceGlyphRasterizer &r) : rasterize(r) {}
    const Glyph &get(const std::string &font, char32_t c) {
        auto key = std::make_pair(font, c);
        auto found = cache.find(key);
        if (found != cache.end())
            return found->second;
        Glyph g;
        g.raw = rasterize(font, c);
        if (!g.raw.empty()) {
            if (g.raw.type() != CV_8UC1)
                throw std::invalid_argument("Glyph rasterizer must return raw L8");
            g.raw = g.raw.clone();
            g.bitmap = sourceGlyphBitmap(g.raw);
            g.metrics = sourceGlyphMetrics(g.raw);
            g.area = cv::sum(g.raw)[0] / 255. / (kEm * kEm);
        }
        return cache.emplace(std::move(key), std::move(g)).first->second;
    }
};
std::vector<char32_t> anchors(const std::u32string &text, const std::string &font, int limit,
                              bool excludeSmall, Glyphs &glyphs) {
    std::set<char32_t> chars(text.begin(), text.end());
    std::vector<std::pair<double, char32_t>> candidates;
    for (char32_t c : chars) {
        if (whitespace(c) || mark(c) || control(c) || punctuation(c) || symbol(c) ||
            (excludeSmall && smallKana(c)))
            continue;
        double size = glyphs.get(font, c).metrics[4];
        if (size > .05)
            candidates.emplace_back(size, c);
    }
    std::sort(candidates.begin(), candidates.end(),
              [](auto a, auto b) { return a.first != b.first ? a.first > b.first : a.second < b.second; });
    std::vector<char32_t> out;
    for (size_t i = 0; i < std::min(candidates.size(), size_t(limit)); i++)
        out.push_back(candidates[i].second);
    return out;
}
cv::Mat transformed(const cv::Mat &bitmap, double unit, double factor, double aspect = 1.,
                    double angle = 0.) {
    int w = std::max(2, pyRound(bitmap.cols * unit * factor * aspect / kEm)),
        h = std::max(2, pyRound(bitmap.rows * unit * factor / kEm));
    cv::Mat small, ink;
    cv::resize(bitmap, small, {w, h}, 0, 0, cv::INTER_AREA);
    ink.create(h, w, CV_32F);
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            ink.at<float>(y, x) = float(small.at<uint8_t>(y, x)) / 255.f;
    if (angle != 0) {
        cv::Mat m = cv::getRotationMatrix2D({(w - 1) / 2.f, (h - 1) / 2.f}, angle, 1.);
        double co = std::abs(m.at<double>(0, 0)), si = std::abs(m.at<double>(0, 1));
        int nw = std::ceil(w * co + h * si), nh = std::ceil(h * co + w * si);
        m.at<double>(0, 2) += (nw - w) / 2.;
        m.at<double>(1, 2) += (nh - h) / 2.;
        cv::warpAffine(ink, small, m, {nw, nh}, cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar(0));
        return small;
    }
    return ink;
}
struct Match {
    double score = -1, factor = 0;
    cv::Point location;
    cv::Size size;
    int mask = 0;
    bool valid = false;
};
Match bestMatch(const cv::Mat &mask, const cv::Mat &bitmap, double unit, double factor, double aspect = 1.,
                double angle = 0.) {
    cv::Mat ink = transformed(bitmap, unit, factor, aspect, angle);
    int pad = std::max(1, pyRound(unit * factor * .04));
    cv::Mat pattern = padded(ink, pad), target = padded(mask, pad);
    cv::Scalar m, s;
    cv::meanStdDev(pattern, m, s);
    if (s[0] < 1e-5 || pattern.rows > target.rows || pattern.cols > target.cols)
        return {};
    cv::Mat corr;
    cv::matchTemplate(target, pattern, corr, cv::TM_CCOEFF_NORMED);
    bool finite = false;
    for (int y = 0; y < corr.rows; y++)
        for (int x = 0; x < corr.cols; x++) {
            float &value = corr.at<float>(y, x);
            if (!std::isfinite(value))
                value = -1;
            else
                finite = true;
        }
    if (!finite)
        return {};
    Match out;
    cv::minMaxLoc(corr, nullptr, &out.score, nullptr, &out.location);
    out.factor = factor;
    out.size = ink.size();
    out.valid = true;
    return out;
}
struct Refined {
    double score, factor, margin;
};
Refined summarizeMatches(const std::vector<std::pair<double, double>> &matches) {
    double best = -1;
    for (auto p : matches)
        best = std::max(best, p.first);
    Vec ties, lower;
    for (auto p : matches) {
        if (std::abs(p.first - best) <= 1e-7)
            ties.push_back(std::log(p.second));
        else
            lower.push_back(p.first);
    }
    return {best, std::exp(ftMean(ties)),
            lower.empty() ? 0 : best - *std::max_element(lower.begin(), lower.end())};
}
Refined refine(const cv::Mat &mask, const cv::Mat &bitmap, double unit, const Match &coarse,
               bool affine = false) {
    int radius = std::max(2, pyRound(unit * .2)), l = std::max(0, coarse.location.x - radius),
        t = std::max(0, coarse.location.y - radius);
    int r = std::min(mask.cols, coarse.location.x + coarse.size.width + radius),
        b = std::min(mask.rows, coarse.location.y + coarse.size.height + radius);
    if (l >= r || t >= b)
        return {coarse.score, coarse.factor, 0};
    cv::Mat local = mask(cv::Rect(l, t, r - l, b - t));
    Vec values = linspace(std::max(.4, coarse.factor - .1), std::min(1.5, coarse.factor + .1), 9);
    values.push_back(coarse.factor);
    values = uniqueSorted(values);
    std::vector<std::pair<double, double>> matches;
    for (double factor : values) {
        Match m = bestMatch(local, bitmap, unit, factor);
        if (m.valid && m.score >= 0)
            matches.emplace_back(m.score, factor);
    }
    if (matches.empty())
        return {coarse.score, coarse.factor, 0};
    Refined out = summarizeMatches(matches);
    if (!affine)
        return out;
    values = linspace(std::max(.4, out.factor - .15), std::min(1.5, out.factor + .15), 9);
    values.push_back(out.factor);
    values = uniqueSorted(values);
    std::vector<std::tuple<double, double, double>> transforms;
    for (double aspect : {.8, .9, 1., 1.1, 1.2})
        for (double factor : values) {
            auto m = bestMatch(local, bitmap, unit, factor, aspect);
            if (m.valid && m.score >= 0)
                transforms.emplace_back(m.score, factor, aspect);
        }
    if (transforms.empty())
        return out;
    std::stable_sort(transforms.begin(), transforms.end(), [](auto a, auto b) {
        return std::make_tuple(-std::get<0>(a), std::abs(std::log(std::get<2>(a))), std::get<1>(a),
                               std::get<2>(a)) < std::make_tuple(-std::get<0>(b),
                                                                 std::abs(std::log(std::get<2>(b))),
                                                                 std::get<1>(b), std::get<2>(b));
    });
    double score = std::get<0>(transforms[0]), factor = std::get<1>(transforms[0]),
           aspect = std::get<2>(transforms[0]);
    std::vector<std::pair<double, double>> rotated;
    for (double angle : {-10., -5., 0., 5., 10.}) {
        auto m = bestMatch(local, bitmap, unit, factor, aspect, angle);
        if (m.valid && m.score >= 0)
            rotated.emplace_back(m.score, angle);
    }
    if (rotated.empty())
        return {score, factor, 0};
    std::stable_sort(rotated.begin(), rotated.end(), [](auto a, auto b) {
        return std::make_tuple(-a.first, std::abs(a.second), a.second) <
               std::make_tuple(-b.first, std::abs(b.second), b.second);
    });
    double angle = rotated[0].second;
    score = rotated[0].first;
    matches.clear();
    values = linspace(std::max(.4, factor - .04), std::min(1.5, factor + .04), 9);
    values.push_back(factor);
    values = uniqueSorted(values);
    for (double f : values) {
        auto m = bestMatch(local, bitmap, unit, f, aspect, angle);
        if (m.valid && m.score >= 0)
            matches.emplace_back(m.score, f);
    }
    return matches.empty() ? Refined{score, factor, 0} : summarizeMatches(matches);
}
Vec observations16(const std::vector<std::array<double, 4>> &rows) {
    if (rows.empty())
        return Vec(16, 0);
    Vec v;
    for (int col = 0; col < 4; col++) {
        Vec x;
        for (auto r : rows)
            x.push_back(r[col]);
        for (double q : {0., .5, 1.})
            v.push_back(ftQuantile(x, q));
    }
    size_t best = 0;
    for (size_t i = 1; i < rows.size(); i++)
        if (rows[i][1] > rows[best][1])
            best = i;
    v.insert(v.end(), rows[best].begin(), rows[best].end());
    return v;
}
std::vector<int> topFonts(const Vec &previous, int count = 8) {
    std::vector<int> ids(count);
    std::iota(ids.begin(), ids.end(), 0);
    std::stable_sort(ids.begin(), ids.end(),
                     [&](int a, int b) { return previous[a * 16 + 13] > previous[b * 16 + 13]; });
    ids.resize(2);
    return ids;
}
Vec nativeTemplates(const FontTemplateInputs &in, const cv::Mat &rgb, const cv::Mat &owned,
                    const cv::Rect2d &bbox, double prior, const std::u32string &text, int limit, int maxSide,
                    Glyphs &glyphs) {
    cv::Rect roi = ftTargetRect(rgb.size(), bbox);
    cv::Mat target = rgb(roi).clone(), own = owned(roi).clone();
    if (cv::countNonZero(own) == 0)
        return Vec(66, 0);
    target.setTo(cv::Scalar(127, 127, 127), own == 0);
    double scale = std::min(1., double(maxSide) / std::max(target.rows, target.cols));
    target = resizeBy(target, scale);
    if (scale < 1)
        cv::resize(own, own, target.size(), 0, 0, cv::INTER_NEAREST);
    if (cv::countNonZero(own) == 0)
        return Vec(66, 0);
    double unit = prior * scale;
    auto chars = anchors(text, in.fonts[0], limit, false, glyphs);
    cv::Mat gray;
    cv::cvtColor(target, gray, cv::COLOR_RGB2GRAY);
    Vec pixels;
    std::vector<uint8_t> samples;
    for (int y = 0; y < gray.rows; y++)
        for (int x = 0; x < gray.cols; x++)
            if (own.at<uint8_t>(y, x))
                samples.push_back(gray.at<uint8_t>(y, x));
    cv::Mat sample(samples), ignore;
    double cutoff = cv::threshold(sample, ignore, 0, 1, cv::THRESH_BINARY_INV | cv::THRESH_OTSU);
    cv::Mat dark = cv::Mat::zeros(gray.size(), CV_32F), pale = dark.clone();
    for (int y = 0; y < target.rows; y++)
        for (int x = 0; x < target.cols; x++)
            if (own.at<uint8_t>(y, x)) {
                auto p = target.at<cv::Vec3b>(y, x);
                int lo = std::min({p[0], p[1], p[2]}), hi = std::max({p[0], p[1], p[2]});
                dark.at<float>(y, x) = gray.at<uint8_t>(y, x) <= cutoff;
                pale.at<float>(y, x) = lo > 180 && hi - lo < 45;
            }
    std::array<cv::Mat, 2> masks{dark, pale};
    Vec values;
    for (const auto &font : in.fonts) {
        std::vector<std::array<double, 4>> obs;
        for (char32_t c : chars) {
            const auto &bitmap = glyphs.get(font, c).bitmap;
            if (bitmap.empty())
                continue;
            std::vector<Match> matches;
            for (double factor : kScales)
                for (int k = 0; k < 2; k++) {
                    auto m = bestMatch(masks[k], bitmap, unit, factor);
                    m.mask = k;
                    if (m.valid && m.score >= 0)
                        matches.push_back(m);
                }
            if (matches.empty())
                continue;
            std::stable_sort(matches.begin(), matches.end(), [](const Match &a, const Match &b) {
                return std::tie(a.score, a.factor, a.mask, a.location.x, a.location.y, a.size.width,
                                a.size.height) > std::tie(b.score, b.factor, b.mask, b.location.x,
                                                          b.location.y, b.size.width, b.size.height);
            });
            auto r = refine(masks[matches[0].mask], bitmap, unit, matches[0]);
            obs.push_back({r.factor, r.score, r.margin, double(r.factor == .4 || r.factor == 1.5)});
        }
        ftAppend(values, observations16(obs));
    }
    ftAppend(values, {double(!chars.empty()), double(chars.size()) / limit});
    return values;
}
struct PaintAlpha {
    cv::Mat alpha, best, good, binary, selected, nearby;
    bool palette = false;
};
PaintAlpha paintAlpha(const FontTemplateInputs &in) {
    PaintAlpha out;
    out.alpha = cv::Mat::zeros(in.rgb.size(), CV_64F);
    out.best = cv::Mat(in.rgb.size(), CV_64F, cv::Scalar(1e9));
    std::vector<cv::Vec3d> palette;
    for (const auto *part : {&in.style.outline, &in.style.background, &in.style.shadow}) {
        if (part != &in.style.background && !part->present)
            continue;
        if (part->hasRGB)
            palette.push_back(part->rgb);
        if (part == &in.style.background)
            palette.insert(palette.end(), part->colors.begin(), part->colors.end());
    }
    for (const auto &color : palette) {
        cv::Vec3d delta = in.style.fill.rgb - color;
        if (cv::norm(delta) <= 35)
            continue;
        out.palette = true;
        double denominator = delta.dot(delta);
        for (int y = 0; y < in.rgb.rows; y++)
            for (int x = 0; x < in.rgb.cols; x++) {
                cv::Vec3b p = in.rgb.at<cv::Vec3b>(y, x);
                cv::Vec3d pixel(p[0], p[1], p[2]);
                double t = clamp((pixel - color).dot(delta) / denominator, 0, 1);
                double res = cv::norm(pixel - (color + t * delta));
                if (res < out.best.at<double>(y, x)) {
                    out.best.at<double>(y, x) = res;
                    out.alpha.at<double>(y, x) = t;
                }
            }
    }
    out.good = (out.best < 22) & (in.ownership != 0);
    out.binary = (out.alpha > .5) & out.good;
    out.binary /= 255;
    cv::Mat labels, stats, centers;
    int n = cv::connectedComponentsWithStats(out.binary, labels, stats, centers, 8);
    std::vector<int> overlaps(n, 0);
    auto roi = ftTargetRect(in.rgb.size(), in.bbox);
    for (int y = roi.y; y < roi.y + roi.height; y++)
        for (int x = roi.x; x < roi.x + roi.width; x++)
            overlaps[labels.at<int>(y, x)]++;
    std::vector<bool> allowed(n, false);
    for (int i = 1; i < n; i++)
        allowed[i] = stats.at<int>(i, cv::CC_STAT_AREA) >= 2 &&
                     double(overlaps[i]) / std::max(1, stats.at<int>(i, cv::CC_STAT_AREA)) >= .3;
    out.selected = cv::Mat::zeros(in.rgb.size(), CV_8U);
    for (int y = 0; y < labels.rows; y++)
        for (int x = 0; x < labels.cols; x++)
            out.selected.at<uint8_t>(y, x) = allowed[labels.at<int>(y, x)];
    cv::dilate(out.selected, out.nearby, cv::Mat::ones(3, 3, CV_8U));
    for (int y = 0; y < labels.rows; y++)
        for (int x = 0; x < labels.cols; x++)
            if (!out.good.at<uint8_t>(y, x) || !out.nearby.at<uint8_t>(y, x))
                out.alpha.at<double>(y, x) = 0;
    return out;
}
Vec paintFeatures(const FontTemplateInputs &in, const std::u32string &text, const PaintAlpha &paint,
                  Glyphs &glyphs) {
    if (!paint.palette)
        return Vec(40, 0);
    std::array<double, 4> area{cv::sum(paint.alpha)[0], 0, 0, 0};
    double ownCount = cv::countNonZero(in.ownership), goodCount = 0, alphaOwn = 0;
    for (int y = 0; y < in.rgb.rows; y++)
        for (int x = 0; x < in.rgb.cols; x++) {
            double alpha = paint.alpha.at<double>(y, x);
            bool good = paint.good.at<uint8_t>(y, x) != 0, near = paint.nearby.at<uint8_t>(y, x) != 0;
            area[1] += paint.binary.at<uint8_t>(y, x) && paint.selected.at<uint8_t>(y, x);
            area[2] += alpha > .2 && good && near;
            area[3] += alpha > .8 && good && near;
            if (in.ownership.at<uint8_t>(y, x)) {
                goodCount += paint.best.at<double>(y, x) < 22;
                alphaOwn += alpha;
            }
        }
    std::vector<char32_t> chars;
    for (char32_t c : text)
        if (!whitespace(c))
            chars.push_back(c);
    Vec values, coverage;
    for (const auto &font : in.extendedFonts) {
        double total = 0, count = 0;
        for (char32_t c : chars) {
            double a = glyphs.get(font, c).area;
            total += a;
            count += a > 0;
        }
        coverage.push_back(count / std::max(1., double(chars.size())));
        for (double a : area)
            values.push_back(
                std::log(std::max(1e-5, total > 0 ? std::sqrt(a / std::max(1e-8, total)) / in.prior : 0.)));
    }
    ftAppend(values,
             {std::log1p(chars.size()), ftMean(coverage), *std::min_element(coverage.begin(), coverage.end()),
              ownCount / in.rgb.total(), ownCount ? goodCount / ownCount : 0,
              ownCount ? alphaOwn / ownCount : 0,
              cv::norm(in.style.fill.rgb - in.style.background.rgb) / 442., area[1] / std::max(1., area[0])});
    return values;
}
struct Pose {
    cv::Mat image;
    cv::Rect2d bbox;
};
Pose rotated(const cv::Mat &image, const cv::Rect2d &bbox, double angle, bool nearest = false,
             cv::Scalar border = cv::Scalar(0)) {
    int h = image.rows, w = image.cols;
    cv::Mat m = cv::getRotationMatrix2D({w / 2.f, h / 2.f}, angle, 1.);
    double co = std::abs(m.at<double>(0, 0)), si = std::abs(m.at<double>(0, 1));
    int nw = std::ceil(w * co + h * si), nh = std::ceil(h * co + w * si);
    m.at<double>(0, 2) += (nw - w) / 2.;
    m.at<double>(1, 2) += (nh - h) / 2.;
    cv::Mat output;
    cv::warpAffine(image, output, m, {nw, nh}, nearest ? cv::INTER_NEAREST : cv::INTER_LINEAR,
                   cv::BORDER_CONSTANT, border);
    std::vector<cv::Point2d> p{{bbox.x, bbox.y},
                               {bbox.x + bbox.width, bbox.y},
                               {bbox.x + bbox.width, bbox.y + bbox.height},
                               {bbox.x, bbox.y + bbox.height}};
    double l = 1e30, t = 1e30, r = -1e30, b = -1e30;
    for (auto v : p) {
        double x = m.at<double>(0, 0) * v.x + m.at<double>(0, 1) * v.y + m.at<double>(0, 2),
               y = m.at<double>(1, 0) * v.x + m.at<double>(1, 1) * v.y + m.at<double>(1, 2);
        l = std::min(l, x);
        t = std::min(t, y);
        r = std::max(r, x);
        b = std::max(b, y);
    }
    return {output, {l, t, r - l, b - t}};
}
struct AlphaTarget {
    cv::Mat image;
    double unit, scale;
};
AlphaTarget alphaTarget(const cv::Mat &alpha, const cv::Rect2d &bbox, double prior, double angle = 0,
                        bool complete = false) {
    Pose p{alpha, bbox};
    if (std::abs(angle) > .1)
        p = rotated(alpha, bbox, angle);
    cv::Mat target = complete ? p.image : p.image(ftTargetRect(p.image.size(), p.bbox));
    double scale = std::min(1., 1600. / std::max(target.rows, target.cols));
    return {resizeBy(target, scale), prior * scale, scale};
}
Vec fillTemplates(const cv::Mat &alpha, double unit, double originalPrior, double orientedPrior,
                  const std::u32string &text, const std::vector<std::string> &fonts,
                  const std::string &reference, Glyphs &glyphs, const Vec *previous = nullptr) {
    auto chars = anchors(text, reference, 2, false, glyphs);
    Vec values;
    std::vector<int> selected = previous ? topFonts(*previous) : std::vector<int>{};
    for (size_t index = 0; index < fonts.size(); index++) {
        if (previous && (std::find(selected.begin(), selected.end(), index) == selected.end() ||
                         (*previous)[index * 16 + 13] < .35)) {
            values.insert(values.end(), previous->begin() + index * 16, previous->begin() + index * 16 + 16);
            continue;
        }
        std::vector<std::array<double, 4>> obs;
        for (char32_t c : chars) {
            const auto &bitmap = glyphs.get(fonts[index], c).bitmap;
            if (bitmap.empty())
                continue;
            Match coarse;
            for (double factor : kScales) {
                auto m = bestMatch(alpha, bitmap, unit, factor);
                if (m.valid && m.score >= 0 && (!coarse.valid || m.score > coarse.score))
                    coarse = m;
            }
            if (!coarse.valid)
                continue;
            auto r = refine(alpha, bitmap, unit, coarse, previous != nullptr);
            obs.push_back({r.factor * orientedPrior / originalPrior, r.score, r.margin,
                           double(r.factor <= .4 || r.factor >= 1.5)});
        }
        ftAppend(values, observations16(obs));
    }
    ftAppend(values, {double(!chars.empty()), chars.size() / 2.});
    return values;
}
struct LocalMatch {
    double score;
    cv::Rect box;
};
std::vector<LocalMatch> localMatches(const cv::Mat &alpha, const cv::Mat &bitmap, double unit, double factor,
                                     double aspect) {
    cv::Mat ink = transformed(bitmap, unit, factor, aspect);
    int pad = std::max(1, pyRound(unit * factor * .04));
    cv::Mat pattern = padded(ink, pad), target = padded(alpha, pad);
    cv::Scalar m, s;
    cv::meanStdDev(pattern, m, s);
    if (s[0] < 1e-5 || pattern.rows > target.rows || pattern.cols > target.cols)
        return {};
    cv::Mat corr;
    cv::matchTemplate(target, pattern, corr, cv::TM_CCOEFF_NORMED);
    for (int y = 0; y < corr.rows; y++)
        for (int x = 0; x < corr.cols; x++)
            if (!std::isfinite(corr.at<float>(y, x)))
                corr.at<float>(y, x) = -1;
    std::vector<LocalMatch> values;
    for (int i = 0; i < 3; i++) {
        double score;
        cv::Point p;
        cv::minMaxLoc(corr, nullptr, &score, nullptr, &p);
        if (score <= 0)
            break;
        values.push_back({score, {p.x, p.y, ink.cols, ink.rows}});
        int rx = std::max(1, pyRound(ink.cols * .6)), ry = std::max(1, pyRound(ink.rows * .6));
        int l = std::max(0, p.x - rx), t = std::max(0, p.y - ry), r = std::min(corr.cols, p.x + rx + 1),
            b = std::min(corr.rows, p.y + ry + 1);
        corr(cv::Rect(l, t, r - l, b - t)).setTo(-1);
    }
    return values;
}
bool collides(const cv::Rect &a, const cv::Rect &b) {
    return double((a & b).area()) / std::max(1, std::min(a.area(), b.area())) > .2;
}
std::array<double, 4> assignment(const std::vector<std::vector<LocalMatch>> &matches) {
    struct State {
        Vec scores;
        std::vector<cv::Rect> boxes;
    };
    std::vector<State> beam(1);
    for (const auto &options : matches) {
        std::vector<State> candidates;
        for (const auto &state : beam) {
            auto skip = state;
            skip.scores.push_back(0);
            candidates.push_back(std::move(skip));
            for (auto option : options) {
                bool collision = false;
                for (const auto &box : state.boxes)
                    if (collides(option.box, box)) {
                        collision = true;
                        break;
                    }
                if (collision)
                    continue;
                auto next = state;
                next.scores.push_back(option.score);
                next.boxes.push_back(option.box);
                candidates.push_back(std::move(next));
            }
        }
        std::stable_sort(candidates.begin(), candidates.end(), [](const State &a, const State &b) {
            return std::accumulate(a.scores.begin(), a.scores.end(), 0.) >
                   std::accumulate(b.scores.begin(), b.scores.end(), 0.);
        });
        if (candidates.size() > 12)
            candidates.resize(12);
        beam = std::move(candidates);
    }
    Vec scores = beam[0].scores;
    std::sort(scores.begin(), scores.end());
    double strict = ftMean(scores), trim = strict;
    if (scores.size() >= 3)
        trim = ftMean(Vec(scores.begin() + 1, scores.end()));
    Vec independent;
    for (auto &options : matches)
        independent.push_back(options.empty() ? 0 : options[0].score);
    double count = 0;
    for (double s : scores)
        count += s != 0;
    return {strict, trim, ftMean(independent) - strict, count / std::max(1., double(scores.size()))};
}
Vec jointTemplates(const cv::Mat &alpha, double unit, double prior, double orientedPrior,
                   const std::u32string &text, const FontTemplateInputs &in, const Vec &previous,
                   Glyphs &glyphs) {
    auto chars = anchors(text, in.fonts[0], 4, true, glyphs);
    auto indices = topFonts(previous);
    Vec values;
    for (int index : indices) {
        std::vector<cv::Mat> bitmaps;
        for (char32_t c : chars) {
            auto b = glyphs.get(in.extendedFonts[index], c).bitmap;
            if (!b.empty())
                bitmaps.push_back(b);
        }
        if (bitmaps.empty()) {
            ftAppend(values, Vec(24, 0));
            continue;
        }
        double centre = clamp(previous[index * 16 + 12] * prior / orientedPrior, .5, 1.6);
        Vec scales;
        for (int k = 0;; k++) {
            double f = .5 + .08 * k;
            if (f >= 1.601)
                break;
            scales.push_back(f);
        }
        scales.push_back(centre);
        scales = uniqueSorted(scales);
        using Obs = std::array<double, 6>;
        std::vector<Obs> observations;
        auto observe = [&](double factor, double aspect) {
            std::vector<std::vector<LocalMatch>> matches;
            for (const auto &b : bitmaps)
                matches.push_back(localMatches(alpha, b, unit, factor, aspect));
            auto a = assignment(matches);
            return Obs{factor, aspect, a[0], a[1], a[2], a[3]};
        };
        for (double aspect : {.85, 1., 1.15})
            for (double factor : scales)
                observations.push_back(observe(factor, aspect));
        auto initial = observations;
        for (int kind : {2, 3}) {
            size_t best = 0;
            for (size_t i = 1; i < initial.size(); i++)
                if (initial[i][kind] > initial[best][kind])
                    best = i;
            auto top = initial[best];
            double low = std::max(.4, top[0] - .08), high = std::min(1.8, top[0] + .08) + .001;
            for (int k = 0;; k++) {
                double factor = low + .02 * k;
                if (factor >= high)
                    break;
                observations.push_back(observe(factor, top[1]));
            }
        }
        for (int kind : {2, 3}) {
            double peak = -1;
            for (auto row : observations)
                peak = std::max(peak, row[kind]);
            size_t chosen = 0;
            double preference = 1e30;
            for (size_t i = 0; i < observations.size(); i++)
                if (observations[i][kind] >= peak - 1e-7) {
                    double p = std::abs(observations[i][1] - 1);
                    if (p < preference) {
                        chosen = i;
                        preference = p;
                    }
                }
            auto top = observations[chosen];
            double near = -1, low = 1e30, high = -1e30, weightSum = 0, weighted = 0;
            for (auto row : observations) {
                if (std::abs(row[0] - top[0]) > .06)
                    near = std::max(near, row[kind]);
                if (row[kind] >= peak - .02) {
                    low = std::min(low, row[0]);
                    high = std::max(high, row[0]);
                }
                double w = std::exp((row[kind] - peak) / .03);
                weightSum += w;
                weighted += w * row[0];
            }
            double avg = weighted / weightSum, var = 0;
            for (auto row : observations)
                var += std::exp((row[kind] - peak) / .03) * (row[0] - avg) * (row[0] - avg);
            double ratio = orientedPrior / prior;
            ftAppend(values, {top[0] * ratio, avg * ratio, top[1], peak, near < 0 ? 0 : peak - near,
                              std::sqrt(var / weightSum) * ratio, low * ratio, high * ratio, top[4], top[5],
                              bitmaps.size() / 4., double(top[0] < .52 || top[0] > 1.55)});
        }
    }
    return values;
}
Vec moments(const cv::Mat &image, double unit) {
    cv::Mat a;
    image.convertTo(a, CV_64F);
    int h = a.rows, w = a.cols;
    double mass = std::max(1e-7, cv::sum(a)[0]);
    double cx = 0, cy = 0;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            double v = a.at<double>(y, x);
            cx += v * (x - (w - 1) / 2.);
            cy += v * (y - (h - 1) / 2.);
        }
    cx /= mass;
    cy /= mass;
    cv::Mat binary = (a > .5);
    binary /= 255;
    std::vector<cv::Point> positions;
    cv::findNonZero(binary, positions);
    cv::Rect bound = positions.empty() ? cv::Rect() : cv::boundingRect(positions);
    cv::Mat labels;
    int n = cv::connectedComponents(binary, labels, 8);
    std::vector<std::vector<cv::Point>> contours;
    std::vector<cv::Vec4i> hierarchy;
    cv::findContours(binary.clone(), contours, hierarchy, cv::RETR_CCOMP, cv::CHAIN_APPROX_SIMPLE);
    double perimeter = 0, holes = 0, hullArea = 0;
    std::vector<cv::Point> points;
    for (size_t i = 0; i < contours.size(); i++) {
        perimeter += cv::arcLength(contours[i], true);
        holes += hierarchy[i][3] >= 0;
        points.insert(points.end(), contours[i].begin(), contours[i].end());
    }
    if (!points.empty()) {
        std::vector<cv::Point> hull;
        cv::convexHull(points, hull);
        hullArea = cv::contourArea(hull);
    }
    cv::Mat depth;
    cv::distanceTransform(binary, depth, cv::DIST_L2, 3);
    Vec positive;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            if (depth.at<float>(y, x) > 0)
                positive.push_back(depth.at<float>(y, x));
    double xx = 0, yy = 0, xy = 0, xxx = 0, yyy = 0, dxSum = 0, dySum = 0, rimMass = 0;
    int edge = std::max(1, pyRound(unit * .025));
    Vec grid(9, 0);
    std::array<int, 4> ys{0, 0, 0, h}, xs{0, 0, 0, w};
    for (int i = 1; i < 3; i++) {
        ys[i] = ys[i - 1] + h / 3 + (i - 1 < h % 3);
        xs[i] = xs[i - 1] + w / 3 + (i - 1 < w % 3);
    }
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            double v = a.at<double>(y, x), dx = x - (w - 1) / 2. - cx, dy = y - (h - 1) / 2. - cy;
            xx += v * dx * dx;
            yy += v * dy * dy;
            xy += v * dx * dy;
            xxx += v * dx * dx * dx;
            yyy += v * dy * dy * dy;
            if (x + 1 < w)
                dxSum += std::abs(a.at<double>(y, x + 1) - v);
            if (y + 1 < h)
                dySum += std::abs(a.at<double>(y + 1, x) - v);
            if (!(y >= edge && y < std::max(edge, h - edge) && x >= edge && x < std::max(edge, w - edge)))
                rimMass += v;
            int iy = y < ys[1] ? 0 : (y < ys[2] ? 1 : 2), ix = x < xs[1] ? 0 : (x < xs[2] ? 1 : 2);
            grid[iy * 3 + ix] += v / mass;
        }
    Vec out{mass / (unit * unit),
            bound.width / unit,
            bound.height / unit,
            cx / unit,
            cy / unit,
            xx / mass / (unit * unit),
            yy / mass / (unit * unit),
            xy / mass / (unit * unit),
            xxx / mass / std::pow(unit, 3),
            yyy / mass / std::pow(unit, 3),
            cv::countNonZero(binary) / (unit * unit),
            perimeter / unit,
            std::log1p(std::max(0, n - 1)),
            std::log1p(holes),
            mass / std::max(1, bound.area()),
            dxSum / unit,
            dySum / unit,
            hullArea / (unit * unit)};
    for (double q : {.25, .5, .75, .9})
        out.push_back(ftQuantile(positive, q) / unit);
    out.push_back(rimMass / mass);
    ftAppend(out, grid);
    return out;
}
Vec glyphStyle(const cv::Mat &alpha, const cv::Mat &observed, const std::vector<char32_t> &chars,
               const std::string &font, double em, Glyphs &glyphs) {
    std::vector<Vec> vectors;
    Vec weights;
    const std::vector<int> ratios{0, 1, 2, 10, 11, 14, 15, 16, 17, 18, 19, 20, 21};
    for (char32_t c : chars) {
        const auto &bitmap = glyphs.get(font, c).bitmap;
        if (bitmap.empty())
            continue;
        Match chosen;
        double aspect = 1;
        for (double a : {.9, 1., 1.1}) {
            auto m = bestMatch(alpha, bitmap, em, 1., a);
            if (m.valid && (!chosen.valid || std::make_pair(m.score, -std::abs(a - 1)) >
                                                 std::make_pair(chosen.score, -std::abs(aspect - 1)))) {
                chosen = m;
                aspect = a;
            }
        }
        if (!chosen.valid || chosen.score < .2)
            continue;
        cv::Mat ink = transformed(bitmap, em, 1., aspect);
        int pad = std::max(1, pyRound(em * .12));
        cv::Mat reference = padded(ink, pad), source = cv::Mat::zeros(reference.size(), CV_32F),
                valid = cv::Mat::zeros(reference.size(), CV_8U);
        int left = chosen.location.x - pad, top = chosen.location.y - pad, l = std::max(0, left),
            t = std::max(0, top), r = std::min(alpha.cols, left + reference.cols),
            b = std::min(alpha.rows, top + reference.rows);
        if (l >= r || t >= b)
            continue;
        alpha(cv::Rect(l, t, r - l, b - t)).copyTo(source(cv::Rect(l - left, t - top, r - l, b - t)));
        observed(cv::Rect(l, t, r - l, b - t)).copyTo(valid(cv::Rect(l - left, t - top, r - l, b - t)));
        double fraction = double(cv::countNonZero(valid)) / valid.total();
        if (fraction < .9)
            continue;
        cv::Mat binary = (source > .5);
        binary /= 255;
        cv::Mat labels, stats, centers;
        int n = cv::connectedComponentsWithStats(binary, labels, stats, centers, 8);
        std::vector<int> overlap(n, 0);
        for (int y = pad; y < pad + ink.rows; y++)
            for (int x = pad; x < pad + ink.cols; x++)
                overlap[labels.at<int>(y, x)]++;
        std::vector<bool> keep(n, false);
        for (int i = 1; i < n; i++)
            keep[i] = double(overlap[i]) / std::max(1, stats.at<int>(i, cv::CC_STAT_AREA)) >= .3;
        cv::Mat support = cv::Mat::zeros(source.size(), CV_8U);
        for (int y = 0; y < source.rows; y++)
            for (int x = 0; x < source.cols; x++)
                support.at<uint8_t>(y, x) = keep[labels.at<int>(y, x)];
        cv::dilate(support, support, cv::Mat::ones(3, 3, CV_8U));
        source.setTo(0, (support == 0) | (valid == 0));
        if (cv::sum(source)[0] < 1)
            continue;
        Vec a = moments(source, em), ref = moments(reference, em), v;
        for (size_t i = 0; i < a.size(); i++)
            v.push_back(a[i] - ref[i]);
        for (int i : ratios)
            v.push_back(std::log(std::max(.0001, a[i]) / std::max(.0001, ref[i])));
        double positive = 0, negative = 0, squared = 0;
        for (int y = 0; y < source.rows; y++)
            for (int x = 0; x < source.cols; x++) {
                float delta = source.at<float>(y, x) - reference.at<float>(y, x);
                positive += std::max(0.f, delta);
                negative += std::max(0.f, -delta);
                squared += float(delta * delta);
            }
        double total = std::max(1., cv::sum(reference)[0]);
        ftAppend(v, {chosen.score, std::log(aspect), positive / total, negative / total,
                     std::sqrt(squared / source.total()), fraction});
        vectors.push_back(v);
        weights.push_back(std::pow(chosen.score, 4));
    }
    if (vectors.empty())
        return Vec(258, 0);
    Vec out;
    for (double q : {.2, .5, .8})
        for (int j = 0; j < 51; j++) {
            Vec col;
            for (auto &v : vectors)
                col.push_back(v[j]);
            out.push_back(ftQuantile(col, q));
        }
    double weightSum = std::accumulate(weights.begin(), weights.end(), 0.);
    for (int j = 0; j < 51; j++) {
        double s = 0;
        for (size_t i = 0; i < vectors.size(); i++)
            s += vectors[i][j] * weights[i];
        out.push_back(s / weightSum);
    }
    for (int j = 0; j < 51; j++) {
        Vec col;
        for (auto &v : vectors)
            col.push_back(v[j]);
        out.push_back(ftStddev(col));
    }
    ftAppend(out, {vectors.size() / 4., std::pow(ftMean(weights), .25), std::log1p(chars.size())});
    return out;
}
Vec styleFeatures(const cv::Mat &alpha, const FontTemplateInputs &in, const std::u32string &text,
                  double angle, const Vec &native, Glyphs &glyphs) {
    cv::Mat value = alpha, observed = cv::Mat::ones(alpha.size(), CV_8U);
    if (std::abs(angle) > .1) {
        value = rotated(alpha, in.bbox, angle).image;
        observed = rotated(observed, in.bbox, angle, true).image;
    }
    double scale = std::min(1., 1600. / std::max(value.rows, value.cols));
    value = resizeBy(value, scale);
    if (scale < 1)
        cv::resize(observed, observed, value.size(), 0, 0, cv::INTER_NEAREST);
    int index = 0;
    for (int i = 1; i < 4; i++)
        if (native[i * 16 + 13] > native[index * 16 + 13])
            index = i;
    double em = native[index * 16 + 1] * in.prior * scale;
    auto chars = anchors(text, in.fonts[0], 4, true, glyphs);
    Vec result = em >= 2 && native[index * 16 + 13] > .2
                     ? glyphStyle(value, observed, chars, in.nativeFonts[index], em, glyphs)
                     : Vec(258, 0);
    for (int i = 0; i < 4; i++)
        result.push_back(result[255] > 0 && i == index ? 1 : 0);
    return result;
}
struct Geometry {
    Vec features, physical;
    double angle = 0;
    bool requested = false;
};
Geometry geometry(const FontTemplateInputs &in) {
    std::vector<std::vector<cv::Point2f>> polygons = in.memberPolygons;
    if (polygons.empty()) {
        auto b = in.bbox;
        polygons = {{{float(b.x), float(b.y)},
                     {float(b.x + b.width), float(b.y)},
                     {float(b.x + b.width), float(b.y + b.height)},
                     {float(b.x), float(b.y + b.height)}}};
    }
    Vec widths, lengths, aabbs, tilts;
    cv::RotatedRect selected;
    double longest = -1;
    for (const auto &polygon : polygons) {
        if (polygon.size() < 3)
            continue;
        auto rect = cv::minAreaRect(polygon);
        double a = std::min(rect.size.width, rect.size.height),
               b = std::max(rect.size.width, rect.size.height);
        if (a < .01)
            continue;
        cv::Point2f v[4];
        rect.points(v);
        cv::Point2f edge;
        double maxLength = -1;
        for (int i = 0; i < 4; i++) {
            auto e = v[(i + 1) % 4] - v[i];
            double length = cv::norm(e);
            if (length > maxLength) {
                maxLength = length;
                edge = e;
            }
        }
        tilts.push_back(std::abs(std::sin(2 * std::atan2(edge.y, edge.x))));
        widths.push_back(a);
        lengths.push_back(b);
        double l = 1e30, t = 1e30, r = -1e30, d = -1e30;
        for (auto p : polygon) {
            l = std::min(l, double(p.x));
            t = std::min(t, double(p.y));
            r = std::max(r, double(p.x));
            d = std::max(d, double(p.y));
        }
        aabbs.push_back(std::max(.01, std::min(r - l, d - t)));
        if (b > longest) {
            longest = b;
            selected = rect;
        }
    }
    if (widths.empty()) {
        widths = {in.prior};
        lengths = {in.prior};
        aabbs = {in.prior};
        tilts = {0};
    }
    std::vector<size_t> order(widths.size());
    std::iota(order.begin(), order.end(), 0);
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) { return widths[a] < widths[b]; });
    Vec weights;
    for (size_t i = 0; i < widths.size(); i++)
        weights.push_back(clamp(lengths[i] / widths[i], 1, 30));
    double half = std::accumulate(weights.begin(), weights.end(), 0.) / 2, acc = 0,
           weighted = widths[order.back()];
    for (size_t i : order) {
        acc += weights[i];
        if (acc >= half) {
            weighted = widths[i];
            break;
        }
    }
    double ow = in.style.outline.present ? in.style.outline.widthPx : 0;
    Geometry out;
    for (double q : {0., .1, .25, .5, .75, .9, 1.})
        out.physical.push_back(ftQuantile(widths, q));
    out.physical.push_back(weighted);
    for (int k : {1, 2, 3})
        out.physical.push_back(std::max(1., weighted - k * ow));
    for (int k : {1, 2, 3})
        out.physical.push_back(std::max(1., ftQuantile(widths, .5) - k * ow));
    for (double v : out.physical)
        out.features.push_back(std::log(std::max(1., v) / in.prior));
    Vec ratio, aspect;
    for (size_t i = 0; i < widths.size(); i++) {
        ratio.push_back(aabbs[i] / widths[i]);
        aspect.push_back(lengths[i] / widths[i]);
    }
    for (double q : {0., .25, .5, .75, 1.})
        out.features.push_back(ftQuantile(ratio, q));
    for (double q : {.1, .5, .9})
        out.features.push_back(ftQuantile(aspect, q));
    for (double q : {0., .5, 1.})
        out.features.push_back(ftQuantile(tilts, q));
    ftAppend(out.features, {ftStddev(widths) / std::max(1., ftMean(widths)), std::log1p(widths.size()),
                            ow / in.prior, in.style.outline.probability, double(in.style.outline.present)});
    for (auto part : {in.style.fill, in.style.outline, in.style.background})
        for (int i = 0; i < 3; i++)
            out.features.push_back(part.hasRGB ? part.rgb[i] / 255. : 0);
    ftAppend(out.features, {cv::norm(in.style.fill.rgb - in.style.outline.rgb) / 442.,
                            cv::norm(in.style.fill.rgb - in.style.background.rgb) / 442.});
    for (double p : in.style.roleProbabilities)
        out.features.push_back(p);
    out.requested = !in.memberPolygons.empty() && in.prior / out.physical[3] >= 1.1;
    if (out.requested) {
        cv::Point2f v[4];
        selected.points(v);
        cv::Point2f edge;
        double maxLength = -1;
        for (int i = 0; i < 4; i++) {
            auto e = v[(i + 1) % 4] - v[i];
            double length = cv::norm(e);
            if (length > maxLength) {
                maxLength = length;
                edge = e;
            }
        }
        double angle = std::atan2(edge.y, edge.x) * 180 / CV_PI;
        out.angle = std::fmod(std::fmod(angle + 45, 90) + 90, 90) - 45;
    }
    return out;
}
Vec areaFeatures(const Vec &paint, const FontTemplateInputs &in, const std::u32string &text, Glyphs &glyphs) {
    std::vector<char32_t> chars;
    for (char32_t c : text)
        if (!whitespace(c))
            chars.push_back(c);
    double oldsum = 0, oldcount = 0;
    for (char32_t c : chars) {
        double a = glyphs.get(in.fonts[0], c).area;
        oldsum += a;
        oldcount += a > 0;
    }
    Vec out, coverage;
    for (const auto &font : in.nativeFonts) {
        double total = 0, count = 0;
        for (char32_t c : chars) {
            double a = glyphs.get(font, c).area;
            total += a;
            count += a > 0;
        }
        double factor = total > 0 && oldsum > 0 ? std::sqrt(oldsum / total) : 0;
        for (int i = 0; i < 4; i++)
            out.push_back(std::exp(paint[i]) * factor);
        coverage.push_back(count / std::max(1., double(chars.size())));
    }
    ftAppend(out, coverage);
    out.push_back(oldcount / std::max(1., double(chars.size())));
    return out;
}
Vec fontMetricsForFonts(const std::vector<std::string> &fonts, const std::u32string &text, const Vec &native, Glyphs &glyphs) {
    std::vector<char32_t> chars;
    for (char32_t c : text)
        if (!whitespace(c) && !mark(c) && !control(c))
            chars.push_back(c);
    Vec result, coverage;
    for (const auto &font : fonts) {
        std::vector<std::array<double, 6>> metrics;
        for (char32_t c : chars) {
            const auto &glyph = glyphs.get(font, c);
            if (!glyph.bitmap.empty())
                metrics.push_back(glyph.metrics);
        }
        coverage.push_back(double(metrics.size()) / std::max(1., double(chars.size())));
        if (metrics.empty()) {
            ftAppend(result, Vec(36, 0));
            continue;
        }
        std::array<std::array<double, 3>, 6> qs;
        for (int j = 0; j < 6; j++) {
            Vec col;
            for (auto m : metrics)
                col.push_back(m[j]);
            for (int q = 0; q < 3; q++) {
                qs[j][q] = ftQuantile(col, .25 + .25 * q);
                result.push_back(qs[j][q]);
            }
        }
        Vec expected;
        for (int j : {2, 3, 4})
            for (double v : qs[j])
                expected.push_back(v);
        for (int offset : {96, 120})
            for (int j = 0; j < 9; j++)
                result.push_back(expected[j] >= .03 ? clamp(native[offset + j] / expected[j], 0, 8) : 0);
    }
    ftAppend(result, {double(!chars.empty()), ftMean(coverage)});
    return result;
}
Vec fontMetrics(const FontTemplateInputs &in, const std::u32string &text, const Vec &native, Glyphs &glyphs) {
    return fontMetricsForFonts(in.fonts, text, native, glyphs);
}
Vec cachedRawFontMetrics(const SourceWeightRawInputs &in, const std::u32string &text, const Vec &native,
                         const SourceGlyphRasterizer &rasterize) {
    std::vector<char32_t> chars;
    for (char32_t c : text)
        if (!whitespace(c) && !mark(c) && !control(c)) chars.push_back(c);
    Vec result, coverage;
    for (const auto &font : in.fonts) {
        auto sha = in.authenticatedFontSHA256.find(font);
        if (sha == in.authenticatedFontSHA256.end() || sha->second.size() != 64)
            throw std::invalid_argument("Authenticated BASE4 content identity required before cache lookup");
        SourceWeightGlyphMetricsCache::Key key;
        auto nibble = [](char c) -> uint8_t {
            if (c >= '0' && c <= '9') return uint8_t(c - '0');
            if (c >= 'a' && c <= 'f') return uint8_t(c - 'a' + 10);
            throw std::invalid_argument("Invalid authenticated glyph content identity");
        };
        for (size_t j = 0; j < key.sha.size(); ++j)
            key.sha[j] = uint8_t(nibble(sha->second[2*j]) * 16 + nibble(sha->second[2*j+1]));
        auto face = in.fontFaceIndices.find(font);
        key.face = face == in.fontFaceIndices.end() ? 0 : uint32_t(face->second);
        auto weight = in.fontWeights.find(font); key.hasWeight = weight != in.fontWeights.end();
        if (key.hasWeight) std::memcpy(&key.weightBits, &weight->second, sizeof(key.weightBits));
        std::vector<std::array<double, 6>> metrics;
        std::vector<std::pair<SourceWeightGlyphMetricsCache::Key, SourceWeightGlyphMetricsCache::Value>> pending;
        for (char32_t c : chars) {
            key.codepoint = uint32_t(c);
            SourceWeightGlyphMetricsCache::Value value;
            if (!in.glyphMetricsCache->find(key, value)) {
                auto local = std::find_if(pending.begin(), pending.end(), [&](const auto &v) { return v.first == key; });
                if (local != pending.end()) value = local->second;
                else {
                    cv::Mat raw = rasterize(font, c);
                    if (!raw.empty()) {
                        if (raw.type() != CV_8UC1) throw std::invalid_argument("Glyph rasterizer must return raw L8");
                        value.metrics = sourceGlyphMetrics(raw);
                        // Preserve Glyphs' authoritative inclusion predicate,
                        // including supported but blank/under-threshold rasters.
                        // This bitmap is temporary and never enters the cache.
                        value.hasInk = !sourceGlyphBitmap(raw).empty();
                    }
                    pending.emplace_back(key, value);
                }
            }
            if (value.hasInk) metrics.push_back(value.metrics);
        }
        if (!pending.empty()) {
            auto path = in.fontFiles.find(font);
            if (path == in.fontFiles.end()) throw std::invalid_argument("BASE4 physical font path required");
            const auto digest = fontDigest(@(path->second.c_str()), true);
            for (size_t j = 0; j < key.sha.size(); ++j)
                if (digest[j] != key.sha[j]) throw std::invalid_argument("Pinned source font changed during glyph measurement");
            // Writable font bytes are read again after rasterization; the
            // corresponding digest on the read-only root is immutable.
            for (const auto &entry : pending) in.glyphMetricsCache->insert(entry.first, entry.second);
        }
        coverage.push_back(double(metrics.size()) / std::max(1., double(chars.size())));
        if (metrics.empty()) { ftAppend(result, Vec(36, 0)); continue; }
        std::array<std::array<double, 3>, 6> qs;
        for (int j = 0; j < 6; j++) {
            Vec col; for (auto m : metrics) col.push_back(m[j]);
            for (int q = 0; q < 3; q++) {
                qs[j][q] = ftQuantile(col, .25 + .25 * q); result.push_back(qs[j][q]);
            }
        }
        Vec expected;
        for (int j : {2, 3, 4}) for (double v : qs[j]) expected.push_back(v);
        // Always input-local; neither native measurements nor ratios are cached.
        for (int offset : {96, 120}) for (int j = 0; j < 9; j++)
            result.push_back(expected[j] >= .03 ? clamp(native[offset + j] / expected[j], 0, 8) : 0);
    }
    ftAppend(result, {double(!chars.empty()), ftMean(coverage)}); return result;
}
Vec technical(const FontTemplateInputs &in, const std::u32string &text) {
    std::vector<char32_t> chars;
    for (char32_t c : text)
        if (!whitespace(c) && !mark(c))
            chars.push_back(c);
    double total = std::max(1., double(chars.size()));
    std::array<double, 8> counts{};
    for (char32_t c : chars) {
        if (han(c))
            counts[0]++;
        else if (kana(c))
            counts[1]++;
        else if (c < 0x250 && member(NSCharacterSet.letterCharacterSet, c))
            counts[3]++;
        else if (number(c))
            counts[4]++;
        else if (punctuation(c))
            counts[5]++;
        else if (symbol(c))
            counts[7]++;
        counts[2] += smallKana(c, true);
        counts[6] += std::u32string(U".．。・･…⋯").find(c) != std::u32string::npos;
    }
    double effective = std::max(1., counts[0] + counts[1] - .5 * counts[2] + .5 * (counts[3] + counts[4]) +
                                        .3 * counts[5] + .5 * counts[7]);
    Vec out{std::log1p(chars.size())};
    for (double c : counts)
        out.push_back(c / total);
    double spaces = 0, newlines = 0, lines = 0;
    bool content = false;
    // Python splitlines recognizes these original source line boundaries.
    for (size_t i = 0; i < text.size(); i++) {
        char32_t c = text[i];
        spaces += whitespace(c);
        newlines += c == U'\n';
        bool boundary = c == U'\n' || c == U'\r' || c == U'\v' || c == U'\f' || (c >= 0x1c && c <= 0x1e) ||
                        c == 0x85 || c == 0x2028 || c == 0x2029;
        if (boundary) {
            if (content)
                lines++;
            content = false;
            if (c == U'\r' && i + 1 < text.size() && text[i + 1] == U'\n') {
                spaces++;
                newlines++;
                i++;
            }
        } else if (!whitespace(c))
            content = true;
    }
    if (content)
        lines++;
    bool valid = std::isfinite(in.confidence) && in.confidence >= 0 && in.confidence <= 1;
    double w = in.bbox.width, h = in.bbox.height, p = in.prior;
    ftAppend(out, {spaces / total, newlines, w / (p * effective), h / (p * effective),
                   std::sqrt(w * h / effective) / p, effective / (w * h / (p * p)), double(valid),
                   valid ? in.confidence : 0, std::log1p(lines)});
    return out;
}
Vec glyphBodyPixels(const cv::Mat &pixels, const cv::Rect2d &bbox, double prior, const cv::Mat &ownership) {
    double scale = std::min(1., 640. / std::max(pixels.rows, pixels.cols)), unit = prior * scale;
    cv::Mat rgb = resizeBy(pixels, scale), owned = ownership;
    if (scale < 1)
        cv::resize(owned, owned, rgb.size(), 0, 0, cv::INTER_NEAREST);
    cv::Rect2d target(bbox.x * scale, bbox.y * scale, bbox.width * scale, bbox.height * scale);
    auto belongs = [&](cv::Rect r) {
        cv::Rect2d rr(r.x, r.y, r.width, r.height);
        return (rr & target).area() >= .5 * r.area();
    };
    std::array<cv::Mat, 2> cores{cv::Mat::zeros(rgb.size(), CV_8U), cv::Mat::zeros(rgb.size(), CV_8U)};
    for (int y = 0; y < rgb.rows; y++)
        for (int x = 0; x < rgb.cols; x++) {
            auto p = rgb.at<cv::Vec3b>(y, x);
            int lo = std::min({p[0], p[1], p[2]}), hi = std::max({p[0], p[1], p[2]});
            cores[0].at<uint8_t>(y, x) = hi < 100;
            cores[1].at<uint8_t>(y, x) = lo > 180 && hi - lo < 45;
        }
    Vec result;
    for (const auto &core : cores) {
        cv::Mat binary;
        cv::bitwise_and(core, owned != 0, binary);
        cv::Mat labels, stats, centers;
        cv::connectedComponentsWithStats(binary, labels, stats, centers, 8);
        std::vector<std::array<double, 3>> components, holes;
        for (int i = 1; i < stats.rows; i++) {
            cv::Rect r(stats.at<int>(i, 0), stats.at<int>(i, 1), stats.at<int>(i, 2), stats.at<int>(i, 3));
            double area = stats.at<int>(i, 4);
            if (area >= std::max(3., unit * unit * .002) && area < binary.total() * .65 && belongs(r))
                components.push_back({r.height / scale, r.width / scale, std::sqrt(area) / scale});
        }
        std::vector<std::vector<cv::Point>> contours;
        std::vector<cv::Vec4i> hierarchy;
        cv::findContours(core.clone(), contours, hierarchy, cv::RETR_CCOMP, cv::CHAIN_APPROX_SIMPLE);
        for (size_t i = 0; i < contours.size(); i++) {
            int parent = hierarchy[i][3];
            if (parent < 0)
                continue;
            double area = cv::contourArea(contours[i]);
            auto r = cv::boundingRect(contours[i]);
            auto outer = cv::boundingRect(contours[parent]);
            if (area < std::max(3., unit * unit * .002) || area >= core.total() * .65 || !belongs(r))
                continue;
            cv::Mat region = cv::Mat::zeros(r.size(), CV_8U);
            std::vector<cv::Point> shifted;
            for (auto p : contours[i])
                shifted.emplace_back(p.x - r.x, p.y - r.y);
            cv::drawContours(region, std::vector<std::vector<cv::Point>>{shifted}, -1, cv::Scalar(1), -1);
            cv::Mat own = owned(r);
            double support = 0, count = 0;
            for (int y = 0; y < r.height; y++)
                for (int x = 0; x < r.width; x++)
                    if (region.at<uint8_t>(y, x)) {
                        count++;
                        support += own.at<uint8_t>(y, x) != 0;
                    }
            if (count == 0 || support / count < .5) {
                cv::Mat border = cv::Mat::zeros(outer.size(), CV_8U);
                shifted.clear();
                for (auto p : contours[parent])
                    shifted.emplace_back(p.x - outer.x, p.y - outer.y);
                cv::drawContours(border, std::vector<std::vector<cv::Point>>{shifted}, -1, cv::Scalar(1), 1);
                own = owned(outer);
                support = 0;
                count = 0;
                for (int y = 0; y < border.rows; y++)
                    for (int x = 0; x < border.cols; x++)
                        if (border.at<uint8_t>(y, x)) {
                            count++;
                            support += own.at<uint8_t>(y, x) != 0;
                        }
                if (count == 0 || support / count < .8)
                    continue;
            }
            holes.push_back({r.height / scale, r.width / scale, std::sqrt(area) / scale});
        }
        for (const auto &channel : {components, holes}) {
            if (channel.empty()) {
                ftAppend(result, Vec(14, 0));
                continue;
            }
            for (int j = 0; j < 3; j++) {
                Vec col;
                for (auto c : channel)
                    col.push_back(c[j]);
                for (double q : {.25, .5, .75, .95})
                    result.push_back(ftQuantile(col, q));
            }
            ftAppend(result, {double(channel.size()), 1});
        }
    }
    return result;
}
Vec glyphBody(const FontTemplateInputs &in) {
    return glyphBodyPixels(in.rgb, in.bbox, in.prior, in.ownership);
}
void validate(const FontTemplateInputs &in) {
    if (in.rgb.empty() || in.rgb.type() != CV_8UC3 || in.ownership.type() != CV_8UC1 ||
        in.ownership.size() != in.rgb.size())
        throw std::invalid_argument("Invalid RGB/ownership geometry");
    auto b = in.bbox;
    if (!std::isfinite(in.prior) || in.prior <= 0 || !std::isfinite(b.x) || !std::isfinite(b.y) ||
        !std::isfinite(b.width) || !std::isfinite(b.height) || b.width <= 0 || b.height <= 0)
        throw std::invalid_argument("Invalid source prior/bbox");
    if (b.x < 0 || b.y < 0 || b.x + b.width > in.rgb.cols + 1 || b.y + b.height > in.rgb.rows + 1 ||
        b.x > .15 * b.width + 1 || b.y > .15 * b.height + 1 ||
        in.rgb.cols - b.x - b.width > .15 * b.width + 1 || in.rgb.rows - b.y - b.height > .15 * b.height + 1)
        throw std::invalid_argument("Source crop exceeds per-side15percent context");
    if (in.fonts.size() != 4 || in.extendedFonts.size() != 8 || in.nativeFonts.size() != 4)
        throw std::invalid_argument("Expected pinned4/8/4 font banks");
    if (!in.style.fill.hasRGB || !in.style.background.hasRGB)
        throw std::invalid_argument("Source-predicted fill/background palette required");
    for (const auto *part : {&in.style.fill, &in.style.outline, &in.style.background, &in.style.shadow}) {
        if (!std::isfinite(part->widthPx) || part->widthPx < 0 || !std::isfinite(part->probability) ||
            part->probability < 0 || part->probability > 1)
            throw std::invalid_argument("Invalid source paint width/probability");
        auto validColor = [](const cv::Vec3d &color) {
            return std::all_of(color.val, color.val + 3,
                               [](double v) { return std::isfinite(v) && v >= 0 && v <= 255; });
        };
        if ((part->hasRGB && !validColor(part->rgb)) ||
            !std::all_of(part->colors.begin(), part->colors.end(), validColor))
            throw std::invalid_argument("Invalid source paint palette");
    }
    for (double probability : in.style.roleProbabilities)
        if (!std::isfinite(probability) || probability < 0 || probability > 1)
            throw std::invalid_argument("Invalid source paint role probability");
    if (!std::isfinite(in.normalizedCenter.x) || !std::isfinite(in.normalizedCenter.y) ||
        in.normalizedCenter.x < 0 || in.normalizedCenter.x > 1 || in.normalizedCenter.y < 0 ||
        in.normalizedCenter.y > 1)
        throw std::invalid_argument("Invalid normalized source center");
    for (int y = 0; y < in.ownership.rows; ++y)
        for (int x = 0; x < in.ownership.cols; ++x) {
            auto value = in.ownership.at<uint8_t>(y, x);
            if (value != 0 && value != 1 && value != 255)
                throw std::invalid_argument("Source ownership must be binary");
        }
    if (!in.native156.empty() &&
        (in.native156.size() != 156 ||
         !std::all_of(in.native156.begin(), in.native156.end(), [](double v) { return std::isfinite(v); })))
        throw std::invalid_argument("Invalid native156");
    for (const auto &polygon : in.memberPolygons) {
        if (polygon.size() < 3)
            throw std::invalid_argument("Invalid source member polygon");
        for (auto p : polygon)
            if (!std::isfinite(p.x) || !std::isfinite(p.y) || p.x < 0 || p.y < 0 || p.x > in.rgb.cols ||
                p.y > in.rgb.rows)
                throw std::invalid_argument("Source polygon outside bounded crop");
    }
}
} // anonymous namespace

cv::Mat sourceGlyphBitmap(const cv::Mat &raw) {
    if (raw.empty())
        return {};
    if (raw.type() != CV_8UC1)
        throw std::invalid_argument("Expected L8 glyph mask");
    std::vector<cv::Point> points;
    cv::findNonZero(raw >= 64, points);
    return points.empty() ? cv::Mat() : raw(cv::boundingRect(points)).clone();
}
std::array<double, 6> sourceGlyphMetrics(const cv::Mat &raw) {
    if (raw.empty())
        return {};
    cv::Mat binary = raw >= 64;
    std::vector<cv::Point> points;
    cv::findNonZero(binary, points);
    if (points.empty())
        return {};
    auto r = cv::boundingRect(points);
    double w = r.width / kEm, h = r.height / kEm, area = cv::countNonZero(binary) / (kEm * kEm);
    return {w, h, std::max(w, h), std::min(w, h), std::sqrt(area), area / (w * h)};
}
cv::Mat sourceFillAlpha(const FontTemplateInputs &input) {
    validate(input);
    cv::Mat alpha;
    paintAlpha(input).alpha.convertTo(alpha, CV_32F);
    return alpha;
}

FontTemplateSignals extractFontTemplateFeatures(const FontTemplateInputs &input,
                                                const SourceGlyphRasterizer &rasterize) {
    validate(input);
    if (!rasterize)
        throw std::invalid_argument("A native glyph rasterizer is required");
    FontTemplateInputs in = input;
    in.ownership = input.ownership != 0;
    in.ownership /= 255;
    auto text = normalize(in.text);
    Glyphs glyphs(rasterize);
    FontTemplateSignals out;
    Vec native = in.native156.empty() ? nativeFeatures(in.rgb, in.bbox, in.prior) : in.native156;
    out.arrays["native156"] = native;
    auto &arrays = out.arrays;
    arrays["fontMetrics146"] = fontMetrics(in, text, native, glyphs);
    arrays["technical18"] = technical(in, text);
    arrays["glyphBody56"] = glyphBody(in);
    arrays["legacyTemplate66"] =
        nativeTemplates(in, in.rgb, in.ownership, in.bbox, in.prior, text, 2, 480, glyphs);
    arrays["templates103"] =
        nativeTemplates(in, in.rgb, in.ownership, in.bbox, in.prior, text, 4, 1600, glyphs);
    std::array<std::u32string, 3> scripts;
    for (char32_t c : text) {
        if (smallKana(c, true))
            continue;
        if (kana(c))
            scripts[0].push_back(c);
        else if (han(c))
            scripts[1].push_back(c);
        else if (c < 0x250 && (member(NSCharacterSet.letterCharacterSet, c) ||
                               member(NSCharacterSet.decimalDigitCharacterSet, c)))
            scripts[2].push_back(c);
    }
    for (auto &script : scripts)
        ftAppend(arrays["templates115"],
                 nativeTemplates(in, in.rgb, in.ownership, in.bbox, in.prior, script, 2, 1600, glyphs));
    Geometry geom = geometry(in);
    arrays["geometry128"] = geom.features;
    arrays["physical128"] = geom.physical;
    out.angle131 = geom.angle;
    double oriented = geom.physical[3];
    out.priorRatio131 = geom.requested ? oriented / in.prior : 1.;
    arrays["templates131"] = arrays["templates103"];
    if (geom.requested) {
        auto p = rotated(in.rgb, in.bbox, geom.angle, false, cv::Scalar(127, 127, 127));
        auto own = rotated(in.ownership, in.bbox, geom.angle, true).image;
        arrays["templates131"] = nativeTemplates(in, p.image, own, p.bbox, oriented, text, 4, 1600, glyphs);
    }
    auto paint = paintAlpha(in);
    arrays["paint130"] = paintFeatures(in, text, paint, glyphs);
    cv::Mat alpha;
    paint.alpha.convertTo(alpha, CV_32F);
    auto local = alphaTarget(alpha, in.bbox, oriented);
    arrays["templates135"] = fillTemplates(local.image, local.unit, in.prior, oriented, text,
                                           in.extendedFonts, in.fonts[0], glyphs);
    local = alphaTarget(alpha, in.bbox, oriented, geom.angle);
    arrays["templates143"] = fillTemplates(local.image, local.unit, in.prior, oriented, text,
                                           in.extendedFonts, in.fonts[0], glyphs, &arrays["templates135"]);
    arrays["joint147"] =
        jointTemplates(local.image, local.unit, in.prior, oriented, text, in, arrays["templates143"], glyphs);
    double mass = cv::sum(alpha)[0], inside = cv::sum(alpha(ftTargetRect(alpha.size(), in.bbox)))[0];
    double outside = mass > 1e-6 ? std::max(0., 1 - inside / mass) : 0;
    out.remeasured158 = outside >= .01 && mass > 10;
    auto complete = alphaTarget(alpha, in.bbox, oriented, geom.angle, true);
    arrays["joint158"] = out.remeasured158 ? jointTemplates(complete.image, complete.unit, in.prior, oriented,
                                                            text, in, arrays["templates143"], glyphs)
                                           : arrays["joint147"];
    arrays["templates167"] = fillTemplates(complete.image, complete.unit, in.prior, oriented, text,
                                           in.nativeFonts, in.fonts[0], glyphs);
    arrays["areas169"] = areaFeatures(arrays["paint130"], in, text, glyphs);
    arrays["style187"] = styleFeatures(alpha, in, text, geom.angle, arrays["templates167"], glyphs);
    const std::array<std::string, 3> roles{"dialogue", "narration", "story_text"};
    Vec ce(291, 0);
    if (!text.empty() && std::isfinite(in.confidence) &&
        std::find(roles.begin(), roles.end(), in.role) != roles.end()) {
        ce.clear();
        ftAppend(ce, arrays["fontMetrics146"]);
        ftAppend(ce, arrays["technical18"]);
        ftAppend(ce, arrays["legacyTemplate66"]);
        for (auto &role : roles)
            ce.push_back(role == in.role);
        ftAppend(ce, arrays["glyphBody56"]);
        ftAppend(ce, {in.normalizedCenter.x, in.normalizedCenter.y});
    }
    arrays["CE291"] = ce;
    const std::map<std::string, size_t> widths{
        {"native156", 156},       {"fontMetrics146", 146}, {"technical18", 18},   {"glyphBody56", 56},
        {"legacyTemplate66", 66}, {"templates103", 66},    {"templates115", 198}, {"geometry128", 45},
        {"physical128", 14},      {"templates131", 66},    {"paint130", 40},      {"templates135", 130},
        {"templates143", 130},    {"joint147", 48},        {"joint158", 48},      {"templates167", 66},
        {"areas169", 21},         {"style187", 262},       {"CE291", 291}};
    for (auto &entry : widths) {
        const auto &v = arrays.at(entry.first);
        if (v.size() != entry.second ||
            !std::all_of(v.begin(), v.end(), [](double x) { return std::isfinite(x); })) {
            throw std::runtime_error("Invalid native feature layout: " + entry.first);
        }
    }
    return out;
}
namespace {
template <typename FontInputs>
SourceGlyphRasterizer nativeRasterizer(const FontInputs &input) {
#if AIDOKU_HAS_NATIVE_GLYPH
    return [&input](const std::string &path, char32_t codepoint) {
        auto file = input.fontFiles.find(path);
        const std::string &actualPath = file == input.fontFiles.end() ? path : file->second;
        auto found = input.fontFaceIndices.find(path);
        int face = found == input.fontFaceIndices.end() ? 0 : found->second;
        int supported = 0;
        if (acv_font_has_glyph(actualPath.c_str(), face, uint32_t(codepoint), &supported) != 0)
            throw std::runtime_error(acv_last_error());
        if (!supported)
            return cv::Mat();
        ACVGlyph glyph{};
        auto weight = input.fontWeights.find(path);
        int code = weight == input.fontWeights.end()
            ? acv_glyph(actualPath.c_str(), face, uint32_t(codepoint), 256 * 64, &glyph)
            : acv_glyph_with_weight(actualPath.c_str(), face, uint32_t(codepoint), 256 * 64,
                                    weight->second, &glyph);
        if (code != 0)
            throw std::runtime_error(acv_last_error() ? acv_last_error()
                                                      : "Native glyph rasterization failed");
        cv::Mat raw;
        if (glyph.pixels && glyph.width > 0 && glyph.height > 0)
            raw = cv::Mat(glyph.height, glyph.width, CV_8UC1, glyph.pixels, glyph.pitch).clone();
        acv_glyph_free(&glyph);
        return raw;
    };
#else
    throw std::runtime_error("AidokuNativeCV glyph backend is not linked");
#endif
}
} // namespace

FontTemplateSignals extractFontTemplateFeatures(const FontTemplateInputs &input) {
    return extractFontTemplateFeatures(input, nativeRasterizer(input));
}

SourceWeightBasics extractSourceWeightBasics(const FontTemplateInputs &input) {
    validate(input);
    SourceWeightBasics out;
    out.native156 = nativeFeatures(input.rgb, input.bbox, input.prior);
    std::fill_n(out.native156.begin(), 6, 0.);
    FontTemplateInputs allOnes = input;
    // Explicit allocation: assigning Mat::ones to a shared Mat can reuse and
    // overwrite the caller's ownership storage.
    allOnes.ownership = cv::Mat(input.rgb.size(), CV_8UC1, cv::Scalar(1));
    out.allOnesGlyphBody56 = glyphBody(allOnes);
    auto rasterize = nativeRasterizer(input);
    Glyphs glyphs(rasterize);
    out.fontMetrics146 = fontMetrics(input, normalize(input.text), out.native156, glyphs);
    return out;
}

SourceWeightBasics extractSourceWeightRawBasics(const SourceWeightRawInputs &input) {
    checkSource(input.rgb, input.bbox, input.prior);
    auto b = input.bbox;
    if (b.x < 0 || b.y < 0 || b.x + b.width > input.rgb.cols + 1 || b.y + b.height > input.rgb.rows + 1 ||
        b.x > .15 * b.width + 1 || b.y > .15 * b.height + 1 ||
        input.rgb.cols - b.x - b.width > .15 * b.width + 1 || input.rgb.rows - b.y - b.height > .15 * b.height + 1)
        throw std::invalid_argument("Source crop exceeds per-side15percent context");
    if (input.fonts.size() != 4)
        throw std::invalid_argument("Exactly four pinned BASE fonts required");
    SourceWeightBasics out;
    out.native156 = nativeFeatures(input.rgb, input.bbox, input.prior);
    std::fill_n(out.native156.begin(), 6, 0.);
    // All-ones support is the actual raw597 algorithm, not a supplied or fake
    // source-mask observation. This ABI never accepts a source ownership mask.
    cv::Mat allOnes(input.rgb.size(), CV_8UC1, cv::Scalar(1));
    out.allOnesGlyphBody56 = glyphBodyPixels(input.rgb, input.bbox, input.prior, allOnes);
    auto rasterize = nativeRasterizer(input);
    Glyphs glyphs(rasterize);
    out.fontMetrics146 = input.glyphMetricsCache
        ? cachedRawFontMetrics(input, normalize(input.text), out.native156, rasterize)
        : fontMetricsForFonts(input.fonts, normalize(input.text), out.native156, glyphs);
    return out;
}

FontTemplateSignals extractSourceWeightResidual(const FontTemplateInputs &input) {
    validate(input);
    FontTemplateInputs in = input;
    in.ownership = input.ownership != 0;
    in.ownership /= 255;
    auto rasterize = nativeRasterizer(in);
    Glyphs glyphs(rasterize);
    auto text = normalize(in.text);
    auto geom = geometry(in);
    cv::Mat alpha;
    paintAlpha(in).alpha.convertTo(alpha, CV_32F);
    auto complete = alphaTarget(alpha, in.bbox, geom.physical[3], geom.angle, true);
    auto native = fillTemplates(complete.image, complete.unit, in.prior, geom.physical[3],
                               text, in.nativeFonts, in.fonts[0], glyphs);
    FontTemplateSignals out;
    out.angle131 = geom.angle;
    out.arrays["style187"] = styleFeatures(alpha, in, text, geom.angle, native, glyphs);
    return out;
}

FontTemplateSignals extractAllSourceSignals(const FontTemplateInputs &input) {
    auto out = extractFontTemplateFeatures(input);
    auto &arrays = out.arrays;
    arrays["masked65"] = maskedFeatures(input.rgb, input.bbox, input.prior, input.ownership);
    arrays["cadence69"] = cadenceFeatures(input.rgb, input.bbox, input.prior, input.ownership,
                                          std::expm1(arrays.at("CE291")[146]));
    arrays["colors100"] = colorBodies(input.rgb, input.bbox, input.prior, input.ownership);
    auto components = extractComponents(input.rgb, input.bbox, input.prior, input.ownership);
    for (const auto &component : components) {
        arrays["components75Features"].insert(arrays["components75Features"].end(),
                                              component.features.begin(), component.features.end());
        arrays["components75Sizes"].push_back(component.size);
        arrays["components75Indices"].push_back(0);
    }
    // Preserve an explicit empty component collection for blank/unsupported crops.
    arrays.try_emplace("components75Features");
    arrays.try_emplace("components75Sizes");
    arrays.try_emplace("components75Indices");
    return out;
}

namespace {
NSArray<NSNumber *> *numbers(const Vec &values) {
    NSMutableArray<NSNumber *> *array = [NSMutableArray arrayWithCapacity:values.size()];
    for (double x : values)
        [array addObject:@(x)];
    return array;
}
Vec readNumbers(id value, size_t length, const char *name) {
    if (![value isKindOfClass:NSArray.class] || [value count] != length)
        throw std::invalid_argument(std::string("Invalid ") + name);
    Vec result;
    for (id number in value) {
        if (![number isKindOfClass:NSNumber.class] || !std::isfinite([number doubleValue]))
            throw std::invalid_argument(std::string("Nonfinite ") + name);
        result.push_back([number doubleValue]);
    }
    return result;
}
double readScalar(id value, const char *name, double defaultValue = 0) {
    if (!value || value == NSNull.null)
        return defaultValue;
    if (![value isKindOfClass:NSNumber.class] || !std::isfinite([value doubleValue]))
        throw std::invalid_argument(std::string("Invalid source scalar ") + name);
    return [value doubleValue];
}
int readInteger(id value, const char *name, int defaultValue = 0) {
    double number = readScalar(value, name, defaultValue);
    if (number < 0 || number > INT_MAX || std::floor(number) != number)
        throw std::invalid_argument(std::string("Invalid source integer ") + name);
    return static_cast<int>(number);
}
SourcePaintPart readPaint(NSDictionary *dictionary) {
    SourcePaintPart out;
    if (![dictionary isKindOfClass:NSDictionary.class])
        return out;
    id rgb = dictionary[@"rgb"];
    if (rgb && rgb != NSNull.null) {
        auto v = readNumbers(rgb, 3, "paint RGB");
        out.rgb = {v[0], v[1], v[2]};
        out.hasRGB = true;
        for (double c : v)
            if (c < 0 || c > 255)
                throw std::invalid_argument("Invalid source paint RGB range");
    }
    out.present = readScalar(dictionary[@"present"], "paint present") != 0;
    out.widthPx = readScalar(dictionary[@"widthPx"], "paint width");
    out.probability = readScalar(dictionary[@"probability"], "paint probability");
    id colors = dictionary[@"colors"];
    if ([colors isKindOfClass:NSArray.class])
        for (id color in colors) {
            auto v = readNumbers(color, 3, "background palette RGB");
            out.colors.push_back({v[0], v[1], v[2]});
        }
    return out;
}
std::vector<std::string> readFonts(id list, std::map<std::string, int> &indices,
                                   std::map<std::string, std::string> &files,
                                   std::map<std::string, double> &weights,
                                   std::map<std::string, std::string> *authenticatedSHA256 = nullptr) {
    if (![list isKindOfClass:NSArray.class])
        throw std::invalid_argument("Pinned source font records required");
    std::vector<std::string> paths;
    for (id value in list) {
        NSString *path = nil;
        int face = 0;
        bool hasWeight = false;
        double weight = 0;
        if ([value isKindOfClass:NSString.class])
            path = value;
        else if ([value isKindOfClass:NSDictionary.class]) {
            path = value[@"path"];
            face = readInteger(value[@"faceIndex"], "font face");
            id coordinate = value[@"wght"];
            hasWeight = coordinate && coordinate != NSNull.null;
            if (hasWeight)
                weight = readScalar(coordinate, "font wght");
        }
        if (![path isKindOfClass:NSString.class] || path.length == 0 || face < 0)
            throw std::invalid_argument("Invalid source font descriptor");
        if ([value isKindOfClass:NSDictionary.class] && value[@"SHA256"]) {
            NSString *expected = value[@"SHA256"];
            if (![expected isKindOfClass:NSString.class] || expected.length != 64 ||
                [expected rangeOfCharacterFromSet:[[NSCharacterSet
                                                      characterSetWithCharactersInString:@"0123456789abcdef"]
                                                      invertedSet]]
                        .location != NSNotFound)
                throw std::invalid_argument("Invalid pinned font SHA256");
            const auto digest = fontDigest(path, authenticatedSHA256 != nullptr);
            NSMutableString *actual = [NSMutableString stringWithCapacity:64];
            for (unsigned char byte : digest)
                [actual appendFormat:@"%02x", byte];
            if (![actual isEqualToString:expected])
                throw std::invalid_argument("Pinned source font SHA256 differs");
        }
        std::string actual(path.fileSystemRepresentation);
        std::string key = face == 0 ? actual : actual + "#face=" + std::to_string(face);
        if (hasWeight) {
            // Exact double identity avoids decimal truncation/cache collisions.
            uint64_t bits;
            static_assert(sizeof(bits) == sizeof(weight));
            std::memcpy(&bits, &weight, sizeof(bits));
            key += "#wghtBits=" + std::to_string(bits);
            weights[key] = weight;
        }
        indices[key] = face;
        files[key] = actual;
        if (authenticatedSHA256) {
            NSString *sha = value[@"SHA256"];
            if (![sha isKindOfClass:NSString.class] || sha.length != 64)
                throw std::invalid_argument("Authenticated BASE4 pin required");
            // Each supplied pin was matched against the actual content digest.
            (*authenticatedSHA256)[key] = std::string(sha.UTF8String);
        }
        paths.push_back(key);
    }
    return paths;
}
} // namespace
SourceWeightRawInputs sourceWeightRawInputsFromDictionary(NSDictionary *packet) {
    if (![packet isKindOfClass:NSDictionary.class] || ![packet[@"measurementABI"] isEqual:@"raw597-base4-v1"])
        throw std::invalid_argument("Explicit raw597-base4-v1 measurement ABI required");
    for (NSString *key in @[@"GTMaskUsed", @"inferenceUsesGT"]) {
        id value = packet[key];
        if (value && (![value isKindOfClass:NSNumber.class] || [value boolValue]))
            throw std::invalid_argument("Only source RGB observations admitted");
    }
    for (NSString *key in @[@"style", @"sourcePredictedStyle", @"ownership", @"owned", @"sourceEm",
                           @"memberPolygons", @"memberPolygonsCrop", @"native156", @"native",
                           @"weightMemberPolygons", @"physicalFontPairs", @"referencePairs", @"sourceAngle"])
        if (packet[key])
            throw std::invalid_argument("BASE4 raw ABI does not admit unrelated legacy observations");
    int width = readInteger(packet[@"width"], "crop width"), height = readInteger(packet[@"height"], "crop height");
    if (width <= 0 || height <= 0 || width > 1500000 / height)
        throw std::invalid_argument("Bounded positive crop dimensions required");
    size_t stride = readInteger(packet[@"rgbBytesPerRow"], "RGB byte stride", width * 3);
    NSData *rgb = packet[@"rgb"] ?: packet[@"rgbBytes"];
    if (![rgb isKindOfClass:NSData.class] || stride < size_t(width) * 3 ||
        stride > SIZE_MAX / size_t(height) || rgb.length < stride * height)
        throw std::invalid_argument("Invalid bounded RGB byte storage");
    SourceWeightRawInputs input;
    input.rgb = cv::Mat(height, width, CV_8UC3, const_cast<void *>(rgb.bytes), stride).clone();
    auto bbox = readNumbers(packet[@"bbox"], 4, "bbox");
    input.bbox = {bbox[0], bbox[1], bbox[2], bbox[3]};
    input.prior = readScalar(packet[@"prior"], "prior");
    NSString *text = packet[@"text"];
    if (![text isKindOfClass:NSString.class])
        throw std::invalid_argument("Original OCR text required");
    input.text = utf32([text precomposedStringWithCanonicalMapping]);
    NSDictionary *spec = packet[@"measurementSpec"];
    if (![spec isKindOfClass:NSDictionary.class] || spec[@"extendedFonts"] || spec[@"nativeFonts"])
        throw std::invalid_argument("BASE4-only measurement specification required");
    id records = spec[@"fonts"];
    if (![records isKindOfClass:NSArray.class] || [records count] != 4)
        throw std::invalid_argument("Exactly four pinned BASE fonts required");
    for (id record in records) {
        if (![record isKindOfClass:NSDictionary.class] || ![record[@"SHA256"] isKindOfClass:NSString.class] ||
            ![record[@"faceIndex"] isKindOfClass:NSNumber.class])
            throw std::invalid_argument("Explicit pinned BASE font descriptor required");
    }
    input.fonts = readFonts(records, input.fontFaceIndices, input.fontFiles, input.fontWeights,
                            &input.authenticatedFontSHA256);
    return input;
}

FontTemplateInputs fontTemplateInputsFromDictionary(NSDictionary *packet) {
    if (![packet isKindOfClass:NSDictionary.class])
        throw std::invalid_argument("Expected source glyph packet");
    if ([packet[@"GTMaskUsed"] boolValue] || [packet[@"inferenceUsesGT"] boolValue])
        throw std::invalid_argument("Only source-predicted glyph packets admitted");
    FontTemplateInputs in;
    int width = readInteger(packet[@"width"], "crop width"),
        height = readInteger(packet[@"height"], "crop height");
    if (width <= 0 || height <= 0)
        throw std::invalid_argument("Positive crop width/height required");
    NSData *rgb = packet[@"rgb"] ?: packet[@"rgbBytes"], *own = packet[@"ownership"] ?: packet[@"owned"];
    size_t rgbStride =
        packet[@"rgbBytesPerRow"] ? [packet[@"rgbBytesPerRow"] unsignedLongLongValue] : size_t(width) * 3;
    size_t ownStride = packet[@"ownershipBytesPerRow"]
                           ? [packet[@"ownershipBytesPerRow"] unsignedLongLongValue]
                           : size_t(width);
    if (![rgb isKindOfClass:NSData.class] || ![own isKindOfClass:NSData.class] ||
        rgbStride < size_t(width) * 3 || ownStride < size_t(width) || rgbStride > SIZE_MAX / size_t(height) ||
        ownStride > SIZE_MAX / size_t(height) || rgb.length < rgbStride * height ||
        own.length < ownStride * height)
        throw std::invalid_argument("Invalid bounded RGB/ownership byte storage");
    in.rgb = cv::Mat(height, width, CV_8UC3, const_cast<void *>(rgb.bytes), rgbStride).clone();
    in.ownership = cv::Mat(height, width, CV_8UC1, const_cast<void *>(own.bytes), ownStride).clone();
    auto bbox = readNumbers(packet[@"bbox"], 4, "bbox");
    in.bbox = {bbox[0], bbox[1], bbox[2], bbox[3]};
    in.prior = readScalar(packet[@"prior"], "prior");
    NSString *text = packet[@"text"] ?: @"";
    if (![text isKindOfClass:NSString.class])
        throw std::invalid_argument("Original OCR must be text");
    in.text = utf32([text precomposedStringWithCanonicalMapping]);
    NSDictionary *style = packet[@"style"] ?: packet[@"sourcePredictedStyle"];
    if (![style isKindOfClass:NSDictionary.class] || [style[@"inferenceUsesGT"] boolValue] ||
        (style[@"sourceOnly"] && ![style[@"sourceOnly"] boolValue]))
        throw std::invalid_argument("Source-predicted paint style required");
    in.style.fill = readPaint(style[@"fill"]);
    in.style.outline = readPaint(style[@"outline"]);
    in.style.background = readPaint(style[@"background"]);
    in.style.shadow = readPaint(style[@"shadow"]);
    id evidence = style[@"pixelRoleEvidence"];
    if (evidence && evidence != NSNull.null && ![evidence isKindOfClass:NSDictionary.class])
        throw std::invalid_argument("Invalid paint role evidence");
    id roles = [evidence isKindOfClass:NSDictionary.class] ? evidence[@"roles"] : nil;
    if (roles && roles != NSNull.null && ![roles isKindOfClass:NSDictionary.class])
        throw std::invalid_argument("Invalid paint role probabilities");
    int index = 0;
    for (NSString *name in @[ @"fill", @"outline", @"background", @"shadowComposite" ]) {
        id entry = [roles isKindOfClass:NSDictionary.class] ? roles[name] : nil;
        if (entry && entry != NSNull.null && ![entry isKindOfClass:NSDictionary.class])
            throw std::invalid_argument("Invalid paint role probability entry");
        in.style.roleProbabilities[index++] =
            readScalar([entry isKindOfClass:NSDictionary.class] ? entry[@"meanProbability"] : nil,
                       "paint role probability");
    }
    id polygons = packet[@"memberPolygons"] ?: packet[@"memberPolygonsCrop"];
    if (polygons && polygons != NSNull.null) {
        if (![polygons isKindOfClass:NSArray.class])
            throw std::invalid_argument("Invalid member polygon collection");
        for (id polygon in polygons) {
            if (![polygon isKindOfClass:NSArray.class])
                throw std::invalid_argument("Invalid member polygon");
            std::vector<cv::Point2f> points;
            for (id pair in polygon) {
                auto p = readNumbers(pair, 2, "member point");
                points.emplace_back(p[0], p[1]);
            }
            in.memberPolygons.push_back(points);
        }
    }
    NSDictionary *spec = packet[@"measurementSpec"] ?: packet;
    in.fonts = readFonts(spec[@"fonts"], in.fontFaceIndices, in.fontFiles, in.fontWeights);
    in.extendedFonts = readFonts(spec[@"extendedFonts"], in.fontFaceIndices, in.fontFiles, in.fontWeights);
    in.nativeFonts = readFonts(spec[@"nativeFonts"], in.fontFaceIndices, in.fontFiles, in.fontWeights);
    id native = packet[@"native156"] ?: packet[@"native"];
    if (native && native != NSNull.null)
        in.native156 = readNumbers(native, 156, "native156");
    if (packet[@"confidence"] && packet[@"confidence"] != NSNull.null) {
        in.confidence = readScalar(packet[@"confidence"], "confidence");
        if (in.confidence < 0 || in.confidence > 1)
            throw std::invalid_argument("Source confidence outside unit interval");
    }
    NSString *role = packet[@"role"];
    if ([role isKindOfClass:NSString.class])
        in.role = role.UTF8String;
    id center = packet[@"normalizedCenter"] ?: packet[@"center"];
    if (center) {
        auto c = readNumbers(center, 2, "normalized source center");
        in.normalizedCenter = {c[0], c[1]};
    } else if (packet[@"pageSize"] && packet[@"cropOrigin"]) {
        auto size = readNumbers(packet[@"pageSize"], 2, "pageSize"),
             origin = readNumbers(packet[@"cropOrigin"], 2, "cropOrigin");
        if (size[0] <= 0 || size[1] <= 0)
            throw std::invalid_argument("Invalid pageSize");
        in.normalizedCenter = {(origin[0] + in.bbox.x + in.bbox.width / 2) / size[0],
                               (origin[1] + in.bbox.y + in.bbox.height / 2) / size[1]};
    } else if (!in.role.empty())
        throw std::invalid_argument("Source page center required for CE291");
    validate(in);
    return in;
}
NSDictionary<NSString *, id> *fontTemplateSignalsDictionary(const FontTemplateSignals &signals) {
    NSMutableDictionary<NSString *, id> *out = [NSMutableDictionary dictionary];
    for (const auto &entry : signals.arrays) {
        if (entry.first == "geometry128" || entry.first == "physical128" ||
            entry.first.rfind("components75", 0) == 0)
            continue;
        out[@(entry.first.c_str())] = numbers(entry.second);
    }
    if (signals.arrays.count("geometry128"))
        out[@"geometry128"] = @{
            @"X" : numbers(signals.arrays.at("geometry128")),
            @"physical" : numbers(signals.arrays.at("physical128"))
        };
    if (signals.arrays.count("components75Features")) {
        auto &flat = signals.arrays.at("components75Features");
        NSMutableArray *features = [NSMutableArray array];
        for (size_t i = 0; i < flat.size(); i += 198)
            [features addObject:numbers(Vec(flat.begin() + i, flat.begin() + i + 198))];
        out[@"components75"] = @{
            @"features" : features,
            @"sizes" : numbers(signals.arrays.at("components75Sizes")),
            @"indices" : numbers(signals.arrays.at("components75Indices"))
        };
    }
    out[@"angles131"] = @(signals.angle131);
    out[@"priorRatio131"] = @(signals.priorRatio131);
    out[@"remeasured158"] = @(signals.remeasured158);
    return out;
}
} // namespace aidoku::source

NSDictionary<NSString *, id> *AIDExtractAllSourceSignals(NSDictionary *packet, NSError **error) {
    // Use the caller's autorelease pool: NSError** writeback occurs after this
    // function returns, so a nested pool must not drain the assigned error.
    try {
        auto input = aidoku::source::fontTemplateInputsFromDictionary(packet);
        auto signals = aidoku::source::extractAllSourceSignals(input);
        return aidoku::source::fontTemplateSignalsDictionary(signals);
    } catch (const std::exception &e) {
        if (error)
            *error = [NSError errorWithDomain:@"Aidoku.SourceFontMeasurements"
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : @(e.what())
                                     }];
        return nil;
    }
}
