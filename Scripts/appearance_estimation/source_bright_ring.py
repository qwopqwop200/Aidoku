"""Native dark-ring hypotheses for bright fill that merges with the global ground."""
from collections import defaultdict
import cv2
import numpy as np
from scipy import ndimage
from source_appearance import lab

VERSION='source-local-bright-interior-ring-v2'


def eligible(prediction):
    if not prediction['outline']['present']:return False
    f,b=lab([prediction['fill']['rgb'],prediction['background']['rgb']])
    return bool(f[0]>=85 and b[0]>=85 and np.linalg.norm(f-b)<=10)


def family_mask(image,colour):
    c=lab([colour])[0];chroma=np.linalg.norm(c[1:]);pc=np.linalg.norm(image[:,:,1:],axis=2)
    if chroma>=8:
        cosine=np.einsum('ijk,k->ij',image[:,:,1:],c[1:])/np.maximum(pc*chroma,1e-6)
        return (cosine>=.9)&(pc>=max(5,chroma*.2))&(np.abs(image[:,:,0]-c[0])<=20)
    return (np.linalg.norm(image[:,:,1:]-c[1:],axis=2)<=8)&(np.abs(image[:,:,0]-c[0])<=15)


def hole_family(a,b):
    ca,cb=np.linalg.norm(a[1:]),np.linalg.norm(b[1:])
    if ca>=8 and cb>=8:return abs(a[0]-b[0])<=20 and float(np.dot(a[1:],b[1:])/(ca*cb))>=.9
    return np.linalg.norm(a-b)<=15


def propose(rgb,mask,polygons,font,colours,prediction):
    out=dict(version=VERSION,eligible=eligible(prediction),proposals=[],GTAtInference=False,contextExpanded=False)
    if not out['eligible']:return out
    image=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB);h,w=mask.shape
    owned=np.ones((h,w),np.uint8)
    if polygons:
        owned[:]=0;cv2.fillPoly(owned,[np.rint(p).astype(np.int32) for p in polygons],1)
    seeded=mask.astype(bool)&owned.astype(bool);minimum=max(12,font*.3);proposals=[]
    for ci,colour in enumerate(colours):
        cl=lab([colour])[0]
        if cl[0]>80:continue
        native=family_mask(image,colour)
        closed=cv2.morphologyEx(native.astype(np.uint8),cv2.MORPH_CLOSE,np.ones((3,3),np.uint8))>0
        n,labels,stats,_=cv2.connectedComponentsWithStats(closed.astype(np.uint8),connectivity=8)
        valid=[]
        for label in range(1,n):
            x,y,cw,ch,area=map(int,stats[label])
            if area<max(20,font):continue
            ring=labels==label;raw=ring&native;raw_fraction=float(raw.sum()/max(1,ring.sum()))
            if raw_fraction<.75 or float(mask[raw].mean())<.65:continue
            filled=ndimage.binary_fill_holes(ring);holes=filled&~ring
            if not holes.any():continue
            width=cv2.distanceTransform((~holes).astype(np.uint8),cv2.DIST_L2,5)
            width_q75=float(np.quantile(width[raw],.75))
            if width_q75>max(3,font*.12):continue
            nh,hlabels,hstats,_=cv2.connectedComponentsWithStats(holes.astype(np.uint8),connectivity=8)
            for hole_id in range(1,nh):
                ha=int(hstats[hole_id,4])
                if ha<minimum:continue
                hole=hlabels==hole_id
                if (hole&seeded).sum()<minimum or float(seeded[hole].mean())<.5:continue
                pixels=image[hole];median=np.median(pixels,axis=0)
                if median[0]-cl[0]<20:continue
                # A contour is a narrow surrounding band, not the coloured bulk of a sign panel.
                distance=cv2.distanceTransform((~hole).astype(np.uint8),cv2.DIST_L2,5)
                nearby=raw&(distance<=max(3,font*.12))
                if nearby.sum()<12:continue
                ry,rx=np.where(nearby)
                if rx.min()<2 or ry.min()<2 or rx.max()>=w-2 or ry.max()>=h-2:continue
                yy,xx=np.where(hole);center=np.array([float(xx.mean()),float(yy.mean())])
                by,bx=np.where(nearby);angles=np.arctan2(by-center[1],bx-center[0]);sectors=((angles+np.pi)/(np.pi/2)).astype(int)%4
                if len(set(sectors.tolist()))<4:continue
                positions=np.flatnonzero(hole);positions=positions[np.linspace(0,len(positions)-1,min(128,len(positions))).astype(int)]
                ringpos=np.flatnonzero(nearby);ringpos=ringpos[np.linspace(0,len(ringpos)-1,min(256,len(ringpos))).astype(int)]
                valid.append(dict(centre=center.tolist(),medianLab=median.tolist(),nativeArea=ha,component=label,hole=hole_id,
                    corePositions=positions.tolist(),ringPositions=ringpos.tolist(),rawRingFraction=raw_fraction,nativeRingWidthQ75=width_q75))
        groups=[]
        for hole in valid:
            # Deduplicate identical native hole support if a closure path was revisited.
            if any(hole['corePositions']==old['corePositions'] for g in groups for old in g):continue
            group=next((g for g in groups if all(hole_family(np.array(v['medianLab']),np.array(hole['medianLab'])) for v in g)),None)
            if group is None:groups.append([hole])
            else:group.append(hole)
        for group in groups:
            if len(group)<3:continue
            ringpos=sorted(set(p for hole in group for p in hole['ringPositions']))
            corepos=sorted(set(p for hole in group for p in hole['corePositions']))
            pixels=rgb.reshape(-1,3)[ringpos];delta=np.linalg.norm(lab(pixels)-cl,axis=1)
            close=delta<=8
            if close.sum()<12:continue
            support=float(close.mean());actual=pixels[close];med=np.median(lab(actual),axis=0);medoid=int(np.argmin(np.linalg.norm(lab(actual)-med,axis=1)));observed=actual[medoid].astype(int).tolist();native_position=int(np.asarray(ringpos)[np.flatnonzero(close)[medoid]])
            proposals.append(dict(candidateIndex=ci,rgb=observed,candidateRGB=colour,holes=group,coreCount=len(group),
                nativeColourSupport=support,nativeRGBWitnessXY=[native_position%w,native_position//w],nativeColourSamples=int(close.sum()),ringPositions=ringpos,corePositions=corepos,
                semanticSupportPending=True))
    proposals.sort(key=lambda p:(p['nativeColourSamples'],p['nativeColourSupport'],p['coreCount']),reverse=True)
    out['proposals']=proposals
    return out


def corroborate(proposal,arrays):
    rf=arrays['rf'].reshape(-1,27).astype(np.float32,copy=False);seg=np.maximum(arrays['segPrimary'],arrays['segBoundary']).ravel();ocr=arrays['ocr'].reshape(-1,8)
    holes=[]
    for hole in proposal['holes']:
        pos=np.asarray(hole['corePositions'],int);owner=np.maximum(rf[pos,15].astype(float)*rf[pos,16],rf[pos,17].astype(float)*rf[pos,18])
        scores=dict(softSegmentationMedian=float(np.median(seg[pos])),rfOwnerMedian=float(np.median(owner)),ocrBoxFraction=float(np.mean(ocr[pos,0]>0)),
            detectorConfidenceMedian=float(np.median(ocr[pos,2][ocr[pos,1]>0])) if (ocr[pos,1]>0).any() else None)
        scores['confirmed']=scores['softSegmentationMedian']>=.5 and scores['rfOwnerMedian']>=.001 and scores['ocrBoxFraction']>=.8 and (scores['detectorConfidenceMedian'] is None or scores['detectorConfidenceMedian']>=.2)
        holes.append(scores)
    ring=np.asarray(proposal['ringPositions'],int);ring_seg=float(np.median(seg[ring]))
    accepted=sum(h['confirmed'] for h in holes)>=3 and ring_seg>=.5
    return dict(accepted=bool(accepted),holes=holes,ringSoftSegmentationMedian=ring_seg,GTAtInference=False,
        semantics='Topology plus direct source text/RF/soft-pixel/OCR ownership. Raw absolute-colour pixel-role predictions are not relabelled as certainty.')
