#import <Foundation/Foundation.h>
#include "SourceWeightStrokeGeometry.h"
#include <cstring>
#include <stdexcept>
using namespace aidoku;
static cv::Mat matrix(NSDictionary *d) {
    int h=[d[@"height"] intValue],w=[d[@"width"] intValue],t=[d[@"type"] intValue];
    NSData *bytes=[[NSData alloc] initWithBase64EncodedString:d[@"data"] options:0];
    cv::Mat m(h,w,t);
    if(bytes.length!=m.total()*m.elemSize()) throw std::invalid_argument("Invalid matrix bytes");
    memcpy(m.data,bytes.bytes,bytes.length);
    cv::Mat padded(h,w+5,t),roi=padded(cv::Rect(1,0,w,h));m.copyTo(roi);return roi;
}
static SourceInkPaint paint(NSDictionary *d) {
    SourceInkPaint p;p.present=[d[@"present"] boolValue];p.widthPx=[d[@"widthPx"] doubleValue];
    auto rgb=[](NSArray *v){return SourceInkRGB{[v[0] doubleValue],[v[1] doubleValue],[v[2] doubleValue]};};
    if([d[@"rgb"] isKindOfClass:NSArray.class])p.rgb=rgb(d[@"rgb"]);
    for(NSArray *v in d[@"colors"])p.colors.push_back(rgb(v));
    for(NSNumber *v in d[@"observedContextWeights"])p.observedContextWeights.push_back(v.doubleValue);
    return p;
}
static double scalar(id n) {
    if([n isKindOfClass:NSString.class]) {
        if([n isEqual:@"nan"])return NAN;
        if([n isEqual:@"inf"])return INFINITY;
        if([n isEqual:@"-inf"])return -INFINITY;
    }
    return [n doubleValue];
}
template<class T> static NSArray *numbers(const T &values) {
    NSMutableArray *out=[NSMutableArray array];for(auto v:values)[out addObject:@(v)];return out;
}
static NSDictionary *directional(const SourceStrokeDirectionalObservation &v) {
    NSMutableDictionary *groups=[NSMutableDictionary dictionary];
    for(const auto &[name,g]:v.groups)groups[@(name.c_str())]=@{@"count":@(g.count),@"quantiles":numbers(g.quantiles)};
    return @{@"groups":groups,@"components":@(v.components),
        @"directionContrast":v.directionContrast?id(@(*v.directionContrast)):id(NSNull.null),
        @"minimumDirectionalMedian":@(v.minimumDirectionalMedian),@"newModelCreated":@(v.newModelCreated),@"modelTrainingPerformed":@(v.modelTrainingPerformed)};
}
static NSDictionary *geometry(const SourceStrokeGeometryObservation &v) {
    NSMutableArray *stages=[NSMutableArray array];
    for(const auto &s:v.stages)[stages addObject:@{@"cutoff":@(s.cutoff),@"components":@(s.components),@"pairedRays":@(s.pairedRays),
        @"pairSupport":@(s.pairSupport),@"pairedQuantiles":numbers(s.pairedQuantiles),@"componentMedian":numbers(s.componentMedian),
        @"componentUpper":numbers(s.componentUpper),@"observedFraction":@(s.observedFraction)}];
    return @{@"stages":stages,@"method":@(v.method.c_str()),@"sourcePaletteQualified":@(v.sourcePaletteQualified),@"learnedModelUsed":@(v.learnedModelUsed)};
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=3)return 2;
        NSArray *records=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
        if(!records)return 3;
        NSMutableArray *out=[NSMutableArray array];
        for(NSDictionary *r in records) {
            try {
                NSString *op=r[@"op"];double em=scalar(r[@"em"]);
                if([op isEqual:@"opposed"]) {
                    auto v=sourceWeightOpposedWidths(matrix(r[@"alpha"]),matrix(r[@"known"]),matrix(r[@"mask"]),em,[r[@"maximumEdges"] intValue]);
                    [out addObject:@{@"widths":numbers(v.widths),@"pairSupport":@(v.pairSupport)}];
                } else if([op isEqual:@"directional"]) {
                    auto cap=r[@"maximumComponentEm"]==NSNull.null?std::optional<double>{}:std::optional<double>{scalar(r[@"maximumComponentEm"])};
                    auto v=measureSourceWeightDirectional(matrix(r[@"alpha"]),matrix(r[@"known"]),em,cap);[out addObject:directional(v)];
                } else {
                    NSArray *b=r[@"bbox"];cv::Rect2d bbox(scalar(b[0]),scalar(b[1]),scalar(b[2]),scalar(b[3]));
                    cv::Mat own=matrix(r[@"ownership"]);
                    if([op isEqual:@"reconstructed"] || [op isEqual:@"alpha"]) {
                        auto a=matrix(r[@"alpha"]),known=matrix(r[@"known"]);
                        auto v=[op isEqual:@"alpha"]?observeSourceWeightStrokeAlpha(a,known,bbox,em,own,[r[@"qualified"] boolValue]):
                            observeReconstructedSourceWeightStrokeGeometry(a,known,bbox,em,own);
                        [out addObject:geometry(v)];
                    } else {
                        NSDictionary *s=r[@"style"];
                        SourceInkStyle style{paint(s[@"fill"]),paint(s[@"background"]),paint(s[@"outline"]),paint(s[@"shadow"])};
                        auto rgb=matrix(r[@"rgb"]);
                        if([op isEqual:@"colorDirectional"])[out addObject:directional(measureColorBackedSourceWeightDirectional(rgb,own,style,em))];
                        else [out addObject:geometry(observeSourceWeightStrokeGeometry(rgb,bbox,em,own,style))];
                    }
                }
            } catch(const std::exception &e) {[out addObject:@{@"error":@(e.what())}];}
        }
        NSData *data=[NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
        return data && [data writeToFile:@(argv[2]) atomically:YES]?0:4;
    }
}
