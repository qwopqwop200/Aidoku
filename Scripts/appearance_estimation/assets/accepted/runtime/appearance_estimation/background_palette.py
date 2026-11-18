"""Describe spatially mixed background colours using observed, non-text source context."""
import cv2
import numpy as np
from source_appearance import lab,role_features

VERSION='observed-background-palette-v1'


def source_features(rgb,own_mask,context_mask,packet,prediction):
    """No GT: context_mask optionally excludes other predicted text in the same crop."""
    if own_mask.shape!=rgb.shape[:2] or context_mask.shape!=own_mask.shape:
        raise ValueError('Source context mask shape mismatch')
    colors=lab(packet['colors']);pixels=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    visible=~context_mask.astype(bool);near_own=~own_mask.astype(bool)
    # Bound the sampling cost while retaining original RGB candidates and output dimensions.
    step=max(1,rgb.shape[0]*rgb.shape[1]//150000)
    sample=pixels.reshape(-1,3)[::step];source=visible.ravel()[::step]
    distance=((sample[:,None,:]-colors[None,:,:])**2).sum(2)
    assigned=distance.argmin(1)
    mass=np.bincount(assigned[source],minlength=len(colors)).astype(float)
    mass/=max(1,mass.sum())
    f=role_features(packet,'background',prediction['fillIndex'],prediction['outlineIndex'])
    extra=[]
    border=np.zeros(visible.shape,bool);border[[0,-1],:]=True;border[:,[0,-1]]=True
    for i,c in enumerate(colors):
        close=((pixels-c)**2).sum(2)<=100
        extra.append([mass[i],float((close&visible).sum()/max(1,visible.sum())),
            float((close&visible&border).sum()/max(1,(visible&border).sum())),
            float((close&near_own).sum()/max(1,near_own.sum())),float(visible.mean())])
    return np.column_stack([f,np.asarray(extra)]).astype(np.float32),mass


def select(packet,prediction,mass,scores,threshold,max_colors):
    candidates=[i for i in np.argsort(-scores) if scores[i]>=threshold]
    if not candidates:candidates=[int(np.argmax(scores))]
    color_lab=lab(packet['colors']);chosen=[]
    for i in candidates:
        if all(np.linalg.norm(color_lab[i]-color_lab[j])>=6 for j in chosen):chosen.append(int(i))
        if len(chosen)>=max_colors:break
    return chosen


def describe(packet,prediction,features,mass,model):
    if model.get('version',VERSION)!=VERSION:
        raise ValueError('Background palette model/feature contract mismatch')
    scores=model['classifier'].predict_proba(features)[:,1]
    chosen=select(packet,prediction,mass,scores,model['threshold'],model['maxColors'])
    colors=lab(packet['colors']);mapping=((colors[:,None,:]-colors[chosen][None,:,:])**2).sum(2).argmin(1)
    weights=np.bincount(mapping,weights=mass,minlength=len(chosen));total=weights.sum()
    if total:weights/=total
    return dict(colors=[packet['colors'][i] for i in chosen],observedContextWeights=weights.tolist() if total else None,
        candidateScores=[float(scores[i]) for i in chosen],representation='observed-context-palette',
        insufficientObservedContext=not bool(total),
        intrinsicBackgroundUnderGlyphsRecovered=False,version=VERSION)
