"""Source-only repeated normal-profile evidence for multiple attached outline rings."""
from collections import defaultdict
import cv2
import numpy as np
from source_appearance import lab
from source_profile_sampling import sample_source,observed_window
from shadow_template_fit import source_core

VERSION='source-normal-outline-rings-v4'


def measure(rgb,mask,prediction,font_pixels,colors,polygons=None):
    result=dict(version=VERSION,reliable=False,layers=[],GTAtInference=False,inputContextExpanded=False)
    if not prediction['outline']['present']:return result
    core=source_core(rgb,mask,prediction,polygons)
    if core is None or isinstance(core,dict):return result
    inside=cv2.distanceTransform(core.astype(np.uint8),cv2.DIST_L2,5)
    outside=cv2.distanceTransform((~core).astype(np.uint8),cv2.DIST_L2,5)
    signed=cv2.GaussianBlur(inside-outside,(0,0),1)
    gy,gx=np.gradient(signed);edge=core&~cv2.erode(core.astype(np.uint8),np.ones((3,3),np.uint8)).astype(bool)
    y,x=np.where(edge)
    if len(y)<40:return result
    if len(y)>1600:
        indices=np.linspace(0,len(y)-1,1600).astype(int);y,x=y[indices],x[indices]
    norm=np.hypot(gx[y,x],gy[y,x]);valid=norm>.2;x=x[valid];y=y[valid];norm=norm[valid]
    dx=-gx[y,x]/norm;dy=-gy[y,x]/norm
    depth=max(8,min(72,int(font_pixels*.3)));steps=np.arange(-4,depth,.5,dtype=np.float32)
    xx=x[:,None].astype(np.float32)+dx[:,None]*steps;yy=y[:,None].astype(np.float32)+dy[:,None]*steps
    sampled,source_valid=sample_source(rgb,xx,yy)
    result['unobservedCoordinateCount']=int((~source_valid).sum())
    result['profileCoordinateCount']=int(source_valid.size)
    # Palette entries stay observed hypotheses; role and repeated radial order provide evidence.
    palette=[prediction['fill']['rgb'],prediction['outline']['rgb']]
    for c in colors:
        if np.min(np.linalg.norm(lab(palette)-lab([c]),axis=1))>10:palette.append(c)
    candidates=lab(palette);samples=cv2.cvtColor(sampled.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    delta=((samples[:,:,None,:]-candidates[None,None,:,:])**2).sum(3)
    labels=delta.argmin(2);labels[(delta.min(2)>10**2)|~source_valid]=-1
    grouped=defaultdict(list);eligible=0
    for i,row in enumerate(labels):
        if 0 not in row[:12]:continue
        # Ignore isolated antialias samples; require finite colour cores in radial order.
        runs=[];start=0
        for j in range(1,len(row)+1):
            if j==len(row) or row[j]!=row[start]:
                if row[start]>=0 and (j-start)*.5>=2:runs.append((int(row[start]),start*.5,j*.5))
                start=j
        if len(runs)<2 or runs[0][0]!=0:continue
        first_index=next((j for j in range(1,len(runs)) if runs[j][0]==1),None)
        if first_index is None or runs[first_index][1]-runs[0][2]>4:continue
        eligible+=1
        if len(runs)<=first_index+1:continue
        first,second=runs[first_index:first_index+2]
        if second[0] in [0,1] or second[1]-first[2]>2:continue
        if second[2]>=len(steps)*.5-1 or second[2]-second[1]<1.5:continue
        # Returning immediately to fill indicates a counter or neighbouring glyph, not an exterior ring.
        if len(runs)>first_index+2 and runs[first_index+2][0] in [0,1]:continue
        transition=second[1]-first[2]
        widths=[first[2]-first[1]+.5*(first[1]-runs[0][2]+transition),
                second[2]-second[1]+.5*transition+.5]
        if max(widths)>min(widths)*4:continue
        sector=int((np.arctan2(dy[i],dx[i])+np.pi)/(np.pi/2))%4
        end=int(second[2]*2)
        if not observed_window(source_valid,i,end):continue
        contrast=float(np.linalg.norm(samples[i,min(len(row)-1,end+2)]-samples[i,max(0,end-2)]))
        grouped[second[0]].append((widths,sector,contrast))
    result['eligibleProfiles']=eligible
    if not grouped:return result
    color,evidence=max(grouped.items(),key=lambda pair:len(pair[1]))
    widths=np.array([r[0] for r in evidence]);sectors=len({r[1] for r in evidence});support=len(evidence)/max(1,eligible)
    result.update(agreeingProfiles=len(evidence),directionSectors=sectors,profileSupport=support,
                  medianOuterBoundaryDeltaE=float(np.median([r[2] for r in evidence])))
    if len(evidence)<30 or sectors<3 or support<.1 or result['medianOuterBoundaryDeltaE']<20:return result
    centers=np.median(widths,axis=0);dispersion=np.quantile(np.abs(widths-centers),.75,axis=0)
    if np.any(dispersion>np.maximum(1.5,centers*.5)):return result
    image_lab=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    second_paint=((image_lab-candidates[color])**2).sum(2)<=10**2
    refined_core=core&~second_paint
    ring_distance=cv2.distanceTransform((~refined_core).astype(np.uint8),cv2.DIST_L2,5)
    near=(ring_distance>=centers[0])&(ring_distance<=centers.sum())
    far=(ring_distance>=centers.sum()+3)&(ring_distance<=centers.sum()+centers[1]+3)
    near_density=float(second_paint[near].mean()) if near.any() else 0
    far_density=float(second_paint[far].mean()) if far.any() else 1
    result.update(secondRingNearDensity=near_density,secondRingFarDensity=far_density,
                  secondRingExteriorPersistence=far_density/max(.001,near_density))
    if near_density<.15 or result['secondRingExteriorPersistence']>.5:return result
    result.update(reliable=True,totalWidthPx=float(centers.sum()),layers=[dict(rgb=palette[k],widthPx=float(width),
        observedWidthInterquartileRangePx=np.quantile(widths[:,i],[.25,.75]).tolist()) for i,(k,width) in enumerate(zip([1,color],centers))])
    return result



def attach(prediction,evidence):
    """Add observable physical layers without silently reinterpreting legacy nominal width GT."""
    if evidence['reliable']:
        prediction['outline'].update(observedLayers=evidence['layers'],
            totalObservedRingWidthPx=evidence['totalWidthPx'],sourceRingEvidence=evidence,
            layerWidthSemantics='Source-pixel ring thickness including half of adjacent antialias transitions')
    return prediction
