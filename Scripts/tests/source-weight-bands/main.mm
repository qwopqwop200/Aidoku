#import <Foundation/Foundation.h>
#include "FontWeightBands.h"
#include <iostream>
#include <map>
namespace {
cv::Mat matrix(NSDictionary *r) {
    NSData *bytes=[[NSData alloc] initWithBase64EncodedString:r[@"data"] options:0];
    int w=[r[@"width"] intValue],h=[r[@"height"] intValue],type=[r[@"type"] intValue];
    if(w<=0 || h<=0 || (type!=CV_8U && type!=CV_32F && type!=CV_64F) || bytes.length!=size_t(w)*h*CV_ELEM_SIZE(type))
        throw std::invalid_argument("Invalid test matrix");
    return cv::Mat(h,w,type,const_cast<void *>(bytes.bytes)).clone();
}
template<class T> NSArray *array(const T &values) {
    NSMutableArray *a=[NSMutableArray array];for(auto v:values)[a addObject:@(v)];return a;
}
aidoku::WeightBandPolicy policy(NSDictionary *r) {
    return {[r[@"minimumAddedStem"] doubleValue],[r[@"minimumCommonBody"] doubleValue],
        [r[@"minimumGlyphFit"] doubleValue],[r[@"maximumReconstructionError"] doubleValue]};
}
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=3)return 2;
        NSDictionary *packet=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
        std::array<aidoku::WeightBandPair,4> pairs;
        for(int i=0;i<4;++i)for(int j=0;j<2;++j) {
            NSDictionary *r=packet[@"pairs"][i][j?@"heavy":@"regular"];
            auto &font=j?pairs[i].heavy:pairs[i].regular;
            font.path=[r[@"path"] UTF8String];font.sha256=[r[@"SHA256"] UTF8String];
            if(r[@"weight"]!=NSNull.null)font.weight=[r[@"weight"] doubleValue];
        }
        std::map<std::pair<int,uint32_t>,cv::Mat> glyphs;
        for(NSDictionary *r in packet[@"glyphs"]) {
            glyphs[{[r[@"face"] intValue],[r[@"cp"] unsignedIntValue]}]=r[@"matrix"]==NSNull.null?cv::Mat():matrix(r[@"matrix"]);
        }
        auto glyph=[&](const aidoku::WeightBandFont &font,uint32_t cp)->cv::Mat {
            int face=-1;
            for(int i=0;i<8;++i) {
                const auto &f=i%2?pairs[i/2].heavy:pairs[i/2].regular;
                if(f.path==font.path && f.sha256==font.sha256 && f.weight==font.weight){face=i;break;}
            }
            auto found=glyphs.find({face,cp});if(found==glyphs.end())throw std::invalid_argument("Missing test glyph resource");
            return found->second;
        };
        auto anchor=[&](uint32_t cp)->std::optional<double> {
            id v=packet[@"anchors"][[NSString stringWithFormat:@"%u",cp]];
            if(!v)throw std::invalid_argument("Missing test anchor resource");
            return v==NSNull.null?std::nullopt:std::optional<double>([v doubleValue]);
        };
        NSMutableArray *results=[NSMutableArray array];
        for(NSDictionary *r in packet[@"records"]) {
            try {
                NSString *op=r[@"op"];
                if([op isEqualToString:@"stats"]) {
                    [results addObject:array(aidoku::fontWeightBandStats(matrix(r[@"source"]),matrix(r[@"regular"]),matrix(r[@"heavy"]),[r[@"score"] doubleValue]))];
                } else if([op isEqualToString:@"fit"]) {
                    [results addObject:array(aidoku::fitFontWeightAffine(matrix(r[@"alpha"]),matrix(r[@"regular"]),matrix(r[@"heavy"]),[r[@"em"] doubleValue]))];
                } else if([op isEqualToString:@"confirm"]) {
                    aidoku::WeightBands bands{};for(int i=0;i<112;++i)bands[i]=[r[@"bands"][i] doubleValue];
                    [results addObject:@(aidoku::confirmFontWeightBands(bands,policy(r[@"policy"])))];
                } else {
                    NSArray *b=r[@"bbox"];
                    aidoku::WeightBandPoses supplied;const aidoku::WeightBandPoses *ptr=nullptr;
                    if(r[@"poses"]) { for(int i=0;i<192;++i)supplied[i]=[r[@"poses"][i] doubleValue];ptr=&supplied; }
                    auto result=aidoku::measureFontWeightBands(matrix(r[@"alpha"]),
                        {[b[0] doubleValue],[b[1] doubleValue],[b[2] doubleValue],[b[3] doubleValue]},
                        [r[@"angle"] doubleValue],[r[@"em"] doubleValue],[r[@"text"] UTF8String],pairs,glyph,anchor,ptr);
                    [results addObject:@{@"poses":array(result.poses),@"bands":array(result.bands),
                        @"confirmed":@(aidoku::confirmFontWeightBands(result.bands,policy(r[@"policy"])))}];
                }
            }catch(const std::exception &e){[results addObject:@{@"error":@(e.what())}];}
        }
        return [[NSJSONSerialization dataWithJSONObject:results options:0 error:nil] writeToFile:@(argv[2]) atomically:YES]?0:3;
    }
}
