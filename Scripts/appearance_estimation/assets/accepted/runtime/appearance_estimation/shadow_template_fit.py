"""Fit source shadow geometry to owned glyph silhouettes; no GT lookup or font identity."""
import cv2
import numpy as np
from scipy import ndimage
from scipy.special import ndtr
from scipy.optimize import minimize
from source_appearance import lab

VERSION='source-shadow-silhouette-fit-v4'


def source_core(rgb,mask,prediction,polygons=None):
    h,w=mask.shape
    if rgb.shape!=(h,w,3):raise ValueError('RGB/mask shape mismatch')
    fill=prediction['fill']['rgb'];outline=prediction['outline']['rgb'];outlined=prediction['outline']['present']
    image_lab=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    roi=np.ones((h,w),np.uint8)
    if polygons:
        roi[:]=0;cv2.fillPoly(roi,[np.rint(p).astype(np.int32) for p in polygons],1)
    bg_candidates=prediction['background'].get('colors') or [prediction['background']['rgb']]
    owned=mask.astype(bool)&roi.astype(bool)
    fill_lab=lab([fill])[0]
    bg_contrast=float(np.linalg.norm(fill_lab-lab([prediction['background']['rgb']])[0]))
    tolerance=min(18,max(3,bg_contrast*.35))
    core_delta=((image_lab-fill_lab)**2).sum(2)
    similar=core_delta<=tolerance**2
    chroma=float(np.linalg.norm(fill_lab[1:]))
    if chroma>=20:
        pixel_chroma=np.linalg.norm(image_lab[:,:,1:],axis=2)
        cosine=(image_lab[:,:,1:]*fill_lab[1:]).sum(2)/np.maximum(1e-6,pixel_chroma*chroma)
        similar|=(cosine>=.96)&(pixel_chroma>=max(15,chroma*.4))&(np.abs(image_lab[:,:,0]-fill_lab[0])<25)
    core=similar&mask.astype(bool)
    if outlined:
        ring=((image_lab-lab([outline])[0])**2).sum(2)<=8**2
        closed=cv2.morphologyEx(ring.astype(np.uint8),cv2.MORPH_CLOSE,np.ones((3,3),np.uint8))>0
        enclosed=core&(ndimage.binary_fill_holes(closed)&~closed)
        if (enclosed&roi.astype(bool)).sum()>=max(12,(core&roi.astype(bool)).sum()*.25):core=enclosed
    elif bg_contrast<8:
        return None
    # Boxes localise ownership; they must never crop glyphs or their exterior shadows.
    count,labels=cv2.connectedComponents(core.astype(np.uint8),connectivity=8)
    seeds=np.bincount(labels[roi.astype(bool)],minlength=count)
    keep=seeds>=3;keep[0]=False;core=keep[labels]
    if core.sum()<20:return dict(version=VERSION,identified=False,reason='Too few owned fill pixels')
    return core


def estimate(rgb,mask,prediction,font_pixels,polygons=None):
    core=source_core(rgb,mask,prediction,polygons)
    if core is None:
        return dict(version=VERSION,identified=False,reason='Fill merges with background and no separating contour is observed')
    if isinstance(core,dict):return core
    return fit_core(rgb,core,prediction,font_pixels)


def fit_core(rgb,core,prediction,font_pixels,other_core=None):
    h,w=core.shape
    outlined=prediction['outline']['present'];outline=prediction['outline']['rgb']
    image_lab=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    bg_candidates=prediction['background'].get('colors') or [prediction['background']['rgb']]
    radius=max(8,min(36,round(font_pixels*.25)))
    distance=cv2.distanceTransform((~core).astype(np.uint8),cv2.DIST_L2,5)
    # A high-recall removal mask also contains genuine background; it is not an exact glyph silhouette.
    guard=max(4,min(float(prediction['outline'].get('widthPx') or 0),font_pixels*.15)+2)
    context=(distance>guard)&(distance<radius*1.5)
    if other_core is not None:
        other_distance=cv2.distanceTransform((~other_core).astype(np.uint8),cv2.DIST_L2,5)
        context&=other_distance>radius*.6
    bg_labs=lab(bg_candidates);support=[int((context&(((image_lab-c)**2).sum(2)<=8**2)).sum()) for c in bg_labs]
    if max(support,default=0)<32:return dict(version=VERSION,identified=False,reason='No observed exterior background plane')
    chosen=int(np.argmax(support));matching=context&(((image_lab-bg_labs[chosen])**2).sum(2)<=8**2)
    background=np.median(rgb[matching],axis=0).astype(float)
    ratios=(background-rgb.astype(float))/np.maximum(background,32)
    data=np.clip(np.median(ratios,axis=2),0,.95)
    neutral=(np.ptp(ratios,axis=2)<=.1)
    outline_paint=np.zeros((h,w),bool)
    if outlined:outline_paint=((image_lab-lab([outline])[0])**2).sum(2)<=6**2
    # Observed contour paint occludes the shadow, even when that contour itself is dark or chromatic.
    data[outline_paint]=0
    valid=(distance>0)&(distance<radius)&(neutral|outline_paint)
    if outlined:valid&=(distance>2)|outline_paint
    if other_core is not None:valid&=other_distance>radius*.6
    if (data[valid]>.03).sum()<32:return dict(version=VERSION,identified=False,reason='No measurable neutral fringe outside owned fill')
    y,x=np.where(valid)
    if len(y)>12000:
        ids=np.linspace(0,len(y)-1,12000).astype(int);y,x=y[ids],x[ids]
    target=data[y,x];xx=x.astype(np.float32)[None,:];yy=y.astype(np.float32)[None,:]
    near_scale=max(3,float(prediction['outline'].get('widthPx') or 0)+font_pixels*.05)
    weights=np.exp(-.5*(distance[y,x]/near_scale)**2)
    maximum=min(12,max(4,font_pixels*.15));maximum_width=min(16,max(4,font_pixels*.15)) if outlined else 0
    def score(parameters,detail=False):
        width,dx,dy,sigma=map(float,parameters)
        if not outlined:width=0
        body=ndtr((width+.5-distance)/.5).astype(np.float32);body[core]=1
        blurred=cv2.GaussianBlur(body,(0,0),sigma)
        shifted=cv2.remap(blurred,xx-dx,yy-dy,cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT).ravel()
        template=shifted*(1-body[y,x])
        alpha=float(np.clip(np.dot(weights*template,target)/max(1e-8,np.dot(weights*template,template)),0,.95))
        residual=alpha*template-target
        # Huber limits unrelated source artwork without changing the pixels.
        absolute=np.abs(residual);cost=float(np.average(np.where(absolute<=.05,.5*residual**2,.05*(absolute-.025)),weights=weights))
        return (cost,alpha,residual,template) if detail else cost
    candidates=[]
    widths=[0] if not outlined else [1,2,4,6]
    for width in widths:
        for sigma in [.7,1.5,3.]:
            for dx,dy in [(2,2),(-2,2),(2,-2),(-2,-2),(0,0)]:
                value=[min(width,maximum_width),dx,dy,sigma];candidates.append((score(value),value))
    best=None
    for _,initial in sorted(candidates,key=lambda p:p[0])[:2]:
        result=minimize(score,initial,method='Powell',bounds=[(0,max(.01,maximum_width)),(-maximum,maximum),(-maximum,maximum),(.35,min(8,maximum))],
            options=dict(maxiter=25,xtol=.04,ftol=1e-5))
        if best is None or result.fun<best.fun:best=result
    cost,alpha,residual,template=score(best.x,True)
    mse=float(np.average(residual**2,weights=weights));energy=float(np.average(target**2,weights=weights));explained=1-mse/max(energy,1e-8)
    width,dx,dy,sigma=map(float,best.x)
    expected=alpha*template>.03
    support=float(weights[expected&(target>.025)].sum()/max(1e-8,weights[expected].sum()))
    identified=explained>=.65 and support>=.75 and alpha>=.03 and max(abs(dx),abs(dy))>=.75 and max(abs(dx),abs(dy))<maximum-.2
    selected=(template>.35)&(target>.025)
    observed=None
    if identified and selected.sum()>=12:
        pixels=rgb[y[selected],x[selected]];brightness=pixels.mean(1);dark=pixels[brightness<=np.quantile(brightness,.25)]
        observed=np.rint(np.median(dark,axis=0)).astype(int).tolist()
    return dict(version=VERSION,identified=bool(identified),offsetPx=[dx,dy] if identified else None,
        observedCompositeRGB=observed,explainedAttenuationEnergy=explained,fitRMSE=mse**.5,
        predictedFringeSupportedFraction=support,diagnosticCandidateOffsetPx=[dx,dy],
        fittedCoreExpansionPx=width if outlined else None,sourceBackgroundRGB=background.astype(int).tolist(),
        conditionalSigmaPx=sigma,conditionalOpacity=alpha,opacity=None,blurRadiusPx=None,
        hypothesis='Black neutral shadow on an observed local background plane; intrinsic opacity and blur remain unidentified',
        inputContextExpanded=False,GTAtInference=False)
