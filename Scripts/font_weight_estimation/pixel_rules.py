"""Direct image measurements and explicit stroke rules, without a classifier.

Candidate palette masks compete by repeated interior glyph support. Hollow
outline rings are penalized so their width cannot stand in for body weight.
Only scalar pooled measurements leave the source crop.
"""
import math
import cv2
import numpy as np


def observe(rgb,bbox,source_em):
    if not math.isfinite(source_em) or source_em<=0:raise ValueError('Invalid source em')
    x,y,w,h=bbox
    target=rgb[max(0,int(y)):min(len(rgb),math.ceil(y+h)),max(0,int(x)):min(rgb.shape[1],math.ceil(x+w))]
    if not target.size:raise ValueError('Empty target')
    scale=min(1.,800/max(target.shape[:2]));unit=source_em*scale
    if scale<1:target=cv2.resize(target,None,fx=scale,fy=scale,interpolation=cv2.INTER_AREA)
    gray=cv2.cvtColor(target,cv2.COLOR_RGB2GRAY);_,dark=cv2.threshold(gray,0,1,cv2.THRESH_BINARY_INV+cv2.THRESH_OTSU)
    lo=target.min(2);hi=target.max(2)
    masks=[('dark-otsu',dark),('light-otsu',1-dark),('dark-core',hi<80),
           ('light-core',(lo>200)&(hi.astype(float)-lo<45)),('color-core',hi.astype(float)-lo>65)]
    # Quantized palette modes are source colour hypotheses, not colour labels.
    bins=(target.astype(np.int32)//32);codes=bins[:,:,0]*64+bins[:,:,1]*8+bins[:,:,2]
    values,counts=np.unique(codes,return_counts=True)
    for code in values[np.argsort(counts)[-6:]]:masks.append(('palette',codes==code))
    observations=[]
    for name,mask in masks:
        mask=np.asarray(mask,np.uint8);n,labels,stats,_=cv2.connectedComponentsWithStats(mask,8);glyphs=[]
        for i in range(1,n):
            sx,sy,sw,sh,area=stats[i];long=max(sw,sh);short=min(sw,sh)
            if not (.22*unit<=long<=1.7*unit and short>=max(2,.06*unit) and area>=max(4,.006*unit**2)):continue
            if area>mask.size*.6:continue
            body=(labels[sy:sy+sh,sx:sx+sw]==i).astype(np.uint8)
            depth=cv2.distanceTransform(np.pad(body,1),cv2.DIST_L2,cv2.DIST_MASK_PRECISE)[1:-1,1:-1]
            ridge=(depth>0)&(depth>=cv2.dilate(depth,np.ones((3,3),np.uint8))-.001)
            if not ridge.any():continue
            # Detached strokes of a kanji can be very short. Dividing by that
            # fragment makes thin normal strokes appear heavier than a full
            # bold glyph. Normalize by source em shared by the whole text.
            widths=2*depth[ridge]/unit
            contours,hierarchy=cv2.findContours(body,cv2.RETR_CCOMP,cv2.CHAIN_APPROX_SIMPLE)
            hole=sum(cv2.contourArea(c) for j,c in enumerate(contours) if hierarchy[0,j,3]>=0) if hierarchy is not None else 0
            hollow=hole/max(1,hole+area)
            contact=(sx==0 or sy==0 or sx+sw==mask.shape[1] or sy+sh==mask.shape[0])
            glyphs.append([float(np.median(widths)),float(np.quantile(widths,.25)),float(np.quantile(widths,.9)),float(hollow),float(area/(sw*sh)),float(contact),float(long/unit)])
        if not glyphs:continue
        g=np.asarray(glyphs)
        quality=np.log1p(len(g))*max(.01,1-float(np.median(g[:,3]))*1.7)*(1-.6*float(g[:,5].mean()))
        quality*=float(np.mean(np.clip(g[:,6],0,1)))
        observations.append({'mask':name,'quality':quality,'glyphCount':len(g),'bodyThickness':float(np.median(g[:,0])),
                             'thinStroke':float(np.median(g[:,1])),'broadStroke':float(np.median(g[:,2])),
                             'hollowFraction':float(np.median(g[:,3])),'occupancy':float(np.median(g[:,4]))})
    if not observations:return {'quality':0.,'glyphCount':0,'bodyThickness':0.,'thinStroke':0.,'broadStroke':0.,'hollowFraction':0.,'occupancy':0.,'mask':'none'}
    return max(observations,key=lambda r:r['quality'])


def infer_page(observations,policy):
    """Same rule for every page; no item IDs, labels, or image hashes accepted."""
    thickness=np.array([r['bodyThickness'] for r in observations]);quality=np.array([r['quality'] for r in observations])
    center=float(np.median(thickness[quality>0])) if (quality>0).any() else 1.
    relative=thickness/max(center,.01)
    return [(r['quality']>=policy['minQuality'] and r['glyphCount']>=policy['minGlyphs']
             and r['hollowFraction']<=policy['maxHollow']
             and (r['bodyThickness']>=policy['absoluteThickness']
                  or (r['bodyThickness']>=policy['relativeFloor'] and ratio>=policy['relativeRatio'])))
            for r,ratio in zip(observations,relative)]
