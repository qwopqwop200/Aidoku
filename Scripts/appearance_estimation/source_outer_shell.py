"""Observe finite attached white secondary layers from fresh source ownership.

No files, labels, corpus IDs, trained thresholds, or study artifacts are read.
The caller supplies aligned RGB/geometry, the final prediction, a fresh
source_gradient_contour.refine diagnostic, and its frozen policy threshold.
RGB, presence, nominal widths, and pre-existing multiple layers are preserved.
"""
import copy
import cv2
import numpy as np
from scipy import ndimage
from source_appearance import lab
from source_bright_ring import family_mask
from native_gradient_contour import body_from_seed
from source_outer_shell_geometry import scan, summarize, structural_gate, shifted

VERSION='source-owned-finite-secondary-layer-v1'
TAG='outerShellCorrection'


def restore_baseline(prediction):
    """Restore exact previous observedLayers presence/value; leave all else alone."""
    result=copy.deepcopy(prediction)
    outline=result['outline']
    prior=outline.get(TAG)
    if prior is None:return result
    if (not isinstance(prior,dict) or prior.get('version')!=VERSION
            or type(prior.get('previousObservedLayersPresent')) is not bool
            or 'previousObservedLayersValue' not in prior):
        raise ValueError('Invalid finite-secondary warm provenance')
    if prior['previousObservedLayersPresent']:
        outline['observedLayers']=copy.deepcopy(prior['previousObservedLayersValue'])
    else:
        outline.pop('observedLayers',None)
    del outline[TAG]
    return result


def confirmed_bodies(rgb,diagnostic):
    """Reconstruct only the exact components certified by the fresh source head.

    RF/seg/OCR probabilities are used by that upstream head, never substituted
    with outer-colour role guesses here. Its diagnostic is an in-memory contract;
    the caller authenticates RGB, models, source evidence and geometry.
    """
    core=np.zeros(rgb.shape[:2],bool)
    semantic=diagnostic.get('semantic',{})
    observation=diagnostic.get('sourceObservation',{})
    certificates=[]
    if diagnostic.get('mechanism')=='bounded-bright-interiors':
        if not semantic.get('accepted'):return core,certificates
        holes=observation.get('holes',[]);support=semantic.get('holes',[])
        if len(holes)!=len(support):raise ValueError('Bright ownership certificate correspondence changed')
        image=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
        native=family_mask(image,observation['candidateRGB'])
        closed=cv2.morphologyEx(native.astype(np.uint8),cv2.MORPH_CLOSE,np.ones((3,3),np.uint8))>0
        _,labels=cv2.connectedComponents(closed.astype(np.uint8),8)
        for hole,certificate in zip(holes,support):
            if not certificate.get('confirmed'):continue
            ring=labels==hole['component']
            interior=ndimage.binary_fill_holes(ring)&~ring
            _,identities=cv2.connectedComponents(interior.astype(np.uint8),8)
            body=identities==hole['hole']
            if int(body.sum())!=hole['nativeArea']:
                raise ValueError('Fresh source bright topology does not match RGB')
            core|=body
            certificates.append(dict(kind='bright-hole',nativeArea=int(body.sum()),
                sourceComponent=hole['component'],sourceHole=hole['hole']))
    else:
        for group in semantic.get('groups',[]):
            seeds=[s for s in group.get('seeds',[]) if s.get('confirmed')]
            if group.get('confirmedSeeds',0)<3 or len(seeds)<3:continue
            if group['confirmedSeeds']!=len(seeds):raise ValueError('Gradient source certificate count changed')
            for seed in seeds:
                x,y=map(int,seed['xy'])
                if not (0<=x<rgb.shape[1] and 0<=y<rgb.shape[0]):
                    raise ValueError('Gradient source seed outside RGB crop')
                body=body_from_seed(rgb,[x,y])
                if body is None:raise ValueError('Fresh source gradient body is not finite')
                core|=body
                certificates.append(dict(kind='gradient-body',nativeArea=int(body.sum()),seedXY=[x,y]))
    if len(certificates)<3:core[:]=False
    return core,certificates


def refine(rgb,geometry,prediction,diagnostic,threshold):
    """Return (prediction, report), attaching only observed finite physical layers.

    threshold is externally supplied frozen null calibration. Missing source
    certificates, merged exteriors and insufficient recurrence cause abstention.
    This head only covers a dark/chromatic primary followed by near-white paint.
    """
    if not np.isfinite(threshold) or threshold<0:raise ValueError('Invalid outer-shell policy threshold')
    result=restore_baseline(prediction);outline=result['outline']
    report=dict(version=VERSION,identified=False,applied=False,GTAtInference=False,
        sourceContextExpanded=False,threshold=float(threshold),
        semantics='Observed finite source-composite secondary band, not intrinsic pigment or nominal stroke width')
    def abstain(reason):
        report['reason']=reason
        return result,report
    existing=outline.get('observedLayers')
    if existing is not None and not isinstance(existing,list):
        raise ValueError('observedLayers must be a list or null')
    if len(existing or [])>=2:return abstain('existing-multiple-layers-preserved')
    if not outline['present']:return abstain('outline-presence-off')
    if lab([outline['rgb']])[0,0]>80:return abstain('primary-not-dark')
    if not isinstance(diagnostic,dict):raise ValueError('Fresh source diagnostic required')
    if not diagnostic.get('semantic'):return abstain('no-source-ownership-certificate')
    semantic=diagnostic['semantic']
    if diagnostic.get('mechanism')=='bounded-bright-interiors':
        certified=semantic.get('accepted') and sum(bool(h.get('confirmed')) for h in semantic.get('holes',[]))>=3
    else:
        certified=any(g.get('confirmedSeeds',0)>=3 and
            sum(bool(s.get('confirmed')) for s in g.get('seeds',[]))>=3 for g in semantic.get('groups',[]))
    if not certified:return abstain('fewer-than-three-source-confirmed-bodies')
    font=float(geometry['fontPixels'])
    if not np.isfinite(font) or font<=0:raise ValueError('Invalid source font scale')
    rgb=np.asarray(rgb)
    if rgb.dtype!=np.uint8 or rgb.ndim!=3 or rgb.shape[2]!=3 or min(rgb.shape[:2])<2:
        raise ValueError('Expected native uint8 RGB crop')
    core,certificates=confirmed_bodies(rgb,diagnostic)
    report.update(sourceVersion=diagnostic.get('version'),confirmedBodies=len(certificates))
    if not core.any():return abstain('fewer-than-three-source-confirmed-bodies')
    native=scan(rgb,core,outline['rgb'],font);summary=summarize(native)
    distance=max(8,round(font*.15));nulls=[]
    for dx,dy in [(distance,0),(-distance,0),(0,distance),(0,-distance)]:
        candidate=summarize(scan(rgb,shifted(core,dx,dy),outline['rgb'],font))
        candidate.pop('examples',None)
        nulls.append(dict(dx=dx,dy=dy,summary=candidate))
    score=summary['coherence']-max(n['summary']['coherence'] for n in nulls)
    report.update(summary=summary,counts=native['counts'],shiftedNulls=nulls,
        excessCoherence=float(score),structural=bool(structural_gate(summary,font)))
    if not summary['profiles']:return abstain('no-finite-outer-edge')
    if not report['structural']:return abstain('insufficient-repeated-finite-geometry')
    if score<=threshold:return abstain('not-above-frozen-shifted-null-threshold')
    x,y=summary['whiteRGBWitnessXY']
    if rgb[y,x].astype(int).tolist()!=summary['whiteRGB']:
        raise ValueError('Secondary colour native RGB witness mismatch')
    # The final primary colour is caller-owned source evidence; never re-estimate
    # it from the broad primary family mask used for geometric tracing.
    report.update(identified=True,applied=True,reason='observed-finite-secondary-layer')
    previousPresent='observedLayers' in outline
    previousValue=copy.deepcopy(outline.get('observedLayers'))
    widths=np.asarray([r['widthsPx'] for r in native['records']])
    outline['observedLayers']=[dict(rgb=copy.deepcopy(outline['rgb']),widthPx=float(summary['widthPx'][0]),
        observedWidthInterquartileRangePx=np.quantile(widths[:,0],[.25,.75]).tolist()),
        dict(rgb=list(summary['whiteRGB']),widthPx=float(summary['widthPx'][1]),
        observedWidthInterquartileRangePx=np.quantile(widths[:,1],[.25,.75]).tolist(),
        nativeRGBWitnessXY=list(summary['whiteRGBWitnessXY']))]
    outline[TAG]=dict(version=VERSION,previousObservedLayersPresent=previousPresent,
        previousObservedLayersValue=previousValue,sourceEvidence=copy.deepcopy(report))
    return result,report
