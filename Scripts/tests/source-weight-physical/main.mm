#import <Foundation/Foundation.h>
#include "FontWeightPhysical.h"
#include <iostream>
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSArray *records = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *r in records) {
            try {
                NSData *bytes = [[NSData alloc] initWithBase64EncodedString:r[@"rgb"] options:0];
                int w = [r[@"width"] intValue], h = [r[@"height"] intValue];
                if (w <= 0 || h <= 0 || bytes.length != size_t(w)*h*3) return 3;
                cv::Mat rgb(h,w,CV_8UC3,const_cast<void *>(bytes.bytes));
                NSArray *b = r[@"bbox"];
                std::array<aidoku::PhysicalFontPair,3> pairs;
                for (int i = 0; i < 3; ++i) {
                    NSArray *p = r[@"pairs"][i];
                    pairs[i] = {{[p[0] UTF8String],[p[1] intValue]}, {[p[2] UTF8String],[p[3] intValue]}};
                }
                auto result = aidoku::measureFontWeightPhysical(rgb,
                    {[b[0] doubleValue],[b[1] doubleValue],[b[2] doubleValue],[b[3] doubleValue]},
                    [r[@"em"] doubleValue],[r[@"text"] UTF8String],pairs);
                NSMutableArray *row = [NSMutableArray array];
                for (double v : result) [row addObject:@(v)];
                [results addObject:row];
            } catch (const std::exception &e) {
                [results addObject:@{@"error":@(e.what())}];
            }
        }
        return [[NSJSONSerialization dataWithJSONObject:results options:0 error:nil]
            writeToFile:@(argv[2]) atomically:YES] ? 0 : 4;
    }
}
