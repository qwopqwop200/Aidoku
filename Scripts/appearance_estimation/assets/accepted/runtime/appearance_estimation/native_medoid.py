"""Exact native RGB medoid of the largest source foreground component; no labels."""
import cv2
import numpy as np
from scipy.spatial.distance import cdist
from source_appearance import lab
VERSION='largest-source-foreground-exact-native-medoid-v1'
POLICY=dict(minimumComponentPixels=3,connectivity=8,foreground='Owned predicted mask, closer to incumbent fill than any predicted background or present outline',largestTie='native component raster order',medoidTie='lexical RGB',sourceOnly=True,GTAtInference=False)

def medoid(pixels):
    unique,inverse,count=np.unique(np.asarray(pixels,np.uint8),axis=0,return_inverse=True,return_counts=True)
    points=lab(unique).astype(float);weight=count.astype(float)
    if len(unique)==1:return unique[0].astype(int).tolist(),dict(uniqueRGB=1,candidatesExactlyScored=1,prunedByConvexLowerBound=0)
    center=np.average(points,axis=0,weights=weight)
    for _ in range(40):
        distances=np.maximum(np.linalg.norm(points-center,axis=1),1e-9);ww=weight/distances;updated=(points*ww[:,None]).sum(0)/ww.sum()
        if np.linalg.norm(updated-center)<1e-8:break
        center=updated
    first=int(np.linalg.norm(points-center,axis=1).argmin());best_cost=float(cdist(points[first:first+1],points).dot(weight)[0]);best=first
    pending=np.arange(len(points));scored=0
    if len(points)>512:
        # Jensen's inequality gives an admissible lower bound per RGB cluster.
        # Refining bins only prunes candidates; every survivor is scored exactly.
        for width in (32,16,8,4):
            keys=unique.astype(np.int32)//width;_,groups=np.unique(keys,axis=0,return_inverse=True)
            total=np.bincount(groups,weights=weight)
            centers=np.column_stack([np.bincount(groups,weights=weight*points[:,j])/total for j in range(3)])
            survivors=[]
            for start in range(0,len(pending),128):
                ids=pending[start:start+128];lower=cdist(points[ids],centers).dot(total)
                survivors.extend(ids[lower<=best_cost+1e-7*weight.sum()].tolist())
            pending=np.asarray(survivors,int)
            if len(pending)<=512 or len(centers)>len(points)*.5:break
    for start in range(0,len(pending),128):
        ids=pending[start:start+128];costs=cdist(points[ids],points).dot(weight);scored+=len(ids)
        for identity,cost in zip(ids,costs):
            if cost<best_cost or (cost==best_cost and identity<best):best=int(identity);best_cost=float(cost)
    return unique[best].astype(int).tolist(),dict(uniqueRGB=len(unique),candidatesExactlyScored=scored,prunedByConvexLowerBound=len(unique)-len(pending),weightedObjective=best_cost)

def infer(rgb,mask,prediction,polygons):
    if rgb.dtype!=np.uint8 or rgb.shape!=mask.shape+(3,) or mask.dtype!=bool:raise ValueError('Native RGB and predicted mask required')
    roi=np.zeros(mask.shape,np.uint8)
    for poly in polygons:cv2.fillPoly(roi,[np.rint(poly).astype(np.int32)],1)
    owned=mask&roi.astype(bool);image_lab=lab(rgb.reshape(-1,3)).reshape(*mask.shape,3)
    distance=np.linalg.norm(image_lab-lab([prediction['fill']['rgb']])[0],axis=2)
    other=list(prediction['background'].get('colors') or [prediction['background']['rgb']])
    if prediction['outline']['present']:other.append(prediction['outline']['rgb'])
    alternate=np.min([np.linalg.norm(image_lab-c,axis=2) for c in lab(other)],axis=0)
    foreground=owned&(distance<alternate)
    n,labels,stats,_=cv2.connectedComponentsWithStats(foreground.astype(np.uint8),connectivity=8)
    ids=[i for i in range(1,n) if stats[i,cv2.CC_STAT_AREA]>=3]
    if not ids:return None,dict(eligible=False,reason='No finite owned foreground component')
    identity=max(ids,key=lambda i:int(stats[i,cv2.CC_STAT_AREA]));ys,xs=np.where(labels==identity)
    colour,evidence=medoid(rgb[ys,xs]);which=int(np.flatnonzero(np.all(rgb[ys,xs]==colour,axis=1))[0])
    return colour,dict(version=VERSION,eligible=True,component=identity,componentPixels=len(xs),components=len(ids),nativeRGB=colour,nativeXY=[int(xs[which]),int(ys[which])],bounds=stats[identity,:4].astype(int).tolist(),medoid=evidence,GTAtInference=False)
