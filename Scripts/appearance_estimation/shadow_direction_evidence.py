"""Repeated source-paint fringe direction, independent of GT and absolute rotation."""
import numpy as np
import cv2
from scipy.ndimage import distance_transform_edt
from source_appearance import lab
from shadow_template_fit import source_core

VERSION='source-shadow-repeated-fringe-direction-v3'


def measure(rgb,mask,prediction,font_pixels,observed_rgb,polygons=None):
    result=dict(version=VERSION,identified=False,GTAtInference=False,
        observedCompositeRGB=observed_rgb,offsetPx=None,intrinsicRGB=None)
    if observed_rgb is None:
        return dict(result,reason='No source-observed colour hypothesis')
    core=np.zeros(mask.shape,bool);colours=[]
    for colour in [prediction['fill']['rgb']]+prediction['fill'].get('colors',[]):
        if tuple(colour) in colours:continue
        colours.append(tuple(colour))
        variant=dict(prediction,fill=dict(prediction['fill'],rgb=colour))
        candidate=source_core(rgb,mask,variant,polygons)
        if candidate is not None and not isinstance(candidate,dict):core|=candidate
        if len(colours)>=12:break
    if not core.any():
        return dict(result,reason='No separated owned glyph paint')
    count,labels,stats,_=cv2.connectedComponentsWithStats(core.astype(np.uint8),8)
    minimum=max(12,float(font_pixels)**2*.005)
    keep=np.r_[False,stats[1:,cv2.CC_STAT_AREA]>=minimum]
    core=keep[labels]
    if not core.any():return dict(result,reason='No independently supported glyph components')
    distance,indices=distance_transform_edt(~core,return_indices=True)
    image_lab=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    colour_distance=np.linalg.norm(image_lab-lab([observed_rgb])[0],axis=2)
    width=float(prediction['outline'].get('widthPx') or 0) if prediction['outline']['present'] else 0
    selected=(colour_distance<=8)&(distance>max(.5,width-.5))&(distance<=width+max(4,min(24,float(font_pixels)*.2)))
    yy,xx=np.where(selected)
    if len(yy)<30:return dict(result,reason='Too few exterior native colour samples',nativeSamples=len(yy))
    dy=yy-indices[0,yy,xx];dx=xx-indices[1,yy,xx]
    unit=np.column_stack([dx,dy])/np.maximum(1e-6,np.hypot(dx,dy))[:,None]
    weights=np.maximum(.05,1-colour_distance[yy,xx]/8)
    center=np.average(unit,axis=0,weights=weights)
    coherence=float(np.linalg.norm(center))
    direction=center/max(coherence,1e-6)
    alignment=np.sum(unit*direction,axis=1)
    forward=float(weights[alignment>=.5].sum())
    reverse=float(weights[alignment<=-.5].sum())
    ratio=forward/max(1.,reverse)
    owners=labels[indices[0,yy,xx],indices[1,yy,xx]]
    component_directions=[];component_weights=[]
    for owner in np.unique(owners):
        owned=owners==owner
        if owned.sum()<8:continue
        local=np.average(unit[owned],axis=0,weights=weights[owned]);strength=float(np.linalg.norm(local))
        if strength>=.15:
            component_directions.append(local/max(strength,1e-6))
            # Disconnected tiny pen strokes are not independent glyph-sized votes.
            # Sublinear native support avoids both fragment-count and large-blob dominance.
            component_weights.append(float(np.sqrt(weights[owned].sum())))
    agreement=float(np.average(np.sum(np.asarray(component_directions)*direction,axis=1)>=.5,
        weights=component_weights)) if component_directions else 0.
    accepted=coherence>=.25 and ratio>=2 and len(component_directions)>=3 and agreement>=.6
    result.update(identified=bool(accepted),reason='Repeated directional source fringe' if accepted else 'Insufficient repeated directional support',
        nativeSamples=len(yy),directionCoherence=coherence,forwardReverseSupportRatio=ratio,
        independentComponents=len(component_directions),componentAgreement=agreement,
        directionUnitXY=direction.tolist(),fontPixels=float(font_pixels),observedFillHypotheses=len(colours),
        note='Direction evidence only; source outline width and local background can obscure true displacement magnitude')
    return result
