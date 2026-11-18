#import "include/AidokuSourceFeatures.h"
#include "../SourceInference/Sources/SourceCoreFeatures.hpp"
#include <stdexcept>
#include <cmath>
namespace {
NSArray<NSNumber *> *numbers(const aidoku::source::Vec &v) {
    NSMutableArray *a=[NSMutableArray arrayWithCapacity:v.size()];
    for(double x:v){if(!std::isfinite(x))throw std::runtime_error("nonfinite core feature");[a addObject:@(x)];}return a;
}
}
@implementation ACVSourceFeatureBridge
+ (NSDictionary *)coreSignalsForPacket:(NSDictionary *)p error:(NSError **)error {
    try {
        if(![p isKindOfClass:NSDictionary.class])throw std::invalid_argument("packet must be dictionary");
        int w=[p[@"width"] intValue],h=[p[@"height"] intValue];
        id rgb=p[@"rgb8"],own=p[@"owned8"]?:p[@"ownership"],box=p[@"bbox"];
        double prior=[p[@"prior"] doubleValue],chars=[p[@"characterCount"] doubleValue];
        if(w<=0||h<=0||int64_t(w)*h>INT32_MAX||![rgb isKindOfClass:NSData.class]||![own isKindOfClass:NSData.class]||![box isKindOfClass:NSArray.class]||[box count]!=4||!std::isfinite(prior)||prior<=0||!std::isfinite(chars)||chars<0)
            throw std::invalid_argument("invalid source packet dimensions/data/bbox/prior/characterCount");
        if([rgb length]!=size_t(w)*h*3||[own length]!=size_t(w)*h)throw std::invalid_argument("source byte count mismatch");
        double b[4];for(int i=0;i<4;++i){b[i]=[box[i] doubleValue];if(!std::isfinite(b[i]))throw std::invalid_argument("nonfinite bbox");}
        if(b[2]<=0||b[3]<=0)throw std::invalid_argument("empty bbox");
        cv::Mat im(h,w,CV_8UC3,const_cast<void*>([rgb bytes])),mask(h,w,CV_8UC1,const_cast<void*>([own bytes]));cv::Rect2d rect(b[0],b[1],b[2],b[3]);
        using namespace aidoku::source;
        NSMutableArray *components=[NSMutableArray array];
        for(const auto &c:extractComponents(im,rect,prior,mask)){
            [components addObject:@{@"features":numbers(c.features),@"size":@(c.size),
                @"bounds":@[@(c.bounds.x),@(c.bounds.y),@(c.bounds.width),@(c.bounds.height)],
                @"packedShape":[NSData dataWithBytes:c.packedShape.data() length:c.packedShape.size()]}];
        }
        NSArray *native=numbers(nativeFeatures(im,rect,prior)), *masked=numbers(maskedFeatures(im,rect,prior,mask));
        NSArray *cadence=numbers(cadenceFeatures(im,rect,prior,mask,chars)), *colors=numbers(colorBodies(im,rect,prior,mask));
        return @{@"native156":native,@"masked180":masked,@"masked65":masked,
            @"cadence122":cadence,@"cadence69":cadence,@"colorBodies128":colors,@"colors100":colors,
            @"components":components,@"components75":components};
    } catch(const std::exception &e) {
        if(error)*error=[NSError errorWithDomain:@"AidokuNativeCV" code:1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithUTF8String:e.what()]}];return nil;
    } catch(...) {
        if(error)*error=[NSError errorWithDomain:@"AidokuNativeCV" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Unknown native core feature failure"}];return nil;
    }
}
@end
