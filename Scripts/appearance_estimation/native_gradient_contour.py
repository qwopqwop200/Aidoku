"""Observed dark finite primary contour around native gradient fill bodies."""
import cv2
import numpy as np
from collections import Counter,defaultdict
from source_appearance import lab

VERSION='native-gradient-body-primary-contour-v3'


def body_from_seed(rgb,xy):
    il=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    x,y=map(int,xy);ff=np.zeros((rgb.shape[0]+2,rgb.shape[1]+2),np.uint8)
    _,_,ff,_=cv2.floodFill(il,ff,(x,y),0,loDiff=(4.,4.,4.),upDiff=(4.,4.,4.),flags=8|cv2.FLOODFILL_MASK_ONLY|(1<<8))
    body=ff[1:-1,1:-1]>0
    if body[0].any() or body[-1].any() or body[:,0].any() or body[:,-1].any():return None
    return body


def profile(rgb,il,body,all_body,origin,normal,depth):
    h,w=body.shape;coordinates=[]
    for t in range(depth+1):
        x,y=np.rint(np.asarray(origin)+normal*t).astype(int)
        if not(0<=x<w and 0<=y<h):return None,'outside-original-crop'
        if not coordinates or coordinates[-1]!=(x,y):coordinates.append((int(x),int(y)))
    first=next((i for i,(x,y) in enumerate(coordinates) if not body[y,x]),None)
    if first is None or first==0 or len(coordinates)-first<5:return None,'insufficient-native-exterior'
    outside=coordinates[first:];before=coordinates[first-1]
    if any(all_body[y,x] for x,y in outside[:5]):return None,'other-observed-fill-body'
    base=il[before[1],before[0]];samples=np.array([il[y,x] for x,y in outside]);colours=np.array([rgb[y,x] for x,y in outside])
    if np.linalg.norm(samples[0]-base)<20:return None,'no-sharp-fill-boundary'
    k=int(np.argmin(samples[:3,0]));drop=float(base[0]-samples[k,0])
    if drop<20:return None,'not-a-dark-primary-band'
    recovery=next((j for j in range(k+1,min(k+4,len(samples)-1)) if samples[j,0]>=base[0]-5
        and samples[j,0]-samples[k,0]>=20 and np.linalg.norm(samples[j]-samples[j+1])<=12),None)
    if recovery is None:return None,'no-sharp-stable-light-exterior'
    if np.linalg.norm(samples[recovery]-samples[recovery-1])<20:return None,'soft-recovery-not-contour'
    if k>0 and np.max(np.linalg.norm(np.diff(np.vstack([base,samples[:k+1]]),axis=0),axis=1))<20:return None,'soft-entry-not-contour'
    band=[dict(rgb=colours[j].astype(int).tolist(),xy=list(outside[j])) for j in range(recovery) if base[0]-samples[j,0]>=20]
    band_lab=lab([v['rgb'] for v in band]);median=np.median(band_lab,axis=0);representative=band[int(np.argmin(np.linalg.norm(band_lab-median,axis=1)))]['rgb']
    return dict(rgb=representative,xy=list(outside[k]),nativeBandColours=band,dropL=drop,
        exteriorRGB=colours[recovery].astype(int).tolist(),nativeBandSamples=recovery,normal=normal.tolist()),None


def measure(rgb,groups,font):
    il=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    bodies=[]
    for gi,group in enumerate(groups):
        for ci,component in enumerate(group):
            body=body_from_seed(rgb,component['seedXY'])
            if body is not None:bodies.append((gi,ci,body))
    all_body=np.zeros(rgb.shape[:2],bool)
    for _,_,body in bodies:all_body|=body
    records=[];reasons=Counter();eligible=0;depth=max(6,min(16,round(font*.2)))
    for identity,(gi,ci,body) in enumerate(bodies):
        inside=cv2.distanceTransform(body.astype(np.uint8),cv2.DIST_L2,5);outside=cv2.distanceTransform((~body).astype(np.uint8),cv2.DIST_L2,5)
        signed=cv2.GaussianBlur(inside-outside,(0,0),1);gy,gx=np.gradient(signed)
        contours,_=cv2.findContours(body.astype(np.uint8),cv2.RETR_EXTERNAL,cv2.CHAIN_APPROX_NONE)
        points=np.concatenate([c[:,0,:] for c in contours]) if contours else np.zeros((0,2),int)
        if len(points)>96:points=points[np.linspace(0,len(points)-1,96).astype(int)]
        for x,y in points:
            normal=-np.array([gx[y,x],gy[y,x]],float);length=np.linalg.norm(normal)
            if length<.2:continue
            normal/=length
            value,reason=profile(rgb,il,body,all_body&~body,(x,y),normal,depth)
            if reason:
                reasons[reason]+=1
                if reason not in ['outside-original-crop','insufficient-native-exterior','other-observed-fill-body','no-sharp-fill-boundary']:eligible+=1
                continue
            eligible+=1;sector=int((np.arctan2(normal[1],normal[0])+np.pi)/(np.pi/2))%4
            value.update(component=identity,group=gi,sector=sector);records.append(value)
    # Each actual source pixel has a single colour vote, retaining all direction/component evidence.
    by_group=defaultdict(list)
    for value in records:by_group[value['group']].append(value)
    clusters=list(by_group.values())
    proposals=[]
    for cluster in clusters:
        unique={tuple(v['xy']):v for v in cluster};sectors={v['sector'] for v in cluster};components={v['component'] for v in cluster}
        by_component=defaultdict(set)
        for v in cluster:by_component[v['component']].add(v['sector'])
        opposing=sum((0 in s and 2 in s) or (1 in s and 3 in s) for s in by_component.values())
        band_pixels={tuple(w['xy']):w['rgb'] for v in cluster for w in v['nativeBandColours']}
        pixels=list(band_pixels.values());ll=lab(pixels);mass=len(unique)
        median=np.median(ll,axis=0);colour=pixels[int(np.argmin(np.linalg.norm(ll-median,axis=1)))]
        support=len(cluster)/max(1,eligible)
        chroma=np.linalg.norm(ll[:,1:],axis=1);chromatic=chroma>=8
        hue_agreement=float(np.linalg.norm(np.mean(ll[chromatic,1:]/chroma[chromatic,None],axis=0))) if chromatic.any() else 1.
        coherent=bool((chromatic.mean()>=.8 and hue_agreement>=.9) or not chromatic.any())
        accepted=coherent and mass>=12 and len(sectors)>=3 and len(components)>=3 and opposing>=2 and support>=.5
        proposals.append(dict(rgb=colour,accepted=bool(accepted),nativePixels=mass,profiles=len(cluster),support=support,
            components=len(components),sectors=sorted(sectors),opposingComponents=opposing,observedColourSamples=len(pixels),hueAgreement=hue_agreement,colourRolePooling='First bounded dark band per validated gradient fill group; colour variation retained as uncertainty',observedLABQ10Q90=np.quantile(ll,[.1,.9],axis=0).tolist()))
    proposals.sort(key=lambda p:(p['accepted'],p['nativePixels'],p['support']),reverse=True)
    best=next((p for p in proposals if p['accepted']),None)
    return dict(version=VERSION,identified=best is not None,rgb=best['rgb'] if best else None,proposals=proposals,
        finiteFillBodies=len(bodies),eligibleProfiles=eligible,censoring=dict(reasons),GTAtInference=False,sourceContextExpanded=False,
        evidenceSemantics='Repeated native dark band with sharp entry/recovery to a stable lighter exterior; observed RGB, not inferred intrinsic pigment or secondary-ring declaration')
