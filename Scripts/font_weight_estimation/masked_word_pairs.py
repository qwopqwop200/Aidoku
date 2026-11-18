"""BBox-constrained word registration with unknown-pixel-aware correlation."""
import math
import unicodedata

import cv2
import numpy as np

from word_pairs import word_masks,transform,LINE_FIELDS,PAIR_FIELDS
from source_observation import observe_fill
from observed_weight_bands import band_stats
from optimized_features.fill_alpha import predicted_fill_alpha
from optimized_features.templates import rotate,pose_angle


def correlation(source,observed,pattern):
    if pattern.shape[0]>source.shape[0] or pattern.shape[1]>source.shape[1]:return None
    source=np.asarray(source,np.float32);valid=np.asarray(observed,np.float32)
    ones=np.ones(pattern.shape,np.float32)
    cross=cv2.matchTemplate(source*valid,pattern,cv2.TM_CCORR)
    source_energy=cv2.matchTemplate(source*source*valid,ones,cv2.TM_CCORR)
    reference_energy=cv2.matchTemplate(valid,pattern*pattern,cv2.TM_CCORR)
    foreground=(pattern>.1).astype(np.float32)
    support=cv2.matchTemplate(valid,foreground,cv2.TM_CCORR)/max(1.,float(foreground.sum()))
    denominator=np.sqrt(np.maximum(0,source_energy*reference_energy))
    score=np.divide(cross,denominator,out=np.full_like(cross,-1.),where=denominator>1e-6)
    return np.where((support>=.3)&np.isfinite(score),np.clip(score,-1,1),-1.)


def locate(source,observed,a,b):
    ca=correlation(source,observed,a);cb=correlation(source,observed,b)
    if ca is None or cb is None:return None
    _,score,_,(x,y)=cv2.minMaxLoc(np.maximum(ca,cb))
    if score<0:return None
    return score,float(ca[y,x]),float(cb[y,x]),x,y


def pattern_pair(base,scale,cross,rotation,vertical,shape):
    # Avoid rasterizing candidates that cannot fit in the bounded source crop.
    h=max(2,round(base[0].shape[0]*scale*(1 if vertical else cross)))
    w=max(2,round(base[0].shape[1]*scale*(cross if vertical else 1)))
    pad=max(1,round(128*scale*.06));h+=2*pad;w+=2*pad
    if rotation:
        angle=math.radians(rotation);h,w=math.ceil(h*abs(math.cos(angle))+w*abs(math.sin(angle))),math.ceil(w*abs(math.cos(angle))+h*abs(math.sin(angle)))
    if h>shape[0] or w>shape[1]:return None
    return transform(*base,scale,cross,rotation,vertical)


def prepare(rgb,bbox,source_em,text,ownership,style,angle):
    text=''.join(c for c in unicodedata.normalize('NFC',text or '') if not c.isspace())
    if not 2<=len(text)<=32 or not any(unicodedata.category(c)[0] in 'LN' for c in text):return None
    alpha=predicted_fill_alpha(rgb,bbox,ownership,style);values,observed=observe_fill(rgb,ownership,style)
    if abs(angle)>.1:
        alpha,_=rotate(alpha,bbox,angle);values,_=rotate(values,bbox,angle)
        observed,_=rotate(observed.astype(np.uint8),bbox,angle,nearest=True)
    scale=min(1.,640/max(alpha.shape))
    if scale<1:
        alpha=cv2.resize(alpha,None,fx=scale,fy=scale,interpolation=cv2.INTER_AREA)
        values=cv2.resize(values,(alpha.shape[1],alpha.shape[0]),interpolation=cv2.INTER_AREA)
        observed=cv2.resize(observed.astype(np.float32),(alpha.shape[1],alpha.shape[0]),interpolation=cv2.INTER_AREA)>.99
    ys,xs=np.nonzero(alpha>.4)
    if len(xs)<5:return None
    vertical=bbox[3]>=bbox[2]
    spans=(ys.max()-ys.min()+1,xs.max()-xs.min()+1)
    long,cross=(spans[0],spans[1]) if vertical else (spans[1],spans[0])
    box_long,box_cross=(bbox[3],bbox[2]) if vertical else (bbox[2],bbox[3])
    return dict(text=text,alpha=np.asarray(values,np.float32),observed=np.asarray(observed,bool),
                vertical=vertical,long=long,cross=cross,boxLong=box_long*scale,
                boxCross=box_cross*scale,unit=source_em*scale)


def fit(prepared,pair,refine=False,renderer=word_masks):
    p=prepared;text=p['text'];vertical=p['vertical'];alpha=p['alpha'];observed=p['observed'];unit=p['unit']
    variants=[text];stripped=text
    while stripped and unicodedata.category(stripped[0])[0] in 'PS':stripped=stripped[1:]
    while stripped and unicodedata.category(stripped[-1])[0] in 'PS':stripped=stripped[:-1]
    if 2<=len(stripped)<len(text):variants.append(stripped)
    best=None
    for variant in variants:
        full=renderer(pair,text,vertical,1.);base=renderer(pair,variant,vertical,1.)
        if full is None or base is None:continue
        length=full[0].shape[0 if vertical else 1];cross_extent=full[0].shape[1 if vertical else 0]
        candidates=[p['long']/length,p['boxLong']*.9/length,p['boxLong']/length,unit/128]
        for scale in sorted(set(candidates)):
            if not .5<=p['boxCross']/max(1,cross_extent*scale)<=2.:continue
            if not .4<=scale*128/max(1,unit)<=2.:continue
            pair_images=pattern_pair(base,scale,1.,0.,vertical,alpha.shape)
            if pair_images is None:continue
            match=locate(alpha,observed,*pair_images)
            if match is not None and (best is None or match[0]>best[0][0]):
                best=(match,scale,1.,1.,0.,pair_images,len(variant)/len(text),variant)
    if best is None:return np.zeros(LINE_FIELDS)
    if refine:
        _,scale,_,_,_,_,coverage,variant=best
        for tracking in (.9,1.,1.1):
            base=renderer(pair,variant,vertical,tracking)
            if base is None:continue
            for factor in (.975,1.,1.025):
                for cross in (.9,1.,1.1):
                    pair_images=pattern_pair(base,scale*factor,cross,0.,vertical,alpha.shape)
                    if pair_images is None:continue
                    match=locate(alpha,observed,*pair_images)
                    if match is not None and match[0]>best[0][0]:
                        best=(match,scale*factor,cross,tracking,0.,pair_images,coverage,variant)
        _,scale,cross,tracking,_,_,coverage,variant=best;base=renderer(pair,variant,vertical,tracking)
        for rotation in (-4.,4.):
            pair_images=pattern_pair(base,scale,cross,rotation,vertical,alpha.shape)
            if pair_images is None:continue
            match=locate(alpha,observed,*pair_images)
            if match is not None and match[0]>best[0][0]:
                best=(match,scale,cross,tracking,rotation,pair_images,coverage,variant)
    (score,ra,rb,x,y),scale,cross,tracking,rotation,(a,b),coverage,_=best
    sy,sx=slice(y,y+a.shape[0]),slice(x,x+a.shape[1])
    bands=band_stats(alpha[sy,sx],a,b,observed[sy,sx],score)
    return np.r_[bands,score,ra,rb,rb-ra,scale*128/max(1,unit),cross,
                 tracking,rotation/4.,coverage,p['boxCross']/max(1,128*scale),
                 float(vertical),float(observed.mean()),1.,1.]


def measure(rgb,bbox,source_em,text,ownership,style,pairs,members=None):
    members=members or [dict(bbox=bbox,text=text)]
    members=sorted(members,key=lambda m:(-m['bbox'][0],m['bbox'][1]) if bbox[3]>=bbox[2] else (m['bbox'][1],m['bbox'][0]))
    if len(members)>6:members=[members[i] for i in np.linspace(0,len(members)-1,6).astype(int)]
    prepared=[]
    for member in members:
        x,y,w,h=member['bbox'];l=max(0,math.floor(x-.1*w));t=max(0,math.floor(y-.1*h))
        r=min(rgb.shape[1],math.ceil(x+1.1*w));b=min(rgb.shape[0],math.ceil(y+1.1*h))
        if l>=r or t>=b or x<0 or y<0 or x+w>rgb.shape[1]+1 or y+h>rgb.shape[0]+1:continue
        angle=pose_angle(member['polygon']) if member.get('polygon') else 0.
        p=prepare(rgb[t:b,l:r],[x-l,y-t,w,h],source_em,member['text'],ownership[t:b,l:r],style,angle)
        if p is not None:prepared.append(p)
    collected=[[] for _ in pairs]
    for p in prepared:
        coarse=[fit(p,pair) for pair in pairs]
        families={}
        for pair,value in zip(pairs,coarse):families[pair['name']]=max(families.get(pair['name'],0),value[18])
        selected=set(sorted(families,key=lambda name:-families[name])[:2])
        for i,(pair,value) in enumerate(zip(pairs,coarse)):
            if pair['name'] in selected and value[-1]>0:value=fit(p,pair,True)
            if value[-1]>0:collected[i].append(value)
    out=[]
    for rows in collected:
        if not rows:out.extend(np.zeros(PAIR_FIELDS));continue
        rows=np.asarray(rows);weights=np.maximum(.01,rows[:,18])**4
        out.extend(np.r_[np.average(rows,axis=0,weights=weights),rows[rows[:,18].argmax()]])
    result=np.asarray(out,float)
    if result.shape!=(len(pairs)*PAIR_FIELDS,) or not np.isfinite(result).all():raise ValueError('Invalid masked word evidence')
    return result
