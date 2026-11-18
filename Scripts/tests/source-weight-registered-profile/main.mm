#import <Foundation/Foundation.h>
#include "SourceWeightRegisteredProfile.h"
#include <cstring>
#include <stdexcept>
using namespace aidoku;
static cv::Mat matrix(NSDictionary *d) {
    int h=[d[@"height"] intValue],w=[d[@"width"] intValue],t=[d[@"type"] intValue];
    NSData *bytes=[[NSData alloc] initWithBase64EncodedString:d[@"data"] options:0];
    cv::Mat m(h,w,t);
    if(bytes.length!=m.total()*m.elemSize())throw std::invalid_argument("Invalid matrix bytes");
    memcpy(m.data,bytes.bytes,bytes.length);
    // Borrowed ROI with hostile neighbouring pixels: public crop boundaries
    // must match NumPy's local image, not sample the enclosing cv::Mat storage.
    cv::Mat padded(h+4,w+7,t,cv::Scalar(239));
    cv::Mat roi=padded(cv::Rect(2,2,w,h));m.copyTo(roi);return roi;
}
static double scalar(id n) {
    if([n isKindOfClass:NSString.class]) {
        if([n isEqual:@"nan"])return NAN;
        if([n isEqual:@"inf"])return INFINITY;
        if([n isEqual:@"-inf"])return -INFINITY;
    }
    return [n doubleValue];
}
static id number(double n) {
    if(std::isnan(n))return @"nan";
    if(std::isinf(n))return n>0?@"inf":@"-inf";
    return @(n);
}
static NSDictionary *observation(const SourceWeightRegisteredProfileObservation &v) {
    NSMutableDictionary *out=[@{@"correspondingCentres":@(v.correspondingCentres),@"informativeCentres":@(v.informativeCentres),
        @"newModelCreated":@(v.newModelCreated),@"modelTrainingPerformed":@(v.modelTrainingPerformed),@"usable":@(v.usable)} mutableCopy];
    if(v.alphaLevels) {
        NSMutableArray *levels=[NSMutableArray array];for(auto n:*v.alphaLevels)[levels addObject:number(n)];out[@"alphaLevels"]=levels;
    }
    if(v.measurements) {
        const auto &m=*v.measurements;
        out[@"medianWeightFraction"]=number(m.medianWeightFraction);
        out[@"lowerWeightFraction"]=number(m.lowerWeightFraction);
        out[@"upperWeightFraction"]=number(m.upperWeightFraction);
        out[@"correspondingSourceSupport"]=number(m.correspondingSourceSupport);
        out[@"medianNormalRadiusEm"]=number(m.medianNormalRadiusEm);
        out[@"medianSourceRadiusEm"]=number(m.medianSourceRadiusEm);
    }
    return out;
}
static NSDictionary *outputMatrix(const cv::Mat &m) {
    auto c=m.clone();
    return @{@"width":@(m.cols),@"height":@(m.rows),@"type":@(m.type()),
        @"data":[[NSData dataWithBytes:c.data length:c.total()*c.elemSize()] base64EncodedStringWithOptions:0]};
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=3)return 2;
        NSArray *records=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
        if(!records)return 3;
        NSMutableArray *results=[NSMutableArray array];
        for(NSDictionary *r in records) {
            try {
                NSString *op=r[@"op"];
                if([op isEqual:@"signed"])[results addObject:outputMatrix(sourceWeightRegisteredSignedDistance(matrix(r[@"binary"])))];
                else if([op isEqual:@"depth"])[results addObject:outputMatrix(sourceWeightSoftProfileDepth(matrix(r[@"alpha"])))];
                else {
                    SourceWeightRegisteredProfileInput input{matrix(r[@"source"]),matrix(r[@"regular"]),matrix(r[@"heavy"]),matrix(r[@"known"]),scalar(r[@"unit"])};
                    auto v=[op isEqual:@"soft"]?measureSourceWeightSoftStrokeProfile(input):measureSourceWeightRegisteredProfile(input);
                    [results addObject:observation(v)];
                }
            } catch(const std::exception &e) {[results addObject:@{@"error":@(e.what())}];}
        }
        NSData *out=[NSJSONSerialization dataWithJSONObject:results options:0 error:nil];
        return out && [out writeToFile:@(argv[2]) atomically:YES]?0:4;
    }
}
