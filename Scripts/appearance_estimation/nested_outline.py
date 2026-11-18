"""Source-only bounded colour-ring topology, including an outer ring sharing the fill colour."""
import cv2
import numpy as np
from scipy import ndimage
from source_appearance import lab

VERSION='bounded-source-colour-ring-v2'


def measure(rgb,mask,prediction,font_pixels,polygons=None):
    h,w=mask.shape
    if rgb.shape!=(h,w,3):raise ValueError('RGB/mask shape mismatch')
    image=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    fill_lab,outline_lab=lab([prediction['fill']['rgb'],prediction['outline']['rgb']])
    result=dict(version=VERSION,reliable=False,GTAtInference=False,inputContextExpanded=False)
    if np.linalg.norm(fill_lab-outline_lab)<25:return result
    fill=((image-fill_lab)**2).sum(2)<=10**2
    ring=((image-outline_lab)**2).sum(2)<=8**2
    roi=np.ones((h,w),np.uint8)
    if polygons:
        roi[:]=0;cv2.fillPoly(roi,[np.rint(p).astype(np.int32) for p in polygons],1)
    count,labels,stats,_=cv2.connectedComponentsWithStats(ring.astype(np.uint8),connectivity=8)
    owned_fill=fill&mask.astype(bool)&roi.astype(bool)
    fill_near=cv2.dilate(fill.astype(np.uint8),cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(7,7))).astype(bool)
    hole_count=0
    candidates=[];all_core=np.zeros((h,w),bool);all_ring=np.zeros((h,w),bool)
    for i in range(1,count):
        x,y,cw,ch,area=map(int,stats[i])
        if x==0 or y==0 or x+cw>=w or y+ch>=h or area<max(20,font_pixels):continue
        local=labels[y:y+ch,x:x+cw]==i
        filled=ndimage.binary_fill_holes(local)
        rectangularity=float(filled.mean())
        if rectangularity>.8:continue
        holes=filled&~local
        core=holes&fill[y:y+ch,x:x+cw]
        seeds=core&owned_fill[y:y+ch,x:x+cw]
        if seeds.sum()<max(12,font_pixels*.3) or core.sum()/max(1,holes.sum())<.5:continue
        component=labels==i;body=ndimage.binary_fill_holes(component)
        exterior=cv2.dilate(body.astype(np.uint8),np.ones((3,3),np.uint8)).astype(bool)&~body
        supported=float(fill_near[exterior].mean()) if exterior.any() else 0
        if supported<.65:continue
        n,_,hole_stats,_=cv2.connectedComponentsWithStats(core.astype(np.uint8),8)
        hole_count+=int(np.sum(hole_stats[1:,4]>=max(12,font_pixels*.3)))
        all_core[y:y+ch,x:x+cw]|=core;all_ring|=component
        candidates.append(dict(bounds=[x,y,x+cw,y+ch],fillPixels=int(core.sum()),ringPixels=area,exteriorSameFillSupport=supported,filledComponentRectangularity=rectangularity))
    result['candidateCount']=len(candidates);result['enclosedCoreCount']=hole_count;result['candidates']=candidates
    if hole_count<3:return result
    coverage=float((all_core&owned_fill).sum()/max(1,owned_fill.sum()))
    if coverage<.35:return result
    result.update(reliable=True,ownedFillEnclosedFraction=coverage,ringRGB=prediction['outline']['rgb'],
                  exteriorRGB=prediction['fill']['rgb'],corePixels=int(all_core.sum()))
    return result



def recover_presence(rgb,mask,prediction,font_pixels,polygons=None):
    """Source-only postprocessor. Classifier probability remains raw, never relabelled as certainty."""
    import copy
    result=copy.deepcopy(prediction)
    if result['outline']['present']:return result
    evidence=measure(rgb,mask,result,font_pixels,polygons)
    if evidence['reliable']:
        result['outline'].update(present=True,classifierPresent=False,
            presenceDecision='bounded-source-contour-recovery',nestedContourEvidence=evidence,
            probabilitySemantics='Raw classifier probability before source topology correction')
    return result
