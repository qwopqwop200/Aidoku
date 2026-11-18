"""Experimental repeated observed dark-shadow paint; no intrinsic colour inference."""
import numpy as np
from source_appearance import lab

VERSION='source-component-validated-dark-shadow-paint-v2'


def estimate(profiles,component_evidence):
    result=dict(version=VERSION,identified=False,observedRGB=None,intrinsicRGB=None,GTAtInference=False,
        lowerObservedFraction=.1,minimumIndependentColourComponents=2,
        semantics='Deepest repeated observed composite paint; intrinsic alpha/blur remain unidentified')
    measured=[c['sourceComponent'] for c in component_evidence if c['eligible']>=10]
    if len(set(measured))!=len(measured):raise ValueError('Fit and validation components must be distinct native identities')
    fit=set(measured[::2]);validation=set(measured[1::2])
    def lower(ids):
        selected=[p for p in profiles if p['sourceComponent'] in ids]
        if not selected:return []
        light=lab([p['rgb'] for p in selected])[:,0];limit=np.quantile(light,.1)
        return [p for p,l in zip(selected,light) if l<=limit]
    first=lower(fit);second=lower(validation)
    def repeated(rows):
        ids,counts=np.unique([r['sourceComponent'] for r in rows],return_counts=True)
        return int((counts>=2).sum())
    if len(first)<8 or len(second)<8 or repeated(first)<1 or repeated(second)<1:
        return dict(result,reason='Dark native paint lacks repeated fit/validation component support',fitSamples=len(first),validationSamples=len(second))
    colours=np.asarray([p['rgb'] for p in first],np.uint8);space=lab(colours);center=np.median(space,axis=0)
    colour=colours[int(np.linalg.norm(space-center,axis=1).argmin())].astype(int).tolist()
    distance=np.linalg.norm(lab([p['rgb'] for p in second])-lab([colour])[0],axis=1)
    matching=[p for p,d in zip(second,distance) if d<=10]
    agreement=float(np.mean(distance<=10));accepted=agreement>=.6 and repeated(matching)>=1
    result.update(identified=bool(accepted),observedRGB=colour if accepted else None,candidateRGB=colour,
        fitSamples=len(first),validationSamples=len(second),fitComponents=repeated(first),validationComponents=repeated(second),
        validationColourAgreement=agreement,matchingValidationComponents=repeated(matching),
        reason='Observed dark paint repeats on held-out source components' if accepted else 'Dark source paint is not consistent on held-out components')
    return result
