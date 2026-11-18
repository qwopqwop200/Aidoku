"""Coherent whole-line font fitting; no independent radical/glyph search.

OCR supplies a reference string, not a learned token feature. Both font weights
share character order, advances, pose and source location. Returned values are
only image registration and differential-stem measurements.
"""
from functools import lru_cache
import math
import unicodedata

import cv2
import numpy as np
from PIL import Image,ImageDraw
from fontTools.ttLib import TTFont

from native_pairs import reference_font,glyph,EM
from source_observation import observe_fill
from observed_weight_bands import band_stats
from optimized_features.fill_alpha import predicted_fill_alpha
from optimized_features.templates import rotate,pose_angle
from affine_pairs import locate

LINE_FIELDS=32
PAIR_FIELDS=64
VERTICAL_ROTATE=set('「」『』[]()（）【】〈〉《》ー―—…')


def font(record):
    return reference_font(record['path'],record['SHA256'],record.get('weight'))


def key(record):return record['path'],record['SHA256'],record.get('weight')


@lru_cache(maxsize=24)
def supported(path,digest):
    with TTFont(path,fontNumber=0,lazy=True) as face:return frozenset(face.getBestCmap())


@lru_cache(maxsize=24)
def _word_masks(regular,heavy,text,vertical,tracking):
    records=[dict(path=r[0],SHA256=r[1],weight=r[2]) for r in (regular,heavy)]
    fonts=[font(r) for r in records]
    if any(ord(c) not in supported(r['path'],r['SHA256']) for c in text for r in records):return None
    if vertical:
        canvases=[np.zeros((math.ceil((len(text)+2)*EM*tracking),3*EM),np.uint8) for _ in records]
        for j,char in enumerate(text):
            for record,canvas in zip(records,canvases):
                ink=glyph(record,char)
                if ink is None:continue
                if char in VERTICAL_ROTATE:ink=cv2.rotate(ink,cv2.ROTATE_90_CLOCKWISE)
                y=round(EM*tracking*(j+1)+(EM*tracking-ink.shape[0])/2)
                x=(canvas.shape[1]-ink.shape[1])//2
                canvas[y:y+ink.shape[0],x:x+ink.shape[1]]=ink
    else:
        advances=[max(f.getlength(c) for f in fonts)*tracking for c in text]
        width=math.ceil(sum(advances)+2*EM)
        images=[Image.new('L',(width,3*EM)) for _ in fonts]
        for f,image in zip(fonts,images):
            draw=ImageDraw.Draw(image);x=float(EM)
            for char,advance in zip(text,advances):
                draw.text((x,1.5*EM),char,font=f,fill=255,anchor='ls');x+=advance
        canvases=[np.asarray(image) for image in images]
    ys,xs=np.nonzero((canvases[0]>32)|(canvases[1]>32))
    if not len(xs):return None
    bounds=(slice(ys.min(),ys.max()+1),slice(xs.min(),xs.max()+1))
    return tuple(np.asarray(v[bounds],np.float32)/255 for v in canvases)


def word_masks(pair,text,vertical=False,tracking=1.):
    return _word_masks(key(pair['regular']),key(pair['heavy']),text,bool(vertical),float(tracking))


def transform(a,b,scale,cross,angle,vertical):
    height=max(2,round(a.shape[0]*scale*(1. if vertical else cross)))
    width=max(2,round(a.shape[1]*scale*(cross if vertical else 1.)))
    a,b=(cv2.resize(v,(width,height),interpolation=cv2.INTER_AREA) for v in (a,b))
    pad=max(1,round(EM*scale*.06));a,b=np.pad(a,pad),np.pad(b,pad)
    if angle:
        frame=[0,0,a.shape[1],a.shape[0]];a,_=rotate(a,frame,angle);b,_=rotate(b,frame,angle)
    return np.asarray(a,np.float32),np.asarray(b,np.float32)


def fit_line(rgb,bbox,source_em,text,ownership,style,pair,angle=0.):
    text=''.join(c for c in unicodedata.normalize('NFC',text or '') if not c.isspace())
    if not 2<=len(text)<=32 or not any(unicodedata.category(c)[0] in 'LN' for c in text):
        return np.zeros(LINE_FIELDS)
    vertical=bbox[3]>=bbox[2]
    alpha=predicted_fill_alpha(rgb,bbox,ownership,style)
    values,observed=observe_fill(rgb,ownership,style)
    if abs(angle)>.1:
        alpha,_=rotate(alpha,bbox,angle);values,_=rotate(values,bbox,angle)
        observed,_=rotate(observed.astype(np.uint8),bbox,angle,nearest=True)
    image_scale=min(1.,640/max(alpha.shape))
    if image_scale<1:
        alpha=cv2.resize(alpha,None,fx=image_scale,fy=image_scale,interpolation=cv2.INTER_AREA)
        values=cv2.resize(values,(alpha.shape[1],alpha.shape[0]),interpolation=cv2.INTER_AREA)
        observed=cv2.resize(observed.astype(np.float32),(alpha.shape[1],alpha.shape[0]),interpolation=cv2.INTER_AREA)>.99
    alpha=np.asarray(alpha,np.float32);observed=np.asarray(observed,bool)
    ys,xs=np.nonzero(alpha>.4)
    if len(xs)<5:return np.zeros(LINE_FIELDS)
    dims=(int(ys.max()-ys.min()+1),int(xs.max()-xs.min()+1))
    long,cross_extent=(dims[0],dims[1]) if vertical else (dims[1],dims[0])
    variants=[text];stripped=text
    while stripped and unicodedata.category(stripped[0])[0] in 'PS':stripped=stripped[1:]
    while stripped and unicodedata.category(stripped[-1])[0] in 'PS':stripped=stripped[:-1]
    if 2<=len(stripped)<len(text):variants.append(stripped)
    best=None;prior_unit=source_em*image_scale
    for tracking in (.9,1.,1.1):
        full=word_masks(pair,text,vertical,tracking)
        if full is None:continue
        full_long=full[0].shape[0 if vertical else 1]
        full_cross=full[0].shape[1 if vertical else 0]
        derived=long/full_long
        # Complete-word geometry rejects a paragraph squeezed into one line.
        if not .6<=cross_extent/max(1,full_cross*derived)<=1.6:continue
        if not .45<=derived*EM/max(1,prior_unit)<=1.8:continue
        scales=[derived*.95,derived,derived*1.05]
        if .7<=prior_unit/EM/derived<=1.3:scales.append(prior_unit/EM)
        for variant in variants:
            base=word_masks(pair,variant,vertical,tracking)
            if base is None:continue
            for scale in scales:
                for cross in (.9,1.,1.1):
                    a,b=transform(*base,scale,cross,0.,vertical)
                    match=locate(alpha,a,b)
                    if match is not None and (best is None or match[0]>best[0][0]):
                        best=(match,base,scale,cross,tracking,0.,a,b,len(variant)/len(text))
    if best is None:return np.zeros(LINE_FIELDS)
    if best[0][0]<.85:
        _,base,scale,cross,tracking,_,_,_,coverage=best
        for factor in (.975,1.,1.025):
            for rotation in (-4.,0.,4.):
                a,b=transform(*base,scale*factor,cross,rotation,vertical)
                match=locate(alpha,a,b)
                if match is not None and match[0]>best[0][0]:
                    best=(match,base,scale*factor,cross,tracking,rotation,a,b,coverage)
    (score,ra,rb,x,y),_,scale,cross,tracking,rotation,a,b,coverage=best
    sy,sx=slice(y,y+a.shape[0]),slice(x,x+a.shape[1])
    bands=band_stats(values[sy,sx],a,b,observed[sy,sx],score)
    result=np.r_[bands,score,ra,rb,rb-ra,scale*EM/max(1,prior_unit),cross,
                 tracking,rotation/4.,coverage,cross_extent/max(1,EM*scale),
                 float(vertical),float((alpha>.4).mean()),1.,1.]
    if result.shape!=(LINE_FIELDS,) or not np.isfinite(result).all():raise ValueError('Invalid word fit')
    return result


def measure(rgb,bbox,source_em,text,ownership,style,pairs,members=None):
    members=members or [dict(bbox=bbox,text=text)]
    members=sorted(members,key=lambda m:(-m['bbox'][0],m['bbox'][1]) if bbox[3]>=bbox[2]
                   else (m['bbox'][1],m['bbox'][0]))
    if len(members)>6:members=[members[i] for i in np.linspace(0,len(members)-1,6).astype(int)]
    lines=[]
    for member in members:
        frame=member['bbox'];x,y,w,h=frame
        left=max(0,math.floor(x-.1*w));top=max(0,math.floor(y-.1*h))
        right=min(rgb.shape[1],math.ceil(x+1.1*w));bottom=min(rgb.shape[0],math.ceil(y+1.1*h))
        if left>=right or top>=bottom or x<0 or y<0 or x+w>rgb.shape[1]+1 or y+h>rgb.shape[0]+1:continue
        angle=pose_angle(member['polygon']) if member.get('polygon') else 0.
        lines.append((rgb[top:bottom,left:right],[x-left,y-top,w,h],
                      member['text'],ownership[top:bottom,left:right],angle))
    output=[]
    for pair in pairs:
        rows=[fit_line(image,frame,source_em,string,own,style,pair,angle)
              for image,frame,string,own,angle in lines]
        rows=[v for v in rows if v[-1]>0]
        if not rows:output.extend(np.zeros(PAIR_FIELDS));continue
        rows=np.asarray(rows);weights=np.maximum(.01,rows[:,18])**4
        output.extend(np.r_[np.average(rows,axis=0,weights=weights),rows[rows[:,18].argmax()]])
    return np.asarray(output,float)
