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
            NSDictionary *result = AIDExtractSourceWeightSignals(packet, &error);
            if (!result) { std::cerr << error.localizedDescription.UTF8String << '\n'; return 4; }
            [results addObject:result];
            for (id badEm in @[@0, @(-1), @(NAN), @(INFINITY), @"20", NSNull.null]) {
                NSMutableDictionary *bad = [packet mutableCopy];
                bad[@"sourceEm"] = badEm;
                error = nil;
                if (AIDExtractSourceWeightSignals(bad, &error) || !error.localizedDescription.length) return 5;
            }
            NSMutableDictionary *bad = [packet mutableCopy];
            [bad removeObjectForKey:@"sourceEm"];
            if (AIDExtractSourceWeightSignals(bad, nullptr)) return 6;
            bad = [packet mutableCopy]; bad[@"GTMaskUsed"] = @YES;
            if (AIDExtractSourceWeightSignals(bad, nullptr)) return 7;
            bad = [packet mutableCopy]; bad[@"ownership"] = [NSData data];
            if (AIDExtractSourceWeightSignals(bad, nullptr)) return 8;
            bad = [packet mutableCopy]; bad[@"bbox"] = @[@(-5), @0, @20, @20];
            if (AIDExtractSourceWeightSignals(bad, nullptr)) return 9;
        }
        if (AIDExtractSourceWeightSignals(@{}, &error) || !error ||
            AIDExtractSourceWeightSignals((NSDictionary *)NSNull.null, nullptr)) return 10;
        data = [NSJSONSerialization dataWithJSONObject:results options:0 error:&error];
        return [data writeToFile:@(argv[2]) options:NSDataWritingAtomic error:&error] ? 0 : 11;
    }
}
