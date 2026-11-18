#import "FontWeightFeatures.h"
#import "FontTemplateFeatures.h"
#include "Sources/SourceWeightFeatures.hpp"
#include "FontWeightPhysical.h"
#include "FontWeightBandSource.h"
#include <cmath>
#include <climits>
#include <stdexcept>

namespace {
NSArray<NSNumber *> *weightNumbers(const std::vector<double> &values) {
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:values.size()];
    for (double value : values)
        [result addObject:@(value)];
    return result;
}
}

NSDictionary<NSString *, id> *AIDExtractSourceWeightRaw597(NSDictionary *packet, NSError **error) {
    try {
        using namespace aidoku::source;
        if (![packet isKindOfClass:NSDictionary.class])
            throw std::invalid_argument("Expected source weight packet");
        id em = packet[@"sourceEm"];
        if (![em isKindOfClass:NSNumber.class] || !std::isfinite([em doubleValue]) || [em doubleValue] <= 0)
            throw std::invalid_argument("Positive finite final sourceEm required");
        for (NSString *key in @[@"weightMemberPolygons", @"sourceAngle", @"physicalFontPairs", @"referencePairs"])
            if (packet[key])
                throw std::invalid_argument("Raw597-only bridge does not admit residual/angle/paired/band requests");
        NSMutableDictionary *observations = [packet mutableCopy];
        [observations removeObjectForKey:@"native156"];
        [observations removeObjectForKey:@"native"];
        // Same generic decoder and basics validator: real style/ownership and
        // all pinned banks remain admission requirements, not fake placeholders.
        auto input = fontTemplateInputsFromDictionary(observations);
        auto basics = extractSourceWeightBasics(input);
        auto raw = composeWeightRaw597(input.rgb, input.bbox, input.prior, basics.native156,
                                       basics.allOnesGlyphBody56, basics.fontMetrics146);
        return @{@"raw597": weightNumbers(raw)};
    } catch (const std::exception &exception) {
        if (error)
            *error = [NSError errorWithDomain:@"Aidoku.SourceWeightMeasurements" code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @(exception.what())}];
        return nil;
    }
}

NSDictionary<NSString *, id> *AIDExtractSourceWeightRaw597Base4(NSDictionary *packet, NSError **error) {
    try {
        using namespace aidoku::source;
        auto input = sourceWeightRawInputsFromDictionary(packet);
        // Intrinsic BASE4 metrics only. Every parser call still hashes actual
        // files, and misses are post-validated before bounded shared commit.
        static const auto metrics = makeSourceWeightGlyphMetricsCache();
        input.glyphMetricsCache = metrics;
        auto basics = extractSourceWeightRawBasics(input);
        auto raw = composeWeightRaw597(input.rgb, input.bbox, input.prior, basics.native156,
                                       basics.allOnesGlyphBody56, basics.fontMetrics146);
        return @{@"raw597": weightNumbers(raw), @"measurementABI": @"raw597-base4-v1"};
    } catch (const std::exception &exception) {
        if (error)
            *error = [NSError errorWithDomain:@"Aidoku.SourceWeightMeasurements" code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @(exception.what())}];
        return nil;
    }
}

NSDictionary<NSString *, id> *AIDExtractSourceWeightSignals(NSDictionary *packet, NSError **error) {
    // NSError writeback belongs to the caller's autorelease pool.
    try {
        using namespace aidoku::source;
        if (![packet isKindOfClass:NSDictionary.class])
            throw std::invalid_argument("Expected source weight packet");
        id em = packet[@"sourceEm"];
        if (![em isKindOfClass:NSNumber.class] || !std::isfinite([em doubleValue]) || [em doubleValue] <= 0)
            throw std::invalid_argument("Positive finite final sourceEm required");
        // Do not accept caller vectors as same-crop measurements.
        NSMutableDictionary *observations = [packet mutableCopy];
        [observations removeObjectForKey:@"native156"];
        [observations removeObjectForKey:@"native"];
        id weightGeometry = packet[@"weightMemberPolygons"];
        if (weightGeometry) {
            if (![weightGeometry isKindOfClass:NSArray.class])
                throw std::invalid_argument("Weight word geometry must be an array");
            observations[@"memberPolygons"] = weightGeometry;
        }
        auto input = fontTemplateInputsFromDictionary(observations);
        auto basics = extractSourceWeightBasics(input);
        auto raw = composeWeightRaw597(input.rgb, input.bbox, input.prior, basics.native156,
                                       basics.allOnesGlyphBody56, basics.fontMetrics146);
        auto direct = weightDirect7(input.rgb, input.bbox, input.prior);
        // Alpha uses actual source ownership/style. Only fill normalization uses
        // final em; original prior/text above are never replaced by a prediction.
        auto alpha = sourceFillAlpha(input);
        cv::Mat ownership = input.ownership != 0;
        ownership /= 255;
        WeightFillStyle style{input.style.fill.rgb, input.style.background.rgb,
                              input.style.outline.present, input.style.outline.widthPx};
        auto fill = weightFill71V1(alpha, input.bbox, [em doubleValue], ownership, style);
        id outlinePresent = packet[@"style"][@"outline"][@"present"];
        bool mixedPaletteKnown = input.style.fill.hasRGB && input.style.background.hasRGB &&
            [outlinePresent isKindOfClass:NSNumber.class] && ![outlinePresent boolValue];
        NSMutableDictionary *result = [@{@"raw597": weightNumbers(raw), @"direct7": weightNumbers(direct.features),
                                        @"fill71": weightNumbers(fill),
                                        @"qualifiedMixed": @(mixedPaletteKnown && qualifiedWeightMixed(input.rgb,input.bbox,[em doubleValue],style))} mutableCopy];
        double angle = 0;
        if (weightGeometry) {
            auto residual = extractSourceWeightResidual(input);
            result[@"weightStyle187"] = weightNumbers(residual.arrays.at("style187"));
            angle = residual.angle131;
            result[@"weightAngle131"] = @(angle);
        } else if (packet[@"sourceAngle"]) {
            id value = packet[@"sourceAngle"];
            if (![value isKindOfClass:NSNumber.class] || !std::isfinite([value doubleValue]))
                throw std::invalid_argument("Finite source weight angle required");
            angle = [value doubleValue];
        }
        id suppliedPairs = packet[@"physicalFontPairs"];
        if (suppliedPairs) {
            if (![suppliedPairs isKindOfClass:NSArray.class] || [suppliedPairs count] != 3)
                throw std::invalid_argument("Exactly three physical font pairs required");
            std::array<aidoku::PhysicalFontPair, 3> pairs;
            for (NSUInteger i = 0; i < 3; ++i) {
                id pair = suppliedPairs[i];
                if ([pair isKindOfClass:NSDictionary.class] && [pair count] == 1 &&
                    [pair[@"available"] isKindOfClass:NSNumber.class] && ![pair[@"available"] boolValue]) {
                    pairs[i].available = false;
                    continue;
                }
                if (![pair isKindOfClass:NSArray.class] || [pair count] != 2)
                    throw std::invalid_argument("Invalid physical font pair");
                for (NSUInteger j = 0; j < 2; ++j) {
                    id descriptor = pair[j];
                    if (![descriptor isKindOfClass:NSDictionary.class])
                        throw std::invalid_argument("Physical font descriptor required");
                    NSString *path = descriptor[@"path"];
                    NSNumber *index = descriptor[@"faceIndex"];
                    if (![path isKindOfClass:NSString.class] || !path.length ||
                        ![index isKindOfClass:NSNumber.class] || !std::isfinite(index.doubleValue) ||
                        index.doubleValue < 0 || index.doubleValue > INT_MAX ||
                        std::floor(index.doubleValue) != index.doubleValue)
                        throw std::invalid_argument("Invalid physical font face");
                    aidoku::PhysicalFontFace face{std::string(path.fileSystemRepresentation), index.intValue};
                    if (j == 0) pairs[i].regular = face;
                    else pairs[i].heavy = face;
                }
            }
            NSString *text = packet[@"text"];
            if (![text isKindOfClass:NSString.class])
                throw std::invalid_argument("Original source OCR text required");
            auto physical = aidoku::measureFontWeightPhysical(input.rgb, input.bbox, [em doubleValue],
                                                              std::string(text.UTF8String, [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]), pairs);
            result[@"paired48"] = weightNumbers(std::vector<double>(physical.begin(), physical.end()));
        }
        id references = packet[@"referencePairs"];
        if (references) {
            if (![references isKindOfClass:NSArray.class] || [references count] != 4 ||
                (!weightGeometry && !packet[@"sourceAngle"]))
                throw std::invalid_argument("Four explicit band pairs and a source angle required");
            std::array<aidoku::WeightBandPair, 4> pairs;
            for (NSUInteger i = 0; i < 4; ++i) {
                id pair = references[i];
                if (![pair isKindOfClass:NSDictionary.class])
                    throw std::invalid_argument("Band pair descriptor required");
                for (NSString *role in @[@"regular", @"heavy"]) {
                    id record = pair[role];
                    if (![record isKindOfClass:NSDictionary.class])
                        throw std::invalid_argument("Band face descriptor required");
                    NSString *path = record[@"path"], *sha = record[@"SHA256"];
                    if (![path isKindOfClass:NSString.class] || !path.length ||
                        ![sha isKindOfClass:NSString.class] || sha.length != 64)
                        throw std::invalid_argument("Pinned band font required");
                    if (record[@"faceIndex"] && record[@"faceIndex"] != NSNull.null) {
                        id index = record[@"faceIndex"];
                        if (![index isKindOfClass:NSNumber.class] || [index doubleValue] != 0)
                            throw std::invalid_argument("Band references require accepted public face0");
                    }
                    aidoku::WeightBandFont font{std::string(path.fileSystemRepresentation), std::string(sha.UTF8String), std::nullopt};
                    id weight = record[@"weight"];
                    if (weight && weight != NSNull.null) {
                        if (![weight isKindOfClass:NSNumber.class] || !std::isfinite([weight doubleValue]))
                            throw std::invalid_argument("Invalid band font weight");
                        font.weight = [weight doubleValue];
                    }
                    if ([role isEqualToString:@"regular"]) pairs[i].regular = font;
                    else pairs[i].heavy = font;
                }
            }
            auto measured = measureSourceWeightBands(input, alpha, [em doubleValue], angle, pairs);
            result[@"bands112"] = weightNumbers(std::vector<double>(measured.bands.begin(), measured.bands.end()));
        }
        return result;
    } catch (const std::exception &exception) {
        if (error)
            *error = [NSError errorWithDomain:@"Aidoku.SourceWeightMeasurements" code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @(exception.what())}];
        return nil;
    }
}
