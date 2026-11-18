#include "SourceWeightInk.h"
#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace aidoku {
namespace {
using RGB = SourceInkRGB;
double distance(const RGB &a, const RGB &b) {
    double v = 0; for (int c=0;c<3;++c) v += (a[c]-b[c])*(a[c]-b[c]);
    return std::sqrt(v);
}
void validateStyle(const SourceInkStyle &s) {
    if (!s.fill.rgb || !s.background.rgb) throw std::invalid_argument("Missing fill/background RGB");
    for (const auto *p : {&s.fill,&s.background,&s.outline,&s.shadow}) {
        auto check=[](const RGB &a) { for (double v:a) if (!std::isfinite(v)) throw std::invalid_argument("Nonfinite paint"); };
        if (p->rgb) check(*p->rgb);
        for (const auto &c:p->colors) check(c);
        if (!std::isfinite(p->widthPx)) throw std::invalid_argument("Nonfinite width");
        for (double w:p->observedContextWeights) if (!std::isfinite(w)) throw std::invalid_argument("Nonfinite context weight");
    }
}
std::vector<RGB> fills(const SourceInkStyle &s) {
    std::vector<RGB> out{*s.fill.rgb}; out.insert(out.end(),s.fill.colors.begin(),s.fill.colors.end()); return out;
}
void uniqueColors(std::vector<RGB> &v) { std::sort(v.begin(),v.end()); v.erase(std::unique(v.begin(),v.end()),v.end()); }
bool nearFill(const std::vector<RGB> &f, const RGB &c, double threshold) {
    for (const auto &v:f) if (distance(v,c)<=threshold) return true; return false;
}
void geometry(const cv::Mat &rgb,const cv::Mat &own) {
    if (rgb.empty() || rgb.type()!=CV_8UC3 || own.type()!=CV_8UC1 || own.size()!=rgb.size())
        throw std::invalid_argument("Source palette geometry differs");
}
cv::Mat boolean(const cv::Mat &m) { cv::Mat out; cv::compare(m,0,out,cv::CMP_NE); out/=255; return out; }
// Python round: nearest-even, independent of the caller's floating rounding mode.
int roundEven(double x) { double f=std::floor(x),d=x-f; return int(d<.5?f:d>.5?f+1:std::fmod(f,2)==0?f:f+1); }
}
std::optional<SourceInkStyle> cleanSourceInkStyle(const SourceInkStyle &style) {
    validateStyle(style);
    auto candidates=fills(style); std::vector<RGB> accepted;
    for (const auto &color:candidates) {
        if (distance(color,*style.background.rgb)<=35) continue;
        if (distance(color,*style.fill.rgb)>1) {
            bool excluded=false;
            for (const auto *p:{&style.outline,&style.shadow})
                if (p->present && p->rgb && distance(color,*p->rgb)<22) excluded=true;
            if (excluded) continue;
        }
        bool duplicate=false; for (const auto &c:accepted) if (distance(color,c)<1) duplicate=true;
        if (!duplicate) accepted.push_back(color);
    }
    if (accepted.empty()) return std::nullopt;
    auto out=style; out.fill.rgb=accepted[0]; out.fill.colors=accepted; return out;
}
SourceInkObservation observeSourceInkPalette(const cv::Mat &rgb,const cv::Mat &ownership,const SourceInkStyle &s) {
    geometry(rgb,ownership); validateStyle(s);
    auto f=fills(s); uniqueColors(f); std::vector<RGB> backgrounds;
    for (const auto *p:{&s.background,&s.outline,&s.shadow}) {
        if (p!=&s.background && !p->present) continue;
        if (p->rgb) backgrounds.push_back(*p->rgb);
        if (p==&s.background) backgrounds.insert(backgrounds.end(),p->colors.begin(),p->colors.end());
    }
    uniqueColors(backgrounds);
    backgrounds.erase(std::remove_if(backgrounds.begin(),backgrounds.end(),[&](const RGB &c){return nearFill(f,c,35);}),backgrounds.end());
    SourceInkObservation out{cv::Mat::zeros(rgb.size(),CV_32F),cv::Mat::zeros(rgb.size(),CV_8U)};
    for (int y=0;y<rgb.rows;++y) for (int x=0;x<rgb.cols;++x) {
        auto pixel=rgb.at<cv::Vec3b>(y,x); double best=INFINITY,alpha=0;
        for (const auto &fill:f) for (const auto &other:backgrounds) {
            double dot=0,den=0; for (int c=0;c<3;++c) {double delta=fill[c]-other[c];dot+=(pixel[c]-other[c])*delta;den+=delta*delta;}
            double t=std::clamp(dot/den,0.,1.),sum=0;
            for (int c=0;c<3;++c) {double d=pixel[c]-(other[c]+t*(fill[c]-other[c]));sum+=d*d;}
            double residual=std::sqrt(sum);
            if (residual<best-1e-6) {best=residual;alpha=t;}
        }
        out.alpha.at<float>(y,x)=float(alpha);
        out.known.at<uchar>(y,x)=best<22 && (ownership.at<uchar>(y,x)!=0 || alpha<.25);
    }
    return out;
}
SourceWeightInkResult reconstructSegmentedSourceWeightInk(const SourceWeightInkInput &in,std::optional<double> maximumEm) {
    geometry(in.rgb,in.ownership); validateStyle(in.style);
    for (const auto *m:{&in.primary,&in.boundary,&in.native,&in.rf,&in.valid}) {
        int type=m==&in.rf?CV_32FC(27):m==&in.valid?CV_8UC1:CV_32FC1;
        if (m->type()!=type || m->size()!=in.rgb.size() || !cv::checkRange(m->reshape(1)))
            throw std::invalid_argument("Invalid existing glyph/RF evidence");
    }
    if (!std::isfinite(in.cutoff) || (in.sourceEm && (!std::isfinite(*in.sourceEm)||*in.sourceEm<=0)) ||
        (maximumEm && (!std::isfinite(*maximumEm)||*maximumEm<=0))) throw std::invalid_argument("Invalid source EM/cutoff/component bound");
    // Native and RF corroborate weak primary only; ownership/validity gate full.
    auto cleaned=cleanSourceInkStyle(in.style);
    SourceInkObservation color{cv::Mat::zeros(in.rgb.size(),CV_32F),cv::Mat::zeros(in.rgb.size(),CV_8U)};
    if (cleaned) color=observeSourceInkPalette(in.rgb,in.ownership,*cleaned);
    auto own=boolean(in.ownership),valid=boolean(in.valid);
    cv::Mat text(in.rgb.size(),CV_32F),sfx(text.size(),CV_32F),full=cv::Mat::zeros(text.size(),CV_8U);
    cv::Mat visible=cv::Mat::zeros(text.size(),CV_32F),seeds=cv::Mat::zeros(text.size(),CV_8U);
    for (int y=0;y<text.rows;++y) for (int x=0;x<text.cols;++x) {
        const float *rf=in.rf.ptr<float>(y)+27*x;
        float t=std::max(rf[0],rf[15]*rf[16]),s=std::max(rf[3],rf[17]*rf[18]);
        text.at<float>(y,x)=t; sfx.at<float>(y,x)=s;
        float p=in.primary.at<float>(y,x),q=in.boundary.at<float>(y,x);
        bool backed=p>=.25 && in.native.at<float>(y,x)>0 && std::max(t,s)>=.05f;
        full.at<uchar>(y,x)=std::max(p,backed?q:0.f)>=float(in.cutoff) && valid.at<uchar>(y,x) && own.at<uchar>(y,x);
        float v=color.alpha.at<float>(y,x)*color.known.at<uchar>(y,x)*own.at<uchar>(y,x);
        visible.at<float>(y,x)=v; seeds.at<uchar>(y,x)=v>.5;
    }
    cv::Mat depth,interior; cv::distanceTransform(full,depth,cv::DIST_L2,cv::DIST_MASK_PRECISE);
    double radius=in.style.outline.present?std::max(0.,in.style.outline.widthPx):0;
    if (radius) {cv::max(depth-radius+.5,0,interior);cv::min(interior,1,interior);} else full.convertTo(interior,CV_32F);
    cv::Mat labels,stats,centroids; int n=cv::connectedComponentsWithStats(interior>.25,labels,stats,centroids,8);
    std::vector<int> hits(n,0); for(int y=0;y<seeds.rows;++y) for(int x=0;x<seeds.cols;++x) if(seeds.at<uchar>(y,x)) ++hits[labels.at<int>(y,x)];
    std::vector<bool> allowed(n,false); int accepted=0;
    for(int k=1;k<n;++k) {
        allowed[k]=hits[k]>=2 && double(hits[k])/std::max(1,stats.at<int>(k,cv::CC_STAT_AREA))>=.03;
        if(in.sourceEm && maximumEm) allowed[k]=allowed[k] && std::max(stats.at<int>(k,cv::CC_STAT_WIDTH),stats.at<int>(k,cv::CC_STAT_HEIGHT))<=(*maximumEm)*(*in.sourceEm);
        accepted+=allowed[k];
    }
    // Exclusion applies to recovered ink, not the directly observed colour.
    cv::Mat recovered=cv::Mat::zeros(text.size(),CV_32F),excluded=cv::Mat::zeros(text.size(),CV_8U),backgroundLike=excluded.clone();
    std::vector<RGB> backgrounds{*in.style.background.rgb};
    for(size_t i=0;i<std::min(in.style.background.colors.size(),in.style.background.observedContextWeights.size());++i)
        if(in.style.background.observedContextWeights[i]>=.1) backgrounds.push_back(in.style.background.colors[i]);
    for(int y=0;y<text.rows;++y) for(int x=0;x<text.cols;++x) {
        auto pixel=in.rgb.at<cv::Vec3b>(y,x); RGB c{double(pixel[0]),double(pixel[1]),double(pixel[2])};
        bool exclude=false;
        if(cleaned) for(const auto *p:{&in.style.outline,&in.style.shadow})
            if(p->present && p->rgb && !nearFill(fills(*cleaned),*p->rgb,35) && distance(c,*p->rgb)<22) exclude=true;
        excluded.at<uchar>(y,x)=exclude;
        for(const auto &b:backgrounds) if(distance(c,b)<22) backgroundLike.at<uchar>(y,x)=1;
        if(allowed[labels.at<int>(y,x)] && !exclude) recovered.at<float>(y,x)=interior.at<float>(y,x);
    }
    cv::Mat components; n=cv::connectedComponents(backgroundLike,components,8); std::vector<bool> exterior(n,false);
    for(int x=0;x<text.cols;++x) {exterior[components.at<int>(0,x)]=true;exterior[components.at<int>(text.rows-1,x)]=true;}
    for(int y=0;y<text.rows;++y) {exterior[components.at<int>(y,0)]=true;exterior[components.at<int>(y,text.cols-1)]=true;} exterior[0]=false;
    cv::Mat exteriorPixels=cv::Mat::zeros(text.size(),CV_8U);
    for(int y=0;y<text.rows;++y) for(int x=0;x<text.cols;++x) if(exterior[components.at<int>(y,x)]) {exteriorPixels.at<uchar>(y,x)=1;recovered.at<float>(y,x)=0;}
    // Closing proposes local gaps only. Original seed counters remain protected.
    int closeRadius=in.sourceEm?std::max(1,std::min(2,roundEven(.025*(*in.sourceEm)))):1;
    cv::Mat closed;cv::morphologyEx(seeds,closed,cv::MORPH_CLOSE,cv::getStructuringElement(cv::MORPH_ELLIPSE,{2*closeRadius+1,2*closeRadius+1}));
    std::vector<std::vector<cv::Point>> contours;std::vector<cv::Vec4i> hierarchy;
    cv::findContours(seeds,contours,hierarchy,cv::RETR_CCOMP,cv::CHAIN_APPROX_SIMPLE);
    cv::Mat counters=cv::Mat::zeros(text.size(),CV_8U);
    for(size_t i=0;i<contours.size();++i) if(hierarchy[i][3]>=0) cv::drawContours(counters,std::vector<std::vector<cv::Point>>{contours[i]},-1,1,cv::FILLED);
    int bridges=0,outside=0; SourceWeightInkResult out{cv::Mat(text.size(),CV_32F),valid|color.known,{}};
    for(int y=0;y<text.rows;++y) for(int x=0;x<text.cols;++x) {
        bool seed=seeds.at<uchar>(y,x),counter=counters.at<uchar>(y,x)&&!seed; counters.at<uchar>(y,x)=counter;
        bool bridge=closed.at<uchar>(y,x)&&!seed&&!counter&&full.at<uchar>(y,x)&&in.boundary.at<float>(y,x)>=.65f&&!exteriorPixels.at<uchar>(y,x)&&!excluded.at<uchar>(y,x);
        if(bridge) {recovered.at<float>(y,x)=1;++bridges;} if(counter) recovered.at<float>(y,x)=0;
        if(seed&&!full.at<uchar>(y,x)) ++outside;
        out.alpha.at<float>(y,x)=std::max(recovered.at<float>(y,x),visible.at<float>(y,x));
    }
    // Audit recoveredPixels precedes direct-colour preservation/overrides, as Python.
    auto &a=out.audit;
    a={{"rawGlyphCutoff",in.cutoff},{"outlineRadiusPx",radius},{"glyphPixels",cv::countNonZero(full)},
       {"seedPixels",cv::countNonZero(seeds)},{"recoveredPixels",cv::countNonZero(recovered>.5)},
       {"colorInkPreservedOutsideSegmentation",outside},{"acceptedReconstructionComponents",accepted},
       {"bridgedGapPixels",bridges},{"excludedOutlineShadowPixels",cv::countNonZero(excluded)},
       {"protectedCounterPixels",cv::countNonZero(counters)},{"exteriorBackgroundPixels",cv::countNonZero(exteriorPixels)}};
    bool any=cv::countNonZero(full)>0;
    a["rfTextMean"]=any?cv::mean(text,full)[0]:0;a["rfSFXMean"]=any?cv::mean(sfx,full)[0]:0;
    a["primaryMean"]=any?cv::mean(in.primary,full)[0]:0;a["boundaryMean"]=any?cv::mean(in.boundary,full)[0]:0;
    return out;
}
SourceWeightInkResult reconstructSourceWeightInk(const SourceWeightInkInput &in,SourceWeightInkRule rule) {
    if(rule==SourceWeightInkRule::Segmented) return reconstructSegmentedSourceWeightInk(in);
    auto out=reconstructSegmentedSourceWeightInk(in,std::nullopt);auto cleaned=cleanSourceInkStyle(in.style);
    if(!cleaned) return out;
    auto color=observeSourceInkPalette(in.rgb,in.ownership,*cleaned);int suppressed=0;
    for(int y=0;y<in.rgb.rows;++y) for(int x=0;x<in.rgb.cols;++x) if(color.known.at<uchar>(y,x)) {
        float foreground=color.alpha.at<float>(y,x)*(in.ownership.at<uchar>(y,x)!=0);
        if(out.alpha.at<float>(y,x)>.5 && foreground<=.25) ++suppressed;
        out.alpha.at<float>(y,x)=foreground;
    }
    out.observed|=color.known;out.audit["suppressedKnownBackgroundPixels"]=suppressed;
    out.audit["directColorOverridesSegmentation"]=1;out.audit["longConnectedGlyphsRetained"]=1;return out;
}
}
