/* Palette argsort and float summation adapt NumPy 2.2.6 aquicksort/aheapsort (Charles R. Harris).
 * https://github.com/numpy/numpy/tree/v2.2.6/numpy/_core/src/npysort
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
#include "SourceWeightFeatures.hpp"
#include <map>

namespace aidoku { namespace source {
namespace {
struct Target { cv::Mat rgb; double unit; };
Target target(const cv::Mat& rgb, const cv::Rect2d& b, double prior, double limit) {
    checkSource(rgb,b,prior);
    cv::Mat t=rgb(targetRect(rgb,b));
    double scale=std::min(1.,limit/std::max(t.rows,t.cols));
    if(scale<1) cv::resize(t,t,cv::Size(),scale,scale,cv::INTER_AREA);
    return {t,prior*scale};
}
std::vector<cv::Mat> masks(const cv::Mat& rgb,int darkCut,int chromaCut) {
    cv::Mat gray,dark; cv::cvtColor(rgb,gray,cv::COLOR_RGB2GRAY);
    cv::threshold(gray,dark,0,1,cv::THRESH_BINARY_INV|cv::THRESH_OTSU);
    std::vector<cv::Mat> out={dark,1-dark,cv::Mat::zeros(rgb.size(),CV_8U),
                             cv::Mat::zeros(rgb.size(),CV_8U),cv::Mat::zeros(rgb.size(),CV_8U)};
    for(int y=0;y<rgb.rows;++y) for(int x=0;x<rgb.cols;++x) {
        auto p=rgb.at<cv::Vec3b>(y,x);int lo=std::min({p[0],p[1],p[2]}),hi=std::max({p[0],p[1],p[2]});
        out[2].at<uchar>(y,x)=hi<darkCut;
        out[3].at<uchar>(y,x)=lo>200&&hi-lo<45;
        out[4].at<uchar>(y,x)=hi-lo>chromaCut;
    }
    return out;
}
// Match the accepted ARM NumPy default unstable count argsort, including
// which six colors survive a count tie. A stable sort changes pixel_rules.
void paletteArgsort(std::vector<int>& order,const std::map<int,int>& counts) {
    auto less=[&](int a,int b){return counts.at(a)<counts.at(b);};
    auto heap=[&](int left,int right) {
        int n=right-left+1;
        auto at=[&](int index)->int& {return order[left+index-1];};
        auto sift=[&](int root,int end,int value) {
            int i=root,j=2*i;
            while(j<=end) {
                if(j<end&&less(at(j),at(j+1)))++j;
                if(!less(value,at(j)))break;
                at(i)=at(j);i=j;j*=2;
            }
            at(i)=value;
        };
        for(int root=n/2;root>0;--root)sift(root,n,at(root));
        while(n>1){int value=at(n);at(n)=at(1);--n;sift(1,n,value);}
    };
    int depth=0;for(size_t n=order.size();n>1;n>>=1)++depth;
    std::vector<std::array<int,3>> stack={{{0,int(order.size())-1,2*depth}}};
    while(!stack.empty()) {
        auto task=stack.back();stack.pop_back();int left=task[0],right=task[1],limit=task[2];
        if(limit<0){heap(left,right);continue;}
        while(right-left>15) {
            int mid=left+(right-left)/2;
            if(less(order[mid],order[left]))std::swap(order[mid],order[left]);
            if(less(order[right],order[mid]))std::swap(order[right],order[mid]);
            if(less(order[mid],order[left]))std::swap(order[mid],order[left]);
            int pivot=order[mid],i=left,j=right-1;std::swap(order[mid],order[j]);
            for(;;){do{++i;}while(less(order[i],pivot));do{--j;}while(less(pivot,order[j]));
                if(i>=j)break;std::swap(order[i],order[j]);}
            std::swap(order[i],order[right-1]);--limit;
            if(i-left<right-i){stack.push_back({i+1,right,limit});right=i-1;}
            else {stack.push_back({left,i-1,limit});left=i+1;}
        }
        for(int i=left+1;i<=right;++i){int value=order[i],j=i;
            while(j>left&&less(value,order[j-1])){order[j]=order[j-1];--j;}order[j]=value;}
    }
}
using Contours=std::vector<std::vector<cv::Point>>;
Vec ridgeWidths(const cv::Mat& body,double unit,bool pad) {
    cv::Mat b=body,depth,maximum;
    if(pad) cv::copyMakeBorder(body,b,1,1,1,1,cv::BORDER_CONSTANT,0);
    cv::distanceTransform(b,depth,cv::DIST_L2,cv::DIST_MASK_PRECISE);
    if(pad) depth=depth(cv::Rect(1,1,body.cols,body.rows));
    cv::dilate(depth,maximum,cv::Mat::ones(3,3,CV_8U));Vec v;
    for(int y=0;y<depth.rows;++y) for(int x=0;x<depth.cols;++x) {
        float d=depth.at<float>(y,x);
        if(d>0&&d>=maximum.at<float>(y,x)-.001f) v.push_back((2.f*d)/float(unit));
    }
    return v;
}
Vec strokeSummary(const cv::Mat& mask,double unit) {
    cv::Mat labels;auto stats=bodies(mask,&labels);cv::Mat body(mask.size(), CV_8U);Vec extents;
    std::vector<uchar> accepted(stats.size() + 1, 0);
    for(size_t i=0;i<stats.size();++i) {
        const auto&s=stats[i];
        if(s.area<std::max(3.,unit*unit*.003)||s.area>=mask.total()*.65||
           s.x<=0||s.y<=0||s.x+s.w>=mask.cols||s.y+s.h>=mask.rows) continue;
        accepted[i + 1] = 1;
        extents.push_back(double(s.area)/(s.w*s.h));
    }
    // Label zero is background. Export selected components once, in the
    // original label order for extents and original pixel order for ridges.
    if (extents.empty()) return Vec(11, 0.);
    for (int y = 0; y < labels.rows; ++y) {
        const int* ids = labels.ptr<int>(y);
        uchar* pixels = body.ptr<uchar>(y);
        for (int x = 0; x < labels.cols; ++x) pixels[x] = accepted[ids[x]];
    }
    Vec f;quantiles(f,ridgeWidths(body,unit,false),{.1,.25,.5,.75,.9});
    Contours c;cv::findContours(body.clone(),c,cv::RETR_LIST,cv::CHAIN_APPROX_SIMPLE);
    double perimeter=0;for(const auto&v:c) perimeter+=cv::arcLength(v,true);
    double area=cv::countNonZero(body);append(f,{area/std::max(size_t(1),body.total()),area/std::max(1.,perimeter)/unit});
    quantiles(f,extents,{.25,.5,.75});f.push_back(std::min(1.,extents.size()/std::max(1.,body.total()/(unit*unit))));return f;
}
void checked(const Vec& v,size_t n) {
    if(v.size()!=n||!std::all_of(v.begin(),v.end(),[](double x){return std::isfinite(x);}))
        throw std::invalid_argument("Weight feature length/finiteness mismatch");
}
// Python round(): ties to even, independent of caller floating-point mode.
int pyRound(double x) { double a=std::floor(x),r=x-a;return int(a+(r>.5||(r==.5&&std::fmod(a,2)!=0))); }
}

static Vec estimatorExtra40(const Target& t,const std::vector<cv::Mat>& cs,const cv::Rect2d& b,double prior) {
    Vec f;double unit=t.unit;
    for(int k:{0,2}) {
        Contours contours;cv::findContours(cs[k].clone(),contours,cv::RETR_EXTERNAL,cv::CHAIN_APPROX_SIMPLE);
        std::vector<Vec> rows;std::vector<cv::Point2f> centers;double edge=0;
        for(const auto&c:contours) {
            auto r=cv::boundingRect(c);double area=cv::contourArea(c);
            if(area<std::max(3.,unit*unit*.003)||area>=cs[k].total()*.65) continue;
            if(r.x<=0||r.y<=0||r.br().x>=cs[k].cols||r.br().y>=cs[k].rows) {++edge;continue;}
            auto box=cv::minAreaRect(c);double small=std::min(box.size.width,box.size.height),big=std::max(box.size.width,box.size.height);
            if(small<=1)continue;
            rows.push_back({big/unit,small/unit,std::sqrt(area)/unit,big/small,area/std::max(1.,big*small)});
            if(small>=unit*.06&&big>=unit*.15)centers.push_back(box.center);
        }
        // estimator uses .T.ravel(), i.e. feature-major quantiles.
        for(size_t j=0;j<5;++j) {Vec col;for(const auto&r:rows)col.push_back(r[j]);quantiles(f,col,{.25,.5,.75});}
        Vec gaps;for(auto c:centers) {double best=INFINITY;for(auto other:centers) {
            double d=std::hypot(double(c.x)-other.x,double(c.y)-other.y);
            if(d>unit*.08&&d<unit*2)best=std::min(best,d);
        } if(std::isfinite(best))gaps.push_back(best/unit);}
        quantiles(f,gaps,{.25,.5,.75});append(f,{rows.size()/std::max(1.,b.width*b.height/(prior*prior)),edge/std::max(1.,edge+rows.size())});
    }
    checked(f,40);return f;
}
static Vec stroke55(const Target& t) {
    Vec f;
    for(const auto&m:masks(t.rgb,70,75))append(f,strokeSummary(m,std::max(1.,t.unit)));
    checked(f,55);return f;
}
static Vec grouped144(const Target& t,const std::vector<cv::Mat>& cs,const cv::Rect2d& b,double prior) {
    Vec f;
    for(int k:{1,3})for(double fraction:{.04,.1,.2}) {
        int size=2*std::max(1,pyRound(t.unit*fraction/2))+1;
        for(auto shape:{cv::Size(size,1),cv::Size(1,size),cv::Size(size,size)}) {
            int pad=std::max(shape.width,shape.height)/2;cv::Mat padded,closed;
            cv::copyMakeBorder(cs[k],padded,pad,pad,pad,pad,cv::BORDER_CONSTANT,0);
            cv::morphologyEx(padded,closed,cv::MORPH_CLOSE,cv::Mat::ones(shape,CV_8U),cv::Point(-1,-1),1,cv::BORDER_CONSTANT,0);
            closed=closed(cv::Rect(pad,pad,t.rgb.cols,t.rgb.rows));Vec longs,shorts;double touch=0;
            for(const auto&s:bodies(closed)) {
                if(s.area<std::max(3.,t.unit*t.unit*.003)||s.area>=closed.total()*.65)continue;
                longs.push_back(std::max(s.w,s.h)/t.unit);shorts.push_back(std::min(s.w,s.h)/t.unit);
                touch+=s.x==0||s.y==0||s.x+s.w>=closed.cols||s.y+s.h>=closed.rows;
            }
            if(longs.empty())zeros(f,8);else {quantiles(f,longs,{.25,.5,.75});quantiles(f,shorts,{.25,.5,.75});
                append(f,{longs.size()/std::max(1.,b.width*b.height/(prior*prior)),touch/longs.size()});}
        }
    }
    checked(f,144);return f;
}
Vec weightEstimatorExtra40(const cv::Mat& rgb,const cv::Rect2d& b,double prior) {
    const auto t = target(rgb,b,prior,640);
    return estimatorExtra40(t,cores(t.rgb),b,prior);
}
Vec weightStroke55(const cv::Mat& rgb,const cv::Rect2d& b,double prior) {
    return stroke55(target(rgb,b,prior,640));
}
Vec weightGrouped144(const cv::Mat& rgb,const cv::Rect2d& b,double prior) {
    const auto t = target(rgb,b,prior,640);
    return grouped144(t,cores(t.rgb),b,prior);
}
Vec composeWeightRaw597(const cv::Mat& rgb,const cv::Rect2d& b,double prior,const Vec& native,
                        const Vec& glyph,const Vec& metrics) {
    checked(native,156);checked(glyph,56);checked(metrics,146);Vec f=native;std::fill(f.begin(),f.begin()+6,0.);
    const auto t = target(rgb,b,prior,640);
    const auto cs = cores(t.rgb);
    append(f,estimatorExtra40(t,cs,b,prior));append(f,stroke55(t));
    append(f,grouped144(t,cs,b,prior));append(f,glyph);append(f,metrics);checked(f,597);return f;
}
WeightDirectObservation weightDirect7(const cv::Mat& rgb,const cv::Rect2d& b,double prior) {
    auto t=target(rgb,b,prior,800);auto ms=masks(t.rgb,80,65);
    std::vector<std::string> names={"dark-otsu","light-otsu","dark-core","light-core","color-core"};
    cv::Mat codes(t.rgb.size(),CV_32S);std::map<int,int> counts;
    for(int y=0;y<t.rgb.rows;++y)for(int x=0;x<t.rgb.cols;++x) {
        auto p=t.rgb.at<cv::Vec3b>(y,x);int c=(p[0]/32)*64+(p[1]/32)*8+p[2]/32;codes.at<int>(y,x)=c;++counts[c];
    }
    std::vector<int> order;for(auto c:counts)order.push_back(c.first);
    paletteArgsort(order,counts);
    for(size_t j=order.size()>6?order.size()-6:0;j<order.size();++j) {cv::Mat m=codes==order[j];m/=255;ms.push_back(m);names.push_back("palette");}
    WeightDirectObservation best={Vec(7,0.),"none"};bool found=false;
    for(size_t k=0;k<ms.size();++k) {
        const auto&m=ms[k];cv::Mat labels;auto stats=bodies(m,&labels);std::vector<Vec> rows;
        for(size_t i=0;i<stats.size();++i) {
            auto s=stats[i];double big=std::max(s.w,s.h),small=std::min(s.w,s.h);
            if(big<.22*t.unit||big>1.7*t.unit||small<std::max(2.,.06*t.unit)||s.area<std::max(4.,.006*t.unit*t.unit)||s.area>m.total()*.6)continue;
            cv::Mat body=labels(cv::Rect(s.x,s.y,s.w,s.h))==int(i+1);body/=255;
            auto widths=ridgeWidths(body,t.unit,true);if(widths.empty())continue;
            Contours contours;std::vector<cv::Vec4i> hierarchy;cv::findContours(body.clone(),contours,hierarchy,cv::RETR_CCOMP,cv::CHAIN_APPROX_SIMPLE);
            double hole=0;for(size_t j=0;j<contours.size();++j)if(hierarchy[j][3]>=0)hole+=cv::contourArea(contours[j]);
            rows.push_back({median(widths),quantile(widths,.25),quantile(widths,.9),hole/std::max(1.,hole+s.area),double(s.area)/(s.w*s.h),
                           double(s.x==0||s.y==0||s.x+s.w==m.cols||s.y+s.h==m.rows),big/t.unit});
        }
        if(rows.empty())continue;
        std::array<Vec,7> cols;for(const auto&r:rows)for(int j=0;j<7;++j)cols[j].push_back(r[j]);
        Vec clipped;for(double v:cols[6])clipped.push_back(std::clamp(v,0.,1.));
        double quality=std::log1p(rows.size())*std::max(.01,1-median(cols[3])*1.7)*(1-.6*mean(cols[5]))*mean(clipped);
        if(!found||quality>best.features[0]) {found=true;best={Vec{quality,double(rows.size()),median(cols[0]),median(cols[1]),median(cols[2]),median(cols[3]),median(cols[4])},names[k]};}
    }
    checked(best.features,7);return best;
}
namespace {
// NumPy float32 pairwise reduction (same BSD notice above). Alpha's sum
// also drives the >1 evidence bit, so rounding it only at the end is wrong.
float alphaPairwise(const float* a,size_t n) {
    if(n<8){float sum=-0.f;for(size_t i=0;i<n;++i)sum+=a[i];return sum;}
    if(n<=128){float r[8];std::copy(a,a+8,r);size_t i=8;
        for(;i<n-n%8;i+=8)for(int j=0;j<8;++j)r[j]+=a[i+j];
        float sum=((r[0]+r[1])+(r[2]+r[3]))+((r[4]+r[5])+(r[6]+r[7]));
        for(;i<n;++i)sum+=a[i];return sum;}
    size_t half=n/2;half-=half%8;return alphaPairwise(a,half)+alphaPairwise(a+half,n-half);
}
float alphaFloatSum(const cv::Mat& a) {
    cv::Mat flat=a.isContinuous()?a:a.clone();const float* p=flat.ptr<float>();
    if(a.isContinuous())return alphaPairwise(p,a.total());
    // NumPy's buffered noncontiguous reduction iterator uses 8192 elements.
    float sum=0;for(size_t i=0;i<a.total();i+=8192)sum+=alphaPairwise(p+i,std::min(size_t(8192),a.total()-i));
    return sum;
}
Vec alphaMoments(const cv::Mat& input,double unit) {
    cv::Mat a;input.convertTo(a,CV_64F);double sum=cv::sum(a)[0],mass=std::max(1e-7,sum),cx=0,cy=0;
    for(int y=0;y<a.rows;++y)for(int x=0;x<a.cols;++x){double v=a.at<double>(y,x);cx+=v*(x-(a.cols-1)/2.);cy+=v*(y-(a.rows-1)/2.);}
    cx/=mass;cy/=mass;double xx=0,yy=0,xy=0,xxx=0,yyy=0,variationX=0,variationY=0,rim=0;
    int edge=std::max(1,pyRound(unit*.025));
    for(int y=0;y<a.rows;++y)for(int x=0;x<a.cols;++x) {
        double v=a.at<double>(y,x),dx=x-(a.cols-1)/2.-cx,dy=y-(a.rows-1)/2.-cy;
        xx+=v*dx*dx;yy+=v*dy*dy;xy+=v*dx*dy;xxx+=v*dx*dx*dx;yyy+=v*dy*dy*dy;
        if(x+1<a.cols)variationX+=std::abs(v-a.at<double>(y,x+1));
        if(y+1<a.rows)variationY+=std::abs(v-a.at<double>(y+1,x));
        if(x<edge||x>=std::max(edge,a.cols-edge)||y<edge||y>=std::max(edge,a.rows-edge))rim+=v;
    }
    cv::Mat binary=a>.5;binary/=255;std::vector<cv::Point> positions;cv::findNonZero(binary,positions);
    auto rect=positions.empty()?cv::Rect():cv::boundingRect(positions);cv::Mat labels;int n=cv::connectedComponents(binary,labels,8);
    Contours contours;std::vector<cv::Vec4i> hierarchy;cv::findContours(binary.clone(),contours,hierarchy,cv::RETR_CCOMP,cv::CHAIN_APPROX_SIMPLE);
    double perimeter=0,holes=0,hullArea=0;std::vector<cv::Point> all;
    for(size_t j=0;j<contours.size();++j) {perimeter+=cv::arcLength(contours[j],true);holes+=hierarchy[j][3]>=0;all.insert(all.end(),contours[j].begin(),contours[j].end());}
    if(!all.empty()){std::vector<cv::Point> hull;cv::convexHull(all,hull);hullArea=cv::contourArea(hull);}
    double u2=unit*unit,u3=u2*unit;
    Vec f={mass/u2,rect.width/unit,rect.height/unit,cx/unit,cy/unit,xx/mass/u2,yy/mass/u2,xy/mass/u2,xxx/mass/u3,yyy/mass/u3,
           cv::countNonZero(binary)/u2,perimeter/unit,std::log1p(std::max(0,n-1)),std::log1p(holes),mass/std::max(1,rect.width*rect.height),variationX/unit,variationY/unit,hullArea/u2};
    cv::Mat depth;cv::distanceTransform(binary,depth,cv::DIST_L2,3);auto positive=values(depth,cv::Mat(),true);
    for(double q:{.25,.5,.75,.9})f.push_back(quantile(positive,q)/unit);
    f.push_back(rim/mass);
    // np.array_split assigns remainder cells to the earliest groups.
    int y0=0;for(int gy=0;gy<3;++gy){int y1=y0+a.rows/3+(gy<a.rows%3);int x0=0;
        for(int gx=0;gx<3;++gx){int x1=x0+a.cols/3+(gx<a.cols%3);double cell=0;
            for(int y=y0;y<y1;++y)for(int x=x0;x<x1;++x)cell+=a.at<double>(y,x);
            f.push_back(cell/mass);x0=x1;}y0=y1;}
    return f;
}
}
Vec weightFill71V1(const cv::Mat& alpha,const cv::Rect2d& b,double em,const cv::Mat& own,const WeightFillStyle& style) {
    if(alpha.empty()||(alpha.type()!=CV_32FC1&&alpha.type()!=CV_64FC1)||own.type()!=CV_8UC1||own.size()!=alpha.size()||!std::isfinite(em)||em<=0||
       !std::isfinite(b.x)||!std::isfinite(b.y)||!std::isfinite(b.width)||!std::isfinite(b.height)||b.width<=0||b.height<=0)
        throw std::invalid_argument("Invalid fill alpha/ownership/bbox/em");
    for(double v:values(alpha))if(!std::isfinite(v)||v<0||v>1)throw std::invalid_argument("Invalid predicted alpha");
    for(double v:values(own))if(v!=0&&v!=1)throw std::invalid_argument("Ownership must be boolean 0/1");
    for(int i=0;i<3;++i)if(!std::isfinite(style.fillRGB[i])||!std::isfinite(style.backgroundRGB[i]))throw std::invalid_argument("Invalid fill palette");
    if(!std::isfinite(style.outlineWidthPx))throw std::invalid_argument("Invalid outline width");
    cv::Mat t=alpha(targetRect(alpha,b));double scale=std::min(1.,800./std::max(t.rows,t.cols)),unit=em*scale;
    if(scale<1)cv::resize(t,t,cv::Size(),scale,scale,cv::INTER_AREA);
    Vec f;for(double cutoff:{.25,.5,.75}){cv::Mat mask=t>cutoff;mask/=255;append(f,strokeSummary(mask,unit));}
    append(f,alphaMoments(t,unit));
    double total=t.depth()==CV_32F?double(alphaFloatSum(t)):cv::sum(t)[0];double meanAlpha=total/t.total();
    // NumPy retains float32 accumulation for float32 alpha.mean()/sum().
    if(t.depth()==CV_32F)meanAlpha=float(meanAlpha);
    append(f,{fraction(t>.5),meanAlpha,cv::norm(style.fillRGB-style.backgroundRGB)/std::sqrt(3.*255*255),
              style.outlinePresent?style.outlineWidthPx/em:0.,double(total>1),cv::sum(own)[0]/own.total()});
    checked(f,71);return f;
}
bool qualifiedWeightMixed(const cv::Mat& rgb,const cv::Rect2d& b,double em,const WeightFillStyle& style) {
    checkSource(rgb,b,em);
    for(int c=0;c<3;++c) {
        if(!std::isfinite(style.fillRGB[c])||!std::isfinite(style.backgroundRGB[c])||
           style.fillRGB[c]<0||style.fillRGB[c]>255||style.backgroundRGB[c]<0||style.backgroundRGB[c]>255)
            return false;
        if(style.fillRGB[c]<=230||style.backgroundRGB[c]>=45)return false;
    }
    if(style.outlinePresent||std::max(b.width,b.height)/std::min(b.width,b.height)<1.3)return false;
    const auto rect=targetRect(rgb,b);auto image=rgb(rect);
    cv::Mat gray,ink;cv::cvtColor(image,gray,cv::COLOR_RGB2GRAY);
    cv::threshold(gray,ink,0,1,cv::THRESH_BINARY_INV|cv::THRESH_OTSU);
    if(cv::mean(ink)[0]>.5)ink=1-ink;
    bool vertical=b.height>=b.width;
    std::vector<int> profile(vertical?ink.cols:ink.rows,0);
    for(int y=0;y<ink.rows;++y)for(int x=0;x<ink.cols;++x)
        profile[vertical?x:y]+=ink.at<uchar>(y,x);
    const double threshold=std::max(1.,*std::max_element(profile.begin(),profile.end())*.06);
    std::vector<std::vector<int>> groups;
    const int gap=std::max(1,pyRound(em*.08));
    for(int i=0;i<int(profile.size());++i)if(profile[i]>threshold) {
        if(groups.empty()||i-groups.back().back()>gap)groups.push_back({});
        groups.back().push_back(i);
    }
    std::vector<cv::Rect2d> lines;
    for(const auto& group:groups) {
        if(group.back()-group.front()+1<em*.15)continue;
        int lo=std::max(0,group.front()-1),hi=std::min(int(profile.size()),group.back()+2);
        lines.push_back(vertical?cv::Rect2d(rect.x+lo,rect.y,hi-lo,rect.height):
                                 cv::Rect2d(rect.x,rect.y+lo,rect.width,hi-lo));
    }
    if(lines.size()<2)return false;
    Vec supported;
    std::vector<WeightDirectObservation> observations;
    for(const auto& line:lines) {
        auto observed=weightDirect7(rgb,line,em);
        if(observed.features[1]>=2)supported.push_back(observed.features[2]);
        observations.push_back(std::move(observed));
    }
    double center=median(supported);bool bold=false,regular=false;
    for(const auto& observed:observations) {
        bool heavy=center>0&&observed.features[1]>=2&&observed.features[2]>=std::max(.12,center*1.5);
        bold|=heavy;regular|=!heavy;
    }
    return bold&&regular;
}
}} // namespace aidoku::source
