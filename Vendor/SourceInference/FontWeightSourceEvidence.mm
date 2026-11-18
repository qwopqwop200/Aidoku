#import "FontWeightSourceEvidence.h"
#import "FontTemplateFeatures.h"
#include "SourceWeightStrokeGeometry.h"
#include "FontWeightBandSource.h"
#include "Sources/SourceWeightFeatures.hpp"
#include "SourceWeightWordObservations.h"
#include "AidokuNativeCV.h"
#include <opencv2/imgproc.hpp>
#include <cmath>
#include <cstring>
#include <stdexcept>
namespace {
using namespace aidoku;
using namespace aidoku::source;
NSArray* numbers(const std::vector<double>& values){NSMutableArray* a=[NSMutableArray array];for(double v:values)[a addObject:@(v)];return a;}
template<size_t N> NSArray* numbers(const std::array<double,N>& values){return numbers(std::vector<double>(values.begin(),values.end()));}
std::u32string text(NSString* value){if(![value isKindOfClass:NSString.class])throw std::invalid_argument("Original recognized text required");NSData* d=[value dataUsingEncoding:NSUTF32LittleEndianStringEncoding];if(!d)throw std::invalid_argument("Invalid Unicode source");std::u32string v(d.length/4,0);memcpy(v.data(),d.bytes,d.length);return v;}
cv::Mat tensor(NSDictionary* packet,NSString* key,int h,int w,int channels,bool floating){
 id value=packet[key];size_t count=size_t(h)*w*channels,bytes=count*(floating?sizeof(float):1);
 if(![value isKindOfClass:NSData.class]||[value length]!=bytes)throw std::invalid_argument("Source observation tensor geometry differs");
 cv::Mat result(h,w,CV_MAKETYPE(floating?CV_32F:CV_8U,channels),(void*)[value bytes]);result=result.clone();
 if(floating){if(!cv::checkRange(result))throw std::invalid_argument("Nonfinite source observations");double low,high;cv::minMaxLoc(result.reshape(1),&low,&high);if(low<0||high>1.001)throw std::invalid_argument("Source observation probabilities differ");}
 return result;
}
SourceInkPaint paint(const SourcePaintPart& p){SourceInkPaint v;v.present=p.present;v.widthPx=p.widthPx;if(p.hasRGB)v.rgb=SourceInkRGB{p.rgb[0],p.rgb[1],p.rgb[2]};for(auto c:p.colors)v.colors.push_back({c[0],c[1],c[2]});return v;}
SourceWeightInkInput inkInput(NSDictionary* packet,const FontTemplateInputs& input,double em){
 int h=input.rgb.rows,w=input.rgb.cols;SourceWeightInkInput v;v.rgb=input.rgb;v.ownership=input.ownership;v.sourceEm=em;
 v.primary=tensor(packet,@"primary",h,w,1,true);v.boundary=tensor(packet,@"boundary",h,w,1,true);v.rf=tensor(packet,@"rf",h,w,27,true);v.valid=tensor(packet,@"valid",h,w,1,false);
 cv::Mat native=tensor(packet,@"nativeMask",h,w,1,false);double lo,hi;cv::minMaxLoc(v.valid,&lo,&hi);if(hi>1||cv::countNonZero(v.valid)==0)throw std::invalid_argument("Unknown valid observation support");
 for(int y=0;y<h;++y)for(int x=0;x<w;++x){int p=native.at<uchar>(y,x);if(p!=0&&p!=1&&p!=255)throw std::invalid_argument("Invalid native source mask");}native.convertTo(v.native,CV_32F);
 v.style.fill=paint(input.style.fill);v.style.background=paint(input.style.background);v.style.outline=paint(input.style.outline);v.style.shadow=paint(input.style.shadow);
 id weights=packet[@"style"][@"background"][@"observedContextWeights"];
 if(weights==NSNull.null){
  // The source appearance schema explicitly records unknown observed mass.
  // Do not invent palette probabilities or treat malformed nulls as evidence.
  id insufficient=packet[@"style"][@"background"][@"insufficientObservedContext"];
  if(![insufficient isKindOfClass:NSNumber.class]||![insufficient isEqualToNumber:@YES])throw std::invalid_argument("Unknown background palette weights require insufficient observed context");
 }else if(weights){if(![weights isKindOfClass:NSArray.class])throw std::invalid_argument("Invalid background palette weights");for(id n in weights){if(![n isKindOfClass:NSNumber.class]||!std::isfinite([n doubleValue]))throw std::invalid_argument("Invalid background weight");v.style.background.observedContextWeights.push_back([n doubleValue]);}}
 return v;
}
WeightBandFont face(NSDictionary* record){
 if(![record isKindOfClass:NSDictionary.class])throw std::invalid_argument("Reference face required");
 NSString* path=record[@"path"],*sha=record[@"SHA256"];
 if(![path isKindOfClass:NSString.class]||!path.length||![sha isKindOfClass:NSString.class]||sha.length!=64)throw std::invalid_argument("Pinned reference font required");
 if(record[@"faceIndex"]&&record[@"faceIndex"]!=NSNull.null&&[record[@"faceIndex"] doubleValue]!=0)throw std::invalid_argument("Public reference face0 required");
 WeightBandFont font{path.fileSystemRepresentation,sha.UTF8String,std::nullopt};id weight=record[@"weight"];
 if(weight&&weight!=NSNull.null){if(![weight isKindOfClass:NSNumber.class]||!std::isfinite([weight doubleValue]))throw std::invalid_argument("Invalid reference weight");font.weight=[weight doubleValue];}return font;
}
std::vector<WordReferencePair> pairs(NSArray* records){
 if(![records isKindOfClass:NSArray.class]||records.count==0||records.count>32)throw std::invalid_argument("Explicit reference pairs required");std::vector<WordReferencePair> result;
 for(NSDictionary* row in records){NSString* name=row[@"name"];if(![name isKindOfClass:NSString.class])throw std::invalid_argument("Reference family missing");result.push_back({name.UTF8String,{face(row[@"regular"]),face(row[@"heavy"])},std::nullopt});}return result;
}
std::vector<SourceWeightRecognizedWord> words(NSArray* rows){
 if(![rows isKindOfClass:NSArray.class]||rows.count>256)throw std::invalid_argument("Original recognized word rows required");std::vector<SourceWeightRecognizedWord> result;
 for(NSDictionary* row in rows){NSArray* b=row[@"bbox"],*polygon=row[@"polygon"];if(![b isKindOfClass:NSArray.class]||b.count!=4||![polygon isKindOfClass:NSArray.class]||polygon.count<3||polygon.count>256)throw std::invalid_argument("Invalid original word geometry");
  double values[4];for(int i=0;i<4;++i){if(![b[i] isKindOfClass:NSNumber.class]||!std::isfinite([b[i] doubleValue]))throw std::invalid_argument("Invalid word bbox");values[i]=[b[i] doubleValue];}if(values[2]<=0||values[3]<=0)throw std::invalid_argument("Empty word bbox");
  SourceWeightRecognizedWord v{{values[0],values[1],values[2],values[3]},text(row[@"text"]),{}};
  for(NSArray* p in polygon){if(![p isKindOfClass:NSArray.class]||p.count!=2||![p[0] isKindOfClass:NSNumber.class]||![p[1] isKindOfClass:NSNumber.class]||!std::isfinite([p[0] doubleValue])||!std::isfinite([p[1] doubleValue]))throw std::invalid_argument("Invalid word polygon");v.polygon.push_back({[p[0] floatValue],[p[1] floatValue]});}result.push_back(v);
 }return result;
}
int informativeGlyphs(const std::vector<SourceWeightRecognizedWord>& members,NSDictionary* policy){
 auto font=face(policy[@"informationFont"]);SourceWeightReferenceGrid grid;grid.nominalWeight(font);
 id limit=policy[@"minimumReferencePerimeterEm"];if(![limit isKindOfClass:NSNumber.class]||!std::isfinite([limit doubleValue]))throw std::invalid_argument("Reference perimeter threshold required");
 std::vector<cv::Rect2d> accepted;int total=0;
 for(size_t j=0;j<std::min(size_t(6),members.size());++j){size_t index=members.size()>6?size_t(double(j)*(members.size()-1)/5):j;const auto& word=members[index];auto b=word.bbox;bool duplicate=false;
  for(auto a:accepted){double overlap=std::max(0.,std::min(b.x+b.width,a.x+a.width)-std::max(b.x,a.x))*std::max(0.,std::min(b.y+b.height,a.y+a.height)-std::max(b.y,a.y));if(overlap/std::max(1e-6,std::min(b.area(),a.area()))>=.8){duplicate=true;break;}}
  if(duplicate)continue;accepted.push_back(b);
  NSString* supplied=[[NSString alloc]initWithBytes:word.text.data() length:word.text.size()*4 encoding:NSUTF32LittleEndianStringEncoding];auto chars=text(supplied.precomposedStringWithCanonicalMapping);
  for(char32_t c:chars){if(![NSCharacterSet.alphanumericCharacterSet longCharacterIsMember:c]||[NSCharacterSet.nonBaseCharacterSet longCharacterIsMember:c])continue;
   int supported=0;if(acv_font_has_glyph(font.path.c_str(),0,c,&supported)!=0)throw std::invalid_argument("Reference cmap failed");if(!supported)continue;ACVGlyph glyph={};
   int status=font.weight?acv_glyph_with_weight(font.path.c_str(),0,c,128*64,std::trunc(*font.weight),&glyph):acv_glyph(font.path.c_str(),0,c,128*64,&glyph);
   if(status!=0)throw std::invalid_argument("Reference glyph failed");double perimeter=0;
   if(glyph.pixels&&glyph.width>0&&glyph.height>0){cv::Mat raster(glyph.height,glyph.width,CV_8U,glyph.pixels,glyph.pitch);std::vector<std::vector<cv::Point>> contours;cv::findContours(raster>127,contours,cv::RETR_LIST,cv::CHAIN_APPROX_SIMPLE);for(const auto& contour:contours)perimeter+=cv::arcLength(contour,true)/128;}
   acv_glyph_free(&glyph);total+=perimeter>=[limit doubleValue];
  }
 }return total;
}
NSMutableDictionary* profile(const SourceWeightRegisteredProfileObservation& p){
 NSMutableDictionary* d=[@{@"usable":@(p.usable),@"informativeCentres":@(p.informativeCentres),@"correspondingCentres":@(p.correspondingCentres),@"newModelCreated":@NO,@"modelTrainingPerformed":@NO} mutableCopy];if(p.alphaLevels)d[@"alphaLevels"]=numbers(*p.alphaLevels);
 if(p.measurements){const auto& m=*p.measurements;d[@"medianWeightFraction"]=@(m.medianWeightFraction);d[@"lowerWeightFraction"]=@(m.lowerWeightFraction);d[@"upperWeightFraction"]=@(m.upperWeightFraction);d[@"correspondingSourceSupport"]=@(m.correspondingSourceSupport);d[@"medianNormalRadiusEm"]=@(m.medianNormalRadiusEm);d[@"medianSourceRadiusEm"]=@(m.medianSourceRadiusEm);}return d;
}
NSDictionary* ordered(const SourceWeightOrderedObservation& o){NSMutableArray* glyphs=[NSMutableArray array];for(const auto& g:o.glyphs){auto d=profile(g.profile);d[@"templateFit"]=@(g.templateFit);d[@"normalFit"]=@(g.normalFit);d[@"heavyFit"]=@(g.heavyFit);d[@"heavyMargin"]=@(g.heavyMargin);d[@"referencePerimeterEm"]=@(g.referencePerimeterEm);d[@"referenceKnownSupport"]=@(g.referenceKnownSupport);d[@"sourceInterval"]=@[@(g.sourceInterval[0]),@(g.sourceInterval[1])];[glyphs addObject:d];}
 if(!o.completePartition)return @{@"usable":@NO,@"glyphs":glyphs,@"reason":@"No complete ordered partition"};return @{@"usable":@(o.usable),@"glyphs":glyphs,@"orderedGlyphCount":@(o.orderedGlyphCount),@"noIndependentRadicalSearch":@YES,@"newModelCreated":@NO,@"modelTrainingPerformed":@NO};}
NSDictionary* directional(const SourceStrokeDirectionalObservation& o){NSMutableDictionary* groups=[NSMutableDictionary dictionary];for(const auto& [name,g]:o.groups)groups[@(name.c_str())]=@{@"count":@(g.count),@"quantiles":numbers(g.quantiles)};return @{@"groups":groups,@"components":@(o.components),@"directionContrast":o.directionContrast?@(*o.directionContrast):(id)NSNull.null,@"minimumDirectionalMedian":@(o.minimumDirectionalMedian),@"newModelCreated":@NO,@"modelTrainingPerformed":@NO};}
}
NSDictionary<NSString*,id>* AIDMeasureSourceWeightImageEvidence(NSDictionary* packet,NSError** error){try{
 using namespace aidoku;using namespace aidoku::source;
 if(![packet isKindOfClass:NSDictionary.class])throw std::invalid_argument("Source evidence packet required");
 auto input=fontTemplateInputsFromDictionary(packet);id value=packet[@"sourceEm"];
 if(![value isKindOfClass:NSNumber.class]||!std::isfinite([value doubleValue])||[value doubleValue]<=0)throw std::invalid_argument("Positive final source em required");double em=[value doubleValue];NSString* kind=packet[@"kind"];
 if(![kind isKindOfClass:NSString.class])throw std::invalid_argument("Source evidence kind required");
 if([kind isEqualToString:@"normalization"]||[kind isEqualToString:@"normalization-bands"]){
  auto alpha=sourceFillAlpha(input);
  if([kind isEqualToString:@"normalization"]){cv::Mat ownership=input.ownership!=0;ownership/=255;WeightFillStyle style{input.style.fill.rgb,input.style.background.rgb,input.style.outline.present,input.style.outline.widthPx};return @{@"fill71":numbers(weightFill71V1(alpha,input.bbox,em,ownership,style))};}
  auto references=pairs(packet[@"referenceInkPairs"]);if(references.size()!=4)throw std::invalid_argument("Four band references required");std::array<WeightBandPair,4> bands;for(size_t i=0;i<4;++i)bands[i]=references[i].faces;
  id angle=packet[@"sourceAngle"];if(![angle isKindOfClass:NSNumber.class]||!std::isfinite([angle doubleValue]))throw std::invalid_argument("Source angle required");return @{@"bands112":numbers(measureSourceWeightBands(input,alpha,em,[angle doubleValue],bands).bands)};
 }
 auto ink=inkInput(packet,input,em);
 if([kind isEqualToString:@"directional"])return @{@"color":directional(measureColorBackedSourceWeightDirectional(input.rgb,input.ownership,ink.style,em))};
 if([kind isEqualToString:@"eligibility"]){auto signal=reconstructSegmentedSourceWeightInk(ink);auto observed=observeReconstructedSourceWeightStrokeGeometry(signal.alpha,signal.observed,input.bbox,em,input.ownership);NSMutableArray* stages=[NSMutableArray array];for(const auto& s:observed.stages)[stages addObject:@{@"pairedQuantiles":numbers(s.pairedQuantiles),@"components":@(s.components)}];return @{@"stages":stages};}
 if([kind isEqualToString:@"information"])return @{@"informativeGlyphs":@(informativeGlyphs(words(packet[@"wordMembers"]),packet[@"policy"]))};
 if(![kind isEqualToString:@"reference"]&&![kind isEqualToString:@"soft"])throw std::invalid_argument("Unknown source evidence kind");
 auto members=words(packet[@"wordMembers"]);auto references=pairs(packet[@"referenceInkPairs"]);bool isSoft=[kind isEqualToString:@"soft"];
 auto observed=observeSourceWeightWords(ink,members,references,isSoft?SourceWeightWordObservationPaths::Soft:SourceWeightWordObservationPaths::Reference,[packet[@"includeOrdered"] boolValue]);NSMutableArray* rows=[NSMutableArray array];
 if(isSoft){for(const auto& w:observed.softWords){auto d=profile(w.profile);d[@"matchedWeight"]=@(w.matchedWeight);d[@"templateFit"]=@(w.templateFit);d[@"normalTemplateMargin"]=@(w.normalTemplateMargin);d[@"referenceFamily"]=@(w.referenceFamily.c_str());if(w.orderedGlyphs)d[@"orderedGlyphs"]=ordered(*w.orderedGlyphs);[rows addObject:d];}return @{@"words":rows,@"expectedWordCount":@(observed.expectedSoftWordCount)};}
 for(const auto& w:observed.referenceWords)[rows addObject:@{@"templateFit":@(w.templateFit),@"estimatedVisualWeight":@(w.estimatedVisualWeight),@"matchedReferenceWeight":@(w.matchedReferenceWeight),@"bestRegularTemplateFit":@(w.bestRegularTemplateFit),@"normalTemplateMargin":@(w.normalTemplateMargin),@"weightFraction":@(w.weightFraction),@"fractionSpread":@(w.fractionSpread),@"registeredStrokeProfile":profile(w.registeredStrokeProfile),@"sourceWidthsPx":numbers(w.sourceWidthsPx),@"regularWidthsPx":numbers(w.regularWidthsPx),@"heavyWidthsPx":numbers(w.heavyWidthsPx),@"visibleSourceFraction":@(w.visibleSourceFraction),@"referenceFamily":@(w.referenceFamily.c_str())}];
 return @{@"words":rows,@"newModelCreated":@NO,@"modelTrainingPerformed":@NO};
 }catch(const std::exception& exception){if(error)*error=[NSError errorWithDomain:@"Aidoku.SourceWeightImageEvidence" code:1 userInfo:@{NSLocalizedDescriptionKey:@(exception.what())}];return nil;}}
