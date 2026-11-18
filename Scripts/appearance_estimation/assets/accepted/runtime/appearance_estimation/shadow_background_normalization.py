"""Conditional black-shadow colour normalized to a source-predicted background."""
import numpy as np
from source_appearance import lab

VERSION='source-shadow-background-normalized-composite-v2'


def estimate(profiles,component_evidence,background_rgb):
    result=dict(version=VERSION,identified=False,rgb=None,intrinsicRGB=None,opacity=None,blurRadiusPx=None,
        GTAtInference=False,semantics='Conditional neutral-black attenuation applied to a predicted source background; not a unique intrinsic colour or opacity estimate')
    measured=[c['sourceComponent'] for c in component_evidence if c['eligible']>=10]
    if len(set(measured))!=len(measured):raise ValueError('Repeated source component identities')
    def peaks(ids):
        values=[]
        for identity in ids:
            a=[p['conditionalBlackAttenuation'] for p in profiles if p['sourceComponent']==identity]
            if len(a)>=3:values.append(float(np.quantile(a,.9)))
        return values
    fit=peaks(measured[::2]);validation=peaks(measured[1::2])
    if len(fit)<2 or len(validation)<2:return dict(result,reason='Insufficient repeated attenuation observations')
    value=float(np.median(fit));agreement=float(np.mean(np.abs(np.asarray(validation)-value)<=.1))
    valid=.03<=value<=.95 and agreement>=.6 and (np.abs(np.asarray(validation)-value)<=.1).sum()>=2
    background=np.asarray(background_rgb,float)
    if background.shape!=(3,) or not np.isfinite(background).all():raise ValueError('Invalid source background colour')
    rgb=np.rint(np.clip(background*(1-value),0,255)).astype(int).tolist()
    result.update(identified=bool(valid),rgb=rgb if valid else None,candidateRGB=rgb,
        conditionalPeakAttenuation=value,fitComponentPeaks=fit,validationComponentPeaks=validation,
        validationAgreement=agreement,reason='Component attenuation repeats after local-background normalization' if valid else 'Attenuation does not repeat on held-out source components')
    return result


def estimate_observed(profiles,component_evidence,background_rgb):
    normalized=estimate(profiles,component_evidence,background_rgb)
    result=dict(version=VERSION,identified=False,rgb=None,intrinsicRGB=None,opacity=None,blurRadiusPx=None,
        GTAtInference=False,normalization=normalized,
        semantics='Native dark shadow-core sample with strong relative attenuation; normalization validates shared attenuation, not absolute RGB equality across backgrounds')
    if not normalized['identified']:return dict(result,reason='Source attenuation is inconsistent')
    measured={c['sourceComponent'] for c in component_evidence if c['eligible']>=10}
    points=[p for p in profiles if p['sourceComponent'] in measured]
    if len(points)<8:return dict(result,reason='Insufficient native shadow samples')
    colours=np.asarray([p['rgb'] for p in points],np.uint8);space=lab(colours)
    attenuation=np.asarray([p['conditionalBlackAttenuation'] for p in points])
    selected=(attenuation>=np.quantile(attenuation,.9))&(space[:,0]<=np.quantile(space[:,0],.1))
    ids=np.flatnonzero(selected)
    components,counts=np.unique([points[i]['sourceComponent'] for i in ids],return_counts=True)
    if len(ids)<8 or (counts>=2).sum()<2:return dict(result,reason='Strong dark paint is isolated rather than repeated',nativeSamples=len(ids))
    center=np.median(space[ids],axis=0);chosen=int(ids[np.linalg.norm(space[ids]-center,axis=1).argmin()])
    result.update(identified=True,rgb=colours[chosen].astype(int).tolist(),nativeActualSample=True,
        nativeSamples=len(ids),repeatedComponents=int((counts>=2).sum()),
        observedRangeRGB=np.quantile(colours[ids],[.1,.9],axis=0).tolist(),
        reason='Repeated native dark paint agrees with independently validated relative attenuation')
    return result
