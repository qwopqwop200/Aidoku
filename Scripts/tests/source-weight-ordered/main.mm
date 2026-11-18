#import <Foundation/Foundation.h>
#include "SourceWeightOrderedGlyph.h"
#include <cstring>
using namespace aidoku::source;
NSArray* vector(const std::array<int,2>& v){return @[@(v[0]),@(v[1])];}
NSDictionary* profile(const aidoku::SourceWeightRegisteredProfileObservation& p){
    NSMutableDictionary* d=[@{@"usable":@(p.usable),@"informativeCentres":@(p.informativeCentres),@"correspondingCentres":@(p.correspondingCentres),@"newModelCreated":@NO,@"modelTrainingPerformed":@NO} mutableCopy];
    if(p.alphaLevels){NSMutableArray* a=[NSMutableArray array];for(double v:*p.alphaLevels)[a addObject:@(v)];d[@"alphaLevels"]=a;}
    if(p.measurements){auto m=*p.measurements;d[@"medianWeightFraction"]=@(m.medianWeightFraction);d[@"lowerWeightFraction"]=@(m.lowerWeightFraction);d[@"upperWeightFraction"]=@(m.upperWeightFraction);d[@"correspondingSourceSupport"]=@(m.correspondingSourceSupport);d[@"medianNormalRadiusEm"]=@(m.medianNormalRadiusEm);d[@"medianSourceRadiusEm"]=@(m.medianSourceRadiusEm);}
    return d;
}
int main(int argc,const char** argv){@autoreleasepool {
 if(argc!=3)return 1;NSArray* inputs=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];NSMutableArray* outputs=[NSMutableArray array];
 for(NSDictionary* row in inputs){try{
  int h=[row[@"height"] intValue],w=[row[@"width"] intValue];NSData* a=[[NSData alloc]initWithBase64EncodedString:row[@"alpha"] options:0];NSData* k=[[NSData alloc]initWithBase64EncodedString:row[@"known"] options:0];if(a.length!=h*w*4||k.length!=h*w)return 2;
  cv::Mat alpha(h,w,CV_32F,(void*)a.bytes),known(h,w,CV_8U,(void*)k.bytes);
  WordReferencePair pair;pair.family="reference";
  for(NSString* role in @[@"regular",@"heavy"]){NSDictionary* f=row[@"family"][role];aidoku::WeightBandFont face{[f[@"path"] UTF8String],[f[@"SHA256"] UTF8String],std::nullopt};if(f[@"weight"]&&f[@"weight"]!=NSNull.null)face.weight=[f[@"weight"] doubleValue];if([role isEqualToString:@"regular"])pair.faces.regular=face;else pair.faces.heavy=face;}
  NSString* str=row[@"text"];NSData* text=[str dataUsingEncoding:NSUTF32LittleEndianStringEncoding];std::u32string t(text.length/4,0);memcpy(t.data(),text.bytes,text.length);
  auto result=measureSourceWeightOrderedGlyphs(alpha,known,t,[row[@"vertical"] boolValue],pair,[row[@"unit"] doubleValue],[row[@"soft"] boolValue]);NSMutableArray* glyphs=[NSMutableArray array];
  for(const auto& glyph:result.glyphs){NSMutableDictionary* d=[profile(glyph.profile) mutableCopy];d[@"templateFit"]=@(glyph.templateFit);d[@"normalFit"]=@(glyph.normalFit);d[@"heavyFit"]=@(glyph.heavyFit);d[@"heavyMargin"]=@(glyph.heavyMargin);d[@"referencePerimeterEm"]=@(glyph.referencePerimeterEm);d[@"referenceKnownSupport"]=@(glyph.referenceKnownSupport);d[@"sourceInterval"]=vector(glyph.sourceInterval);[glyphs addObject:d];}
  NSMutableDictionary* d=[@{@"usable":@(result.usable),@"glyphs":glyphs} mutableCopy];if(result.completePartition){d[@"orderedGlyphCount"]=@(result.orderedGlyphCount);d[@"noIndependentRadicalSearch"]=@YES;d[@"newModelCreated"]=@NO;d[@"modelTrainingPerformed"]=@NO;}else d[@"reason"]=@"No complete ordered partition";[outputs addObject:d];
 }catch(const std::exception& e){[outputs addObject:@{@"error":@(e.what())}];}}
 NSData* data=[NSJSONSerialization dataWithJSONObject:outputs options:0 error:nil];return [data writeToFile:@(argv[2]) atomically:YES]?0:3;
}}
