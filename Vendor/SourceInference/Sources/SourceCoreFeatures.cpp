#include "SourceCoreFeatures.hpp"
#include <set>
namespace aidoku { namespace source {

Vec nativeFeatures(const cv::Mat&rgb,const cv::Rect2d&b,double prior){
    checkSource(rgb,b,prior);cv::Mat target=rgb(targetRect(rgb,b));double scale=std::min(1.,640./std::max(target.rows,target.cols));
    if(scale<1)cv::resize(target,target,cv::Size(),scale,scale,cv::INTER_AREA);
    cv::Mat gray,dark,local,contrast,edge;cv::cvtColor(target,gray,cv::COLOR_RGB2GRAY);
    Vec f={std::log(prior),b.width/prior,b.height/prior,std::min(b.width,b.height)/prior,std::max(b.width,b.height)/prior,std::log(std::max(b.width/b.height,1e-6))};
    cv::threshold(gray,dark,0,255,cv::THRESH_BINARY_INV|cv::THRESH_OTSU);cv::GaussianBlur(gray,local,cv::Size(),std::max(1.,prior*scale*.18));cv::absdiff(gray,local,contrast);cv::threshold(contrast,edge,0,255,cv::THRESH_BINARY|cv::THRESH_OTSU);
    std::vector<cv::Mat> masks={dark,255-dark,edge};double unit=scale*prior;
    for(const auto&mask:masks){Vec lengths,widths;int count=0;for(const auto&s:bodies(mask))if(s.area>=std::max(3.,unit*unit*.004)&&s.area<mask.total()*.75){lengths.push_back(std::max(s.w,s.h)/unit);widths.push_back(std::min(s.w,s.h)/unit);++count;}
        if(count){quantiles(f,lengths,{.2,.5,.8,.95});quantiles(f,widths,{.2,.5,.8});append(f,{count/std::max(1.,b.width*b.height/(prior*prior)),fraction(mask)});}else zeros(f,9);
        for(int axis=0;axis<2;++axis){auto corr=correlation(projection(mask,axis));int low=std::max(2,int(unit*.55)),high=std::min(int(corr.size())-1,int(unit*1.7));
            if(high>low&&corr[0]>1e-8){int lag=low;for(int j=low+1;j<=high;++j)if(corr[j]>corr[lag])lag=j;append(f,{lag/unit,corr[lag]/corr[0]});}else zeros(f,2);}
    }
    for(const auto&mask:masks){std::vector<Body> s;for(const auto&v:bodies(mask))if(v.area>=std::max(3.,unit*unit*.006)&&v.area<mask.total()*.6)s.push_back(v);
        if(!s.empty()){Vec area,extent;double touch=0;for(const auto&v:s){area.push_back(v.area/(unit*unit));extent.push_back(double(v.area)/(v.w*v.h));touch+=v.x==0||v.y==0||v.x+v.w>=mask.cols||v.y+v.h>=mask.rows;}
            quantiles(f,area,{.25,.5,.75});quantiles(f,extent,{.25,.5,.75});f.push_back(touch/s.size());}else zeros(f,7);
        for(int axis=0;axis<2;++axis){Vec gaps;std::vector<cv::Point2d> cc;for(const auto&v:s)if((axis==0?v.h:v.w)>=unit*.22&&std::max(v.w,v.h)<=unit*1.8)cc.emplace_back(v.cx,v.cy);
            for(auto c:cc){double best=INFINITY;for(auto o:cc)if(std::abs((axis==0?o.y:o.x)-(axis==0?c.y:c.x))<=unit*.35){double d=(axis==0?o.x-c.x:o.y-c.y);if(d>=unit*.35&&d<=unit*1.8)best=std::min(best,d);}if(std::isfinite(best))gaps.push_back(best/unit);}
            quantiles(f,gaps,{.25,.5,.75});f.push_back(std::min(1.,gaps.size()/std::max(1.,b.width*b.height/(prior*prior))));}
        cv::Mat depth;cv::distanceTransform(mask,depth,cv::DIST_L2,3);auto nz=values(depth,cv::Mat(),true);f.push_back(quantile(nz,.5)/unit);f.push_back(quantile(nz,.9)/unit);
    }
    for(const auto&core:cores(target)){std::vector<Body>s,inside;for(const auto&v:bodies(core))if(v.area>=std::max(3.,unit*unit*.003)&&v.area<core.total()*.65){s.push_back(v);if(v.x>0&&v.y>0&&v.x+v.w<core.cols&&v.y+v.h<core.rows)inside.push_back(v);}
        if(s.empty()){zeros(f,12);continue;}if(inside.empty())zeros(f,9);else for(int kind=0;kind<3;++kind){Vec v;for(const auto&t:inside)v.push_back(kind==0?std::max(t.w,t.h)/unit:kind==1?std::min(t.w,t.h)/unit:std::sqrt(t.area)/unit);quantiles(f,v,{.25,.5,.75});}
        Vec ratios;double total=0;for(const auto&t:s){ratios.push_back(double(t.w)/t.h);total+=t.area;}append(f,{double(inside.size())/s.size(),total/core.total(),median(ratios)});
    }
    if(f.size()!=156)throw std::logic_error("Native156 layout mismatch");return f;
}

Vec maskedFeatures(const cv::Mat&rgb,const cv::Rect2d&b,double prior,const cv::Mat&ownership){
    checkSource(rgb,b,prior,&ownership);auto r=targetRect(rgb,b);cv::Mat image=rgb(r),own=ownership(r)>0;own/=255;double scale=std::min(1.,640./std::max(image.rows,image.cols)),unit=prior*scale;
    if(scale<1){cv::resize(image,image,cv::Size(),scale,scale,cv::INTER_AREA);cv::resize(own,own,image.size(),0,0,cv::INTER_NEAREST);}
    cv::Mat gray;cv::cvtColor(image,gray,cv::COLOR_RGB2GRAY);Vec f;std::array<Vec,3>ink;Vec chroma,grays;
    for(int y=0;y<image.rows;++y)for(int x=0;x<image.cols;++x)if(own.at<uchar>(y,x)){auto p=image.at<cv::Vec3b>(y,x);for(int c=0;c<3;++c)ink[c].push_back(p[c]);chroma.push_back(std::max({p[0],p[1],p[2]})-std::min({p[0],p[1],p[2]}));grays.push_back(gray.at<uchar>(y,x));}
    for(double q:{.1,.5,.9})for(auto&v:ink)f.push_back(quantile(v,q)/255.);cv::Mat outside=own==0;Vec bg=medianRGB(image,cv::countNonZero(outside)?outside:cv::Mat());for(double v:bg)f.push_back(v/255.);append(f,{fraction(own),mean(chroma)/255.,stddev(grays)/255.});
    std::vector<cv::Mat>masks(5);for(auto&m:masks)m=cv::Mat::zeros(image.size(),CV_8U);
    for(int y=0;y<image.rows;++y)for(int x=0;x<image.cols;++x)if(own.at<uchar>(y,x)){auto p=image.at<cv::Vec3b>(y,x);int lo=std::min({p[0],p[1],p[2]}),hi=std::max({p[0],p[1],p[2]}),c=hi-lo;double distance=0;for(int k=0;k<3;++k)distance+=(p[k]-bg[k])*(p[k]-bg[k]);
        masks[0].at<uchar>(y,x)=hi<100;masks[1].at<uchar>(y,x)=hi<180;masks[2].at<uchar>(y,x)=lo>180&&c<45;masks[3].at<uchar>(y,x)=c>70;masks[4].at<uchar>(y,x)=distance>2500;}
    for(const auto&mask:masks){std::vector<Vec>rows;for(const auto&s:bodies(mask))if(s.area>=std::max(3.,unit*unit*.003)&&s.area<mask.total()*.75)rows.push_back({s.w/unit,s.h/unit,std::sqrt(s.area)/unit,double(s.area)/(s.w*s.h)});
        if(rows.empty())zeros(f,13);else{matrixQuantiles(f,rows,{.25,.5,.75},4);f.push_back(std::min(10.,rows.size()/std::max(1.,mask.total()/(unit*unit))));}
        cv::Mat depth;cv::distanceTransform(mask,depth,cv::DIST_L2,3);auto v=values(depth,cv::Mat(),true);for(double q:{.25,.5,.9})f.push_back(quantile(v,q)/unit);
        std::vector<std::vector<cv::Point>>contours;cv::findContours(mask.clone(),contours,cv::RETR_EXTERNAL,cv::CHAIN_APPROX_SIMPLE);rows.clear();
        for(const auto&c:contours){double a=cv::contourArea(c);if(a<std::max(3.,unit*unit*.003)||a>=mask.total()*.75)continue;auto box=cv::minAreaRect(c);double small=std::min(box.size.width,box.size.height),big=std::max(box.size.width,box.size.height);if(small>1)rows.push_back({small/unit,big/unit,a/(small*big)});}matrixQuantiles(f,rows,{.25,.5,.75},3);
        for(int axis=0;axis<2;++axis){auto corr=correlation(projection(mask,axis));auto ids=peaks(corr,std::max(2,int(.3*unit)),std::min(int(corr.size())-2,int(1.8*unit)),2);for(size_t k=0;k<2;++k)if(k<ids.size())append(f,{ids[k]/unit,corr[ids[k]]/corr[0]});else zeros(f,2);}
    }
    if(f.size()!=180)throw std::logic_error("Masked180 layout mismatch");return f;
}

Vec cadenceFeatures(const cv::Mat&rgb,const cv::Rect2d&b,double prior,const cv::Mat&ownership,double characterCount){
    checkSource(rgb,b,prior,&ownership);auto r=targetRect(rgb,b);cv::Mat image=rgb(r),own=ownership(r)>0;own/=255;bool vertical=b.height>=b.width;
    if(!vertical){cv::transpose(image,image);cv::transpose(own,own);}double scale=std::min(1.,1200./std::max(image.rows,image.cols)),unit=prior*scale;
    if(scale<1){cv::resize(image,image,cv::Size(),scale,scale,cv::INTER_AREA);cv::resize(own,own,image.size(),0,0,cv::INTER_NEAREST);}
    std::vector<cv::Mat>masks(5);for(auto&m:masks)m=cv::Mat::zeros(image.size(),CV_8U);own.copyTo(masks[0]);
    for(int y=0;y<image.rows;++y)for(int x=0;x<image.cols;++x)if(own.at<uchar>(y,x)){auto p=image.at<cv::Vec3b>(y,x);int lo=std::min({p[0],p[1],p[2]}),hi=std::max({p[0],p[1],p[2]}),chroma=hi-lo;
        masks[1].at<uchar>(y,x)=hi<100;masks[2].at<uchar>(y,x)=hi<180;masks[3].at<uchar>(y,x)=chroma>65;masks[4].at<uchar>(y,x)=lo>180&&chroma<45;}
    Vec f={double(vertical),std::log1p(characterCount)};
    for(const auto&mask:masks){auto projectionCross=projection(mask,0);cv::Mat cross(1,int(projectionCross.size()),CV_64F,projectionCross.data()),smooth;cv::GaussianBlur(cross,smooth,cv::Size(),std::max(.5,unit*.04));double crossmax=0;cv::minMaxLoc(smooth,nullptr,&crossmax);cv::Mat active=smooth>std::max(.01,crossmax*.07);active/=255;
        cv::morphologyEx(active,active,cv::MORPH_CLOSE,cv::Mat::ones(1,std::max(1,int(unit*.08)),CV_8U));std::vector<std::pair<int,int>>columns;int begin=-1;
        for(int x=0;x<=active.cols;++x){bool on=x<active.cols&&active.at<uchar>(0,x);if(on&&begin<0)begin=x;if(!on&&begin>=0){if(x-begin>=unit*.18)columns.emplace_back(begin,x);begin=-1;}}
        Vec widths,spans,periods,strengths,allpeaks,peakstrength,density;
        for(auto column:columns){cv::Mat core=mask.colRange(column.first,column.second);auto longitudinal=projection(core,1);std::vector<int>occupied;for(size_t j=0;j<longitudinal.size();++j)if(longitudinal[j]>.02)occupied.push_back(int(j));if(occupied.size()<2)continue;
            widths.push_back((column.second-column.first)/unit);spans.push_back((occupied.back()-occupied.front()+1)/unit);density.push_back(fraction(core));auto corr=correlation(longitudinal);if(corr[0]<1e-8)continue;double zero=corr[0];for(double&v:corr)v/=zero;
            int low=std::max(2,int(unit*.55)),high=std::min(int(corr.size())-2,int(unit*1.7));std::vector<std::pair<double,int>>candidates;
            for(int j=low;j<=high;++j)if(corr[j]>0&&corr[j]>=corr[j-1]&&corr[j]>corr[j+1]){double score=corr[j],denom=1.;for(auto pair:std::vector<std::pair<int,double>>{{2,.5},{3,.25}})if(j*pair.first<int(corr.size())){score+=pair.second*corr[j*pair.first];denom+=pair.second;}candidates.emplace_back(score/denom,j);}
            std::sort(candidates.begin(),candidates.end(),std::greater<std::pair<double,int>>());for(size_t j=0;j<std::min(size_t(3),candidates.size());++j){allpeaks.push_back(candidates[j].second/unit);peakstrength.push_back(candidates[j].first);}
            for(auto candidate:candidates)if(candidate.second/unit>=.7&&candidate.second/unit<=1.35){periods.push_back(candidate.second/unit);strengths.push_back(candidate.first);break;}
        }
        double denom=std::max(1.,characterCount);append(f,{double(columns.size()),std::accumulate(spans.begin(),spans.end(),0.)/denom,(std::accumulate(spans.begin(),spans.end(),0.)+.1*spans.size())/denom});
        for(const auto*v:{&widths,&spans,&periods,&strengths,&allpeaks,&peakstrength,&density})quantiles(f,*v,{.1,.5,.9});
    }
    if(f.size()!=122)throw std::logic_error("Cadence122 layout mismatch");return f;
}

static ComponentDescriptor describeComponent(const cv::Mat&patch,double prior,const Vec&color,const cv::Rect&bounds){
    double scale=32./std::max(patch.rows,patch.cols);cv::Mat fp,small,canvas=cv::Mat::zeros(32,32,CV_32F);patch.convertTo(fp,CV_32F);
    cv::resize(fp,small,cv::Size(std::max(1,int(std::nearbyint(patch.cols*scale))),std::max(1,int(std::nearbyint(patch.rows*scale)))),0,0,cv::INTER_AREA);
    small.copyTo(canvas(cv::Rect((32-small.cols)/2,(32-small.rows)/2,small.cols,small.rows)));cv::Mat dct,gx,gy,magnitude,angle;cv::dct(canvas,dct);cv::Sobel(canvas,gx,CV_32F,1,0);cv::Sobel(canvas,gy,CV_32F,0,1);cv::cartToPolar(gx,gy,magnitude,angle);
    float dctSum=0.;for(int y=0;y<8;++y)for(int x=0;x<8;++x){float v=dct.at<float>(y,x);dctSum+=v*v;}float dctNorm=std::max(1e-8f,std::sqrt(dctSum));Vec v;
    for(int y=0;y<8;++y)for(int x=0;x<8;++x)v.push_back(.6*double(dct.at<float>(y,x)/dctNorm));Vec hog;
    for(int top=0;top<32;top+=8)for(int left=0;left<32;left+=8){Vec bins(8,0.);for(int y=top;y<top+8;++y)for(int x=left;x<left+8;++x){int bin=int((angle.at<float>(y,x)*8.f)/float(2*M_PI))%8;bins[bin]+=magnitude.at<float>(y,x);}for(double val:bins)hog.push_back(std::sqrt(val));}
    double sum=0;for(double val:hog)sum+=val*val;double norm=std::max(1e-8,std::sqrt(sum));for(double val:hog)v.push_back(.8*val/norm);
    double size=std::sqrt(double(patch.cols)*patch.rows);append(v,{.15*std::clamp(std::log(double(patch.cols)/patch.rows),-2.,2.),.25*std::clamp(std::log(size/prior),-2.,2.)});for(double c:color)v.push_back(c/255.*.1);v.push_back(.2*fraction(patch));sum=0;for(double val:v)sum+=val*val;norm=std::max(1e-8,std::sqrt(sum));for(double&val:v)val=double(float(val/norm));
    std::vector<unsigned char>packed(8+(patch.total()+7)/8,0);int32_t dims[2]={patch.cols,patch.rows};for(int d=0;d<2;++d)for(int j=0;j<4;++j)packed[d*4+j]=(unsigned(dims[d])>>(8*j))&255;
    for(int y=0;y<patch.rows;++y)for(int x=0;x<patch.cols;++x)if(patch.at<uchar>(y,x)){size_t index=y*patch.cols+x;packed[8+index/8]|=1<<(7-index%8);}
    if(v.size()!=198)throw std::logic_error("Component198 layout mismatch");return {v,size,bounds,packed};
}

std::vector<ComponentDescriptor> extractComponents(const cv::Mat&rgb,const cv::Rect2d&b,double prior,const cv::Mat&ownership){
    checkSource(rgb,b,prior,&ownership);auto roi=targetRect(rgb,b);cv::Mat image=rgb(roi),own=ownership(roi)>0;std::vector<cv::Mat>masks(3);for(auto&m:masks)m=cv::Mat::zeros(image.size(),CV_8U);
    for(int y=0;y<image.rows;++y)for(int x=0;x<image.cols;++x)if(own.at<uchar>(y,x)){auto p=image.at<cv::Vec3b>(y,x);int lo=std::min({p[0],p[1],p[2]}),hi=std::max({p[0],p[1],p[2]}),c=hi-lo;masks[0].at<uchar>(y,x)=hi<120;masks[1].at<uchar>(y,x)=c>65;masks[2].at<uchar>(y,x)=lo>190&&c<45;}
    std::vector<ComponentDescriptor>out;std::set<std::vector<unsigned char>>seen;
    for(const auto&core:masks){cv::Mat labels;auto stats=bodies(core,&labels);for(size_t i=0;i<stats.size();++i){const auto&s=stats[i];if(std::min(s.w,s.h)<std::max(7.,.3*prior)||std::max(s.w,s.h)>1.4*prior||s.area<25||double(s.area)/(s.w*s.h)>.88)continue;
            cv::Rect r(s.x,s.y,s.w,s.h);cv::Mat patch=labels(r)==int(i+1);patch/=255;std::vector<std::vector<cv::Point>>contours;cv::findContours(patch.clone(),contours,cv::RETR_LIST,cv::CHAIN_APPROX_SIMPLE);size_t points=0;for(const auto&c:contours)points+=c.size();if(contours.empty()||points<14)continue;
            auto result=describeComponent(patch,prior,medianRGB(image(r),patch),cv::Rect(roi.x+s.x,roi.y+s.y,s.w,s.h));if(!seen.insert(result.packedShape).second)continue;out.push_back(std::move(result));}}
    return out;
}

Vec colorBodies(const cv::Mat&rgb,const cv::Rect2d&b,double prior,const cv::Mat&ownership){
    checkSource(rgb,b,prior,&ownership);auto roi=targetRect(rgb,b);cv::Mat image=rgb(roi),own=ownership(roi)>0;own/=255;if(cv::countNonZero(own)<8)return Vec(128,0.);
    double scale=std::min(1.,1200./std::max(image.rows,image.cols)),unit=prior*scale;if(scale<1){cv::resize(image,image,cv::Size(),scale,scale,cv::INTER_AREA);cv::resize(own,own,image.size(),0,0,cv::INTER_NEAREST);}cv::Mat lab8,lab;cv::cvtColor(image,lab8,cv::COLOR_RGB2Lab);lab8.convertTo(lab,CV_32F);
    std::vector<cv::Vec3f>pixels;for(int y=0;y<lab.rows;++y)for(int x=0;x<lab.cols;++x)if(own.at<uchar>(y,x))pixels.push_back(lab.at<cv::Vec3f>(y,x));int sampleCount=std::min(4096,int(pixels.size()));cv::Mat sample(sampleCount,3,CV_32F);std::set<std::array<int,3>>unique;
    for(int i=0;i<sampleCount;++i){size_t index=sampleCount<=1?0:size_t(double(i)*(pixels.size()-1)/(sampleCount-1));auto p=pixels[index];std::array<int,3>key;for(int c=0;c<3;++c){sample.at<float>(i,c)=p[c];key[c]=int(std::nearbyint(p[c]/8.f));}unique.insert(key);}
    int k=std::min(4,int(unique.size()));cv::Mat labels,centers;cv::setRNGSeed(100);cv::kmeans(sample,k,labels,cv::TermCriteria(cv::TermCriteria::EPS|cv::TermCriteria::MAX_ITER,50,.1),3,cv::KMEANS_PP_CENTERS,centers);
    std::vector<int>order(k);std::iota(order.begin(),order.end(),0);std::stable_sort(order.begin(),order.end(),[&](int a,int c){return centers.at<float>(a,0)<centers.at<float>(c,0);});std::vector<cv::Mat>bins(k);for(auto&m:bins)m=cv::Mat::zeros(own.size(),CV_8U);
    size_t pi=0;for(int y=0;y<own.rows;++y)for(int x=0;x<own.cols;++x)if(own.at<uchar>(y,x)){auto p=pixels[pi++];double best=INFINITY;int chosen=0;for(int j=0;j<k;++j){auto c=centers.ptr<float>(order[j]);float d0=p[0]-c[0],d1=p[1]-c[1],d2=p[2]-c[2];float d=d0*d0+d1*d1+d2*d2;if(d<best){best=d;chosen=j;}}bins[chosen].at<uchar>(y,x)=1;}
    Vec f;double owned=std::max(1,cv::countNonZero(own));
    for(int j=0;j<4;++j){if(j>=k){zeros(f,32);continue;}auto&mask=bins[j];Vec z;for(int c=0;c<3;++c)z.push_back(centers.at<float>(order[j],c)/255.);z.push_back(cv::countNonZero(mask)/owned);std::vector<Vec>rows;Vec extents;
        for(const auto&s:bodies(mask))if(s.area>=std::max(3.,.002*unit*unit)&&s.area<mask.total()*.6&&std::max(s.w,s.h)<2.5*unit){rows.push_back({s.w/unit,s.h/unit,std::sqrt(s.area)/unit});extents.push_back(double(s.area)/(s.w*s.h));}
        if(rows.empty())zeros(z,16);else{matrixQuantiles(z,rows,{.25,.5,.75,.95},3);quantiles(z,extents,{.25,.5,.75});z.push_back(std::log1p(rows.size()));}
        cv::Mat depth;cv::distanceTransform(mask,depth,cv::DIST_L2,3);auto d=values(depth,cv::Mat(),true);for(double q:{.25,.5,.9})z.push_back(quantile(d,q)/unit);
        std::vector<std::vector<cv::Point>>contours;cv::findContours(mask.clone(),contours,cv::RETR_EXTERNAL,cv::CHAIN_APPROX_SIMPLE);rows.clear();for(const auto&c:contours){double area=cv::contourArea(c);if(area<std::max(3.,.002*unit*unit)||area>=mask.total()*.6)continue;auto box=cv::minAreaRect(c);double a=std::min(box.size.width,box.size.height),bb=std::max(box.size.width,box.size.height);if(a>1&&bb<2.5*unit)rows.push_back({a/unit,bb/unit,area/(a*bb)});}matrixQuantiles(z,rows,{.25,.5,.75},3);if(z.size()!=32)throw std::logic_error("Color32 layout mismatch");append(f,z);
    }
    if(f.size()!=128)throw std::logic_error("Colors128 layout mismatch");return f;
}

}} // namespace
