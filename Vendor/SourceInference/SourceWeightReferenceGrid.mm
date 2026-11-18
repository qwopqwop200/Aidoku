#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include "SourceWeightReferenceGrid.h"
#include "../NativeSourceCV/include/AidokuNativeCV.h"
#include <opencv2/imgproc.hpp>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_TRUETYPE_TABLES_H
#include <algorithm>
#include <cmath>
#include <map>
#include <set>
#include <stdexcept>
#include <tuple>
namespace aidoku::source {
namespace {
void gridCheck(bool ok,const char *why) { if(!ok)throw std::invalid_argument(why); }
void acvCheck(int code) { if(code)throw std::runtime_error(acv_last_error()); }
int evenRound(double x) {
    double b=std::floor(x),f=x-b;
    return int(b+(f>.5 || (f==.5 && std::fmod(b,2.)!=0)));
}
using FaceKey=std::tuple<std::string,std::string,std::optional<double>>;
FaceKey faceKey(const WeightBandFont &f) { return {f.path,f.sha256,f.weight}; }
struct Glyph {
    cv::Mat raw;
    int left=0,top=0;
    int64_t advance=0;
};
struct Storage { ACVGlyph value{}; ~Storage(){acv_glyph_free(&value);} };
bool verticalRotate(uint32_t cp) {
    static const std::u32string chars=U"「」『』[]()（）【】〈〉《》ー―—…";
    return chars.find(cp)!=std::u32string::npos;
}
// Pillow BASIC getmask2(start): modf -> float32 -> round(26.6) -> PIXEL.
// Do not round the full accumulated advance or recenter a trimmed mask.
int pillowStart(double x) {
    float frac=float(std::modf(x,&x));
    int phase=int(std::round(frac*64.f));
    return int(x)+((phase+32)>>6);
}
void paste(cv::Mat &dst,const cv::Mat &src,int x,int y,bool lighter=false) {
    for(int r=0;r<src.rows;++r)for(int c=0;c<src.cols;++c) {
        int dy=y+r,dx=x+c;if(dx<0 || dy<0 || dx>=dst.cols || dy>=dst.rows)continue;
        int a=src.at<uint8_t>(r,c);auto &v=dst.at<uint8_t>(dy,dx);
        if(lighter)v=std::max<int>(v,a);
        else { // Pillow L bitmap ink255 coverage compositing, DIV255.
            unsigned t=unsigned(v)*(255-a)+128;
            v=uint8_t(a+((t+(t>>8))>>8));
        }
    }
}
cv::Mat floatMask(const cv::Mat &a) {
    cv::Mat b;a.convertTo(b,CV_32F);
    for(int y=0;y<b.rows;++y)for(int x=0;x<b.cols;++x)b.at<float>(y,x)/=255.f;
    return b;
}
cv::Mat rotateWord(const cv::Mat &src,double angle) {
    int w=src.cols,h=src.rows;
    auto m=cv::getRotationMatrix2D(cv::Point2f(w/2.f,h/2.f),angle,1);
    double c=std::abs(m.at<double>(0,0)),s=std::abs(m.at<double>(0,1));
    int nw=int(std::ceil(w*c+h*s)),nh=int(std::ceil(h*c+w*s));
    m.at<double>(0,2)+=(nw-w)/2.;m.at<double>(1,2)+=(nh-h)/2.;
    cv::Mat out;cv::warpAffine(src,out,m,{nw,nh},cv::INTER_LINEAR,cv::BORDER_CONSTANT,0);return out;
}
}
struct SourceWeightReferenceGrid::Impl {
    struct FontData { std::map<uint32_t,Glyph> glyphs;std::map<uint32_t,bool> coverage;double nominal=0; };
    std::map<std::string,std::string> hashes;
    std::map<FaceKey,FontData> fonts;
    using RenderKey=std::tuple<FaceKey,FaceKey,FaceKey,FaceKey,std::u32string,bool,double,bool>;
    std::map<RenderKey,std::optional<WordReferenceMasks>> renderCache;
    FontData &font(const WeightBandFont &f) {
        auto k=faceKey(f);auto found=fonts.find(k);if(found!=fonts.end())return found->second;
        gridCheck(!f.path.empty() && f.path.find('\0')==std::string::npos,"Explicit reference file required");
        gridCheck(f.sha256.size()==64 && f.sha256.find_first_not_of("0123456789abcdef")==std::string::npos,"Invalid font SHA256");
        gridCheck(!f.weight || std::isfinite(*f.weight),"Invalid reference weight");
        auto digest=hashes.find(f.path);
        if(digest==hashes.end()) {
            NSString *path=[[NSString alloc] initWithBytes:f.path.data() length:f.path.size() encoding:NSUTF8StringEncoding];
            gridCheck(path!=nil,"Invalid font path encoding");
            NSData *bytes=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
            gridCheck(bytes && bytes.length && bytes.length<=UINT32_MAX,"Reference font unavailable");
            unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes.bytes,CC_LONG(bytes.length),hash);
            constexpr char digits[]="0123456789abcdef";std::string text;
            for(auto b:hash){text+=digits[b>>4];text+=digits[b&15];}
            digest=hashes.emplace(f.path,text).first;
        }
        gridCheck(digest->second==f.sha256,"Reference font SHA256 differs");
        Storage probe;
        if(f.weight)acvCheck(acv_reference_glyph_with_weight(f.path.c_str(),0,0,128*64,*f.weight,&probe.value));
        else acvCheck(acv_glyph(f.path.c_str(),0,0,128*64,&probe.value));
        double nominal;
        if(f.weight)nominal=*f.weight;
        else {
            struct Face {
                FT_Library lib=nullptr;FT_Face face=nullptr;
                ~Face(){if(face)FT_Done_Face(face);if(lib)FT_Done_FreeType(lib);}
            } meta;
            gridCheck(!FT_Init_FreeType(&meta.lib) && !FT_New_Face(meta.lib,f.path.c_str(),0,&meta.face),"Font metadata unavailable");
            auto os2=static_cast<TT_OS2 *>(FT_Get_Sfnt_Table(meta.face,ft_sfnt_os2));
            gridCheck(os2!=nullptr,"Reference OS/2 weight unavailable");nominal=os2->usWeightClass;
        }
        FontData data;data.nominal=nominal;return fonts.emplace(k,std::move(data)).first->second;
    }
    bool supported(const WeightBandFont &f,uint32_t cp) {
        auto &data=font(f);auto it=data.coverage.find(cp);if(it!=data.coverage.end())return it->second;
        int supported=0;acvCheck(acv_font_has_glyph(f.path.c_str(),0,cp,&supported));
        data.coverage.emplace(cp,supported!=0);return supported!=0;
    }
    const Glyph &glyph(const WeightBandFont &f,uint32_t cp) {
        auto &data=font(f);auto it=data.glyphs.find(cp);if(it!=data.glyphs.end())return it->second;
        Storage storage;auto &g=storage.value;
        // Pillow13 setvaraxes truncates coordinates before making FT_Fixed.
        if(f.weight)acvCheck(acv_reference_glyph_with_weight(f.path.c_str(),0,cp,128*64,std::trunc(*f.weight),&g));
        else acvCheck(acv_glyph(f.path.c_str(),0,cp,128*64,&g));
        Glyph out;out.left=g.left;out.top=g.top;out.advance=g.advanceX26_6;
        if(g.pixels && g.width && g.height)out.raw=cv::Mat(g.height,g.width,CV_8U,g.pixels,g.pitch).clone();
        return data.glyphs.emplace(cp,std::move(out)).first->second;
    }
    void draw(cv::Mat &image,const WeightBandFont &f,uint32_t cp,double x,double y,bool middle=false) {
        const auto &g=glyph(f,cp);if(g.raw.empty())return;
        // Pillow ms uses PIXEL(position/2), not cropped-glyph centering.
        int anchor=middle?int(((g.advance/2)+32)>>6):0;
        paste(image,g.raw,pillowStart(x)+g.left-anchor,pillowStart(y)-g.top);
    }
    std::optional<WordReferenceMasks> render(const WordReferencePair &pair,const std::u32string &text,
                                            bool vertical,double tracking,bool grid) {
        gridCheck(std::isfinite(tracking) && tracking>0 && tracking<=4 && text.size()<=128,"Invalid bounded word rendering input");
        auto frame=grid && pair.frame?*pair.frame:pair.faces;
        RenderKey key{faceKey(pair.faces.regular),faceKey(pair.faces.heavy),faceKey(frame.regular),faceKey(frame.heavy),text,vertical,tracking,grid};
        auto old=renderCache.find(key);if(old!=renderCache.end())return old->second;
        std::array<WeightBandFont,4> fs={pair.faces.regular,pair.faces.heavy,frame.regular,frame.heavy};
        int count=grid?4:2;
        for(int i=0;i<count;++i)font(fs[i]);
        for(int i=0;i<count;++i) {
            for(auto cp:text) {
                gridCheck(cp<=0x10ffff && !(cp>=0xd800 && cp<=0xdfff),"Invalid word scalar");
                if(!supported(fs[i],cp))return renderCache.emplace(key,std::nullopt).first->second;
            }
        }
        std::vector<double> advances;double length=0;
        for(auto cp:text) {
            double advance=std::max(glyph(fs[grid?2:0],cp).advance,glyph(fs[grid?3:1],cp).advance)/64.*tracking;
            advances.push_back(advance);length+=advance;
        }
        int w=vertical?384:int(std::ceil(length+256));
        int h=vertical?int(std::ceil((text.size()+2)*128*tracking)):384;
        gridCheck(w>0 && h>0 && int64_t(w)*h<=33554432,"Word canvas exceeds bounded budget");
        std::array<cv::Mat,4> images;
        for(int i=0;i<count;++i)images[i]=cv::Mat::zeros(h,w,CV_8U);
        for(int i=0;i<count;++i) {
            if(!vertical) {
                double x=128;
                for(size_t j=0;j<text.size();++j){draw(images[i],fs[i],text[j],x,192);x+=advances[j];}
            } else for(size_t j=0;j<text.size();++j) {
                if(grid) {
                    cv::Mat cell=cv::Mat::zeros(384,384,CV_8U);draw(cell,fs[i],text[j],192,230.4,true);
                    if(verticalRotate(text[j]))cv::rotate(cell,cell,cv::ROTATE_90_CLOCKWISE);
                    paste(images[i],cell,0,evenRound(128*tracking*(j+1)-128),true);
                } else {
                    auto &g=glyph(fs[i],text[j]);if(g.raw.empty())continue;
                    cv::Mat support=g.raw>40;if(!cv::countNonZero(support))continue;
                    cv::Mat ink=g.raw(cv::boundingRect(support)).clone();
                    if(verticalRotate(text[j]))cv::rotate(ink,ink,cv::ROTATE_90_CLOCKWISE);
                    int y=evenRound(128*tracking*(j+1)+(128*tracking-ink.rows)/2);
                    int x=(384-ink.cols)/2;
                    // Python assigns the complete rectangle, including zeros.
                    gridCheck(x>=0 && y>=0 && x+ink.cols<=w && y+ink.rows<=h,"Vertical glyph exceeds cell budget");
                    ink.copyTo(images[i](cv::Rect(x,y,ink.cols,ink.rows)));
                }
            }
        }
        int a=grid?2:0,b=grid?3:1;cv::Mat support=(images[a]>(grid?0:32)) | (images[b]>(grid?0:32));
        if(!cv::countNonZero(support))return renderCache.emplace(key,std::nullopt).first->second;
        cv::Rect bounds=cv::boundingRect(support);
        WordReferenceMasks masks={floatMask(images[0](bounds)),floatMask(images[1](bounds))};
        return renderCache.emplace(key,masks).first->second;
    }
};
SourceWeightReferenceGrid::SourceWeightReferenceGrid():impl(std::make_unique<Impl>()){}
SourceWeightReferenceGrid::~SourceWeightReferenceGrid()=default;
std::optional<WordReferenceMasks> SourceWeightReferenceGrid::wordMasks(const WordReferencePair &p,const std::u32string &t,bool v,double tracking) {
    return impl->render(p,t,v,tracking,false);
}
std::optional<WordReferenceMasks> SourceWeightReferenceGrid::masks(const WordReferencePair &p,const std::u32string &t,bool v,double tracking) {
    return impl->render(p,t,v,tracking,true);
}
double SourceWeightReferenceGrid::nominalWeight(const WeightBandFont &f){return impl->font(f).nominal;}
WordReferenceMasks transformSourceWeightWord(const WordReferenceMasks &base,double scale,double cross,double angle,bool vertical) {
    gridCheck(!base[0].empty() && base[0].type()==CV_32F && base[0].size()==base[1].size() && base[1].type()==CV_32F,"Invalid word masks");
    gridCheck(std::isfinite(scale) && scale>0 && scale<=16 && std::isfinite(cross) && cross>0 && cross<=4 && std::isfinite(angle) && std::abs(angle)<=360,"Invalid word transform");
    int h=std::max(2,evenRound(base[0].rows*scale*(vertical?1:cross)));
    int w=std::max(2,evenRound(base[0].cols*scale*(vertical?cross:1)));
    int pad=std::max(1,evenRound(128*scale*.06));WordReferenceMasks out;
    for(int i=0;i<2;++i) {
        cv::resize(base[i],out[i],{w,h},0,0,cv::INTER_AREA);
        cv::copyMakeBorder(out[i],out[i],pad,pad,pad,pad,cv::BORDER_CONSTANT,0);
        if(angle)out[i]=rotateWord(out[i],angle);
    }
    return out;
}
}
