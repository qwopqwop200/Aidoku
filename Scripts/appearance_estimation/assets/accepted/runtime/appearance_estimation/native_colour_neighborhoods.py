"""Bounded native-pixel colour neighborhoods without RGB-cube membership boundaries."""
import numpy as np
from source_appearance import lab

VERSION='native-perceptual-colour-neighborhood-v1'


def dominant_neighborhood(colours,ratio=2.):
    if not colours:return None
    if len(colours)==1 or colours[0]['observedMass']>=ratio*colours[1]['observedMass']:return colours[0]
    return None


def clusters(pixels,weights,limit=3,radius=8.):
    pixels=np.asarray(pixels,np.uint8).reshape(-1,3);weights=np.asarray(weights,float)
    if len(pixels)!=len(weights) or not np.isfinite(weights).all() or (weights<0).any():
        raise ValueError('Native colour weights must match observed pixels and be finite/nonnegative')
    if len(pixels)<8 or weights.sum()<=0:return []
    # Cube bins only nominate bounded native seeds; membership uses all native LAB pixels.
    code=(pixels.astype(np.int32)//16)@np.array([256,16,1]);mass=np.bincount(code,weights=weights,minlength=4096)
    native_lab=lab(pixels);seeds=[]
    for identity in np.argsort(-mass)[:64]:
        ids=np.flatnonzero(code==identity)
        if not len(ids):continue
        median=np.median(native_lab[ids],axis=0)
        seeds.append(int(ids[np.argmin(((native_lab[ids]-median)**2).sum(1))]))
    available=np.ones(len(pixels),bool);result=[];total=float(weights.sum())
    for _ in range(limit):
        best=None
        for seed in seeds:
            member=available&(np.linalg.norm(native_lab-native_lab[seed],axis=1)<=radius)
            value=float(weights[member].sum())
            if member.sum()>=8 and value>=max(1.,.05*total) and (best is None or value>best[0]):best=(value,member)
        if best is None:break
        value,member=best;ids=np.flatnonzero(member)
        centre=np.average(native_lab[ids],axis=0,weights=weights[ids])
        chosen=int(ids[np.argmin(((native_lab[ids]-centre)**2).sum(1))])
        result.append(dict(rgb=pixels[chosen].astype(int).tolist(),samples=len(ids),observedMass=value/total,
            nativeActualSample=True,perceptualRadius=float(radius)))
        available[member]=False
    return result
