#import <Foundation/Foundation.h>
#include "SourceWeightOrderedGlyph.h"
#include "SourceWeightUnicode.h"
#include <opencv2/imgproc.hpp>
#include <set>
#include <limits>
#include <cmath>
namespace aidoku::source {
namespace {
int orderedRound(double x){double b=std::floor(x),r=x-b;return int(b+(r>.5||(r==.5&&std::fmod(b,2)!=0)));}
bool bodyChar(char32_t c){return [NSCharacterSet.alphanumericCharacterSet longCharacterIsMember:c]&&![NSCharacterSet.nonBaseCharacterSet longCharacterIsMember:c];}
std::u32string normalized(const std::u32string& text){
    NSString* s=[[NSString alloc]initWithBytes:text.data() length:text.size()*4 encoding:NSUTF32LittleEndianStringEncoding];
    if(!s)throw std::invalid_argument("Invalid ordered source text");
    NSData* d=[s.precomposedStringWithCanonicalMapping dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    std::u32string result;const uint32_t* p=(const uint32_t*)d.bytes;
    for(size_t i=0;i<d.length/4;++i)if(![NSCharacterSet.whitespaceAndNewlineCharacterSet longCharacterIsMember:p[i]])result.push_back(p[i]);
    return result;
}
std::vector<double> glyphAdvances(const std::u32string& text){
    static const std::u32string small=U"ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮ";
    std::vector<double> result;
    for(char32_t c:text)result.push_back(small.find(c)!=std::u32string::npos?.65:sourceWeightPairedPunctuation(c)?.5:1.);
    return result;
}
}
std::vector<std::array<int,2>> partitionSourceWeightGlyphs(const cv::Mat& alpha,const cv::Mat& known,const std::vector<double>& expected,bool vertical){
    if(alpha.type()!=CV_32F||known.type()!=CV_8U||alpha.size()!=known.size()||!cv::checkRange(alpha))throw std::invalid_argument("Invalid ordered glyph source");
    if(expected.empty()||std::any_of(expected.begin(),expected.end(),[](double v){return !std::isfinite(v)||v<=0;}))return {};
    int size=vertical?alpha.rows:alpha.cols;std::vector<double> projection(size,0.);
    for(int y=0;y<alpha.rows;++y)for(int x=0;x<alpha.cols;++x)if(alpha.at<float>(y,x)>.5&&known.at<uchar>(y,x))projection[vertical?y:x]++;
    int start=0,stop=size;while(start<stop&&projection[start]==0)start++;while(stop>start&&projection[stop-1]==0)stop--;
    int length=stop-start,count=int(expected.size());if(length<2*count)return {};
    double total=0;for(double v:expected)total+=v;double unit=length/total;
    std::vector<double> cut(length+1,0.);double maximum=std::max(1.,*std::max_element(projection.begin()+start,projection.begin()+stop));
    for(int j=1;j<length;++j)cut[j]=(projection[start+j-1]+projection[start+j])/(2*maximum);
    const double infinity=std::numeric_limits<double>::infinity();
    std::vector<std::vector<double>> costs(count+1,std::vector<double>(length+1,infinity));
    std::vector<std::vector<int>> previous(count+1,std::vector<int>(length+1,-1));costs[0][0]=0;
    for(int i=1;i<=count;++i){double target=unit*expected[i-1];int lower=std::max(2,int(.4*target)),upper=std::max(3,int(1.8*target)+1);
        for(int end=2*i;end<=length;++end){double best=infinity;int origin=-1;
            for(int begin=std::max(0,end-upper);begin<=end-lower;++begin){double d=(end-begin-target)/std::max(1.,target),score=costs[i-1][begin]+.5*d*d+2*cut[end];if(score<best){best=score;origin=begin;}}
            if(std::isfinite(best)){costs[i][end]=best;previous[i][end]=origin;}
        }
    }
    if(!std::isfinite(costs[count][length]))return {};
    std::vector<int> cuts={length};int end=length;
    for(int i=count;i>0;--i){end=previous[i][end];cuts.push_back(end);}std::reverse(cuts.begin(),cuts.end());
    std::vector<std::array<int,2>> result;for(size_t i=1;i<cuts.size();++i)result.push_back({start+cuts[i-1],start+cuts[i]});return result;
}
SourceWeightOrderedObservation measureSourceWeightOrderedGlyphs(const cv::Mat& alpha,const cv::Mat& known,const std::u32string& supplied,bool vertical,const WordReferencePair& family,double unit,bool softProfile){
    if(!std::isfinite(unit)||unit<=0)throw std::invalid_argument("Invalid ordered source unit");
    auto text=normalized(supplied);auto intervals=partitionSourceWeightGlyphs(alpha,known,glyphAdvances(text),vertical);SourceWeightOrderedObservation result;
    if(intervals.size()!=text.size())return result;
    result.completePartition=true;result.orderedGlyphCount=intervals.size();SourceWeightReferenceGrid grid;
    for(size_t i=0;i<text.size();++i){if(!bodyChar(text[i]))continue;auto interval=intervals[i];
        auto r=vertical?cv::Rect(0,interval[0],alpha.cols,interval[1]-interval[0]):cv::Rect(interval[0],0,interval[1]-interval[0],alpha.rows);
        cv::Mat src=alpha(r),valid=known(r),mask;cv::bitwise_and(src>.5,valid!=0,mask);std::vector<cv::Point> points;cv::findNonZero(mask,points);if(points.size()<8)continue;
        auto box=cv::boundingRect(points);int l=box.x,t=box.y,right=box.br().x,bottom=box.br().y,pad=std::max(3,orderedRound(.1*unit));
        int top=std::max(0,t-pad),bot=std::min(src.rows,bottom+pad),left=std::max(0,l-pad),rr=std::min(src.cols,right+pad),height=src.rows,width=src.cols;
        src=src(cv::Rect(left,top,rr-left,bot-top));valid=valid(cv::Rect(left,top,rr-left,bot-top));
        cv::copyMakeBorder(src,src,std::max(0,pad-t),std::max(0,bottom+pad-height),std::max(0,pad-l),std::max(0,right+pad-width),cv::BORDER_CONSTANT|cv::BORDER_ISOLATED,0);
        cv::copyMakeBorder(valid,valid,std::max(0,pad-t),std::max(0,bottom+pad-height),std::max(0,pad-l),std::max(0,right+pad-width),cv::BORDER_CONSTANT|cv::BORDER_ISOLATED,0);
        auto base=grid.masks(family,std::u32string(1,text[i]),vertical);if(!base)continue;
        std::vector<std::vector<cv::Point>> contours;cv::findContours((*base)[0]>.5,contours,cv::RETR_LIST,cv::CHAIN_APPROX_SIMPLE);double information=0;for(const auto& c:contours)information+=cv::arcLength(c,true)/128;
        double scale=double(std::max(box.height,box.width))/std::max((*base)[0].rows,(*base)[0].cols);
        double best=-std::numeric_limits<double>::infinity(),normalScore=0,heavyScore=0;cv::Point location;WordReferenceMasks matched;bool found=false;
        for(double factor:std::set<double>{scale*.95,scale,scale*1.05,unit/128}){if(factor*128/unit<.5||factor*128/unit>1.6)continue;
            for(double cross:{.9,1.,1.1}){int h=std::max(2,orderedRound((*base)[0].rows*factor*(vertical?1:cross))),w=std::max(2,orderedRound((*base)[0].cols*factor*(vertical?cross:1))),padding=std::max(1,orderedRound(128*factor*.06));
                if(h+2*padding>src.rows||w+2*padding>src.cols)continue;
                auto patterns=transformSourceWeightWord(*base,factor,cross,0,vertical);auto a=correlateSourceWeightWord(src,valid,patterns[0]),b=correlateSourceWeightWord(src,valid,patterns[1]);if(a.empty()||b.empty())continue;
                cv::Mat joint=(a+b)/2;double score;cv::Point at;cv::minMaxLoc(joint,nullptr,&score,nullptr,&at);if(!found||score>best){found=true;best=score;normalScore=a.at<float>(at);heavyScore=b.at<float>(at);location=at;matched=patterns;}
            }
        }
        if(!found)continue;cv::Rect roi(location,matched[0].size());auto observed=src(roi),isKnown=valid(roi);
        SourceWeightRegisteredProfileInput profileInput{observed,matched[0],matched[1],isKnown,unit};auto profile=softProfile?measureSourceWeightSoftStrokeProfile(profileInput):measureSourceWeightRegisteredProfile(profileInput);
        cv::Mat support=(matched[0]>.1)|(matched[1]>.1),trusted;cv::bitwise_and(support,isKnown!=0,trusted);double totalSupport=cv::countNonZero(support),knownSupport=totalSupport?cv::countNonZero(trusted)/totalSupport:0;
        result.glyphs.push_back({profile,best,normalScore,heavyScore,heavyScore-normalScore,information,knownSupport,interval});
    }
    result.usable=!result.glyphs.empty();return result;
}
}
