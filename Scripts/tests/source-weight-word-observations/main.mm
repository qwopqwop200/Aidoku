#import <Foundation/Foundation.h>
#include "SourceWeightWordObservations.h"
#include <cstring>
#include <stdexcept>
using namespace aidoku;using namespace aidoku::source;
namespace {
cv::Mat matrix(NSDictionary *d) {
    int h=[d[@"height"] intValue],w=[d[@"width"] intValue],t=[d[@"type"] intValue];
    NSData *b=[[NSData alloc] initWithBase64EncodedString:d[@"data"] options:0];
    cv::Mat m(h,w,t);if(b.length!=m.total()*m.elemSize())throw std::invalid_argument("Invalid matrix bytes");
    memcpy(m.data,b.bytes,b.length);cv::Mat padded(h,w+3,t),roi=padded(cv::Rect(0,0,w,h));m.copyTo(roi);return roi;
}
id encoded(const cv::Mat &m) {
    cv::Mat c=m.isContinuous()?m:m.clone();return @{@"width":@(c.cols),@"height":@(c.rows),@"type":@(c.type()),
        @"data":[[NSData dataWithBytes:c.data length:c.total()*c.elemSize()] base64EncodedStringWithOptions:0]};
}
SourceInkPaint paint(NSDictionary *d) {
    SourceInkPaint p;p.present=[d[@"present"] boolValue];p.widthPx=[d[@"widthPx"] doubleValue];
    auto rgb=[](NSArray *v){return SourceInkRGB{[v[0] doubleValue],[v[1] doubleValue],[v[2] doubleValue]};};
    if([d[@"rgb"] isKindOfClass:NSArray.class])p.rgb=rgb(d[@"rgb"]);
    for(NSArray *v in d[@"colors"])p.colors.push_back(rgb(v));
    for(NSNumber *v in d[@"observedContextWeights"])p.observedContextWeights.push_back(v.doubleValue);return p;
}
cv::Rect2d bbox(NSArray *v){return {[v[0] doubleValue],[v[1] doubleValue],[v[2] doubleValue],[v[3] doubleValue]};}
std::u32string text(NSString *s) {
    NSData *b=[s dataUsingEncoding:NSUTF32LittleEndianStringEncoding];auto p=static_cast<const char32_t *>(b.bytes);return {p,p+b.length/4};
}
WeightBandFont font(NSDictionary *d) {
    WeightBandFont f{[d[@"path"] UTF8String],[d[@"SHA256"] UTF8String],{}};
    if(d[@"weight"] && d[@"weight"]!=NSNull.null)f.weight=[d[@"weight"] doubleValue];return f;
}
template<class T> NSArray *numbers(const T &v){NSMutableArray *a=[NSMutableArray array];for(auto x:v)[a addObject:@(x)];return a;}
NSMutableDictionary *profile(const SourceWeightRegisteredProfileObservation &p) {
    NSMutableDictionary *d=[@{@"correspondingCentres":@(p.correspondingCentres),@"informativeCentres":@(p.informativeCentres),
        @"newModelCreated":@(p.newModelCreated),@"modelTrainingPerformed":@(p.modelTrainingPerformed),@"usable":@(p.usable)} mutableCopy];
    if(p.alphaLevels)d[@"alphaLevels"]=numbers(*p.alphaLevels);
    if(p.measurements) {
        const auto &m=*p.measurements;
        d[@"medianWeightFraction"]=@(m.medianWeightFraction);d[@"lowerWeightFraction"]=@(m.lowerWeightFraction);
        d[@"upperWeightFraction"]=@(m.upperWeightFraction);d[@"correspondingSourceSupport"]=@(m.correspondingSourceSupport);
        d[@"medianNormalRadiusEm"]=@(m.medianNormalRadiusEm);d[@"medianSourceRadiusEm"]=@(m.medianSourceRadiusEm);
    }
    return d;
}
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=3)return 2;
        NSDictionary *packet=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
        std::vector<WordReferencePair> pairs;
        for(NSDictionary *d in packet[@"pairs"])pairs.push_back({[d[@"name"] UTF8String],{font(d[@"regular"]),font(d[@"heavy"])},{}});
        NSMutableArray *results=[NSMutableArray array];
        for(NSDictionary *r in packet[@"records"])try {
            SourceWeightInkInput in;
            in.rgb=matrix(r[@"rgb"]);in.ownership=matrix(r[@"ownership"]);in.valid=matrix(r[@"valid"]);
            in.primary=matrix(r[@"primary"]);in.boundary=matrix(r[@"boundary"]);in.native=matrix(r[@"native"]);in.rf=matrix(r[@"rf"]);
            NSDictionary *s=r[@"style"];in.style={paint(s[@"fill"]),paint(s[@"background"]),paint(s[@"outline"]),paint(s[@"shadow"])};
            if(r[@"em"]!=NSNull.null)in.sourceEm=[r[@"em"] doubleValue];in.cutoff=r[@"cutoff"]?[r[@"cutoff"] doubleValue]:.5;
            if([r[@"op"] isEqualToString:@"prepare"]) {
                auto cleaned=cleanSourceInkStyle(in.style);
                auto p=cleaned?prepareSourceWeightPaletteWord(in.rgb,bbox(r[@"bbox"]),*in.sourceEm,text(r[@"text"]),in.ownership,*cleaned,[r[@"angle"] doubleValue]):std::nullopt;
                if(!p){[results addObject:NSNull.null];continue;}
                NSString *str=[[NSString alloc] initWithBytes:p->text.data() length:p->text.size()*4 encoding:NSUTF32LittleEndianStringEncoding];
                [results addObject:@{@"text":str,@"alpha":encoded(p->alpha),@"observed":encoded(p->known),@"vertical":@(p->vertical),
                    @"long":@(p->longExtent),@"cross":@(p->crossExtent),@"boxLong":@(p->boxLong),@"boxCross":@(p->boxCross),@"unit":@(p->unit)}];continue;
            }
            std::vector<SourceWeightRecognizedWord> members;
            for(NSDictionary *d in r[@"members"]) {
                SourceWeightRecognizedWord word{bbox(d[@"bbox"]),text(d[@"text"]),{}};
                for(NSArray *p in d[@"polygon"])word.polygon.emplace_back([p[0] floatValue],[p[1] floatValue]);members.push_back(word);
            }
            if(r[@"injectNonfiniteWord"])members.at([r[@"injectNonfiniteWord"] unsignedIntValue]).bbox.x=NAN;
            auto result=observeSourceWeightWords(in,members,pairs,static_cast<SourceWeightWordObservationPaths>(r[@"paths"]?[r[@"paths"] intValue]:3),[r[@"includeOrdered"] boolValue]);
            NSMutableArray *reference=[NSMutableArray array],*soft=[NSMutableArray array];
            for(const auto &w:result.referenceWords)[reference addObject:@{
                @"templateFit":@(w.templateFit),@"estimatedVisualWeight":@(w.estimatedVisualWeight),@"matchedReferenceWeight":@(w.matchedReferenceWeight),
                @"bestRegularTemplateFit":@(w.bestRegularTemplateFit),@"normalTemplateMargin":@(w.normalTemplateMargin),
                @"weightFraction":@(w.weightFraction),@"fractionSpread":@(w.fractionSpread),@"registeredStrokeProfile":profile(w.registeredStrokeProfile),
                @"sourceWidthsPx":numbers(w.sourceWidthsPx),@"regularWidthsPx":numbers(w.regularWidthsPx),@"heavyWidthsPx":numbers(w.heavyWidthsPx),
                @"visibleSourceFraction":@(w.visibleSourceFraction),@"referenceFamily":@(w.referenceFamily.c_str())}];
            for(const auto &w:result.softWords) {
                NSMutableDictionary *d=profile(w.profile);d[@"matchedWeight"]=@(w.matchedWeight);d[@"templateFit"]=@(w.templateFit);
                d[@"normalTemplateMargin"]=@(w.normalTemplateMargin);d[@"referenceFamily"]=@(w.referenceFamily.c_str());
                if(w.orderedGlyphs) {
                    const auto &o=*w.orderedGlyphs;NSMutableArray *glyphs=[NSMutableArray array];
                    for(const auto &g:o.glyphs) {
                        NSMutableDictionary *v=profile(g.profile);v[@"templateFit"]=@(g.templateFit);v[@"normalFit"]=@(g.normalFit);v[@"heavyFit"]=@(g.heavyFit);
                        v[@"heavyMargin"]=@(g.heavyMargin);v[@"referencePerimeterEm"]=@(g.referencePerimeterEm);v[@"referenceKnownSupport"]=@(g.referenceKnownSupport);
                        v[@"sourceInterval"]=numbers(g.sourceInterval);[glyphs addObject:v];
                    }
                    if(!o.completePartition)d[@"orderedGlyphs"]=@{@"usable":@NO,@"glyphs":glyphs,@"reason":@"No complete ordered partition"};
                    else d[@"orderedGlyphs"]=@{@"usable":@(o.usable),@"glyphs":glyphs,@"orderedGlyphCount":@(o.orderedGlyphCount),
                        @"noIndependentRadicalSearch":@YES,@"newModelCreated":@NO,@"modelTrainingPerformed":@NO};
                }
                [soft addObject:d];
            }
            auto debugInk=reconstructSourceWeightInk(in);
            [results addObject:@{@"_inkAlpha":encoded(debugInk.alpha),@"_inkKnown":encoded(debugInk.observed),@"reference":reference,@"soft":soft,@"expectedReference":@(result.expectedReferenceWordCount),
                @"expectedSoft":@(result.expectedSoftWordCount),@"orderedGlyphsImplemented":@(result.orderedGlyphsImplemented)}];
        }catch(const std::exception &e){[results addObject:@{@"error":@(e.what())}];}
        return [[NSJSONSerialization dataWithJSONObject:results options:0 error:nil] writeToFile:@(argv[2]) atomically:YES]?0:3;
    }
}
