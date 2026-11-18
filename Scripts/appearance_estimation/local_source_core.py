"""Experimental local native-edge fallback for globally low-contrast source paint."""
import cv2
import numpy as np
from source_appearance import lab
from shadow_template_fit import source_core

VERSION='source-locally-supported-fill-core-v1'


def extract(rgb,mask,prediction,polygons=None,font_pixels=None):
    original=source_core(rgb,mask,prediction,polygons)
    evidence=dict(version=VERSION,usedLocalFallback=False,GTAtInference=False,contextExpanded=False)
    if original is not None and not isinstance(original,dict):return original,evidence
    fill=lab([prediction['fill']['rgb']])[0]
    global_contrast=float(np.linalg.norm(fill-lab([prediction['background']['rgb']])[0]))
    if prediction['outline']['present'] or global_contrast>=8:
        return original,dict(evidence,reason='Original failure is not the unoutlined global-background shortcut')
    h,w=mask.shape
    owned=np.ones((h,w),np.uint8)
    if polygons:
        owned[:]=0;cv2.fillPoly(owned,[np.rint(p).astype(np.int32) for p in polygons],1)
    il=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    delta=np.linalg.norm(il-fill,axis=2)
    similar=(delta<=max(3,min(18,global_contrast*.35)))&mask.astype(bool)
    count,labels,stats,_=cv2.connectedComponentsWithStats(similar.astype(np.uint8),connectivity=8)
    f=float(font_pixels or min(h,w));minimum=max(12,f*f*.005)
    result=np.zeros((h,w),bool);accepted=[];censored=0
    for identity in range(1,count):
        x,y,cw,ch,area=map(int,stats[identity])
        component=labels==identity
        if area<minimum or (component&owned.astype(bool)).sum()<3:continue
        if x<3 or y<3 or x+cw+3>w or y+ch+3>h:
            censored+=1;continue
        ring=(cv2.dilate(component.astype(np.uint8),np.ones((7,7),np.uint8))>0)&~similar
        if ring.sum()<8:continue
        lower=float(np.quantile(delta[ring],.25));median=float(np.median(delta[ring]))
        if lower<3 or median<8:continue
        result|=component
        accepted.append(dict(nativePixels=area,lowerBoundaryDeltaE=lower,medianBoundaryDeltaE=median))
    evidence.update(globalFillBackgroundDeltaE=global_contrast,finiteContrastingComponents=accepted,
        censoredComponents=censored,nativeCorePixels=int(result.sum()))
    if len(accepted)<3 or result.sum()<20:
        return None,dict(evidence,reason='Insufficient repeated finite local boundary support')
    evidence.update(usedLocalFallback=True,reason='Repeated native fill components contrast against their own local exterior')
    return result,evidence
