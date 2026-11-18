"""Paired regular/heavy glyph fits at one shared source location and scale.

Only pooled physical fit scores are returned. Neither OCR strings, glyph IDs,
font-weight labels nor page identifiers are model features.
"""
from functools import lru_cache
import math
from pathlib import Path
import unicodedata

import cv2
import numpy as np
from PIL import ImageFont

EM=128
FEATURE_COUNT=48
SCALES=(.5,.65,.8,1.,1.2,1.5)

@lru_cache(maxsize=1)
def font_pairs():
    paths={unicodedata.normalize('NFC',p.name):str(p) for p in Path('/System/Library/Fonts').glob('*.ttc')}
    return [(paths['ヒラギノ角ゴシック W3.ttc'],0,paths['ヒラギノ角ゴシック W6.ttc'],0),
            (paths['ヒラギノ角ゴシック W6.ttc'],0,paths['ヒラギノ角ゴシック W9.ttc'],0),
            (paths['ヒラギノ明朝 ProN.ttc'],0,paths['ヒラギノ明朝 ProN.ttc'],2)]

@lru_cache(maxsize=8)
def font(path,index):return ImageFont.truetype(path,EM,index=index)

@lru_cache(maxsize=16384)
def bitmap(path,index,char):
    mask=font(path,index).getmask(char,mode='L')
    if not min(mask.size):return None
    image=np.asarray(mask,np.uint8).reshape(mask.size[1],mask.size[0]);ys,xs=np.nonzero(image>40)
    if not len(xs):return None
    return image[ys.min():ys.max()+1,xs.min():xs.max()+1].copy()

def paired_patterns(a,b,unit):
    images=[]
    for image in (a,b):
        width=max(2,round(image.shape[1]*unit/EM));height=max(2,round(image.shape[0]*unit/EM))
        images.append(cv2.resize(image,(width,height),interpolation=cv2.INTER_AREA).astype(np.float32)/255)
    pad=max(1,round(unit*.08));height=max(i.shape[0] for i in images)+2*pad;width=max(i.shape[1] for i in images)+2*pad
    result=[]
    for image in images:
        canvas=np.zeros((height,width),np.float32);y=(height-image.shape[0])//2;x=(width-image.shape[1])//2;canvas[y:y+image.shape[0],x:x+image.shape[1]]=image;result.append(canvas)
    return result

def match_pair(masks,regular,heavy,unit,scales=SCALES):
    best=None
    for factor in scales:
        a,b=paired_patterns(regular,heavy,unit*factor)
        for mask in masks:
            if a.shape[0]>mask.shape[0] or a.shape[1]>mask.shape[1]:continue
            ca=cv2.matchTemplate(mask,a,cv2.TM_CCOEFF_NORMED);cb=cv2.matchTemplate(mask,b,cv2.TM_CCOEFF_NORMED)
            joint=(ca+cb)/2;joint=np.where(np.isfinite(joint),joint,-1.)
            _,score,_,(x,y)=cv2.minMaxLoc(joint)
            ra,rb=float(ca[y,x]),float(cb[y,x])
            if not math.isfinite(ra+rb):continue
            if best is None or score>best[0]:best=(float(score),ra,rb,float(factor))
    return best

def measure(rgb,bbox,source_em,text,scales=SCALES):
    if not math.isfinite(source_em) or source_em<=0:raise ValueError('Invalid source em')
    x,y,w,h=bbox;target=rgb[max(0,int(y)):min(len(rgb),math.ceil(y+h)),max(0,int(x)):min(rgb.shape[1],math.ceil(x+w))]
    if not target.size:raise ValueError('Empty target')
    scale=min(1.,360/max(target.shape[:2]));unit=source_em*scale
    if scale<1:target=cv2.resize(target,None,fx=scale,fy=scale,interpolation=cv2.INTER_AREA)
    gray=cv2.cvtColor(target,cv2.COLOR_RGB2GRAY);_,dark=cv2.threshold(gray,0,1,cv2.THRESH_BINARY_INV+cv2.THRESH_OTSU)
    lo=target.min(2);hi=target.max(2);pale=(lo>180)&(hi.astype(float)-lo<45);color=hi.astype(float)-lo>70
    masks=[dark.astype(np.float32),pale.astype(np.float32),color.astype(np.float32)]
    groups=[[],[]]
    for char in sorted(set(unicodedata.normalize('NFC',text or ''))):
        if char.isspace() or unicodedata.category(char)[0] in 'MCPZS':continue
        category=0 if 0x3040<=ord(char)<=0x30ff else 1
        raster=bitmap(font_pairs()[0][0],0,char)
        if raster is not None:groups[category].append((int((raster>40).sum()),char))
    # One simple kana and one dense non-kana are complementary weight witnesses.
    chars=[[c for _,c in sorted(g,reverse=True)[:1]] for g in groups]
    output=[]
    for pa,ia,pb,ib in font_pairs():
        for category in chars:
            observations=[]
            for char in category:
                regular=bitmap(pa,ia,char);heavy=bitmap(pb,ib,char)
                if regular is None or heavy is None:continue
                result=match_pair(masks,regular,heavy,unit,scales=scales)
                if result is not None:observations.append(result)
            if not observations:output.extend([0.]*8);continue
            array=np.array(observations);score,ra,rb,factor=np.median(array,axis=0)
            output.extend([score,ra,rb,rb-ra,factor,float(len(observations)),float(score>.5),float(score>.7)])
    result=np.asarray(output,float)
    if result.shape!=(FEATURE_COUNT,) or not np.isfinite(result).all():raise ValueError('Invalid paired fit')
    return result
