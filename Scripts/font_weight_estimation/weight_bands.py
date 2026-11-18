"""Estimate added weight only where two aligned font weights differ.

Common glyph shape is a validity signal, not evidence of boldness. The signed
regular-to-black difference isolates added stems and contracted counters.
"""
import cv2
import numpy as np

import affine_pairs
from native_pairs import glyph
from optimized_features.fill_alpha import predicted_fill_alpha
from optimized_features.templates import rotate, anchor_chars
from font_metric_features import default_font_paths

FIELDS = 14


def confirmation(bands,policy):
    values=np.asarray(bands,float)
    if values.ndim!=2 or values.shape[1]%FIELDS or not np.isfinite(values).all():
        raise ValueError('Invalid differential weight-band batch')
    if not len(values):return np.zeros(0,bool)
    values=values.reshape(len(values),-1,FIELDS)
    best=values[np.arange(len(values)),values[:,:,12].argmax(axis=1)]
    return ((best[:,0]>=policy['minimumAddedStem']) &
            (best[:,5]>=policy['minimumCommonBody']) &
            (best[:,12]>=policy['minimumGlyphFit']) &
            (best[:,4]<=policy['maximumReconstructionError']))


def band_stats(source, regular, heavy, score=1.):
    source, a, b = (np.asarray(v, float) for v in (source, regular, heavy))
    if source.shape != a.shape or source.shape != b.shape or source.ndim != 2:
        raise ValueError('Weight-band arrays differ')
    delta = b-a
    energy = float(np.square(delta).sum())
    union = np.maximum(a,b) > .1
    if energy < 1. or not union.any():
        return np.zeros(FIELDS)
    coefficient = float(np.clip(((source-a)*delta).sum()/energy, -2., 3.))
    fitted = a+np.clip(coefficient,0,1)*delta
    errors = [float(np.square(source-v)[union].mean()) for v in (a,b,fitted)]
    common = np.minimum(a,b) > .75
    plus, minus = delta > .25, delta < -.25
    informative = plus | minus
    local = np.clip((source[informative]-a[informative])/delta[informative],-2,3)
    quantiles = np.quantile(local,[.25,.5,.75]) if len(local) else np.zeros(3)
    result = np.r_[coefficient, errors[0], errors[1], errors[0]-errors[1], errors[2],
                   float(source[common].mean()) if common.any() else 0.,
                   float(source[plus].mean()) if plus.any() else 0.,
                   float(source[minus].mean()) if minus.any() else 0.,
                   energy/max(1,int(union.sum())), quantiles, score, 1.]
    if result.shape != (FIELDS,) or not np.isfinite(result).all():
        raise ValueError('Invalid weight-band evidence')
    return result


def measure(rgb,bbox,source_em,text,ownership,style,pairs,angle=0.,poses=None):
    if poses is None:
        poses=affine_pairs.measure(rgb,bbox,source_em,text,ownership,style,pairs,angle)
    poses=np.asarray(poses,float).reshape(len(pairs),2,24)
    alpha=predicted_fill_alpha(rgb,bbox,ownership,style)
    if abs(angle)>.1:alpha,_=rotate(alpha,bbox,angle)
    scale=min(1.,480/max(alpha.shape))
    if scale<1:alpha=cv2.resize(alpha,None,fx=scale,fy=scale,interpolation=cv2.INTER_AREA)
    alpha=np.asarray(alpha,np.float32);unit=source_em*scale
    chars=anchor_chars(text,default_font_paths()[0],256,exclude_small=True)
    groups=[[c for c in chars if 0x3040<=ord(c)<=0x30ff][:2],
            [c for c in chars if not 0x3040<=ord(c)<=0x30ff][:2]]
    output=[]
    for i,pair in enumerate(pairs):
        for kind,witnesses in enumerate(groups):
            pose=poses[i,kind]
            if not pose[15]:output.extend(np.zeros(FIELDS));continue
            candidates=[]
            for char in witnesses:
                r,h=glyph(pair['regular'],char),glyph(pair['heavy'],char)
                if r is None or h is None:continue
                a,b=affine_pairs.transformed_pair(r,h,unit*pose[4],pose[16],pose[17]*4)
                match=affine_pairs.locate(alpha,a,b)
                if match is None:continue
                score,_,_,x,y=match
                # Recover the original visible witness using physical score
                # equality. Its token identity never enters returned features.
                source=alpha[y:y+a.shape[0],x:x+a.shape[1]]
                candidates.append((abs(score-pose[0]),-score,band_stats(source,a,b,score)))
            if candidates:
                output.extend(min(candidates,key=lambda v:(v[0],v[1]))[2])
            else:output.extend(np.zeros(FIELDS))
    return np.asarray(output,float)
