#import <Foundation/Foundation.h>
#include "SourceWeightWordFit.h"
#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <cmath>
#include <map>
#include <set>
#include <stdexcept>
#include <tuple>
namespace aidoku::source {
namespace {
void fitCheck(bool ok,const char *why) {if(!ok)throw std::invalid_argument(why);}
int fitRound(double v) {
    double b=std::floor(v),f=v-b;return int(b+(f>.5 || (f==.5 && std::fmod(b,2.)!=0)));
}
double sum(const std::vector<double> &v){double s=0;for(double x:v)s+=x;return s;}
double mean(const std::vector<double> &v){return v.empty()?0:sum(v)/v.size();}
double qtile(std::vector<double> v,double q) {
    if(v.empty())return 0;std::sort(v.begin(),v.end());double p=(v.size()-1)*q;size_t i=size_t(p);double f=p-i;
    double a=v[i],b=v[std::min(i+1,v.size()-1)];return f>=.5?b-(b-a)*(1-f):a+(b-a)*f;
}
bool punctuationOrSymbol(char32_t c) {
    return [[NSCharacterSet punctuationCharacterSet] longCharacterIsMember:c] ||
           [[NSCharacterSet symbolCharacterSet] longCharacterIsMember:c];
}
std::array<double,18> observedBands(const cv::Mat &s,const WordReferenceMasks &m,const cv::Mat &known,double score) {
    std::vector<double> energy,product,errors[3],common,plus,minus,local;
    size_t unionCount=0,validCount=0,infoCount=0,infoKnown=0,commonCount=0,commonKnown=0,seen=0;
    for(int y=0;y<s.rows;++y)for(int x=0;x<s.cols;++x) {
        double a=m[0].at<float>(y,x),b=m[1].at<float>(y,x),v=s.at<float>(y,x),d=b-a;
        bool k=known.at<uint8_t>(y,x)!=0;
        energy.push_back(d*d*k);product.push_back((v-a)*d*k);
    }
    double e=sum(energy);if(e<1)return {};
    double coefficient=std::clamp(sum(product)/e,-2.,3.);
    for(int y=0;y<s.rows;++y)for(int x=0;x<s.cols;++x) {
        double a=m[0].at<float>(y,x),b=m[1].at<float>(y,x),v=s.at<float>(y,x),d=b-a;
        bool k=known.at<uint8_t>(y,x)!=0,u=std::max(a,b)>.1,c=std::min(a,b)>.75,info=d>.25 || d<-.25;
        seen+=k;unionCount+=u;validCount+=u&&k;infoCount+=info;infoKnown+=info&&k;commonCount+=c;commonKnown+=c&&k;
        if(u && k) {
            double f=a+std::clamp(coefficient,0.,1.)*d;
            errors[0].push_back((v-a)*(v-a));errors[1].push_back((v-b)*(v-b));errors[2].push_back((v-f)*(v-f));
        }
        if(c && k)common.push_back(v);if(d>.25 && k)plus.push_back(v);if(d<-.25 && k)minus.push_back(v);
        if(info && k)local.push_back(std::clamp((v-a)/d,-2.,3.));
    }
    if(!validCount)return {};
    return {coefficient,mean(errors[0]),mean(errors[1]),mean(errors[0])-mean(errors[1]),mean(errors[2]),
        mean(common),mean(plus),mean(minus),e/validCount,qtile(local,.25),qtile(local,.5),qtile(local,.75),score,1.,
        double(validCount)/std::max(size_t(1),unionCount),double(infoKnown)/std::max(size_t(1),infoCount),
        double(commonKnown)/std::max(size_t(1),commonCount),double(seen)/known.total()};
}
std::optional<WordReferenceMasks> pattern(const WordReferenceMasks &base,double scale,double cross,
                                         double angle,bool vertical,cv::Size shape) {
    int h=std::max(2,fitRound(base[0].rows*scale*(vertical?1:cross)));
    int w=std::max(2,fitRound(base[0].cols*scale*(vertical?cross:1)));
    int pad=std::max(1,fitRound(128*scale*.06));h+=2*pad;w+=2*pad;
    if(angle) {
        double radians=angle*(CV_PI/180),c=std::abs(std::cos(radians)),s=std::abs(std::sin(radians));
        int nh=int(std::ceil(h*c+w*s)),nw=int(std::ceil(w*c+h*s));h=nh;w=nw;
    }
    if(h>shape.height || w>shape.width)return std::nullopt;
    return transformSourceWeightWord(base,scale,cross,angle,vertical);
}
void checkPrepared(const PreparedSourceWeightWord &p) {
    fitCheck(p.text.size()>=2 && p.text.size()<=32,"Expected prepared complete OCR string of 2..32 scalars");
    fitCheck(!p.alpha.empty() && p.alpha.type()==CV_32F && p.known.type()==CV_8U && p.alpha.size()==p.known.size(),"Invalid prepared values/known geometry");
    for(double v:{p.unit,p.longExtent,p.crossExtent,p.boxLong,p.boxCross})fitCheck(std::isfinite(v) && v>0 && v<=1e6,"Invalid prepared source geometry");
    fitCheck(cv::checkRange(p.alpha),"Nonfinite prepared source values");
    double high;cv::minMaxLoc(p.known,nullptr,&high);fitCheck(high<=1,"Known map must be boolean 0/1");
}
}
cv::Mat correlateSourceWeightWord(const cv::Mat &source,const cv::Mat &known,const cv::Mat &pattern) {
    fitCheck(source.type()==CV_32F && known.type()==CV_8U && source.size()==known.size() && pattern.type()==CV_32F && !pattern.empty(),"Invalid masked word correlation inputs");
    if(pattern.rows>source.rows || pattern.cols>source.cols)return {};
    cv::Mat valid;known.convertTo(valid,CV_32F);
    cv::Mat sourceValid,sourceSquared,sourceEnergy,referenceEnergy,cross,ones=cv::Mat::ones(pattern.size(),CV_32F);
    cv::multiply(source,valid,sourceValid);cv::multiply(source,source,sourceSquared);cv::multiply(sourceSquared,valid,sourceSquared);
    cv::matchTemplate(sourceValid,pattern,cross,cv::TM_CCORR);
    cv::matchTemplate(sourceSquared,ones,sourceEnergy,cv::TM_CCORR);
    cv::Mat squared;cv::multiply(pattern,pattern,squared);cv::matchTemplate(valid,squared,referenceEnergy,cv::TM_CCORR);
    cv::Mat foreground=pattern>.1;foreground/=255;foreground.convertTo(foreground,CV_32F);
    cv::Mat support;cv::matchTemplate(valid,foreground,support,cv::TM_CCORR);
    float area=std::max(1.,double(cv::countNonZero(foreground)));
    cv::Mat result(cross.size(),CV_32F);
    for(int y=0;y<cross.rows;++y)for(int x=0;x<cross.cols;++x) {
        float denominator=std::sqrt(std::max(0.f,sourceEnergy.at<float>(y,x)*referenceEnergy.at<float>(y,x)));
        float score=denominator>1e-6f?cross.at<float>(y,x)/denominator:-1.f;
        float cover=support.at<float>(y,x)/area;
        result.at<float>(y,x)=cover>=.3f && std::isfinite(score)?std::clamp(score,-1.f,1.f):-1.f;
    }
    return result;
}
std::optional<SourceWeightWordMatch> locateSourceWeightWord(const cv::Mat &source,const cv::Mat &known,const WordReferenceMasks &m) {
    auto a=correlateSourceWeightWord(source,known,m[0]),b=correlateSourceWeightWord(source,known,m[1]);
    if(a.empty() || b.empty())return std::nullopt;
    cv::Mat objective;cv::max(a,b,objective);double score;cv::Point at;
    cv::minMaxLoc(objective,nullptr,&score,nullptr,&at);if(score<0)return std::nullopt;
    return SourceWeightWordMatch{score,a.at<float>(at),b.at<float>(at),at.x,at.y};
}
SourceWeightWordFit fitSourceWeightWord(const PreparedSourceWeightWord &p,const WordReferencePair &pair,
    SourceWeightReferenceGrid &grid,bool refine,SourceWeightWordRenderer renderer) {
    checkPrepared(p);
    auto render=[&](const std::u32string &text,double tracking){
        return renderer==SourceWeightWordRenderer::SharedFrame?grid.masks(pair,text,p.vertical,tracking):grid.wordMasks(pair,text,p.vertical,tracking);
    };
    std::vector<std::u32string> variants={p.text};auto stripped=p.text;
    while(!stripped.empty() && punctuationOrSymbol(stripped.front()))stripped.erase(stripped.begin());
    while(!stripped.empty() && punctuationOrSymbol(stripped.back()))stripped.pop_back();
    if(stripped.size()>=2 && stripped.size()<p.text.size())variants.push_back(stripped);
    struct Best {SourceWeightWordMatch match;double scale,cross,tracking,rotation,coverage;WordReferenceMasks masks;std::u32string variant;};
    std::optional<Best> best;
    auto attempt=[&](const WordReferenceMasks &base,double scale,double cross,double tracking,double angle,double coverage,const std::u32string &variant) {
        auto m=pattern(base,scale,cross,angle,p.vertical,p.alpha.size());if(!m)return;
        auto match=locateSourceWeightWord(p.alpha,p.known,*m);if(!match)return;
        if(!best || match->score>best->match.score)best=Best{*match,scale,cross,tracking,angle,coverage,*m,variant};
    };
    for(const auto &variant:variants) {
        auto full=render(p.text,1),base=render(variant,1);if(!full || !base)continue;
        double length=p.vertical?(*full)[0].rows:(*full)[0].cols;
        double extent=p.vertical?(*full)[0].cols:(*full)[0].rows;
        std::set<double> scales={p.longExtent/length,p.boxLong*.9/length,p.boxLong/length,p.unit/128};
        for(double scale:scales) {
            double aspect=p.boxCross/std::max(1.,extent*scale),ratio=scale*128/std::max(1.,p.unit);
            if(aspect<.5 || aspect>2 || ratio<.4 || ratio>2)continue;
            attempt(*base,scale,1,1,0,double(variant.size())/p.text.size(),variant);
        }
    }
    if(!best)return {};
    if(refine) {
        auto initial=*best;
        for(double tracking:{.9,1.,1.1}) {
            auto base=render(initial.variant,tracking);if(!base)continue;
            for(double factor:{.975,1.,1.025})for(double cross:{.9,1.,1.1})
                attempt(*base,initial.scale*factor,cross,tracking,0,initial.coverage,initial.variant);
        }
        auto selected=*best;auto base=render(selected.variant,selected.tracking);
        for(double angle:{-4.,4.})if(base)attempt(*base,selected.scale,selected.cross,selected.tracking,angle,selected.coverage,selected.variant);
    }
    const auto &m=best->match;cv::Rect roi(m.x,m.y,best->masks[0].cols,best->masks[0].rows);
    auto bands=observedBands(p.alpha(roi),best->masks,p.known(roi),m.score);
    SourceWeightWordFit out{};std::copy(bands.begin(),bands.end(),out.begin());
    std::array<double,14> tail={m.score,m.regular,m.heavy,m.heavy-m.regular,best->scale*128/std::max(1.,p.unit),
        best->cross,best->tracking,best->rotation/4,best->coverage,p.boxCross/std::max(1.,128*best->scale),
        double(p.vertical),double(cv::countNonZero(p.known))/p.known.total(),1,1};
    std::copy(tail.begin(),tail.end(),out.begin()+18);return out;
}
std::vector<FairSourceWeightFaceFit> fairSourceWeightFaceFits(const PreparedSourceWeightWord &p,const std::vector<WordReferencePair> &pairs) {
    checkPrepared(p);fitCheck(!pairs.empty() && pairs.size()<=32,"Bounded reference intervals required");
    SourceWeightReferenceGrid grid;
    struct Frame {std::optional<WeightBandFont> regular,heavy;double heavyWeight=0;};
    std::map<std::string,Frame> frames;std::vector<std::array<double,2>> weights;
    for(const auto &pair:pairs) {
        double a=grid.nominalWeight(pair.faces.regular),b=grid.nominalWeight(pair.faces.heavy);
        fitCheck(std::isfinite(a+b) && b>a,"Invalid reference weight intervals");weights.push_back({a,b});
        auto &frame=frames[pair.family];if(a<=400)frame.regular=pair.faces.regular;
        if(b>frame.heavyWeight){frame.heavy=pair.faces.heavy;frame.heavyWeight=b;}
    }
    std::set<std::tuple<std::string,std::string,double>> seen;
    std::vector<FairSourceWeightFaceFit> candidates;
    for(size_t i=0;i<pairs.size();++i)for(int j=0;j<2;++j) {
        auto face=j?pairs[i].faces.heavy:pairs[i].faces.regular;double w=weights[i][j];
        if(!seen.emplace(face.path,face.sha256,w).second)continue;
        auto &frame=frames.at(pairs[i].family);fitCheck(frame.regular && frame.heavy,"Family lacks normal/heavy common frame");
        WordReferencePair candidate{pairs[i].family,{face,face},WeightBandPair{*frame.regular,*frame.heavy}};
        candidates.push_back({fitSourceWeightWord(p,candidate,grid,false,SourceWeightWordRenderer::SharedFrame),candidate,w});
    }
    std::vector<FairSourceWeightFaceFit> out;
    for(bool normal:{true,false}) {
        std::vector<size_t> group;
        for(size_t i=0;i<candidates.size();++i)if((candidates[i].nominalWeight<=400)==normal && candidates[i].fit[31])group.push_back(i);
        std::stable_sort(group.begin(),group.end(),[&](auto a,auto b){return candidates[a].fit[18]>candidates[b].fit[18];});
        if(group.size()>2)group.resize(2);
        for(auto i:group) {
            auto candidate=candidates[i];candidate.fit=fitSourceWeightWord(p,candidate.reference,grid,true,SourceWeightWordRenderer::SharedFrame);
            out.push_back(std::move(candidate));
        }
    }
    return out;
}
}
