#ifndef AIDOKU_NATIVE_CV_H
#define AIDOKU_NATIVE_CV_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* All input/output images are contiguous row-major. Errors are thread-local;
 * no C++ exceptions cross this ABI. All capacities are element counts. */
const char *acv_last_error(void);
const char *acv_opencv_version(void);
const char *acv_freetype_version(void);
/* Normalized float32 cosine neighbors, row-major QxD / RxD. Exactly 8
 * results/query; ties use ascending original reference index. Exclusions are a
 * shared page-level set (duplicates allowed); NULL is valid only at count0.
 * Requires >=8 eligible references. Zero queries is a no-op. Inputs stay borrowed:
 * no whole-bank copy or QxR allocation; query batches <=128, bounded ref tiles.
 * Outputs must hold qCount*8 elements. Nonfinite inputs/invalid indices fail. */
int acv_cosine_neighbors(const float *queries,int qCount,const float *references,int rCount,int dim,
                         const int32_t *excluded,int excludedCount,int neighbors,
                         int32_t *outIndices,float *outDistances);
int acv_components(const uint8_t *mask,int w,int h,int connectivity,int32_t *labels,int32_t *stats,double *centroids,size_t componentCapacity,int *count);
int acv_component_areas8(const uint8_t *mask, int w, int h, int32_t *areas, size_t capacity, int *count);
int acv_morphology(const void *src,void *dst,int w,int h,int float32,int operation,int shape,int kw,int kh,int border);
int acv_box_mean(const float *src,float *dst,int w,int h,int size);
int acv_distance(const uint8_t *src,float *dst,int32_t *labels,int w,int h,int metric,int maskSize);
int acv_gray(const uint8_t *rgb,uint8_t *dst,int w,int h);
int acv_fill_holes4(const uint8_t *src,uint8_t *dst,int w,int h);
int acv_fill_external(const uint8_t *src,uint8_t *dst,int w,int h);
int acv_dct(const float *src,float *dst,int w,int h,int flags);
int acv_hog(const uint8_t *src,int w,int h,int channels,int block,int stride,int cell,int bins,float *dst,size_t capacity,size_t *count);
int acv_match_template(const uint8_t *src,int w,int h,const uint8_t *pattern,int pw,int ph,int channels,int method,float *dst,size_t capacity);
int acv_rgb_box_mean(const uint8_t *src,float *dst,int w,int h,int size);
int acv_rgb_sobel_magnitude(const uint8_t *src,float *dst,int w,int h);
int acv_rgb_to_lab(const void *src,void *dst,int w,int h,int float32);
int acv_resize(const void *src,int w,int h,void *dst,int dw,int dh,int channels,int float32,int interpolation);
int acv_warp_affine(const void *src,int w,int h,void *dst,int dw,int dh,int channels,int float32,const double *matrix6,int flags,int border,double borderValue);
int acv_min_area_rect(const float *xy,int count,float *result5);
int acv_fill_poly(const float *xy,const int32_t *counts,int polygons,uint8_t *dst,int w,int h,uint8_t value);
int acv_blur(const void *src,void *dst,int w,int h,int channels,int float32,int size,double sigma,int median,int border);
int acv_remap(const void *src,void *dst,int w,int h,int dw,int dh,int channels,int float32,const float *mapX,const float *mapY,int interpolation,int border,double borderValue);
typedef struct ACVGlyph {
    uint8_t *pixels;
    int32_t width,height,left,top,pitch;
    int64_t advanceX26_6,advanceY26_6;
} ACVGlyph;
/* One library/face per call: safe concurrently, no shared face mutation.
 * path is a filesystem path (decode file:// URLs in the caller).
 * pixelSize26_6 = 256 * 64 for the accepted EM256 glyph resource.
 * On error out is zero; caller must free a successful result exactly once. */
int acv_font_has_glyph(const char *path,int faceIndex,uint32_t codepoint,int *supported);
int acv_font_face_index(const char *path,const char *postscriptName,int *faceIndex);
int acv_glyph(const char *path,int faceIndex,uint32_t codepoint,int pixelSize26_6,ACVGlyph *out);
/* Explicit OpenType wght design coordinate (16.16 rounding), never synthetic bold.
 * Rejects a missing axis, nonfinite/out-of-range weight, or unsupported glyph.
 * All other variation coordinates retain their face/instance defaults.
 * acv_glyph above retains its original default/.notdef behavior and ABI. */
int acv_glyph_with_weight(const char *path,int faceIndex,uint32_t codepoint,int pixelSize26_6,double weight,ACVGlyph *out);
/* Reference fitting preserves Pillow's actual .notdef raster when a reference
 * family lacks an OCR character. This differs deliberately from the strict
 * supported-glyph API above; it never substitutes a different font or weight. */
int acv_reference_glyph_with_weight(const char *path,int faceIndex,uint32_t codepoint,int pixelSize26_6,double weight,ACVGlyph *out);
void acv_glyph_free(ACVGlyph *glyph);
#ifdef __cplusplus
}
#endif
#endif
