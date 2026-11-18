#include "SourceWeightStrokeGeometry.h"
#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

#ifdef __clang__
#pragma clang fp contract(off)
#endif

namespace aidoku {
namespace {
void alphaGeometry(const cv::Mat &alpha, const cv::Mat &known, const char *message) {
    if (alpha.empty() || alpha.type() != CV_32FC1 || known.type() != CV_8UC1 || known.size() != alpha.size())
        throw std::invalid_argument(message);
}
cv::Mat boolean(const cv::Mat &m) {
    cv::Mat out; cv::compare(m, 0, out, cv::CMP_NE); out /= 255; return out;
}
int nearestEven(double x) {
    double f = std::floor(x), d = x-f;
    return int(d < .5 ? f : d > .5 ? f+1 : std::fmod(f, 2) == 0 ? f : f+1);
}
double quantile(std::vector<double> values, double q) {
    if (values.empty()) return 0;
    std::sort(values.begin(), values.end());
    double pos = (values.size()-1)*q;
    size_t i = size_t(pos), j = std::min(i+1, values.size()-1);
    // NumPy's linear interpolation chooses the upper endpoint when weight>=.5.
    double t = pos-i, diff = values[j]-values[i];
    return t < .5 ? values[i]+diff*t : values[j]-diff*(1-t);
}
struct EdgeRay { int x, y, group; float nx, ny; bool alive = true; };
struct RaySamples {
    std::vector<double> widths;
    std::array<std::vector<double>, 3> groups;
    size_t sampled = 0;
};
RaySamples trace(const cv::Mat &alpha, const cv::Mat &known, const cv::Mat &mask,
                 double unit, int maximumEdges) {
    cv::Mat smooth, dx, dy, length(alpha.size(), CV_32F), eroded, trusted;
    cv::GaussianBlur(alpha, smooth, {3,3}, .65);
    cv::Sobel(smooth, dx, CV_32F, 1, 0, 3);
    cv::Sobel(smooth, dy, CV_32F, 0, 1, 3);
    cv::Mat kernel = cv::Mat::ones(3, 3, CV_8U);
    cv::erode(mask, eroded, kernel); cv::erode(known, trusted, kernel);
    std::vector<EdgeRay> rays;
    for (int y=0; y<alpha.rows; ++y) for (int x=0; x<alpha.cols; ++x) {
        float gx=dx.at<float>(y,x), gy=dy.at<float>(y,x), mag=std::hypot(gx,gy);
        length.at<float>(y,x)=mag;
        if (mask.at<uchar>(y,x) && !eroded.at<uchar>(y,x) && trusted.at<uchar>(y,x) && mag>.08f) {
            float nx=gx/mag, ny=gy/mag;
            int group=std::abs(nx)>=.9f ? 0 : std::abs(ny)>=.9f ? 1 : 2;
            rays.push_back({x,y,group,nx,ny});
        }
    }
    if (rays.size()>size_t(maximumEdges)) {
        std::vector<EdgeRay> selected;
        double step=maximumEdges>1 ? double(rays.size()-1)/(maximumEdges-1) : 0;
        for (int i=0; i<maximumEdges; ++i) {
            size_t index=i==maximumEdges-1 && maximumEdges>1 ? rays.size()-1 : size_t(i*step);
            selected.push_back(rays[index]);
        }
        rays=std::move(selected);
    }
    RaySamples out; out.sampled=rays.size();
    // np.arange's upper endpoint is excluded. A ray dies on its FIRST outside
    // mask hit, even if that hit has a bad normal or is too close to qualify.
    double end=std::max(2.1, .5*unit)+.1;
    for (double distance=.5; distance<end; distance+=.5) {
        bool any=false;
        for (auto &r:rays) if (r.alive) {
            any=true;
            // np.arange distance is float64, so positions use double arithmetic.
            int x=nearestEven(r.x+distance*double(r.nx)), y=nearestEven(r.y+distance*double(r.ny));
            if (x<0 || y<0 || x>=alpha.cols || y>=alpha.rows || !trusted.at<uchar>(y,x)) { r.alive=false; continue; }
            if (mask.at<uchar>(y,x)) continue;
            float dotX=r.nx*dx.at<float>(y,x), dotY=r.ny*dy.at<float>(y,x);
            float alignment=(dotX+dotY)/std::max(1e-6f,length.at<float>(y,x));
            if (alignment<-.5f && length.at<float>(y,x)>.08f && distance>=1.) {
                out.widths.push_back(distance/unit); out.groups[r.group].push_back(distance/unit);
            }
            r.alive=false;
        }
        if (!any) break;
    }
    return out;
}
void validScale(double em, const char *message) {
    if (!std::isfinite(em) || em<=0) throw std::invalid_argument(message);
}
}
SourceStrokeOpposedWidths sourceWeightOpposedWidths(const cv::Mat &alpha,
    const cv::Mat &observed, const cv::Mat &mask, double unit, int maximumEdges) {
    alphaGeometry(alpha, observed, "Invalid stroke-width geometry");
    if (mask.type()!=CV_8UC1 || mask.size()!=alpha.size()) throw std::invalid_argument("Invalid stroke-width geometry");
    validScale(unit,"Invalid stroke-width geometry");
    if (maximumEdges<0) throw std::invalid_argument("Number of samples must be non-negative");
    auto rays=trace(alpha,boolean(observed),boolean(mask),unit,maximumEdges);
    return {rays.widths,rays.sampled ? double(rays.widths.size())/rays.sampled : 0.};
}
SourceStrokeDirectionalObservation measureSourceWeightDirectional(const cv::Mat &alpha,
    const cv::Mat &known, double unit, std::optional<double> maximumComponentEm) {
    alphaGeometry(alpha,known,"Invalid directional stroke input");
    if (unit<=0 || !cv::checkRange(alpha)) throw std::invalid_argument("Invalid directional stroke input");
    SourceStrokeDirectionalObservation out;
    const std::array<std::string,3> names={"verticalStems","horizontalStems","diagonalStems"};
    for (const auto &name:names) out.groups[name]={};
    // directional_ink checks <=0 but not finite(unit). NaN yields its zero
    // structure; infinity fails at np.arange and remains an error here.
    if (std::isnan(unit)) return out;
    if (!std::isfinite(unit)) throw std::invalid_argument("Maximum allowed size exceeded");
    cv::Mat binary=(alpha>.5f)&(known!=0),labels,stats,centroids;
    int n=cv::connectedComponentsWithStats(binary,labels,stats,centroids,8);
    std::vector<uchar> accepted(n,0);
    for (int i=1; i<n; ++i) {
        int extent=std::max(stats.at<int>(i,2),stats.at<int>(i,3));
        bool ok=extent>=.2*unit && stats.at<int>(i,4)>=std::max(4.,.003*(unit*unit));
        if (maximumComponentEm) ok=ok && extent<=*maximumComponentEm*unit;
        accepted[i]=ok; out.components+=ok;
    }
    cv::Mat mask=cv::Mat::zeros(alpha.size(),CV_8U);
    for (int y=0; y<alpha.rows; ++y) for (int x=0; x<alpha.cols; ++x) mask.at<uchar>(y,x)=accepted[labels.at<int>(y,x)];
    auto rays=trace(alpha,boolean(known),mask,unit,6000);
    std::vector<double> medians;
    const std::array<double,4> qs={.1,.25,.5,.75};
    for (int i=0; i<3; ++i) {
        auto &group=out.groups[names[i]]; group.count=int(rays.groups[i].size());
        for (int j=0; j<4; ++j) group.quantiles[j]=quantile(rays.groups[i],qs[j]);
        if (group.count>=12) medians.push_back(group.quantiles[2]);
    }
    if (!medians.empty()) out.minimumDirectionalMedian=*std::min_element(medians.begin(),medians.end());
    if (medians.size()>=2) out.directionContrast=*std::max_element(medians.begin(),medians.end())/std::max(1e-6,out.minimumDirectionalMedian);
    return out;
}
SourceStrokeDirectionalObservation measureColorBackedSourceWeightDirectional(const cv::Mat &rgb,
    const cv::Mat &ownership, const SourceInkStyle &style, double em) {
    validScale(em,"Invalid directional source geometry");
    if (rgb.empty() || rgb.type()!=CV_8UC3 || ownership.type()!=CV_8UC1 || ownership.size()!=rgb.size())
        throw std::invalid_argument("Invalid directional source geometry");
    auto clean=cleanSourceInkStyle(style);
    SourceInkObservation color{cv::Mat::zeros(rgb.size(),CV_32F),boolean(ownership)};
    if (clean) color=observeSourceInkPalette(rgb,ownership,*clean);
    color.alpha.setTo(0,ownership==0);
    return measureSourceWeightDirectional(color.alpha,color.known,em);
}
SourceStrokeGeometryObservation observeSourceWeightStrokeAlpha(const cv::Mat &sourceAlpha,
    const cv::Mat &sourceKnown, const cv::Rect2d &bbox, double em, const cv::Mat &sourceOwnership,
    bool sourcePaletteQualified) {
    validScale(em,"Invalid stroke measurement scale");
    alphaGeometry(sourceAlpha,sourceKnown,"Invalid stroke measurement geometry");
    if (sourceOwnership.type()!=CV_8UC1 || sourceOwnership.size()!=sourceAlpha.size() ||
        !std::isfinite(bbox.x) || !std::isfinite(bbox.y) || !std::isfinite(bbox.width) || !std::isfinite(bbox.height))
        throw std::invalid_argument("Invalid stroke measurement geometry");
    cv::Mat alpha=sourceAlpha,known=boolean(sourceKnown),ownership=boolean(sourceOwnership);
    double scale=std::min(1.,800./std::max(alpha.rows,alpha.cols));
    if (scale<1) {
        cv::resize(sourceAlpha,alpha,{},scale,scale,cv::INTER_AREA);
        cv::Mat knownFloat;known.convertTo(knownFloat,CV_32F);
        cv::resize(knownFloat,knownFloat,alpha.size(),0,0,cv::INTER_AREA);known=boolean(knownFloat>.99f);
        cv::resize(ownership,ownership,alpha.size(),0,0,cv::INTER_NEAREST);
    }
    double unit=em*scale;
    cv::Mat target=cv::Mat::zeros(alpha.size(),CV_8U);
    // Match Python's clipped slice, including negative stop indices/empty boxes.
    auto bound=[](double value,int size) { return int(std::clamp(value,0.,double(size))); };
    int left=bound(std::floor(bbox.x*scale),alpha.cols),top=bound(std::floor(bbox.y*scale),alpha.rows);
    double stopX=std::min(double(alpha.cols),std::ceil(bbox.x*scale+bbox.width*scale));
    double stopY=std::min(double(alpha.rows),std::ceil(bbox.y*scale+bbox.height*scale));
    int right=bound(stopX<0 ? alpha.cols+stopX : stopX,alpha.cols),bottom=bound(stopY<0 ? alpha.rows+stopY : stopY,alpha.rows);
    if (right>left && bottom>top) target(cv::Rect(left,top,right-left,bottom-top)).setTo(1);
    SourceStrokeGeometryObservation out;out.sourcePaletteQualified=sourcePaletteQualified;
    const std::array<double,3> cutoffs={.25,.5,.75};
    const std::array<double,4> qs={.25,.5,.75,.9};
    for (int k=0; k<3; ++k) {
        auto &stage=out.stages[k]; stage.cutoff=cutoffs[k];
        cv::Mat binary=(alpha>float(cutoffs[k]))&(known!=0)&(ownership!=0),labels,stats,centroids;
        int n=cv::connectedComponentsWithStats(binary,labels,stats,centroids,8);
        std::vector<int> overlaps(n,0); std::vector<uchar> chosen(n,0);
        for (int y=0; y<alpha.rows; ++y) for (int x=0; x<alpha.cols; ++x) if (target.at<uchar>(y,x)) ++overlaps[labels.at<int>(y,x)];
        std::vector<std::array<double,8>> bodies;
        for (int i=1; i<n; ++i) {
            int sx=stats.at<int>(i,0),sy=stats.at<int>(i,1),sw=stats.at<int>(i,2),sh=stats.at<int>(i,3),area=stats.at<int>(i,4);
            int extent=std::max(sw,sh);
            if (!(extent>=.22*unit && extent<=1.7*unit && std::min(sw,sh)>=std::max(2.,.06*unit) &&
                  area>=std::max(4.,.006*(unit*unit)) && double(overlaps[i])/area>=.3)) continue;
            cv::Mat body=cv::Mat::zeros(sh+2,sw+2,CV_8U);
            cv::Mat inside=(labels(cv::Rect(sx,sy,sw,sh))==i);inside/=255;
            inside.copyTo(body(cv::Rect(1,1,sw,sh)));
            cv::Mat depth,dilated;
            cv::distanceTransform(body,depth,cv::DIST_L2,cv::DIST_MASK_PRECISE);
            cv::dilate(depth,dilated,cv::Mat::ones(3,3,CV_8U));
            std::vector<double> widths;
            for (int y=0; y<body.rows; ++y) for (int x=0; x<body.cols; ++x) {
                float d=depth.at<float>(y,x);
                if (d>0 && d>=dilated.at<float>(y,x)-.001f) widths.push_back(float(2.f*d/float(unit)));
            }
            if (widths.size()<std::max(3.,.1*unit)) continue;
            std::vector<std::vector<cv::Point>> contours;std::vector<cv::Vec4i> hierarchy;
            cv::findContours(body,contours,hierarchy,cv::RETR_CCOMP,cv::CHAIN_APPROX_SIMPLE);
            double perimeter=0,holes=0;
            for (size_t c=0; c<contours.size(); ++c) {
                perimeter+=cv::arcLength(contours[c],true);
                if (hierarchy[c][3]>=0) holes+=cv::contourArea(contours[c]);
            }
            bodies.push_back({quantile(widths,qs[0]),quantile(widths,qs[1]),quantile(widths,qs[2]),quantile(widths,qs[3]),
                2.*area/std::max(1.,perimeter)/unit,double(area)/(sw*sh),double(extent)/unit,holes/std::max(1.,holes+area)});
            chosen[i]=1;
        }
        cv::Mat selected=cv::Mat::zeros(alpha.size(),CV_8U);
        for (int y=0; y<alpha.rows; ++y) for (int x=0; x<alpha.cols; ++x) selected.at<uchar>(y,x)=chosen[labels.at<int>(y,x)];
        auto paired=sourceWeightOpposedWidths(alpha,known,selected,unit);
        stage.components=int(bodies.size());stage.pairedRays=int(paired.widths.size());stage.pairSupport=paired.pairSupport;
        for (int j=0; j<4; ++j) stage.pairedQuantiles[j]=quantile(paired.widths,qs[j]);
        for (int j=0; j<8; ++j) {
            std::vector<double> values;for (const auto &body:bodies) values.push_back(body[j]);
            stage.componentMedian[j]=quantile(values,.5);stage.componentUpper[j]=quantile(values,.75);
        }
        stage.observedFraction=double(cv::countNonZero(known))/known.total();
    }
    return out;
}
SourceStrokeGeometryObservation observeSourceWeightStrokeGeometry(const cv::Mat &rgb,
    const cv::Rect2d &bbox, double em, const cv::Mat &ownership, const SourceInkStyle &style) {
    validScale(em,"Invalid stroke measurement scale");
    if (rgb.empty() || rgb.type()!=CV_8UC3 || ownership.type()!=CV_8UC1 || ownership.size()!=rgb.size())
        throw std::invalid_argument("Source palette geometry differs");
    auto clean=cleanSourceInkStyle(style);
    SourceInkObservation color{cv::Mat::zeros(rgb.size(),CV_32F),cv::Mat::ones(rgb.size(),CV_8U)};
    if (clean) color=observeSourceInkPalette(rgb,ownership,*clean);
    return observeSourceWeightStrokeAlpha(color.alpha,color.known,bbox,em,ownership,bool(clean));
}
SourceStrokeGeometryObservation observeReconstructedSourceWeightStrokeGeometry(const cv::Mat &alpha,
    const cv::Mat &observed, const cv::Rect2d &bbox, double em, const cv::Mat &ownership) {
    alphaGeometry(alpha,observed,"Invalid reconstructed stroke geometry");
    if (ownership.type()!=CV_8UC1 || ownership.size()!=alpha.size() || (!cv::checkRange(alpha) || cv::countNonZero(alpha<0) || cv::countNonZero(alpha>1)))
        throw std::invalid_argument("Invalid reconstructed stroke geometry");
    cv::Mat signal(alpha.size(),CV_8UC3);
    for (int y=0; y<alpha.rows; ++y) for (int x=0; x<alpha.cols; ++x) {
        float difference=1.f-alpha.at<float>(y,x),value=255.f*difference;
        uchar gray=uchar(nearestEven(value));signal.at<cv::Vec3b>(y,x)={gray,gray,gray};
    }
    SourceInkStyle neutral;neutral.fill.rgb=SourceInkRGB{0,0,0};neutral.background.rgb=SourceInkRGB{255,255,255};
    return observeSourceWeightStrokeGeometry(signal,bbox,em,boolean(ownership)&boolean(observed),neutral);
}
}
