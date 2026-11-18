#import <Foundation/Foundation.h>
#include "SourceWeightWordObservations.h"
#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <cmath>
#include <map>
#include <stdexcept>
#ifdef __clang__
#pragma clang fp contract(off)
#endif
namespace aidoku::source {
namespace {
void observationCheck(bool ok,const char *why) {if(!ok)throw std::invalid_argument(why);}
cv::Mat boolMap(const cv::Mat &m){cv::Mat b=m!=0;b/=255;return b;}
int roundEven(double v){double a=std::floor(v),f=v-a;return int(a+(f>.5 || (f==.5 && std::fmod(a,2.)!=0)));}
double quantile(std::vector<double> values,double q) {
    if(values.empty())return 0;std::sort(values.begin(),values.end());double p=(values.size()-1)*q;
    size_t i=size_t(p);double f=p-i,a=values[i],b=values[std::min(i+1,values.size()-1)];return f>=.5?b-(b-a)*(1-f):a+(b-a)*f;
}
bool punctuationOrSymbol(uint32_t cp) {
    return [[NSCharacterSet punctuationCharacterSet] longCharacterIsMember:cp] || [[NSCharacterSet symbolCharacterSet] longCharacterIsMember:cp];
}
std::u32string normalizedWord(const std::u32string &s) {
    for(uint32_t cp:s)observationCheck(cp<=0x10ffff && !(cp>=0xd800 && cp<=0xdfff),"Invalid recognized word scalar");
    NSString *text=[[NSString alloc] initWithBytes:s.data() length:s.size()*4 encoding:NSUTF32LittleEndianStringEncoding];
    observationCheck(text!=nil,"Invalid original recognized text");
    NSData *data=[text.precomposedStringWithCanonicalMapping dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    auto cp=static_cast<const char32_t *>(data.bytes);std::u32string out;
    for(size_t i=0;i<data.length/4;++i) {
        // Python str.isspace additionally includes ASCII information separators.
        if((cp[i]>=0x1c && cp[i]<=0x1f) || [[NSCharacterSet whitespaceAndNewlineCharacterSet] longCharacterIsMember:cp[i]])continue;
        out+=cp[i];
    }
    return out;
}
bool hasLetterOrNumber(const std::u32string &text) {
    for(uint32_t cp:text)if([[NSCharacterSet alphanumericCharacterSet] longCharacterIsMember:cp] &&
        ![[NSCharacterSet nonBaseCharacterSet] longCharacterIsMember:cp])return true;
    return false;
}
cv::Mat rotateObservation(const cv::Mat &image,double angle,bool nearest=false) {
    int w=image.cols,h=image.rows;auto m=cv::getRotationMatrix2D(cv::Point2f(w/2.f,h/2.f),angle,1);
    double c=std::abs(m.at<double>(0,0)),s=std::abs(m.at<double>(0,1));
    int nw=int(std::ceil(w*c+h*s)),nh=int(std::ceil(h*c+w*s));
    m.at<double>(0,2)+=(nw-w)/2.;m.at<double>(1,2)+=(nh-h)/2.;
    cv::Mat out;cv::warpAffine(image,out,m,{nw,nh},nearest?cv::INTER_NEAREST:cv::INTER_LINEAR,cv::BORDER_CONSTANT,0);return out;
}
double polygonAngle(const std::vector<cv::Point2f> &polygon) {
    if(polygon.empty())return 0;
    for(auto p:polygon)observationCheck(std::isfinite(p.x) && std::isfinite(p.y),"Nonfinite word polygon");
    auto rect=cv::minAreaRect(polygon);cv::Point2f vertices[4];rect.points(vertices);
    int best=0;float maximum=-1;
    for(int i=0;i<4;++i){auto d=vertices[(i+1)%4]-vertices[i];float length=std::sqrt(d.x*d.x+d.y*d.y);if(length>maximum){maximum=length;best=i;}}
    auto edge=vertices[(best+1)%4]-vertices[best];
    float theta=std::atan2(edge.y,edge.x),degrees=theta*float(180./CV_PI);
    float mod=std::fmod(degrees+45.f,90.f);if(mod<0)mod+=90.f;return double(mod-45.f);
}
// Frozen predicted_fill_alpha used ONLY to initialize Python prepare's geometry.
// Final aligned evidence is always the existing segmentation/RF reconstruction.
cv::Mat predictedGeometryAlpha(const cv::Mat &rgb,const cv::Mat &ownership,const SourceInkStyle &style,const cv::Rect2d &bbox) {
    std::vector<SourceInkRGB> palette;const auto fill=*style.fill.rgb;
    for(const auto *part:{&style.outline,&style.background,&style.shadow}) {
        if(part!=&style.background && !part->present)continue;
        if(part->rgb)palette.push_back(*part->rgb);
        if(part==&style.background)palette.insert(palette.end(),part->colors.begin(),part->colors.end());
    }
    palette.erase(std::remove_if(palette.begin(),palette.end(),[&](const auto &p){double d=0;for(int c=0;c<3;++c)d+=(fill[c]-p[c])*(fill[c]-p[c]);return std::sqrt(d)<=35;}),palette.end());
    cv::Mat alpha=cv::Mat::zeros(rgb.size(),CV_64F),good=cv::Mat::zeros(rgb.size(),CV_8U);
    for(int y=0;y<rgb.rows;++y)for(int x=0;x<rgb.cols;++x) {
        auto pixel=rgb.at<cv::Vec3b>(y,x);double best=1e9,value=0;
        for(auto p:palette) {
            double numerator=0,denominator=0;for(int c=0;c<3;++c){double d=fill[c]-p[c];numerator+=(pixel[c]-p[c])*d;denominator+=d*d;}
            double t=std::clamp(numerator/denominator,0.,1.),error=0;
            for(int c=0;c<3;++c){double d=pixel[c]-(p[c]+t*(fill[c]-p[c]));error+=d*d;}
            error=std::sqrt(error);if(error<best){best=error;value=t;}
        }
        alpha.at<double>(y,x)=value;good.at<uint8_t>(y,x)=best<22 && ownership.at<uint8_t>(y,x)!=0;
    }
    cv::Mat binary=(alpha>.5)&(good!=0);binary/=255;
    cv::Mat labels,stats,centres;int n=cv::connectedComponentsWithStats(binary,labels,stats,centres,8);
    cv::Mat inside=cv::Mat::zeros(rgb.size(),CV_8U);
    int l=std::max(0,int(bbox.x)),t=std::max(0,int(bbox.y)),r=std::min(rgb.cols,int(std::ceil(bbox.x+bbox.width))),b=std::min(rgb.rows,int(std::ceil(bbox.y+bbox.height)));
    if(r>l && b>t)inside(cv::Rect(l,t,r-l,b-t)).setTo(1);
    std::vector<int> overlaps(n,0);for(int y=0;y<rgb.rows;++y)for(int x=0;x<rgb.cols;++x)if(inside.at<uint8_t>(y,x))++overlaps[labels.at<int>(y,x)];
    std::vector<bool> allowed(n,false);for(int i=1;i<n;++i)allowed[i]=double(overlaps[i])/std::max(1,stats.at<int>(i,4))>=.3 && stats.at<int>(i,4)>=2;
    cv::Mat selected(rgb.size(),CV_8U);for(int y=0;y<rgb.rows;++y)for(int x=0;x<rgb.cols;++x)selected.at<uint8_t>(y,x)=allowed[labels.at<int>(y,x)];
    cv::Mat nearby;cv::dilate(selected,nearby,cv::Mat::ones(3,3,CV_8U));
    for(int y=0;y<rgb.rows;++y)for(int x=0;x<rgb.cols;++x)alpha.at<double>(y,x)*=(good.at<uint8_t>(y,x) && nearby.at<uint8_t>(y,x));
    alpha.convertTo(alpha,CV_32F);return alpha;
}
std::optional<std::pair<int,int>> spans(const cv::Mat &alpha,const cv::Mat &known,double threshold,int minimum) {
    cv::Mat ink=alpha>threshold;if(!known.empty())ink&=known!=0;
    if(cv::countNonZero(ink)<minimum)return std::nullopt;
    cv::Rect bounds=cv::boundingRect(ink);return std::pair<int,int>{bounds.height,bounds.width};
}
// Exact reference_ink_weight.stroke_profile / opposed_widths numeric path.
std::optional<std::array<double,4>> referenceWidths(const cv::Mat &alpha,const cv::Mat &known,double unit) {
    cv::Mat mask=(alpha>.5)&(known!=0);mask/=255;
    cv::Mat labels,stats,centres;int n=cv::connectedComponentsWithStats(mask,labels,stats,centres,8);
    std::vector<bool> keep(n,false);
    for(int i=1;i<n;++i)keep[i]=std::max(stats.at<int>(i,2),stats.at<int>(i,3))>=.2*unit && stats.at<int>(i,4)>=std::max(3.,.003*unit*unit);
    for(int y=0;y<mask.rows;++y)for(int x=0;x<mask.cols;++x)mask.at<uint8_t>(y,x)=keep[labels.at<int>(y,x)];
    cv::Mat smooth,dx,dy,eroded,trusted;cv::GaussianBlur(alpha,smooth,{3,3},.65,0,cv::BORDER_DEFAULT|cv::BORDER_ISOLATED);
    cv::Sobel(smooth,dx,CV_32F,1,0,3);cv::Sobel(smooth,dy,CV_32F,0,1,3);
    cv::erode(mask,eroded,cv::Mat::ones(3,3,CV_8U));cv::erode(known,trusted,cv::Mat::ones(3,3,CV_8U),{-1,-1},1,cv::BORDER_CONSTANT|cv::BORDER_ISOLATED,cv::morphologyDefaultBorderValue());
    cv::Mat length(alpha.size(),CV_32F);
    std::vector<cv::Point> edges;
    for(int y=0;y<alpha.rows;++y)for(int x=0;x<alpha.cols;++x) {
        float len=std::hypot(dx.at<float>(y,x),dy.at<float>(y,x));length.at<float>(y,x)=len;
        if(mask.at<uint8_t>(y,x) && !eroded.at<uint8_t>(y,x) && trusted.at<uint8_t>(y,x) && len>.08f)edges.emplace_back(x,y);
    }
    if(edges.size()>6000) {
        std::vector<cv::Point> selected;double step=(edges.size()-1)/5999.;
        for(int i=0;i<6000;++i)selected.push_back(edges[i==5999?edges.size()-1:size_t(i*step)]);edges=std::move(selected);
    }
    std::vector<float> nx,ny;std::vector<bool> alive(edges.size(),true);
    for(auto p:edges){nx.push_back(dx.at<float>(p)/length.at<float>(p));ny.push_back(dy.at<float>(p)/length.at<float>(p));}
    std::vector<double> widths;
    double stop=std::max(2.1,.5*unit)+.1;
    for(double distance=.5;distance<stop;distance+=.5)for(size_t i=0;i<edges.size();++i) {
        if(!alive[i])continue;
        int x=roundEven(edges[i].x+distance*nx[i]),y=roundEven(edges[i].y+distance*ny[i]);
        if(x<0 || y<0 || x>=alpha.cols || y>=alpha.rows || !trusted.at<uint8_t>(y,x)){alive[i]=false;continue;}
        if(mask.at<uint8_t>(y,x))continue;
        float alignment=(nx[i]*dx.at<float>(y,x)+ny[i]*dy.at<float>(y,x))/std::max(1e-6f,length.at<float>(y,x));
        if(alignment<-.5f && length.at<float>(y,x)>.08f && distance>=1)widths.push_back(distance/unit);
        alive[i]=false;
    }
    if(widths.size()<16)return std::nullopt;
    for(double &v:widths)v*=unit;
    return std::array<double,4>{quantile(widths,.25),quantile(widths,.5),quantile(widths,.75),quantile(widths,.9)};
}
struct AlignedWord {
    cv::Mat source,known,wordSource,wordKnown;
    std::u32string wordText;
    bool vertical;
    WordReferenceMasks masks;
    double unit,score,nominal,normalMargin,normalScore;
    WordReferencePair family;
};
}
std::optional<PreparedSourceWeightWord> prepareSourceWeightPaletteWord(const cv::Mat &rgb,const cv::Rect2d &bbox,
    double em,const std::u32string &original,const cv::Mat &ownership,const SourceInkStyle &style,double angle) {
    observationCheck(!rgb.empty() && rgb.type()==CV_8UC3 && ownership.type()==CV_8U && ownership.size()==rgb.size(),"Invalid word palette geometry");
    for(double v:{bbox.x,bbox.y,bbox.width,bbox.height,em,angle})observationCheck(std::isfinite(v),"Nonfinite word geometry");
    observationCheck(em>0 && bbox.width>0 && bbox.height>0,"Invalid source em/bbox");
    auto text=normalizedWord(original);if(text.size()<2 || text.size()>32 || !hasLetterOrNumber(text))return std::nullopt;
    // The existing palette helper also validates paint and supplies exact
    // lexicographic unique colours / 1e-6 residual tie semantics.
    auto palette=observeSourceInkPalette(rgb,ownership,style);
    auto prepareGeometry=[&](const SourceInkStyle &candidate)->std::optional<PreparedSourceWeightWord> {
        auto frozen=predictedGeometryAlpha(rgb,ownership,candidate,bbox);
        if(std::abs(angle)>.1)frozen=rotateObservation(frozen,angle);
        double scale=std::min(1.,640./std::max(frozen.rows,frozen.cols));
        if(scale<1)cv::resize(frozen,frozen,{},scale,scale,cv::INTER_AREA);
        auto span=spans(frozen,{},.4,5);if(!span)return std::nullopt;
        bool vertical=bbox.height>=bbox.width;
        PreparedSourceWeightWord p;p.text=text;p.vertical=vertical;p.unit=em*scale;
        p.longExtent=vertical?span->first:span->second;p.crossExtent=vertical?span->second:span->first;
        p.boxLong=(vertical?bbox.height:bbox.width)*scale;p.boxCross=(vertical?bbox.width:bbox.height)*scale;return p;
    };
    auto prepared=prepareGeometry(style);
    if(!prepared)for(auto color:style.fill.colors){auto alternate=style;alternate.fill.rgb=color;prepared=prepareGeometry(alternate);if(prepared)break;}
    if(!prepared)return std::nullopt;
    cv::Mat alpha=palette.alpha,known=palette.known;
    if(std::abs(angle)>.1){alpha=rotateObservation(alpha,angle);known=rotateObservation(known,angle,true);}
    double scale=std::min(1.,640./std::max(alpha.rows,alpha.cols));
    if(scale<1) {
        cv::resize(alpha,alpha,{},scale,scale,cv::INTER_AREA);
        cv::Mat f;known.convertTo(f,CV_32F);cv::resize(f,f,alpha.size(),0,0,cv::INTER_AREA);known=boolMap(f>.99);
    }
    prepared->alpha=alpha;prepared->known=known;
    if(auto span=spans(alpha,known,.4,5)) {
        prepared->longExtent=prepared->vertical?span->first:span->second;prepared->crossExtent=prepared->vertical?span->second:span->first;
    }
    return prepared;
}
SourceWeightWordObservations observeSourceWeightWords(const SourceWeightInkInput &input,const std::vector<SourceWeightRecognizedWord> &words,
    const std::vector<WordReferencePair> &pairs,SourceWeightWordObservationPaths paths,bool includeOrdered) {
    bool reference=(int(paths)&1)!=0,soft=(int(paths)&2)!=0;
    observationCheck(int(paths)>=1 && int(paths)<=3,"Invalid word observation paths");
    observationCheck(input.sourceEm && std::isfinite(*input.sourceEm) && *input.sourceEm>0,"Positive finite final sourceEm required");
    observationCheck(input.cutoff==.5,"Word observations require Python reconstruction cutoff .5");
    observationCheck(words.size()<=4096 && !pairs.empty() && pairs.size()<=32,"Invalid bounded word/reference count");
    auto ink=reconstructSourceWeightInk(input,SourceWeightInkRule::ColorConsistent);
    auto clean=cleanSourceInkStyle(input.style);
    SourceWeightWordObservations out;
    out.expectedReferenceWordCount=reference?std::min(size_t(6),words.size()):0;
    out.expectedSoftWordCount=soft?std::min(size_t(6),words.size()):0;
    if(!clean)return out;
    SourceWeightReferenceGrid grid;
    std::map<size_t,std::optional<AlignedWord>> aligned;
    auto align=[&](size_t index,bool referenceWord)->const std::optional<AlignedWord> & {
        auto old=aligned.find(index);if(old!=aligned.end())return old->second;
        std::optional<AlignedWord> result;
        const auto &word=words[index];auto b=word.bbox;
        bool finite=true;for(double v:{b.x,b.y,b.width,b.height})finite&=std::isfinite(v);
        // Reference's Python floor fails on nonfinite bbox. Soft explicitly
        // skips it; preserve that distinction when reference is not requested.
        if(!finite){observationCheck(!referenceWord,"Nonfinite reference word bbox");return aligned.emplace(index,result).first->second;}
        if(std::min(b.width,b.height)<=0 || std::min(b.x,b.y)<0 || b.x+b.width>input.rgb.cols+1 || b.y+b.height>input.rgb.rows+1)
            return aligned.emplace(index,result).first->second;
        int l=std::max(0,int(std::floor(b.x-.1*b.width))),t=std::max(0,int(std::floor(b.y-.1*b.height)));
        int r=std::min(input.rgb.cols,int(std::ceil(b.x+1.1*b.width))),bottom=std::min(input.rgb.rows,int(std::ceil(b.y+1.1*b.height)));
        if(l>=r || t>=bottom)return aligned.emplace(index,result).first->second;
        cv::Rect roi(l,t,r-l,bottom-t);cv::Rect2d local(b.x-l,b.y-t,b.width,b.height);
        double angle=polygonAngle(word.polygon);
        auto p=prepareSourceWeightPaletteWord(input.rgb(roi),local,*input.sourceEm,word.text,input.ownership(roi),*clean,angle);
        if(!p)return aligned.emplace(index,result).first->second;
        cv::Mat source=ink.alpha(roi),known=ink.observed(roi);
        if(std::abs(angle)>.1){source=rotateObservation(source,angle);known=rotateObservation(known,angle,true);}
        if(source.size()!=p->alpha.size()) {
            cv::resize(source,source,p->alpha.size(),0,0,cv::INTER_AREA);
            cv::Mat f;known.convertTo(f,CV_32F);cv::resize(f,f,source.size(),0,0,cv::INTER_AREA);known=boolMap(f>.99);
        }
        auto span=spans(source,known,.5,5);if(!span)return aligned.emplace(index,result).first->second;
        p->longExtent=p->vertical?span->first:span->second;p->crossExtent=p->vertical?span->second:span->first;
        p->alpha=source;p->known=known;
        auto fits=fairSourceWeightFaceFits(*p,pairs);if(fits.empty())return aligned.emplace(index,result).first->second;
        size_t best=0;double normalScore=0;
        for(size_t i=0;i<fits.size();++i){if(fits[i].fit[18]>fits[best].fit[18])best=i;if(fits[i].nominalWeight<=400)normalScore=std::max(normalScore,fits[i].fit[18]);}
        const auto &winner=fits[best];const auto &pose=winner.fit;
        auto text=p->text;
        if(pose[26]<.999){while(!text.empty() && punctuationOrSymbol(text.front()))text.erase(text.begin());while(!text.empty() && punctuationOrSymbol(text.back()))text.pop_back();}
        observationCheck(winner.reference.frame.has_value(),"Winning reference lacks shared family frame");
        WordReferencePair family{winner.reference.family,*winner.reference.frame,{}};
        auto images=grid.masks(family,text,p->vertical,pose[24]);if(!images)return aligned.emplace(index,result).first->second;
        auto masks=transformSourceWeightWord(*images,pose[22]*p->unit/128,pose[23],pose[25]*4,p->vertical);
        auto match=locateSourceWeightWord(source,known,masks);if(!match)return aligned.emplace(index,result).first->second;
        cv::Rect crop(match->x,match->y,masks[0].cols,masks[0].rows);
        result=AlignedWord{source(crop),known(crop),source,known,p->text,p->vertical,masks,p->unit,pose[18],winner.nominalWeight,pose[18]-normalScore,normalScore,family};
        return aligned.emplace(index,std::move(result)).first->second;
    };
    if(reference)for(size_t j=0;j<out.expectedReferenceWordCount;++j) {
        size_t index=words.size()>6?(j==5?words.size()-1:size_t(j*((words.size()-1)/5.))):j;
        const auto &a=align(index,true);if(!a)continue;
        cv::Mat all=cv::Mat::ones(a->masks[0].size(),CV_8U);
        auto source=referenceWidths(a->source,a->known,a->unit),regular=referenceWidths(a->masks[0],all,a->unit),heavy=referenceWidths(a->masks[1],all,a->unit);
        if(!source || !regular || !heavy)continue;
        std::vector<double> fractions;
        for(size_t i=0;i<4;++i){double gap=(*heavy)[i]-(*regular)[i];if(gap>=.75)fractions.push_back(((*source)[i]-(*regular)[i])/gap);}
        if(fractions.size()<2)continue;
        double fraction=quantile(fractions,.5),low=grid.nominalWeight(a->family.faces.regular),high=grid.nominalWeight(a->family.faces.heavy);
        auto registered=measureSourceWeightRegisteredProfile({a->source,a->masks[0],a->masks[1],a->known,a->unit});
        out.referenceWords.push_back({a->score,low+fraction*(high-low),a->nominal,a->normalScore,a->normalMargin,fraction,
            *std::max_element(fractions.begin(),fractions.end())-*std::min_element(fractions.begin(),fractions.end()),registered,
            *source,*regular,*heavy,double(cv::countNonZero(a->wordKnown))/a->wordKnown.total(),a->family.family});
    }
    if(soft)for(size_t index=0;index<out.expectedSoftWordCount;++index) {
        const auto &a=align(index,false);if(!a)continue;
        auto profile=measureSourceWeightSoftStrokeProfile({a->source,a->masks[0],a->masks[1],a->known,a->unit});
        std::optional<SourceWeightOrderedObservation> ordered;
        if(includeOrdered)ordered=measureSourceWeightOrderedGlyphs(a->wordSource,a->wordKnown,a->wordText,a->vertical,a->family,a->unit,true);
        out.softWords.push_back({profile,ordered,a->nominal,a->score,a->normalMargin,a->family.family});
    }
    return out;
}
}
