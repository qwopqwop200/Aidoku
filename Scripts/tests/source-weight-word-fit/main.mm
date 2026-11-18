#import <Foundation/Foundation.h>
#include "SourceWeightReferenceGrid.h"
#include "SourceWeightWordFit.h"
#include <iostream>
using namespace aidoku;using namespace aidoku::source;
namespace {
WeightBandFont font(NSDictionary *r) {
    WeightBandFont f{[r[@"path"] UTF8String],[r[@"SHA256"] UTF8String],{}};
    if(r[@"weight"] && r[@"weight"]!=NSNull.null)f.weight=[r[@"weight"] doubleValue];return f;
}
WeightBandPair faces(NSDictionary *r){return {font(r[@"regular"]),font(r[@"heavy"])};}
WordReferencePair pair(NSDictionary *r) {
    WordReferencePair p{[r[@"name"] UTF8String],faces(r),{}};
    if(r[@"_frame"])p.frame=faces(r[@"_frame"]);return p;
}
std::u32string text(NSString *s) {
    NSData *data=[s dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    auto p=static_cast<const char32_t *>(data.bytes);return {p,p+data.length/4};
}
id encoded(const cv::Mat &m) {
    cv::Mat c=m.isContinuous()?m:m.clone();
    NSData *d=[NSData dataWithBytes:c.data length:c.total()*c.elemSize()];
    return @{@"width":@(c.cols),@"height":@(c.rows),@"data":[d base64EncodedStringWithOptions:0]};
}
cv::Mat matrix(NSDictionary *r) {
    NSData *d=[[NSData alloc] initWithBase64EncodedString:r[@"data"] options:0];
    int w=[r[@"width"] intValue],h=[r[@"height"] intValue],type=[r[@"type"] intValue];
    if(d.length!=size_t(w)*h*CV_ELEM_SIZE(type))throw std::invalid_argument("Test matrix length");
    return cv::Mat(h,w,type,const_cast<void *>(d.bytes)).clone();
}
PreparedSourceWeightWord prepared(NSDictionary *r) {
    PreparedSourceWeightWord p;
    p.text=text(r[@"text"]);p.alpha=matrix(r[@"alpha"]);p.known=matrix(r[@"known"]);
    p.vertical=[r[@"vertical"] boolValue];p.longExtent=[r[@"long"] doubleValue];p.crossExtent=[r[@"crossExtent"] doubleValue];
    p.boxLong=[r[@"boxLong"] doubleValue];p.boxCross=[r[@"boxCross"] doubleValue];p.unit=[r[@"unit"] doubleValue];return p;
}
template<class T> NSArray *numbers(const T &v) {NSMutableArray *a=[NSMutableArray array];for(auto x:v)[a addObject:@(x)];return a;}
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=3)return 2;
        NSArray *records=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
        NSMutableArray *out=[NSMutableArray array];SourceWeightReferenceGrid renderer;
        for(NSDictionary *r in records)try {
            NSString *op=r[@"op"];
            if([op isEqualToString:@"correlation"]) {
                auto map=correlateSourceWeightWord(matrix(r[@"source"]),matrix(r[@"known"]),matrix(r[@"pattern"]));
                [out addObject:map.empty()?NSNull.null:encoded(map)];continue;
            }
            if([op isEqualToString:@"locate"]) {
                auto found=locateSourceWeightWord(matrix(r[@"source"]),matrix(r[@"known"]),{matrix(r[@"a"]),matrix(r[@"b"])});
                if(found)[out addObject:@[@(found->score),@(found->regular),@(found->heavy),@(found->x),@(found->y)]];
                else [out addObject:NSNull.null];continue;
            }
            if([op isEqualToString:@"fit"]) {
                auto fit=fitSourceWeightWord(prepared(r[@"prepared"]),pair(r[@"pair"]),renderer,[r[@"refine"] boolValue],
                    [r[@"grid"] boolValue]?SourceWeightWordRenderer::SharedFrame:SourceWeightWordRenderer::WordMasks);
                [out addObject:numbers(fit)];continue;
            }
            if([op isEqualToString:@"fair"]) {
                std::vector<WordReferencePair> refs;for(NSDictionary *record in r[@"pairs"])refs.push_back(pair(record));
                auto fits=fairSourceWeightFaceFits(prepared(r[@"prepared"]),refs);NSMutableArray *rows=[NSMutableArray array];
                for(auto &fit:fits)[rows addObject:@{@"family":@(fit.reference.family.c_str()),@"weight":@(fit.nominalWeight),@"fit":numbers(fit.fit)}];
                [out addObject:rows];continue;
            }
            auto p=pair(r[@"pair"]);bool vertical=[r[@"vertical"] boolValue];double tracking=[r[@"tracking"] doubleValue];
            auto masks=[r[@"op"] isEqualToString:@"word"]?renderer.wordMasks(p,text(r[@"text"]),vertical,tracking):renderer.masks(p,text(r[@"text"]),vertical,tracking);
            if(!masks){[out addObject:NSNull.null];continue;}
            if(r[@"scale"])masks=transformSourceWeightWord(*masks,[r[@"scale"] doubleValue],[r[@"cross"] doubleValue],[r[@"angle"] doubleValue],vertical);
            [out addObject:@[encoded((*masks)[0]),encoded((*masks)[1])]];
        }catch(const std::exception &e){[out addObject:@{@"error":@(e.what())}];}
        return [[NSJSONSerialization dataWithJSONObject:out options:0 error:nil] writeToFile:@(argv[2]) atomically:YES]?0:3;
    }
}
