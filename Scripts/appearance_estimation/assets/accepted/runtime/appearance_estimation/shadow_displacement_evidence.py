"""Categorical source-paint displacement, validated across independent components."""
import cv2
import numpy as np
from scipy.ndimage import distance_transform_edt
from source_appearance import lab
from shadow_template_fit import source_core

VERSION='source-shadow-component-displacement-v2'


def shifted(array,dx,dy):
    h,w=array.shape;out=np.zeros_like(array)
    x0=max(0,dx);x1=min(w,w+dx);y0=max(0,dy);y1=min(h,h+dy)
    if x1>x0 and y1>y0:out[y0:y1,x0:x1]=array[y0-dy:y1-dy,x0-dx:x1-dx]
    return out


def estimate(rgb,mask,prediction,font_pixels,observed_rgb,polygons=None):
    result=dict(version=VERSION,identified=False,offsetPx=None,observedCompositeRGB=None,
        intrinsicRGB=None,GTAtInference=False,contextExpanded=False)
    if observed_rgb is None:return dict(result,reason='No observed source-colour hypothesis')
    core=source_core(rgb,mask,prediction,polygons)
    if core is None or isinstance(core,dict):return dict(result,reason='No separated owned glyph core')
    n,labels,stats,_=cv2.connectedComponentsWithStats(core.astype(np.uint8),connectivity=8)
    ids=[i for i in range(1,n) if stats[i,cv2.CC_STAT_AREA]>=max(12,font_pixels**2*.005)]
    ids=sorted(ids,key=lambda i:-stats[i,cv2.CC_STAT_AREA])[:12]
    if len(ids)<3:return dict(result,reason='Fewer than three independent source components')
    width=float(prediction['outline'].get('widthPx') or 0) if prediction['outline']['present'] else 0
    radius=max(3,min(12,round(font_pixels*.15)))
    distance,nearest=distance_transform_edt(~core,return_indices=True)
    owners=labels[nearest[0],nearest[1]]
    body=distance<=width
    il=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    delta=np.linalg.norm(il-lab([observed_rgb])[0],axis=2)
    target=(delta<=8)&(distance>max(.5,width-.5))&(distance<=width+radius+2)
    components=[];censored=0
    for identity in ids:
        x,y,w,h,_=stats[identity]
        pad=int(np.ceil(width))+radius+2
        # Never score a translated silhouette against unobserved crop exterior.
        if x-pad<0 or y-pad<0 or x+w+pad>mask.shape[1] or y+h+pad>mask.shape[0]:
            censored+=1;continue
        x0,y0=max(0,int(x)-pad),max(0,int(y)-pad)
        x1,y1=min(mask.shape[1],int(x+w)+pad),min(mask.shape[0],int(y+h)+pad)
        local=(labels[y0:y1,x0:x1]==identity)
        local_body=distance_transform_edt(~local)<=width
        observed=target[y0:y1,x0:x1]&(owners[y0:y1,x0:x1]==identity)
        if observed.sum()<8:continue
        components.append((local_body,body[y0:y1,x0:x1],observed))
    if len(components)<3:return dict(result,reason='Insufficient component-local observed paint',components=len(components),censoredComponents=censored)
    offsets=[(dx,dy) for dy in range(-radius,radius+1) for dx in range(-radius,radius+1) if dx or dy]
    scores=np.zeros((len(components),len(offsets)))
    for row,(local_body,occlusion,observed) in enumerate(components):
        count=int(observed.sum())
        for col,(dx,dy) in enumerate(offsets):
            expected=shifted(local_body,dx,dy)&~occlusion
            overlap=int((expected&observed).sum())
            scores[row,col]=2*overlap/max(1,int(expected.sum())+count)
    # Interleaved area order avoids choosing an offset from the validation components.
    train=np.arange(len(components))%2==0;validation=~train
    selected=int(scores[train].mean(0).argmax());dx,dy=offsets[selected]
    opposite=offsets.index((-dx,-dy))
    train_score=float(scores[train,selected].mean());validation_score=float(scores[validation,selected].mean())
    train_margin=train_score/max(.01,float(scores[train,opposite].mean()))
    validation_margin=validation_score/max(.01,float(scores[validation,opposite].mean()))
    agreement=float(np.mean(scores[:,selected]>=.25))
    accepted=train_score>=.25 and validation_score>=.25 and train_margin>=2 and validation_margin>=1.5 and agreement>=.6
    result.update(identified=bool(accepted),reason='Component-held-out categorical displacement' if accepted else 'Displacement does not repeat on held-out source components',
        components=len(components),censoredComponents=censored,trainingComponents=int(train.sum()),validationComponents=int(validation.sum()),
        candidateOffsetPx=[dx,dy],sourceTrainingF1=train_score,sourceValidationF1=validation_score,
        trainingOppositeRatio=train_margin,validationOppositeRatio=validation_margin,
        componentAgreement=agreement,searchRadiusPx=radius,
        offsetPx=[dx,dy] if accepted else None,observedCompositeRGB=observed_rgb if accepted else None,
        note='Observed categorical paint displacement; no intrinsic opacity or blur identification')
    return result
