"""Differential stems with explicit source-pixel observation coverage."""
import cv2
import numpy as np

import affine_pairs
from native_pairs import glyph
from source_observation import observe_fill
from optimized_features.templates import rotate,anchor_chars
from font_metric_features import default_font_paths

FIELDS=18


def band_stats(source,regular,heavy,observed,score=1.):
    source,a,b=(np.asarray(v,float) for v in (source,regular,heavy))
    observed=np.asarray(observed,bool)
    if source.shape!=a.shape or source.shape!=b.shape or source.shape!=observed.shape:
        raise ValueError('Observed source-band geometry differs')
    delta=b-a;union=np.maximum(a,b)>.1;valid=union&observed
    energy=float((np.square(delta)*observed).sum())
    if energy<1. or not valid.any():return np.zeros(FIELDS)
    coefficient=float(np.clip(((source-a)*delta*observed).sum()/energy,-2,3))
    fitted=a+np.clip(coefficient,0,1)*delta
    errors=[float(np.square(source-v)[valid].mean()) for v in (a,b,fitted)]
    common=np.minimum(a,b)>.75;plus=delta>.25;minus=delta<-.25;info=plus|minus
    def average(mask):
        mask=mask&observed
        return float(source[mask].mean()) if mask.any() else 0.
    def coverage(mask):return float((mask&observed).sum()/max(1,int(mask.sum())))
    active=info&observed
    local=np.clip((source[active]-a[active])/delta[active],-2,3)
    q=np.quantile(local,[.25,.5,.75]) if len(local) else np.zeros(3)
    value=np.r_[coefficient,errors[0],errors[1],errors[0]-errors[1],errors[2],
                average(common),average(plus),average(minus),energy/max(1,int(valid.sum())),
                q,score,1.,coverage(union),coverage(info),coverage(common),float(observed.mean())]
    if value.shape!=(FIELDS,) or not np.isfinite(value).all():raise ValueError('Invalid observed band evidence')
    return value


def measure(rgb,bbox,source_em,text,ownership,style,pairs,angle=0.,poses=None):
    if poses is None:poses=affine_pairs.measure(rgb,bbox,source_em,text,ownership,style,pairs,angle)
    poses=np.asarray(poses,float).reshape(len(pairs),2,24)
    alpha,observed=observe_fill(rgb,ownership,style)
    if abs(angle)>.1:
        alpha,_=rotate(alpha,bbox,angle);observed,_=rotate(observed.astype(np.uint8),bbox,angle,nearest=True)
    scale=min(1.,480/max(alpha.shape))
    if scale<1:
        alpha=cv2.resize(alpha,None,fx=scale,fy=scale,interpolation=cv2.INTER_AREA)
        # A mixed valid/unknown downsampling footprint must not become a known
        # negative pixel merely because its center happened to be observed.
        observed=cv2.resize(observed.astype(np.float32),(alpha.shape[1],alpha.shape[0]),interpolation=cv2.INTER_AREA)>.99
    alpha=np.asarray(alpha,np.float32);observed=np.asarray(observed,bool);unit=source_em*scale
    chars=anchor_chars(text,default_font_paths()[0],256,exclude_small=True)
    groups=[[c for c in chars if 0x3040<=ord(c)<=0x30ff][:2],
            [c for c in chars if not 0x3040<=ord(c)<=0x30ff][:2]]
    # Pose localization still uses the frozen alpha used to produce the poses;
    # unknown pixels only affect the subsequent differential-stem estimation.
    from optimized_features.fill_alpha import predicted_fill_alpha
    locate_alpha=predicted_fill_alpha(rgb,bbox,ownership,style)
    if abs(angle)>.1:locate_alpha,_=rotate(locate_alpha,bbox,angle)
    if scale<1:locate_alpha=cv2.resize(locate_alpha,None,fx=scale,fy=scale,interpolation=cv2.INTER_AREA)
    locate_alpha=np.asarray(locate_alpha,np.float32);out=[]
    for i,pair in enumerate(pairs):
        for kind,witnesses in enumerate(groups):
            pose=poses[i,kind]
            if not pose[15]:out.extend(np.zeros(FIELDS));continue
            candidates=[]
            for char in witnesses:
                r,h=glyph(pair['regular'],char),glyph(pair['heavy'],char)
                if r is None or h is None:continue
                a,b=affine_pairs.transformed_pair(r,h,unit*pose[4],pose[16],pose[17]*4)
                match=affine_pairs.locate(locate_alpha,a,b)
                if match is None:continue
                score,_,_,x,y=match;ys=slice(y,y+a.shape[0]);xs=slice(x,x+a.shape[1])
                values=band_stats(alpha[ys,xs],a,b,observed[ys,xs],score)
                candidates.append((abs(score-pose[0]),-score,values))
            out.extend(min(candidates,key=lambda v:(v[0],v[1]))[2] if candidates else np.zeros(FIELDS))
    return np.asarray(out,float)
