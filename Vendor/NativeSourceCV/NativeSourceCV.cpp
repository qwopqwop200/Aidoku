#include "include/AidokuNativeCV.h"
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/objdetect.hpp>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_GLYPH_H
#include FT_MULTIPLE_MASTERS_H
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>
#include <limits>
#include <cmath>
#include <algorithm>

namespace {
thread_local std::string error;
void require(bool b,const char *s) { if(!b) throw std::invalid_argument(s); }
int type(int channels,int fp) { require(channels>=1&&channels<=4,"invalid channels");return CV_MAKETYPE(fp?CV_32F:CV_8U,channels); }
cv::Mat input(const void *p,int w,int h,int t) {
    require(p&&w>0&&h>0&&static_cast<int64_t>(w)*h<=INT32_MAX,"invalid image");
    return cv::Mat(h,w,t,const_cast<void*>(p));
}
void output(const cv::Mat &m,void *p) { require(p,"null output"); if(m.isContinuous())std::memcpy(p,m.data,m.total()*m.elemSize());else for(int y=0;y<m.rows;++y)std::memcpy(static_cast<uint8_t*>(p)+y*m.cols*m.elemSize(),m.ptr(y),m.cols*m.elemSize()); }
// NumPy's contiguous float32 add.reduce uses an eight-lane pairwise tree.
float pairwiseSum(const float *p,int n) {
    if(n<8){float s=-0.0f;for(int i=0;i<n;++i)s+=p[i];return s;}
    if(n<=128){
        float s[8];for(int j=0;j<8;++j)s[j]=p[j];int i=8;
        for(;i+7<n;i+=8)for(int j=0;j<8;++j)s[j]+=p[i+j];
        float total=((s[0]+s[1])+(s[2]+s[3]))+((s[4]+s[5])+(s[6]+s[7]));
        for(;i<n;++i)total+=p[i];return total;
    }
    int half=(n/2)&~7;return pairwiseSum(p,half)+pairwiseSum(p+half,n-half);
}
void normalizedRow(const float *row,float *dst,int dim,std::vector<float> &squares) {
    for(int j=0;j<dim;++j){require(std::isfinite(row[j]),"nonfinite cosine input");squares[j]=row[j]*row[j];}
    float norm=std::max(std::sqrt(pairwiseSum(squares.data(),dim)),1e-30f);
    for(int j=0;j<dim;++j)dst[j]=row[j]/norm;
}

struct Font {
    FT_Library library=nullptr; FT_Face face=nullptr;
    ~Font(){if(face)FT_Done_Face(face);if(library)FT_Done_FreeType(library);}
    Font(const char *path,int index){ require(path,"null font path");require(!FT_Init_FreeType(&library),"FreeType init failed");if(FT_New_Face(library,path,index,&face)){FT_Done_FreeType(library);library=nullptr;throw std::invalid_argument("font path/face inaccessible");} }
};
// Shared raster arithmetic: the legacy entry never sets variation coordinates.
void renderGlyph(Font &f,uint32_t cp,int size,ACVGlyph *out) {
    require(!FT_Set_Char_Size(f.face,0,size,72,72),"font size failed");require(!FT_Load_Char(f.face,cp,FT_LOAD_DEFAULT|FT_LOAD_TARGET_NORMAL),"glyph load failed");
    FT_Glyph glyph=nullptr;require(!FT_Get_Glyph(f.face->glyph,&glyph),"glyph outline failed");FT_BBox box;FT_Glyph_Get_CBox(glyph,FT_GLYPH_BBOX_PIXELS,&box);FT_Done_Glyph(glyph);
    auto slot=f.face->glyph;int left=std::min<FT_Pos>(0,box.xMin),right=std::max<FT_Pos>((slot->advance.x+32)>>6,box.xMax);
    int top=std::max<FT_Pos>(0,box.yMax),bottom=std::min<FT_Pos>(0,box.yMin);
    require(!FT_Render_Glyph(slot,FT_RENDER_MODE_NORMAL),"glyph render failed");auto &b=slot->bitmap;
    int width=right-left,height=top-bottom;require(width>=0&&height>=0&&static_cast<int64_t>(width)*height<=16777216,"glyph bitmap too large");
    uint8_t *pixels=nullptr;if(width&&height){pixels=static_cast<uint8_t*>(std::calloc(static_cast<size_t>(width)*height,1));require(pixels,"glyph allocation failed");
        for(unsigned y=0;y<b.rows;++y){const uint8_t *row=b.buffer+(b.pitch>=0?y*b.pitch:(b.rows-1-y)*(-b.pitch));int dy=top-slot->bitmap_top+y;
            for(unsigned x=0;x<b.width;++x){int dx=slot->bitmap_left-left+x;if(dx>=0&&dx<width&&dy>=0&&dy<height)pixels[dy*width+dx]=b.pixel_mode==FT_PIXEL_MODE_MONO?((row[x>>3]&(0x80>>(x&7)))?255:0):row[x];}}
    }
    out->pixels=pixels;out->width=width;out->height=height;out->pitch=width;out->left=left;out->top=top;out->advanceX26_6=slot->advance.x;out->advanceY26_6=slot->advance.y;
}
void setWeight(Font &f,double weight) {
    require(std::isfinite(weight),"nonfinite font wght");
    struct Variation {
        FT_Library library;
        FT_MM_Var *axes=nullptr;
        ~Variation(){if(axes)FT_Done_MM_Var(library,axes);}
    } variation{f.library};
    require(!FT_Get_MM_Var(f.face,&variation.axes)&&variation.axes,"font has no variation axes");
    auto axes=variation.axes;
    FT_UInt axis=axes->num_axis;
    for(FT_UInt i=0;i<axes->num_axis;++i)
        if(axes->axis[i].tag==FT_MAKE_TAG('w','g','h','t')){axis=i;break;}
    require(axis<axes->num_axis,"font has no wght axis");
    require(weight>=axes->axis[axis].minimum/65536.&&weight<=axes->axis[axis].maximum/65536.,
            "font wght outside axis range");
    // Keep every other coordinate, including a selected named instance, intact.
    std::vector<FT_Fixed> coordinates(axes->num_axis);
    require(!FT_Get_Var_Design_Coordinates(f.face,axes->num_axis,coordinates.data()),
            "font variation coordinates unavailable");
    coordinates[axis]=static_cast<FT_Fixed>(std::llround(weight*65536.));
    require(!FT_Set_Var_Design_Coordinates(f.face,axes->num_axis,coordinates.data()),
            "font wght selection failed");
}

}
#define START try { error.clear();
#define END return 0; } catch(const std::exception &e){error=e.what();return -1;} catch(...){error="unknown native failure";return -1;}
extern "C" {
const char *acv_last_error(){return error.c_str();}
const char *acv_opencv_version(){return CV_VERSION;}
const char *acv_freetype_version(){return "2.14.3";}
int acv_cosine_neighbors(const float *queries,int qCount,const float *references,int rCount,int dim,
                         const int32_t *excluded,int excludedCount,int neighbors,int32_t *outIndices,float *outDistances){START
    require(qCount>=0&&rCount>=8&&dim>0&&dim<=262144&&neighbors==8,"invalid cosine dimensions/neighbors");
    require(excludedCount>=0&&(excludedCount==0||excluded),"invalid cosine exclusions");
    require(static_cast<uint64_t>(qCount)*dim<=SIZE_MAX/sizeof(float)&&static_cast<uint64_t>(rCount)*dim<=SIZE_MAX/sizeof(float)
        &&static_cast<uint64_t>(qCount)*8<=SIZE_MAX/sizeof(float),"cosine dimensions overflow");
    // Store only supplied indices, never a bank-sized exclusion bitmap.
    std::vector<int32_t> omit;if(excludedCount)omit.assign(excluded,excluded+excludedCount);
    for(auto index:omit)require(index>=0&&index<rCount,"cosine exclusion index out of range");
    std::sort(omit.begin(),omit.end());omit.erase(std::unique(omit.begin(),omit.end()),omit.end());
    require(static_cast<size_t>(rCount)-omit.size()>=8,"insufficient independent TRAIN prototypes");
    if(qCount==0)return 0;
    require(queries&&references&&outIndices&&outDistances,"null cosine input/output");
    constexpr int scratchElements=262144;
    const int qBatch=std::min(128,std::max(1,scratchElements/dim));
    const int rBatch=std::min(1024,std::max(1,scratchElements/dim));
    std::vector<float> squares(dim);
    for(int qs=0;qs<qCount;){
        int nq=std::min(qBatch,qCount-qs);cv::Mat q(nq,dim,CV_32F);
        for(int i=0;i<nq;++i)normalizedRow(queries+static_cast<size_t>(qs+i)*dim,q.ptr<float>(i),dim,squares);
        for(int i=0;i<nq;++i)for(int k=0;k<8;++k){outIndices[static_cast<size_t>(qs+i)*8+k]=-1;outDistances[static_cast<size_t>(qs+i)*8+k]=std::numeric_limits<float>::infinity();}
        for(int rs=0;rs<rCount;){
            int nr=std::min(rBatch,rCount-rs);cv::Mat ref(nr,dim,CV_32F),cosine;
            for(int j=0;j<nr;++j)normalizedRow(references+static_cast<size_t>(rs+j)*dim,ref.ptr<float>(j),dim,squares);
            cv::gemm(q,ref,1,cv::noArray(),0,cosine,cv::GEMM_2_T);
            auto excludedPosition=std::lower_bound(omit.begin(),omit.end(),rs);
            for(int j=0;j<nr;++j){
                int index=rs+j;
                if(excludedPosition!=omit.end()&&*excludedPosition==index){++excludedPosition;continue;}
                for(int i=0;i<nq;++i){
                    float distance=std::max(0.f,std::min(2.f,1.f-cosine.at<float>(i,j)));
                    require(std::isfinite(distance),"nonfinite cosine distance");
                    size_t start=static_cast<size_t>(qs+i)*8;int at=7;
                    if(distance>outDistances[start+7]||(distance==outDistances[start+7]&&index>outIndices[start+7]))continue;
                    while(at>0&&(distance<outDistances[start+at-1]||(distance==outDistances[start+at-1]&&index<outIndices[start+at-1]))){
                        outDistances[start+at]=outDistances[start+at-1];outIndices[start+at]=outIndices[start+at-1];--at;
                    }
                    outDistances[start+at]=distance;outIndices[start+at]=index;
                }
            }
            rs+=nr;
        }
        qs+=nq;
    }
    END}
int acv_components(const uint8_t *p,int w,int h,int connectivity,int32_t *labels,int32_t *stats,double *centroids,size_t capacity,int *count){START
    require(count&&labels&&stats&&centroids,"null components output");require(connectivity==4||connectivity==8,"invalid connectivity");
    cv::Mat lab,st,c;int n=cv::connectedComponentsWithStats(input(p,w,h,CV_8U),lab,st,c,connectivity,CV_32S);
    *count=n;require(capacity>=static_cast<size_t>(n),"component capacity too small");output(lab,labels);output(st,stats);output(c,centroids); END}
int acv_component_areas8(const uint8_t *p, int w, int h, int32_t *areas, size_t capacity, int *count) { START
    require(areas && count, "null component areas output");
    const cv::Mat mask = input(p, w, h, CV_8U);
    auto bounds = cv::boundingRect(mask);
    if (bounds.empty()) { *count = 0; return 0; }
    // Keep OpenCV's 2×2 labeling blocks aligned with the original grid.
    bounds.width += bounds.x & 1;
    bounds.height += bounds.y & 1;
    bounds.x &= ~1;
    bounds.y &= ~1;
    cv::Mat labels;
    const int foreground = cv::connectedComponents(mask(bounds), labels, 8, CV_32S) - 1;
    require(static_cast<size_t>(foreground) <= capacity, "component area capacity too small");
    std::fill_n(areas, foreground, 0);
    for (int y = 0; y < labels.rows; ++y) {
        const auto *row = labels.ptr<int32_t>(y);
        for (int x = 0; x < labels.cols; ++x) {
            const int label = row[x];
            if (label != 0) ++areas[label - 1];
        }
    }
    *count = foreground;
    END
}
int acv_morphology(const void *p,void *dst,int w,int h,int fp,int op,int shape,int kw,int kh,int border){START
    require(kw>0&&kh>0&&kw<=65535&&kh<=65535,"invalid kernel");cv::Mat out;
    cv::morphologyEx(input(p,w,h,type(1,fp)),out,op,cv::getStructuringElement(shape,{kw,kh}),{-1,-1},1,border);output(out,dst); END}
int acv_box_mean(const float *p,float *dst,int w,int h,int size){START
    require(size>0&&size<=65535,"invalid box size");cv::Mat out;cv::boxFilter(input(p,w,h,CV_32F),out,-1,{size,size},{-1,-1},true,cv::BORDER_REPLICATE);output(out,dst); END}
int acv_distance(const uint8_t *p,float *dst,int32_t *labels,int w,int h,int metric,int maskSize){START
    cv::Mat out,lab;if(labels){require(metric==cv::DIST_L2&&maskSize==5,"labels require L2 mask5");cv::distanceTransform(input(p,w,h,CV_8U),out,lab,metric,maskSize,cv::DIST_LABEL_PIXEL);output(lab,labels);}else cv::distanceTransform(input(p,w,h,CV_8U),out,metric,maskSize,CV_32F);output(out,dst); END}
int acv_gray(const uint8_t *p,uint8_t *dst,int w,int h){START cv::Mat out;cv::cvtColor(input(p,w,h,CV_8UC3),out,cv::COLOR_RGB2GRAY);output(out,dst); END}
int acv_fill_holes4(const uint8_t *p,uint8_t *dst,int w,int h){START
    auto src=input(p,w,h,CV_8U);cv::Mat padded;cv::copyMakeBorder(src,padded,1,1,1,1,cv::BORDER_CONSTANT,cv::Scalar(0));
    cv::Mat binary;padded.convertTo(binary,CV_8U);cv::compare(binary,0,binary,cv::CMP_NE);cv::floodFill(binary,{0,0},cv::Scalar(127),nullptr,cv::Scalar(),cv::Scalar(),4);
    cv::Mat out;cv::compare(binary(cv::Rect(1,1,w,h)),127,out,cv::CMP_NE);output(out,dst); END}
int acv_fill_external(const uint8_t *p,uint8_t *dst,int w,int h){START
    auto src=input(p,w,h,CV_8U).clone();std::vector<std::vector<cv::Point>> contours;cv::findContours(src,contours,cv::RETR_EXTERNAL,cv::CHAIN_APPROX_SIMPLE);cv::Mat out=cv::Mat::zeros(h,w,CV_8U);cv::drawContours(out,contours,-1,cv::Scalar(255),cv::FILLED);output(out,dst); END}
int acv_dct(const float *p,float *dst,int w,int h,int flags){START cv::Mat out;cv::dct(input(p,w,h,CV_32F),out,flags);output(out,dst); END}
int acv_hog(const uint8_t *p,int w,int h,int channels,int block,int stride,int cell,int bins,float *dst,size_t capacity,size_t *count){START
    require(count&&block>0&&stride>0&&cell>0&&bins>0,"invalid HOG parameters");require(channels==1||channels==3,"HOG needs gray or RGB");
    cv::HOGDescriptor hog({w,h},{block,block},{stride,stride},{cell,cell},bins,1,-1,cv::HOGDescriptor::L2Hys,0.2,false);
    std::vector<float> v;hog.compute(input(p,w,h,type(channels,0)),v);*count=v.size();require(dst&&capacity>=v.size(),"HOG capacity too small");std::memcpy(dst,v.data(),v.size()*sizeof(float)); END}
int acv_match_template(const uint8_t *p,int w,int h,const uint8_t *q,int pw,int ph,int channels,int method,float *dst,size_t capacity){START
    require(pw<=w&&ph<=h&&pw>0&&ph>0,"invalid template dimensions");require(capacity>=static_cast<size_t>(w-pw+1)*(h-ph+1),"template capacity too small");
    cv::Mat out;cv::matchTemplate(input(p,w,h,type(channels,0)),input(q,pw,ph,type(channels,0)),out,method);output(out,dst); END}
int acv_rgb_box_mean(const uint8_t *p,float *dst,int w,int h,int size){START
    require(size>0&&size<=65535,"invalid box size");cv::Mat rgb,out;input(p,w,h,CV_8UC3).convertTo(rgb,CV_32FC3,1./255);cv::boxFilter(rgb,out,-1,{size,size},{-1,-1},true,cv::BORDER_REFLECT);output(out,dst); END}
int acv_rgb_sobel_magnitude(const uint8_t *p,float *dst,int w,int h){START
    cv::Mat rgb,gray,x,y,out;input(p,w,h,CV_8UC3).convertTo(rgb,CV_32FC3,1./255);cv::cvtColor(rgb,gray,cv::COLOR_RGB2GRAY);cv::Sobel(gray,x,CV_32F,1,0,3);cv::Sobel(gray,y,CV_32F,0,1,3);cv::magnitude(x,y,out);output(out,dst); END}
int acv_rgb_to_lab(const void *p,void *dst,int w,int h,int fp){START cv::Mat out;cv::cvtColor(input(p,w,h,type(3,fp)),out,cv::COLOR_RGB2Lab);output(out,dst); END}
int acv_resize(const void *p,int w,int h,void *dst,int dw,int dh,int channels,int fp,int interpolation){START
    require(dw>0&&dh>0,"invalid resize destination");cv::Mat out;cv::resize(input(p,w,h,type(channels,fp)),out,{dw,dh},0,0,interpolation);output(out,dst); END}
int acv_warp_affine(const void *p,int w,int h,void *dst,int dw,int dh,int channels,int fp,const double *matrix,int flags,int border,double value){START
    require(matrix&&dw>0&&dh>0,"invalid affine destination/matrix");for(int i=0;i<6;++i)require(std::isfinite(matrix[i]),"nonfinite affine matrix");
    cv::Mat out;cv::warpAffine(input(p,w,h,type(channels,fp)),out,cv::Mat(2,3,CV_64F,const_cast<double*>(matrix)),{dw,dh},flags,border,cv::Scalar::all(value));output(out,dst); END}
int acv_min_area_rect(const float *xy,int count,float *out){START
    require(xy&&out&&count>0,"invalid points");std::vector<cv::Point2f> points;for(int i=0;i<count;++i){require(std::isfinite(xy[2*i])&&std::isfinite(xy[2*i+1]),"nonfinite point");points.emplace_back(xy[2*i],xy[2*i+1]);}
    auto r=cv::minAreaRect(points);out[0]=r.center.x;out[1]=r.center.y;out[2]=r.size.width;out[3]=r.size.height;out[4]=r.angle; END}
int acv_fill_poly(const float *xy,const int32_t *counts,int polygons,uint8_t *dst,int w,int h,uint8_t value){START
    require(xy&&counts&&polygons>0&&dst&&w>0&&h>0,"invalid polygons");std::vector<std::vector<cv::Point>> contours;int offset=0;
    for(int i=0;i<polygons;++i){require(counts[i]>0&&counts[i]<=1000000,"invalid polygon point count");std::vector<cv::Point> points;for(int j=0;j<counts[i];++j){float x=xy[2*(offset+j)],y=xy[2*(offset+j)+1];require(std::isfinite(x)&&std::isfinite(y)&&std::abs(x)<1e8&&std::abs(y)<1e8,"invalid polygon point");points.emplace_back(static_cast<int>(std::nearbyint(x)),static_cast<int>(std::nearbyint(y)));}offset+=counts[i];contours.push_back(std::move(points));}
    cv::Mat out=cv::Mat::zeros(h,w,CV_8U);cv::fillPoly(out,contours,cv::Scalar(value),cv::LINE_8);output(out,dst); END}
int acv_blur(const void *p,void *dst,int w,int h,int channels,int fp,int size,double sigma,int median,int border){START
    require(size>0&&(size%2)==1,"blur size must be positive odd");cv::Mat out;if(median)cv::medianBlur(input(p,w,h,type(channels,fp)),out,size);else cv::GaussianBlur(input(p,w,h,type(channels,fp)),out,{size,size},sigma,sigma,border);output(out,dst); END}
int acv_remap(const void *p,void *dst,int w,int h,int dw,int dh,int channels,int fp,const float *mx,const float *my,int interpolation,int border,double value){START
    cv::Mat out;cv::remap(input(p,w,h,type(channels,fp)),out,input(mx,dw,dh,CV_32F),input(my,dw,dh,CV_32F),interpolation,border,cv::Scalar::all(value));output(out,dst); END}
int acv_font_has_glyph(const char *path,int index,uint32_t cp,int *supported){START
    require(supported&&index>=0&&cp<=0x10ffff,"invalid glyph coverage query");Font f(path,index);*supported=FT_Get_Char_Index(f.face,cp)!=0; END}
int acv_font_face_index(const char *path,const char *name,int *index){START
    require(name&&index,"invalid face lookup");Font f(path,0);long n=f.face->num_faces;
    for(int i=0;i<n;++i){if(i){FT_Done_Face(f.face);f.face=nullptr;require(!FT_New_Face(f.library,path,i,&f.face),"font face lookup failed");}const char *ps=FT_Get_Postscript_Name(f.face);if(ps&&std::strcmp(ps,name)==0){*index=i;return 0;}}
    throw std::invalid_argument("PostScript face missing in font file"); END}
int acv_glyph(const char *path,int faceIndex,uint32_t cp,int size,ACVGlyph *out){START
    require(out,"null glyph output");*out={};require(size>0&&size<=4096*64&&faceIndex>=0&&cp<=0x10ffff,"invalid glyph size/face/codepoint");Font f(path,faceIndex);
    renderGlyph(f,cp,size,out); END}
int acv_glyph_with_weight(const char *path,int faceIndex,uint32_t cp,int size,double weight,ACVGlyph *out){START
    require(out,"null glyph output");*out={};
    require(size>0&&size<=4096*64&&faceIndex>=0&&cp<=0x10ffff,"invalid glyph size/face/codepoint");
    Font f(path,faceIndex);setWeight(f,weight);
    require(FT_Get_Char_Index(f.face,cp)!=0,"font glyph unsupported");
    renderGlyph(f,cp,size,out); END}
void acv_glyph_free(ACVGlyph *glyph){if(glyph){std::free(glyph->pixels);*glyph={};}}
int acv_reference_glyph_with_weight(const char *path,int faceIndex,uint32_t cp,int size,double weight,ACVGlyph *out){START
    require(out,"null glyph output");*out={};
    require(size>0&&size<=4096*64&&faceIndex>=0&&cp<=0x10ffff,"invalid glyph size/face/codepoint");
    Font f(path,faceIndex);setWeight(f,weight);
    renderGlyph(f,cp,size,out); END}
}
