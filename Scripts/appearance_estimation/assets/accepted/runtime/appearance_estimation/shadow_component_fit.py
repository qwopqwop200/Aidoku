"""Experimental source-only shadow consensus across independently fitted glyph components."""
import cv2
import numpy as np
from shadow_template_fit import source_core,fit_core

VERSION='source-shadow-component-consensus-v1'


def estimate(rgb,mask,prediction,font_pixels,polygons=None):
    core=source_core(rgb,mask,prediction,polygons)
    if core is None or isinstance(core,dict):
        return dict(version=VERSION,identified=False,reason='No separated owned glyph core')
    count,labels,stats,_=cv2.connectedComponentsWithStats(core.astype(np.uint8),connectivity=8)
    minimum=max(20,font_pixels*font_pixels*.005)
    components=[i for i in range(1,count) if stats[i,cv2.CC_STAT_AREA]>=minimum]
    components=sorted(components,key=lambda i:-stats[i,cv2.CC_STAT_AREA])[:8]
    padding=max(20,min(72,round(font_pixels*.6)));h,w=core.shape;fits=[]
    for component in components:
        x,y,cw,ch,area=map(int,stats[component])
        x0,y0=max(0,x-padding),max(0,y-padding);x1,y1=min(w,x+cw+padding),min(h,y+ch+padding)
        local_labels=labels[y0:y1,x0:x1]
        result=fit_core(rgb[y0:y1,x0:x1],local_labels==component,prediction,font_pixels,
                        other_core=(local_labels!=0)&(local_labels!=component))
        fits.append(dict(area=area,bounds=[x0,y0,x1,y1],fit=result))
    supported=[r for r in fits if r['fit'].get('identified')]
    result=dict(version=VERSION,identified=False,offsetPx=None,observedCompositeRGB=None,
                opacity=None,blurRadiusPx=None,components=fits,GTAtInference=False,
                inputContextExpanded=False,reason='Insufficient independent component agreement')
    if len(supported)<3:return result
    shifts=np.array([r['fit']['offsetPx'] for r in supported]);distance=np.linalg.norm(shifts[:,None,:]-shifts[None,:,:],axis=2)
    tolerance=max(1.,min(2.,font_pixels*.025));agree=distance<=tolerance
    best=int(np.argmax(agree.sum(1)));accepted=agree[best]
    if accepted.sum()<3 or accepted.mean()<.6:return result
    weights=np.sqrt([r['area'] for r in supported])[accepted]
    center=np.average(shifts[accepted],axis=0,weights=weights)
    colours=[r['fit']['observedCompositeRGB'] for r,keep in zip(supported,accepted) if keep and r['fit']['observedCompositeRGB'] is not None]
    result.update(identified=True,offsetPx=center.tolist(),reason=None,agreeingComponents=int(accepted.sum()),
                  observedCompositeRGB=np.rint(np.median(colours,axis=0)).astype(int).tolist() if len(colours)>=3 else None)
    return result
