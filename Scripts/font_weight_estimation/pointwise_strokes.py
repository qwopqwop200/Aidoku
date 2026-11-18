"""Same-glyph signed-boundary displacement and local stem-width ratios.

These compare corresponding pixels rather than globally pooled body density.
Transcription is used only to rasterize the same reference glyph; returned
features contain no glyph bitmap, token identity, source ID, or page position.
"""
import math
from pathlib import Path
import sys
import cv2
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'font_size_estimation'))
from template_features import glyph_bitmap,transformed_glyph,best_template_match

FEATURE_COUNT=440

def signed_distance(binary):
    binary=np.asarray(binary,np.uint8)
    inside=cv2.distanceTransform(np.pad(binary,1),cv2.DIST_L2,cv2.DIST_MASK_PRECISE)[1:-1,1:-1]
    outside=cv2.distanceTransform(np.pad(1-binary,1),cv2.DIST_L2,cv2.DIST_MASK_PRECISE)[1:-1,1:-1]
    value=inside-outside
    return value-.5*np.sign(value)

def quantiles(values):
    return np.quantile(values,[.1,.25,.5,.75,.9]) if len(values) else np.zeros(5)

def paired_stats(source,reference,unit,score=1.,factor=1.,aspect=1.,coverage=1.):
    a=np.asarray(source,np.float32);b=np.asarray(reference,np.float32)
    if a.shape!=b.shape or a.ndim!=2 or unit<=0:raise ValueError('Invalid glyph pair')
    sa=(a>.5).astype(np.uint8);sb=(b>.5).astype(np.uint8)
    if not sa.any() or not sb.any():return np.zeros(26)
    da=signed_distance(sa);db=signed_distance(sb);difference=(da-db)/unit
    edge_a=(sa>0)&(da<=1.1);edge_b=(sb>0)&(db<=1.1)
    depth_b=cv2.distanceTransform(sb,cv2.DIST_L2,cv2.DIST_MASK_PRECISE)
    ridge=(depth_b>0)&(depth_b>=cv2.dilate(depth_b,np.ones((3,3),np.uint8))-.001)&(sa>0)
    depth_a=cv2.distanceTransform(sa,cv2.DIST_L2,cv2.DIST_MASK_PRECISE)
    ratios=np.log(np.maximum(.5,depth_a[ridge])/np.maximum(.5,depth_b[ridge]))
    gx=np.abs(cv2.Sobel(b,cv2.CV_32F,1,0));gy=np.abs(cv2.Sobel(b,cv2.CV_32F,0,1))
    horizontal=edge_b&(gy>=gx);vertical=edge_b&(gx>gy)
    orientation=[]
    for keep in [vertical,horizontal]:
        orientation.extend([float(np.mean(difference[keep])),float(np.median(difference[keep]))] if keep.any() else [0.,0.])
    dice=2*float(np.minimum(a,b).sum())/max(1e-6,float(a.sum()+b.sum()))
    result=np.r_[quantiles(difference[edge_b]),quantiles(difference[edge_a]),quantiles(ratios),orientation,
                 math.log(max(1e-6,float(a.sum()))/max(1e-6,float(b.sum()))),dice,score,factor,aspect,coverage,float(ridge.sum()/max(1,int(sb.sum()))) ]
    if result.shape!=(26,) or not np.isfinite(result).all():raise ValueError('Invalid pointwise metrics')
    return result

def glyph_metrics(alpha,observed,char,path,unit):
    bitmap=glyph_bitmap(path,char)
    if bitmap is None:return None
    matches=[]
    for factor in [.9,1.,1.1]:
        for aspect in [.9,1.,1.1]:
            match=best_template_match(alpha,bitmap,unit,factor,aspect)
            if match is not None:matches.append((match[0],-abs(math.log(factor)),-abs(math.log(aspect)),factor,aspect,match[1]))
    if not matches:return None
    score,_,_,factor,aspect,(x,y)=max(matches)
    if score<.2:return None
    ink=transformed_glyph(bitmap,unit,factor,aspect);pad=max(2,round(unit*.12));reference=np.pad(ink,pad);h,w=reference.shape
    source=np.zeros((h,w),np.float32);valid=np.zeros((h,w),bool);left=x-pad;top=y-pad;l=max(0,left);t=max(0,top);r=min(alpha.shape[1],left+w);b=min(alpha.shape[0],top+h)
    if l>=r or t>=b:return None
    source[t-top:b-top,l-left:r-left]=alpha[t:b,l:r];valid[t-top:b-top,l-left:r-left]=observed[t:b,l:r]
    if valid.mean()<.9:return None
    n,lab,stats,_=cv2.connectedComponentsWithStats((source>.5).astype(np.uint8),8)
    inside=np.zeros(source.shape,bool);inside[pad:pad+ink.shape[0],pad:pad+ink.shape[1]]=True
    overlaps=np.bincount(lab[inside].ravel(),minlength=n);keep=overlaps/np.maximum(1,stats[:,4])>=.3;keep[0]=False
    selected=cv2.dilate(keep[lab].astype(np.uint8),np.ones((3,3),np.uint8))>0;source*=selected&valid
    if source.sum()<1:return None
    return paired_stats(source,reference,unit,score,factor,aspect,float(valid.mean()))

def worker(job):
    from measure_normalized_style import prepare_source
    alpha,observed,unit,groups,fonts=prepare_source(job);output=[];family_scores=np.zeros((2,4))
    for font_index,path in enumerate(fonts):
        for kind,chars in enumerate(groups):
            values=[v for char in chars if (v:=glyph_metrics(alpha,observed,char,path,unit)) is not None]
            if not values:output.extend([0.]*54);continue
            values=np.asarray(values);weights=np.maximum(.01,values[:,21])**4
            mean=np.average(values,axis=0,weights=weights);median=np.median(values,axis=0)
            quality=float(np.mean(weights)**.25);family_scores[kind,font_index]=quality
            output.extend(np.r_[mean,median,len(values)/max(1,len(chars)),quality])
    for scores in family_scores:output.extend(np.eye(4)[scores.argmax()] if scores.max()>0 else np.zeros(4))
    result=np.array(output);assert result.shape==(FEATURE_COUNT,) and np.isfinite(result).all();return result
