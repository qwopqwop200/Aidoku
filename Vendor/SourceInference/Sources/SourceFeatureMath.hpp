#pragma once
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <array>
#include <cmath>
#include <numeric>
#include <stdexcept>
#include <string>
#include <tuple>
#include <vector>

namespace aidoku { namespace source {
using Vec = std::vector<double>;
inline double mean(const Vec &v) { return v.empty()?0.:std::accumulate(v.begin(),v.end(),0.)/v.size(); }
inline double quantile(Vec v,double p) {
    if(v.empty())return 0.;std::sort(v.begin(),v.end());double pos=(v.size()-1)*p;
    size_t a=(size_t)std::floor(pos),b=(size_t)std::ceil(pos);return v[a]+(v[b]-v[a])*(pos-a);
}
inline double median(const Vec&v){return quantile(v,.5);}
inline double stddev(const Vec&v){if(v.empty())return 0.;double a=mean(v),sum=0.;for(double x:v)sum+=(x-a)*(x-a);return std::sqrt(sum/v.size());}
inline void append(Vec &out,const Vec &v){out.insert(out.end(),v.begin(),v.end());}
inline void zeros(Vec &out,size_t n){out.insert(out.end(),n,0.);}
inline void quantiles(Vec &out,const Vec &v,std::initializer_list<double> ps){for(double p:ps)out.push_back(quantile(v,p));}
inline void matrixQuantiles(Vec &out,const std::vector<Vec> &v,std::initializer_list<double> ps,size_t width){
    for(double p:ps)for(size_t j=0;j<width;++j){Vec col;for(const auto&r:v)col.push_back(r[j]);out.push_back(quantile(col,p));}
}
inline cv::Rect targetRect(const cv::Mat&m,const cv::Rect2d&b){
    int x=std::max(0,(int)b.x),y=std::max(0,(int)b.y),r=std::min(m.cols,(int)std::ceil(b.x+b.width)),d=std::min(m.rows,(int)std::ceil(b.y+b.height));
    if(r<=x||d<=y)throw std::invalid_argument("Empty source target");return cv::Rect(x,y,r-x,d-y);
}
struct Body {int x,y,w,h,area;double cx,cy;};
inline std::vector<Body> bodies(const cv::Mat&mask,cv::Mat*labelsOut=nullptr){
    cv::Mat labels,stats,centers;int n=cv::connectedComponentsWithStats(mask,labels,stats,centers,8,CV_32S);std::vector<Body> out;
    for(int i=1;i<n;++i)out.push_back({stats.at<int>(i,0),stats.at<int>(i,1),stats.at<int>(i,2),stats.at<int>(i,3),stats.at<int>(i,4),centers.at<double>(i,0),centers.at<double>(i,1)});
    if(labelsOut)*labelsOut=labels;return out;
}
inline Vec values(const cv::Mat&m,const cv::Mat&mask=cv::Mat(),bool positive=false){
    cv::Mat d;m.convertTo(d,CV_64F);Vec out;for(int y=0;y<d.rows;++y)for(int x=0;x<d.cols;++x){double v=d.at<double>(y,x);if((mask.empty()||mask.at<uchar>(y,x))&&(!positive||v>0))out.push_back(v);}return out;
}
inline double fraction(const cv::Mat&m){return m.empty()?0.:double(cv::countNonZero(m))/m.total();}
inline Vec projection(const cv::Mat&m,int axis){
    Vec out(axis==0?m.cols:m.rows,0.);for(int y=0;y<m.rows;++y)for(int x=0;x<m.cols;++x)if(m.at<uchar>(y,x))out[axis==0?x:y]+=1.;double n=axis==0?m.rows:m.cols;for(double&v:out)v/=n;return out;
}
inline Vec correlation(Vec signal){
    double a=mean(signal);for(double&v:signal)v-=a;Vec out(signal.size(),0.);
    for(size_t lag=0;lag<signal.size();++lag)for(size_t j=0;j+lag<signal.size();++j)out[lag]+=signal[j]*signal[j+lag];return out;
}
inline std::vector<int> peaks(const Vec&corr,int low,int high,size_t count){
    std::vector<int> out;if(corr.empty()||corr[0]<=1e-8)return out;
    for(int i=low;i<=high;++i)if(i>0&&i+1<(int)corr.size()&&corr[i]>0&&corr[i]>=corr[i-1]&&corr[i]>corr[i+1])out.push_back(i);
    std::stable_sort(out.begin(),out.end(),[&](int a,int b){return corr[a]>corr[b];});if(out.size()>count)out.resize(count);return out;
}
inline std::vector<cv::Mat> cores(const cv::Mat&rgb){
    std::vector<cv::Mat> out(5);for(auto&m:out)m=cv::Mat::zeros(rgb.size(),CV_8U);
    for(int y=0;y<rgb.rows;++y)for(int x=0;x<rgb.cols;++x){auto p=rgb.at<cv::Vec3b>(y,x);int lo=std::min({p[0],p[1],p[2]}),hi=std::max({p[0],p[1],p[2]}),c=hi-lo;
        out[0].at<uchar>(y,x)=hi<40;out[1].at<uchar>(y,x)=hi<100;out[2].at<uchar>(y,x)=lo>220&&c<45;out[3].at<uchar>(y,x)=lo>180&&c<45;out[4].at<uchar>(y,x)=c>80;}
    return out;
}
inline Vec medianRGB(const cv::Mat&rgb,const cv::Mat&mask){
    std::array<Vec,3> c;for(int y=0;y<rgb.rows;++y)for(int x=0;x<rgb.cols;++x)if(mask.empty()||mask.at<uchar>(y,x)){auto p=rgb.at<cv::Vec3b>(y,x);for(int j=0;j<3;++j)c[j].push_back(p[j]);}
    return {median(c[0]),median(c[1]),median(c[2])};
}
inline void checkSource(const cv::Mat&rgb,const cv::Rect2d&bbox,double prior,const cv::Mat*own=nullptr){
    if(rgb.type()!=CV_8UC3||rgb.empty()||!std::isfinite(prior)||prior<=0||!std::isfinite(bbox.x)||!std::isfinite(bbox.y)||!std::isfinite(bbox.width)||!std::isfinite(bbox.height)||bbox.width<=0||bbox.height<=0)throw std::invalid_argument("Invalid bounded RGB source");
    if(own&&(own->type()!=CV_8UC1||own->size()!=rgb.size()))throw std::invalid_argument("Ownership geometry mismatch");
}
}} // namespace
