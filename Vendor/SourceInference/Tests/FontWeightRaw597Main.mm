#import "../FontWeightFeatures.h"
#import <Foundation/Foundation.h>
#include <iostream>

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
        NSArray *records = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (!records) return 3;
        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *record in records) {
            NSMutableDictionary *packet = [record mutableCopy];
            for (NSString *key in @[@"rgb", @"ownership"])
                packet[key] = [[NSData alloc] initWithBase64EncodedString:packet[key] options:0];
            NSDictionary *full = AIDExtractSourceWeightSignals(packet, &error);
            NSDictionary *raw = AIDExtractSourceWeightRaw597(packet, &error);
            if (!full || !raw || raw.count != 1 || ![raw[@"raw597"] isEqual:full[@"raw597"]]) return 4;
            [results addObject:raw];
            if (results.count == 1) {
                // Production uses SHA descriptors; ordinary synthetic oracle
                // path lists alone would not exercise this admission boundary.
                for (NSNumber *missing in @[@NO, @YES]) {
                    NSMutableDictionary *bad = [packet mutableCopy];
                    NSMutableDictionary *spec = [packet[@"measurementSpec"] mutableCopy];
                    NSMutableArray *fonts = [spec[@"fonts"] mutableCopy];
                    fonts[0] = @{@"path": missing.boolValue ? @"/aidoku-nonexistent-font-identity-control.ttf" : fonts[0],
                        @"faceIndex": @0, @"SHA256": [@"" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0]};
                    spec[@"fonts"] = fonts; bad[@"measurementSpec"] = spec;
                    NSError *a = nil, *b = nil;
                    if (AIDExtractSourceWeightRaw597(bad, &a) || AIDExtractSourceWeightSignals(bad, &b) ||
                        !a.localizedDescription.length || ![a.localizedDescription isEqual:b.localizedDescription]) return 11;
                }
            }
            // Valid admission-only inputs must not become hidden raw597 inputs.
            NSMutableDictionary *changed = [packet mutableCopy];
            changed[@"sourceEm"] = @([packet[@"sourceEm"] doubleValue] * 2);
            NSDictionary *same = AIDExtractSourceWeightRaw597(changed, &error);
            if (!same || ![same isEqual:raw]) return 9;
            changed = [packet mutableCopy];
            changed[@"style"] = @{@"fill": @{@"rgb": @[@111, @22, @83]},
                @"background": @{@"rgb": @[@20, @30, @40]},
                @"outline": @{@"present": @NO, @"widthPx": @21, @"rgb": @[@240, @10, @80]}};
            same = AIDExtractSourceWeightRaw597(changed, &error);
            if (!same || ![same isEqual:raw]) return 10;
            NSMutableArray *badPackets = [NSMutableArray array];
            for (NSString *key in @[@"sourceEm", @"style", @"ownership", @"measurementSpec", @"prior", @"bbox", @"width", @"height", @"rgb"]) {
                NSMutableDictionary *bad = [packet mutableCopy];
                [bad removeObjectForKey:key]; [badPackets addObject:bad];
            }
            for (id value in @[@0, @(-1), @(NAN), @(INFINITY), @"20", NSNull.null]) {
                NSMutableDictionary *bad = [packet mutableCopy]; bad[@"sourceEm"] = value; [badPackets addObject:bad];
            }
            for (NSString *key in @[@"GTMaskUsed", @"inferenceUsesGT"]) {
                NSMutableDictionary *bad = [packet mutableCopy]; bad[key] = @YES; [badPackets addObject:bad];
            }
            NSMutableDictionary *bad = [packet mutableCopy]; bad[@"bbox"] = @[@(-5), @0, @20, @20]; [badPackets addObject:bad];
            bad = [packet mutableCopy]; bad[@"ownership"] = [NSData data]; [badPackets addObject:bad];
            bad = [packet mutableCopy]; bad[@"measurementSpec"] = @{}; [badPackets addObject:bad];
            bad = [packet mutableCopy]; bad[@"style"] = @{}; [badPackets addObject:bad];
            bad = [packet mutableCopy]; bad[@"confidence"] = @2; [badPackets addObject:bad];
            for (NSDictionary *invalid in badPackets) {
                NSError *a = nil, *b = nil;
                if (AIDExtractSourceWeightRaw597(invalid, &a) || AIDExtractSourceWeightSignals(invalid, &b) ||
                    !a.localizedDescription.length || !b.localizedDescription.length ||
                    ![a.localizedDescription isEqual:b.localizedDescription]) return 5;
            }
            for (NSString *key in @[@"weightMemberPolygons", @"sourceAngle", @"physicalFontPairs", @"referencePairs"]) {
                bad = [packet mutableCopy]; bad[key] = NSNull.null; error = nil;
                if (AIDExtractSourceWeightRaw597(bad, &error) || !error.localizedDescription.length) return 6;
            }
        }
        if (AIDExtractSourceWeightRaw597(@{}, &error) || !error ||
            AIDExtractSourceWeightRaw597((NSDictionary *)NSNull.null, nullptr)) return 7;
        data = [NSJSONSerialization dataWithJSONObject:results options:0 error:&error];
        return [data writeToFile:@(argv[2]) options:NSDataWritingAtomic error:&error] ? 0 : 8;
    }
}
