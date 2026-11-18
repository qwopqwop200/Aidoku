#import <Foundation/Foundation.h>
#include "SourceWeightInk.h"
#include <cstring>
#include <stdexcept>
using namespace aidoku;
static cv::Mat matrix(NSDictionary *d) {
    int h=[d[@"height"] intValue],w=[d[@"width"] intValue],t=[d[@"type"] intValue];
    NSData *b=[[NSData alloc] initWithBase64EncodedString:d[@"data"] options:0];
    cv::Mat m(h,w,t); if(b.length!=m.total()*m.elemSize()) throw std::invalid_argument("Invalid matrix bytes");
    memcpy(m.data,b.bytes,b.length);
    // Exercise borrowed row strides for every native input, including RF27.
    cv::Mat padded(h,w+3,t),roi=padded(cv::Rect(0,0,w,h));m.copyTo(roi);return roi;
}
static SourceInkPaint paint(NSDictionary *d) {
    SourceInkPaint p;p.present=[d[@"present"] boolValue];p.widthPx=[d[@"widthPx"] doubleValue];
    auto rgb=[](NSArray *v) {return SourceInkRGB{[v[0] doubleValue],[v[1] doubleValue],[v[2] doubleValue]};};
    if([d[@"rgb"] isKindOfClass:NSArray.class]) p.rgb=rgb(d[@"rgb"]);
    for(NSArray *v in d[@"colors"]) p.colors.push_back(rgb(v));
    for(NSNumber *v in d[@"observedContextWeights"]) p.observedContextWeights.push_back(v.doubleValue);
    return p;
}
static NSString *encoded(const cv::Mat &m) {
    cv::Mat c=m.isContinuous()?m:m.clone();
    return [[NSData dataWithBytes:c.data length:c.total()*c.elemSize()] base64EncodedStringWithOptions:0];
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=3)return 2;
        NSArray *records=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
        NSMutableArray *results=[NSMutableArray array];
        for(NSDictionary *r in records) {
            try {
                SourceWeightInkInput in;
                in.rgb=matrix(r[@"rgb"]);in.ownership=matrix(r[@"ownership"]);in.valid=matrix(r[@"valid"]);
                in.primary=matrix(r[@"primary"]);in.boundary=matrix(r[@"boundary"]);in.native=matrix(r[@"native"]);in.rf=matrix(r[@"rf"]);
                NSDictionary *s=r[@"style"];in.style={paint(s[@"fill"]),paint(s[@"background"]),paint(s[@"outline"]),paint(s[@"shadow"])};
                if(r[@"em"]!=NSNull.null)in.sourceEm=[r[@"em"] doubleValue];in.cutoff=[r[@"cutoff"] doubleValue];
                auto result=[r[@"mode"] isEqual:@"uncapped"]?reconstructSegmentedSourceWeightInk(in,std::nullopt):
                    reconstructSourceWeightInk(in,[r[@"mode"] isEqual:@"segmented"]?SourceWeightInkRule::Segmented:SourceWeightInkRule::ColorConsistent);
                NSMutableDictionary *audit=[NSMutableDictionary dictionary];for(auto &[k,v]:result.audit)audit[@(k.c_str())]=@(v);
                auto clean=cleanSourceInkStyle(in.style);
                SourceInkObservation color{cv::Mat::zeros(in.rgb.size(),CV_32F),cv::Mat::zeros(in.rgb.size(),CV_8U)};
                if(clean)color=observeSourceInkPalette(in.rgb,in.ownership,*clean);
                [results addObject:@{@"alpha":encoded(result.alpha),@"observed":encoded(result.observed),@"audit":audit,
                    @"color":encoded(color.alpha),@"known":encoded(color.known),@"clean":@(bool(clean))}];
            } catch(const std::exception &e) {[results addObject:@{@"error":@(e.what())}];}
        }
        NSData *out=[NSJSONSerialization dataWithJSONObject:results options:0 error:nil];
        return [out writeToFile:@(argv[2]) atomically:YES]?0:3;
    }
}
