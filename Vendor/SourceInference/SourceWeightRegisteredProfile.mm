#include "SourceWeightRegisteredProfile.h"
#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <vector>

#ifdef __clang__
#pragma clang fp contract(off)
#endif

namespace aidoku {
namespace {
bool alphaType(const cv::Mat &a) { return a.type()==CV_32FC1 || a.type()==CV_64FC1; }
double pixel(const cv::Mat &a, int y, int x) {
    if (a.type()==CV_8UC1) return a.at<uchar>(y,x);
    return a.type()==CV_32FC1 ? double(a.at<float>(y,x)) : a.at<double>(y,x);
}
cv::Mat knownBytes(const cv::Mat &known) {
    if (known.type()==CV_8UC1) return known;
    cv::Mat out(known.size(),CV_8U);
    for (int y=0; y<known.rows; ++y) for (int x=0; x<known.cols; ++x) {
        // astype(uint8) truncates and wraps; convertTo would round/saturate.
        double v=std::fmod(std::trunc(pixel(known,y,x)),256.);
        out.at<uchar>(y,x)=uchar(v<0 ? v+256 : v);
    }
    return out;
}
void validate(const SourceWeightRegisteredProfileInput &in, bool soft) {
    const char *geometry=soft ? "Invalid soft stroke geometry" : "Registered stroke geometry differs";
    if (in.source.empty() || !alphaType(in.source) || !alphaType(in.regular) || !alphaType(in.heavy) ||
        !(in.known.type()==CV_8UC1 || alphaType(in.known)) || in.source.dims!=2 ||
        in.regular.size()!=in.source.size() || in.heavy.size()!=in.source.size() || in.known.size()!=in.source.size() ||
        in.unit<=0 || (soft && !std::isfinite(in.unit))) throw std::invalid_argument(geometry);
    for (const auto *a : {&in.source,&in.regular,&in.heavy,&in.known})
        if (!cv::checkRange(*a)) throw std::invalid_argument(soft ? geometry : "Nonfinite registered stroke evidence");
}
float median(std::vector<float> v) {
    std::sort(v.begin(),v.end()); size_t n=v.size();
    // np.median on a float32 array uses float32 sum/division for even sizes.
    return n%2 ? v[n/2] : (v[n/2-1]+v[n/2])/2.f;
}
float quantile(std::vector<float> v, double q) {
    std::sort(v.begin(),v.end()); double position=(v.size()-1)*q;
    size_t i=size_t(position),j=std::min(i+1,v.size()-1);
    float t=float(position-i),difference=v[j]-v[i];
    // Scalar .25/.75 NumPy quantiles retain float32 arithmetic and output.
    return t<.5f ? v[i]+difference*t : v[j]-difference*(1.f-t);
}
SourceWeightRegisteredProfileObservation profile(const SourceWeightRegisteredProfileInput &in, bool soft) {
    validate(in,soft);
    cv::Mat nd,bd,sd;
    if (soft) {
        nd=sourceWeightSoftProfileDepth(in.regular); bd=sourceWeightSoftProfileDepth(in.heavy);
        sd=sourceWeightSoftProfileDepth(in.source);
    } else {
        cv::Mat normal=in.regular>.5,heavy=in.heavy>.5,source=in.source>.5;
        normal/=255; heavy/=255; source/=255;
        nd=sourceWeightRegisteredSignedDistance(normal); bd=sourceWeightRegisteredSignedDistance(heavy);
        sd=sourceWeightRegisteredSignedDistance(source);
    }
    cv::Mat dilated,trusted;
    cv::dilate(nd,dilated,cv::Mat::ones(3,3,CV_8U));
    cv::erode(knownBytes(in.known),trusted,cv::Mat::ones(3,3,CV_8U),{-1,-1},1,
              cv::BORDER_CONSTANT|cv::BORDER_ISOLATED,cv::morphologyDefaultBorderValue());
    SourceWeightRegisteredProfileObservation out;
    if (soft) out.alphaLevels=sourceWeightSoftProfileLevels();
    std::vector<float> fractions,normalRadii,sourceRadii; int support=0;
    for (int y=0; y<nd.rows; ++y) for (int x=0; x<nd.cols; ++x) {
        float n=nd.at<float>(y,x),b=bd.at<float>(y,x),s=sd.at<float>(y,x);
        bool ridge=n>0 && n>=dilated.at<float>(y,x)-.001f;
        if (!(ridge && trusted.at<uchar>(y,x) && b>0)) continue;
        ++out.correspondingCentres;
        float difference=b-n;
        if (difference<(soft ? .5f : .75f)) continue;
        ++out.informativeCentres;
        fractions.push_back((s-n)/difference); normalRadii.push_back(n); sourceRadii.push_back(s);
        // Soft support tests ORIGINAL source alpha, not the integrated sd sign.
        support+=soft ? pixel(in.source,y,x)>.5 : s>0;
    }
    if (out.informativeCentres<8) return out;
    out.usable=true;
    out.measurements=SourceWeightRegisteredProfileMeasurements{
        median(fractions),quantile(fractions,.25),quantile(fractions,.75),
        double(support)/out.informativeCentres,
        float(median(normalRadii)/float(in.unit)),float(median(sourceRadii)/float(in.unit))};
    return out;
}
}
const std::array<double,9> &sourceWeightSoftProfileLevels() {
    static const std::array<double,9> levels={.1,.2,.30000000000000004,.4,.5,.6,.7000000000000001,.8,.9};
    return levels;
}
cv::Mat sourceWeightRegisteredSignedDistance(const cv::Mat &binary) {
    if (binary.empty() || binary.type()!=CV_8UC1 || cv::countNonZero(binary>1))
        throw std::invalid_argument("Expected binary registered stroke mask");
    cv::Mat insideInput,outsideInput,inside,outside;
    cv::copyMakeBorder(binary,insideInput,1,1,1,1,cv::BORDER_CONSTANT|cv::BORDER_ISOLATED,0);
    cv::Mat complement=1-binary;
    cv::copyMakeBorder(complement,outsideInput,1,1,1,1,cv::BORDER_CONSTANT|cv::BORDER_ISOLATED,1);
    cv::distanceTransform(insideInput,inside,cv::DIST_L2,cv::DIST_MASK_PRECISE);
    cv::distanceTransform(outsideInput,outside,cv::DIST_L2,cv::DIST_MASK_PRECISE);
    cv::Rect crop(1,1,binary.cols,binary.rows);
    return inside(crop)-outside(crop);
}
cv::Mat sourceWeightSoftProfileDepth(const cv::Mat &alpha) {
    if (alpha.empty() || !alphaType(alpha)) throw std::invalid_argument("Invalid soft stroke geometry");
    cv::Mat a; alpha.convertTo(a,CV_32F);
    cv::Mat result=cv::Mat::zeros(a.size(),CV_32F);
    for (double level:sourceWeightSoftProfileLevels()) {
        cv::Mat binary=a>=float(level); binary/=255;
        auto sd=sourceWeightRegisteredSignedDistance(binary);
        for (int y=0; y<a.rows; ++y) for (int x=0; x<a.cols; ++x) {
            // np.where yields float64 edge correction. += casts to float32
            // only AFTER adding this corrected distance to the accumulator.
            double edge=binary.at<uchar>(y,x) ? .5 : -.5;
            double corrected=double(sd.at<float>(y,x))-edge;
            result.at<float>(y,x)=float(double(result.at<float>(y,x))+corrected);
        }
    }
    for (int y=0; y<a.rows; ++y) for (int x=0; x<a.cols; ++x)
        result.at<float>(y,x)/=float(sourceWeightSoftProfileLevels().size());
    return result;
}
SourceWeightRegisteredProfileObservation measureSourceWeightRegisteredProfile(const SourceWeightRegisteredProfileInput &in) {
    return profile(in,false);
}
SourceWeightRegisteredProfileObservation measureSourceWeightSoftStrokeProfile(const SourceWeightRegisteredProfileInput &in) {
    return profile(in,true);
}
}
