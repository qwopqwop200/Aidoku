/* Float summation adapts NumPy 2.2.6 pairwise reduction.
 * https://github.com/numpy/numpy/blob/v2.2.6/numpy/_core/src/umath/loops_utils.h.src
 * Copyright (c) 2005-2024, NumPy Developers. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 * * Redistributions of source code must retain the above copyright notice,
 *   this list of conditions and the following disclaimer.
 * * Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 * * Neither the name of the NumPy Developers nor the names of any contributors
 *   may be used to endorse or promote products derived from this software
 *   without specific prior written permission.
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */
#import <Foundation/Foundation.h>
#include "FontWeightBands.h"
#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <cmath>
#include <map>
#include <set>
#include <stdexcept>
#include <vector>
namespace aidoku {
namespace {
void check(bool ok, const char *why) { if (!ok) throw std::invalid_argument(why); }
constexpr std::array<double,5> scales = {.85,.95,1.,1.05,1.15};
int roundEven(double x) {
    double b=std::floor(x), f=x-b;
    return int(b+(f>.5 || (f==.5 && std::fmod(b,2.)!=0)));
}
double quantile(std::vector<double> a, double q) {
    if (a.empty()) return 0;
    std::sort(a.begin(),a.end()); double index=(a.size()-1)*q;
    size_t i=size_t(index); double f=index-i;
    // NumPy lerp chooses the closer endpoint for numerical accuracy.
    return f>=.5 ? a[std::min(i+1,a.size()-1)]-(a[std::min(i+1,a.size()-1)]-a[i])*(1-f)
                 : a[i]+(a[std::min(i+1,a.size()-1)]-a[i])*f;
}
template<class T> T pairSum(const T *p, size_t n) {
    if (n<8) { T s=-T(0); for(size_t i=0;i<n;++i)s+=p[i]; return s; }
    if (n<=128) {
        T r[8]; std::copy(p,p+8,r); size_t i=8;
        for(;i<n-n%8;i+=8)for(int k=0;k<8;++k)r[k]+=p[i+k];
        T s=((r[0]+r[1])+(r[2]+r[3]))+((r[4]+r[5])+(r[6]+r[7]));
        for(;i<n;++i)s+=p[i]; return s;
    }
    size_t h=n/2; h-=h%8; return pairSum(p,h)+pairSum(p+h,n-h);
}
double floatSum(const cv::Mat &m) {
    cv::Mat c=m.isContinuous()?m:m.clone(); const float *p=c.ptr<float>();
    if(m.isContinuous())return pairSum(p,m.total());
    float sum=0; for(size_t i=0;i<m.total();i+=8192)sum+=pairSum(p+i,std::min(size_t(8192),m.total()-i));
    return sum;
}
cv::Mat rotate(const cv::Mat &src, double angle) {
    int w=src.cols,h=src.rows;
    auto matrix=cv::getRotationMatrix2D(cv::Point2f(w/2.f,h/2.f),angle,1);
    double c=std::abs(matrix.at<double>(0,0)),s=std::abs(matrix.at<double>(0,1));
    int nw=int(std::ceil(w*c+h*s)),nh=int(std::ceil(h*c+w*s));
    matrix.at<double>(0,2)+=(nw-w)/2.; matrix.at<double>(1,2)+=(nh-h)/2.;
    cv::Mat out; cv::warpAffine(src,out,matrix,{nw,nh},cv::INTER_LINEAR,cv::BORDER_CONSTANT,0); return out;
}
std::array<cv::Mat,2> transformed(const cv::Mat &r,const cv::Mat &h,double unit,double aspect=1,double angle=0) {
    std::array<cv::Mat,2> images, result; int w=0,height=0,pad=std::max(1,roundEven(unit*.08));
    for(int i=0;i<2;++i) {
        auto &src=i?h:r; cv::Mat small;
        cv::resize(src,small,{std::max(2,roundEven(src.cols*unit/128)),std::max(2,roundEven(src.rows*unit/128))},0,0,cv::INTER_AREA);
        small.convertTo(images[i],CV_32F);
        for(int y=0;y<small.rows;++y)for(int x=0;x<small.cols;++x) images[i].at<float>(y,x)/=255.f;
        w=std::max(w,small.cols);height=std::max(height,small.rows);
    }
    w+=2*pad;height+=2*pad;
    for(int i=0;i<2;++i) {
        result[i]=cv::Mat::zeros(height,w,CV_32F);
        images[i].copyTo(result[i](cv::Rect((w-images[i].cols)/2,(height-images[i].rows)/2,images[i].cols,images[i].rows)));
        if(aspect!=1)cv::resize(result[i],result[i],{std::max(2,roundEven(w*aspect)),height},0,0,cv::INTER_LINEAR);
        if(angle)result[i]=rotate(result[i],angle);
    }
    return result;
}
struct Match { double score,ra,rb; cv::Point location; };
std::optional<Match> locate(const cv::Mat &alpha,const std::array<cv::Mat,2> &ab) {
    if(ab[0].rows>alpha.rows || ab[0].cols>alpha.cols)return std::nullopt;
    cv::Mat ca,cb,objective;
    cv::matchTemplate(alpha,ab[0],ca,cv::TM_CCOEFF_NORMED);
    cv::matchTemplate(alpha,ab[1],cb,cv::TM_CCOEFF_NORMED);
    objective.create(ca.size(),CV_32F);
    for(int y=0;y<ca.rows;++y)for(int x=0;x<ca.cols;++x) {
        float a=ca.at<float>(y,x),b=cb.at<float>(y,x);
        objective.at<float>(y,x)=std::isfinite(a+b)?std::max(a,b):-1.f;
    }
    double score;cv::Point location;cv::minMaxLoc(objective,nullptr,&score,nullptr,&location);
    return Match{score,ca.at<float>(location),cb.at<float>(location),location};
}
double strokeMedian(const cv::Mat &v,double unit) {
    cv::Mat mask=v>.5;mask/=255;
    cv::Mat labels,stats,centers;
    int n=cv::connectedComponentsWithStats(mask,labels,stats,centers,8);
    std::vector<bool> keep(n,false);
    for(int i=1;i<n;++i)keep[i]=stats.at<int>(i,4)>=std::max(3.,unit*unit*.003) && stats.at<int>(i,4)<mask.total()*.95;
    cv::Mat body(mask.size(),CV_8U);
    for(int y=0;y<mask.rows;++y)for(int x=0;x<mask.cols;++x)body.at<uint8_t>(y,x)=keep[labels.at<int>(y,x)];
    cv::Mat depth,dilated; cv::distanceTransform(body,depth,cv::DIST_L2,cv::DIST_MASK_PRECISE);
    cv::dilate(depth,dilated,cv::Mat::ones(3,3,CV_8U));
    std::vector<double> thickness;
    for(int y=0;y<depth.rows;++y)for(int x=0;x<depth.cols;++x) {
        float d=depth.at<float>(y,x);
        if(d>0 && d>=dilated.at<float>(y,x)-.001f)thickness.push_back((2.f*d)/float(unit));
    }
    return quantile(thickness,.5);
}
void validGlyph(const cv::Mat &m) { check(m.empty() || (m.type()==CV_8U && m.rows<=4096 && m.cols<=4096),"Expected trimmed EM128 uint8 glyph"); }
std::array<std::vector<uint32_t>,2> anchors(const std::string &text,const WeightBandAnchor &metric) {
    NSString *s=[[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding];
    check(s!=nil,"Invalid UTF8 text");
    NSData *data=[s.precomposedStringWithCanonicalMapping dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    std::set<uint32_t> chars;
    const uint32_t *p=static_cast<const uint32_t *>(data.bytes);
    for(size_t i=0;i<data.length/4;++i)chars.insert(p[i]);
    std::set<uint32_t> small={0x3041,0x3043,0x3045,0x3047,0x3049,0x3063,0x3083,0x3085,0x3087,0x308e,
        0x30a1,0x30a3,0x30a5,0x30a7,0x30a9,0x30c3,0x30e3,0x30e5,0x30e7,0x30ee};
    std::vector<std::pair<double,uint32_t>> ranked;
    for(auto cp:chars) {
        if(![[NSCharacterSet alphanumericCharacterSet] longCharacterIsMember:cp] ||
            [[NSCharacterSet nonBaseCharacterSet] longCharacterIsMember:cp] || small.count(cp))continue;
        auto dim=metric(cp); if(!dim)continue;check(std::isfinite(*dim),"Invalid anchor metric");
        if(*dim>.05)ranked.emplace_back(*dim,cp);
    }
    std::sort(ranked.begin(),ranked.end(),[](auto a,auto b){return a.first!=b.first?a.first>b.first:a.second<b.second;});
    if(ranked.size()>256)ranked.resize(256);
    std::array<std::vector<uint32_t>,2> groups;
    for(auto item:ranked) {
        auto cp=item.second;int g=cp>=0x3040 && cp<=0x30ff?0:1;
        if(groups[g].size()<2)groups[g].push_back(cp);
    }
    return groups;
}
}
std::array<double,24> fitFontWeightAffine(const cv::Mat &alpha,const cv::Mat &r,const cv::Mat &h,double unit) {
    check(alpha.type()==CV_32F && !alpha.empty() && std::isfinite(unit) && unit>0 && unit<=4096,"Invalid affine input");
    validGlyph(r);validGlyph(h);check(!r.empty() && !h.empty(),"Missing affine glyph");
    std::optional<Match> best;std::array<cv::Mat,2> ab;double factor=0,aspect=1,angle=0;
    for(double f:scales) {
        auto candidate=transformed(r,h,unit*f);auto match=locate(alpha,candidate);
        if(match && (!best || match->score>best->score)){best=match;factor=f;ab=candidate;}
    }
    if(!best)return {};
    double coarse=best->score;
    if(coarse<.85)for(double a:{.9,1.,1.1})for(double deg:{-4.,0.,4.}) {
        if(a==1 && deg==0)continue;
        auto candidate=transformed(r,h,unit*factor,a,deg);auto match=locate(alpha,candidate);
        if(match && match->score>best->score){best=match;aspect=a;angle=deg;ab=candidate;}
    }
    cv::Mat source=alpha(cv::Rect(best->location,ab[0].size()));
    double mass=floatSum(source);std::array<double,2> areas,dice;
    for(int i=0;i<2;++i) {
        areas[i]=floatSum(ab[i]);cv::Mat common;cv::min(source,ab[i],common);
        dice[i]=2*floatSum(common)/std::max(1e-6,mass+areas[i]);
    }
    return {best->score,best->ra,best->rb,best->rb-best->ra,factor,dice[0],dice[1],dice[1]-dice[0],
        std::log(std::max(1e-6,mass)/std::max(1e-6,areas[0])),std::log(std::max(1e-6,mass)/std::max(1e-6,areas[1])),
        strokeMedian(source,unit),strokeMedian(ab[0],unit),strokeMedian(ab[1],unit),
        double(cv::countNonZero(source>.5))/source.total(),double(best->score>.5),1.,aspect,angle/4.,best->score-coarse,coarse,0,0,0,0};
}
std::array<double,14> fontWeightBandStats(const cv::Mat &src,const cv::Mat &regular,const cv::Mat &heavy,double score) {
    check(!src.empty() && src.channels()==1 && src.size()==regular.size() && src.size()==heavy.size(),"Weight-band arrays differ");
    cv::Mat s,a,b;src.convertTo(s,CV_64F);regular.convertTo(a,CV_64F);heavy.convertTo(b,CV_64F);
    std::vector<double> energies,products,err[3],common,plus,minus,local;
    for(int y=0;y<s.rows;++y)for(int x=0;x<s.cols;++x) {
        double av=a.at<double>(y,x),bv=b.at<double>(y,x),v=s.at<double>(y,x),d=bv-av;
        check(std::isfinite(v+av+bv),"Nonfinite band arrays");energies.push_back(d*d);products.push_back((v-av)*d);
    }
    double energy=pairSum(energies.data(),energies.size());
    if(energy<1)return {};
    double coefficient=std::clamp(pairSum(products.data(),products.size())/energy,-2.,3.);
    for(int y=0;y<s.rows;++y)for(int x=0;x<s.cols;++x) {
        double av=a.at<double>(y,x),bv=b.at<double>(y,x),v=s.at<double>(y,x),d=bv-av;
        if(std::max(av,bv)>.1) {
            double f=av+std::clamp(coefficient,0.,1.)*d;
            err[0].push_back((v-av)*(v-av));err[1].push_back((v-bv)*(v-bv));err[2].push_back((v-f)*(v-f));
        }
        if(std::min(av,bv)>.75)common.push_back(v);
        if(d>.25)plus.push_back(v);if(d<-.25)minus.push_back(v);
        if(d>.25 || d<-.25)local.push_back(std::clamp((v-av)/d,-2.,3.));
    }
    if(err[0].empty())return {};
    auto mean=[](const std::vector<double> &v){return v.empty()?0.:pairSum(v.data(),v.size())/v.size();};
    return {coefficient,mean(err[0]),mean(err[1]),mean(err[0])-mean(err[1]),mean(err[2]),mean(common),mean(plus),mean(minus),
        energy/err[0].size(),quantile(local,.25),quantile(local,.5),quantile(local,.75),score,1.};
}
WeightBandResult measureFontWeightBands(const cv::Mat &input,const cv::Rect2d &bbox,double angle,double em,
    const std::string &text,const std::array<WeightBandPair,4> &pairs,const WeightBandGlyph &glyph,
    const WeightBandAnchor &anchor,const WeightBandPoses *provided) {
    check(!input.empty() && (input.type()==CV_32F || input.type()==CV_64F),"Invalid predicted alpha");
    check(std::isfinite(em) && em>0 && em<=4096 && std::isfinite(angle) && std::abs(angle)<=360,"Invalid em/angle");
    for(double v:{bbox.x,bbox.y,bbox.width,bbox.height})check(std::isfinite(v),"Invalid bbox");
    check(bbox.width>0 && bbox.height>0 && glyph && anchor,"Missing caller prerequisites");
    for(int y=0;y<input.rows;++y)for(int x=0;x<input.cols;++x) {
        double v=input.depth()==CV_32F?input.at<float>(y,x):input.at<double>(y,x);
        check(std::isfinite(v) && v>=0 && v<=1,"Invalid alpha range");
    }
    cv::Mat alpha=input;
    if(std::abs(angle)>.1)alpha=rotate(alpha,angle);
    double scale=std::min(1.,480./std::max(alpha.rows,alpha.cols));
    if(scale<1)cv::resize(alpha,alpha,{},scale,scale,cv::INTER_AREA);
    alpha.convertTo(alpha,CV_32F);double unit=em*scale;
    WeightBandResult out{};
    if(provided) {out.poses=*provided;for(double v:out.poses)check(std::isfinite(v),"Invalid supplied poses");}
    auto groups=anchors(text,anchor);
    std::map<std::pair<int,uint32_t>,cv::Mat> cache;
    auto raster=[&](int face,uint32_t cp)->cv::Mat {
        auto key=std::make_pair(face,cp);auto it=cache.find(key);
        if(it==cache.end()) {
            cv::Mat m=glyph(face%2?pairs[face/2].heavy:pairs[face/2].regular,cp);
            validGlyph(m);it=cache.emplace(key,m.clone()).first;
        }
        return it->second;
    };
    bool massGate=floatSum(alpha)<1;
    for(int i=0;i<4;++i)for(int g=0;g<2;++g) {
        size_t slot=(i*2+g)*24;
        if(!provided && !massGate) {
            std::vector<std::array<double,24>> values;
            for(auto cp:groups[g]) {
                auto r=raster(i*2,cp),h=raster(i*2+1,cp);
                if(!r.empty() && !h.empty())values.push_back(fitFontWeightAffine(alpha,r,h,unit));
            }
            if(!values.empty()) {
                size_t best=0;std::vector<double> delta,dice,scores;double visible=0;
                for(size_t j=0;j<values.size();++j) {
                    if(values[j][0]>values[best][0])best=j;
                    visible+=values[j][0]>=.5;delta.push_back(values[j][3]);dice.push_back(values[j][7]);scores.push_back(values[j][0]);
                }
                auto value=values[best];value[20]=visible/values.size();value[21]=quantile(delta,.5);value[22]=quantile(dice,.5);
                value[23]=pairSum(scores.data(),scores.size())/scores.size();
                std::copy(value.begin(),value.end(),out.poses.begin()+slot);
            }
        }
        const double *pose=out.poses.data()+slot;
        if(!pose[15])continue;
        check(pose[4]>0 && pose[4]<=2 && pose[16]>0 && pose[16]<=2 && std::abs(pose[17])<=90,"Invalid supplied pose transform");
        std::optional<std::pair<double,double>> bestKey;std::array<double,14> bands{};
        for(auto cp:groups[g]) {
            auto r=raster(i*2,cp),h=raster(i*2+1,cp);if(r.empty() || h.empty())continue;
            auto ab=transformed(r,h,unit*pose[4],pose[16],pose[17]*4);auto match=locate(alpha,ab);if(!match)continue;
            std::pair<double,double> key{std::abs(match->score-pose[0]),-match->score};
            if(!bestKey || key<*bestKey) {
                bestKey=key;auto source=alpha(cv::Rect(match->location,ab[0].size()));
                bands=fontWeightBandStats(source,ab[0],ab[1],match->score);
            }
        }
        std::copy(bands.begin(),bands.end(),out.bands.begin()+(i*2+g)*14);
    }
    return out;
}
bool confirmFontWeightBands(const WeightBands &bands,const WeightBandPolicy &policy) {
    for(double v:bands)check(std::isfinite(v),"Invalid differential weight-band batch");
    size_t best=0;for(size_t i=1;i<8;++i)if(bands[i*14+12]>bands[best*14+12])best=i;
    const double *b=bands.data()+best*14;
    return b[0]>=policy.minimumAddedStem && b[5]>=policy.minimumCommonBody &&
        b[12]>=policy.minimumGlyphFit && b[4]<=policy.maximumReconstructionError;
}
}
