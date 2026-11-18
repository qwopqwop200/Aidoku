#import <Foundation/Foundation.h>
// Test the exact internal production provider's bytes/anchor metrics as well
// as the public adapter, without exporting a diagnostic production API.
#include "FontWeightBandSource.mm"
#include <iostream>
namespace {
cv::Mat matrix(NSDictionary *r) {
    NSData *data=[[NSData alloc] initWithBase64EncodedString:r[@"data"] options:0];
    int w=[r[@"width"] intValue],h=[r[@"height"] intValue],type=[r[@"type"] intValue];
    if(w<=0 || h<=0 || data.length!=size_t(w)*h*CV_ELEM_SIZE(type))throw std::invalid_argument("Test matrix");
    return cv::Mat(h,w,type,const_cast<void *>(data.bytes)).clone();
}
id encoded(const cv::Mat &m) {
    if(m.empty())return NSNull.null;
    cv::Mat c=m.isContinuous()?m:m.clone();
    NSData *data=[NSData dataWithBytes:c.data length:c.total()*c.elemSize()];
    return @{@"width":@(c.cols),@"height":@(c.rows),@"data":[data base64EncodedStringWithOptions:0]};
}
template<class T> NSArray *numbers(const T &v) {
    NSMutableArray *a=[NSMutableArray array];for(auto x:v)[a addObject:@(x)];return a;
}
std::array<aidoku::WeightBandPair,4> pairsFrom(NSArray *records) {
    std::array<aidoku::WeightBandPair,4> pairs;
    for(int i=0;i<4;++i)for(int j=0;j<2;++j) {
        NSDictionary *r=records[i][j?@"heavy":@"regular"];
        auto &f=j?pairs[i].heavy:pairs[i].regular;
        f.path=[r[@"path"] UTF8String];f.sha256=[r[@"SHA256"] UTF8String];
        if(r[@"weight"]!=NSNull.null)f.weight=[r[@"weight"] doubleValue];
    }
    return pairs;
}
aidoku::source::FontTemplateInputs inputFrom(NSDictionary *r) {
    aidoku::source::FontTemplateInputs in;
    in.rgb=matrix(r[@"rgb"]);
    in.prior=[r[@"prior"] doubleValue];
    NSArray *b=r[@"bbox"];
    in.bbox={[b[0] doubleValue],[b[1] doubleValue],[b[2] doubleValue],[b[3] doubleValue]};
    NSString *text=r[@"text"];
    NSData *data=[text dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const char32_t *p=static_cast<const char32_t *>(data.bytes);in.text.assign(p,p+data.length/4);
    NSDictionary *anchor=r[@"anchor"];
    std::string key=[anchor[@"key"] UTF8String];
    in.fonts={key};
    if(anchor[@"path"])in.fontFiles[key]=[anchor[@"path"] UTF8String];
    if(anchor[@"face"])in.fontFaceIndices[key]=[anchor[@"face"] intValue];
    if(anchor[@"weight"] && anchor[@"weight"]!=NSNull.null)in.fontWeights[key]=[anchor[@"weight"] doubleValue];
    return in;
}
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=3)return 2;
        NSDictionary *packet=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
        NSMutableArray *results=[NSMutableArray array];
        for(NSDictionary *r in packet[@"records"]) {
            try {
                auto pairs=pairsFrom(r[@"pairs"]?:packet[@"pairs"]);
                auto in=inputFrom(r);
                if([r[@"op"] isEqualToString:@"resources"]) {
                    aidoku::source::BandSourceResources resources(in,pairs);
                    NSMutableArray *rasters=[NSMutableArray array],*anchors=[NSMutableArray array];
                    for(NSNumber *cp in r[@"codepoints"]) {
                        auto metric=resources.anchor(cp.unsignedIntValue);
                        [anchors addObject:metric?@(metric.value()):NSNull.null];
                        NSMutableArray *faces=[NSMutableArray array];
                        for(auto &pair:pairs)for(auto *font:{&pair.regular,&pair.heavy})
                            [faces addObject:encoded(resources.glyph(*font,cp.unsignedIntValue))];
                        [rasters addObject:faces];
                    }
                    [results addObject:@{@"rasters":rasters,@"anchors":anchors}];
                } else if([r[@"op"] isEqualToString:@"legacy"]) {
                    uint32_t cp=[r[@"cp"] unsignedIntValue];auto font=pairs[0].regular;
                    ACVGlyph a{},b{},c{};
                    int legacy=acv_glyph(font.path.c_str(),0,cp,128*64,&a);
                    int strict=acv_glyph_with_weight(font.path.c_str(),0,cp,128*64,*font.weight,&b);
                    int reference=acv_reference_glyph_with_weight(font.path.c_str(),0,cp,128*64,*font.weight,&c);
                    id rawA=a.pixels?encoded(cv::Mat(a.height,a.width,CV_8U,a.pixels,a.pitch)):NSNull.null;
                    id rawC=c.pixels?encoded(cv::Mat(c.height,c.width,CV_8U,c.pixels,c.pitch)):NSNull.null;
                    [results addObject:@{@"defaultCode":@(legacy),@"strictCode":@(strict),@"referenceCode":@(reference),@"default":rawA,@"reference":rawC}];
                    acv_glyph_free(&a);acv_glyph_free(&b);acv_glyph_free(&c);
                } else {
                    auto result=aidoku::source::measureSourceWeightBands(in,matrix(r[@"alpha"]),[r[@"em"] doubleValue],[r[@"angle"] doubleValue],pairs);
                    [results addObject:@{@"poses":numbers(result.poses),@"bands":numbers(result.bands)}];
                }
            }catch(const std::exception &e){[results addObject:@{@"error":@(e.what())}];}
        }
        return [[NSJSONSerialization dataWithJSONObject:results options:0 error:nil] writeToFile:@(argv[2]) atomically:YES]?0:3;
    }
}
