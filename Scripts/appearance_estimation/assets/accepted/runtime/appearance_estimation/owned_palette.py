"""Source-only bounded gradient fill proposal. No IDs, labels, or file access."""
import cv2
import numpy as np
from source_appearance import lab
from source_gradient_core import propose, select_components
from native_gradient_contour import measure, body_from_seed
from paint_palette_metrics import predicted_colours

POLICY = dict(version='independent-contour-native-marginal-coverage-v2',
              boundedBrightPolicy=dict(version='certified-bright-native-palette-v1',sourceSupport=.95,maximumAdditions=3,minimumGainFraction=.1),
              coverageDeltaE=10., noveltyDeltaE=6., minimumGainFraction=.02,
              minimumGainPixels=12, minimumRepeatedComponents=2,
              minimumGainPixelsPerComponent=3, maximumAdditionsPerGroup=1,
              interiorDistanceStrictlyGreaterThan=1.5,
              minimumSourceCertifiedComponents=3,
              rank='newly covered native interior pixels, capped distance reduction, RGB lexical',
              candidateUniverse='every distinct actual RGB in every certified native body interior',
              sourceOnly=True, GTAtInference=False)


def supported(arrays, ys, xs):
    rf=arrays['rf'][ys,xs].astype(float); ocr=arrays['ocr'][ys,xs]
    owner=np.maximum(rf[:,15]*rf[:,16],rf[:,17]*rf[:,18])
    seg=np.maximum(arrays['segPrimary'][ys,xs],arrays['segBoundary'][ys,xs])
    return (owner>=.001)&(seg>=.5)&(ocr[:,0]>0)&((ocr[:,1]==0)|(ocr[:,2]>=.2))&((ocr[:,3]==0)|(ocr[:,4]>=.2))


def infer(rgb, mask, arrays, geometry, prediction, pixel_model, packet):
    from source_gradient_contour import _refine_contour, restore_baseline
    # Recompute the actual runtime certificate, rather than treating a cached
    # correction, item identity, outline RGB, or page as an eligibility flag.
    base=restore_baseline(prediction)
    _, diagnostic=_refine_contour(rgb,mask,arrays,geometry,base,pixel_model,packet)
    return _from_fresh_contour(rgb,mask,arrays,geometry,base,pixel_model,packet,diagnostic)


def _from_fresh_contour(rgb, mask, arrays, geometry, prediction, pixel_model, packet, diagnostic):
    """Internal stage handoff; diagnostic must come from this invocation's contour."""
    from source_gradient_contour import restore_baseline, trusted_groups
    if diagnostic.get('mechanism')=='bounded-bright-interiors':
        from certified_bright_palette import infer as bright_infer
        return bright_infer(rgb,mask,arrays,geometry,prediction,diagnostic)
    if not (diagnostic.get('mechanism')=='confirmed-gradient-body' and
            diagnostic.get('sourceObservation',{}).get('identified') is True):
        return [], dict(eligible=False, diagnostic=diagnostic, groups=[])
    base=restore_baseline(prediction); font=geometry['fontPixels']
    groups=select_components(propose(rgb,mask,base,geometry['polygons'],font))
    groups, semantic=trusted_groups(rgb,mask,arrays,geometry,base,pixel_model,packet,groups)
    existing=[prediction['fill']['rgb']]+[c['rgb'] for c in predicted_colours(prediction)]
    additions=[]; reports=[]
    for gi, group in enumerate(groups):
        contour=measure(rgb,[group],font)
        if not contour['identified']:
            reports.append(dict(group=gi, rejected='group lacks independent contour',contour=contour)); continue
        pixels=[]; coords=[]; identities=[]; source_support=[]; bodies=[]
        for ci, component in enumerate(group):
            body=body_from_seed(rgb,component['seedXY'])
            if body is None:continue
            interior=cv2.distanceTransform(body.astype(np.uint8),cv2.DIST_L2,5)>1.5
            ys,xs=np.where(interior)
            # All interiors contribute, without quantile or spatial subsampling.
            pixels.extend(rgb[ys,xs].tolist());coords.extend(zip(xs.tolist(),ys.tolist()))
            identities.extend([ci]*len(xs));source_support.extend(supported(arrays,ys,xs).tolist())
            bodies.append(dict(component=ci,bodyPixels=int(body.sum()),interiorPixels=len(xs),seedXY=component['seedXY']))
        if len(bodies)<3:continue
        pixels=np.asarray(pixels,np.uint8); coords=np.asarray(coords); ids=np.asarray(identities)
        support=np.asarray(source_support,bool); ll=lab(pixels); old=lab(existing+additions)
        distance=np.linalg.norm(ll[:,None]-old[None,:],axis=2).min(1)
        uncovered=distance>POLICY['coverageDeltaE']
        candidates=np.unique(pixels,axis=0); candidate_lab=lab(candidates)
        novel=np.linalg.norm(candidate_lab[:,None]-old[None,:],axis=2).min(1)>POLICY['noveltyDeltaE']
        ranked=[]
        for c,cl in zip(candidates[novel],candidate_lab[novel]):
            dd=np.linalg.norm(ll-cl,axis=1); gain=uncovered&(dd<=POLICY['coverageDeltaE'])
            n=int(gain.sum()); votes=[]; witnesses=[]
            for ci in range(len(group)):
                positions=np.flatnonzero(gain&support&(ids==ci))
                if len(positions)<POLICY['minimumGainPixelsPerComponent']:continue
                votes.append(ci); k=int(positions[np.argmin(dd[positions])])
                witnesses.append(dict(component=ci,xy=coords[k].tolist(),rgb=pixels[k].astype(int).tolist(),
                                      deltaE=float(dd[k]),sourceSupportedNewPixels=len(positions)))
            if len(votes)<POLICY['minimumRepeatedComponents']:continue
            if n<max(POLICY['minimumGainPixels'],POLICY['minimumGainFraction']*len(ll)):continue
            reduction=float(np.maximum(0,np.minimum(distance,10)-np.minimum(dd,10)).sum())
            exact=int(np.flatnonzero(np.all(pixels==c,axis=1))[0])
            ranked.append(dict(rgb=c.astype(int).tolist(),gainPixels=n,gainFraction=n/len(ll),
                               cappedDistanceReduction=reduction,components=votes,witnesses=witnesses,
                               exactRGBWitnessXY=coords[exact].tolist(),exactRGBWitnessComponent=int(ids[exact])))
        ranked.sort(key=lambda r:(-r['gainPixels'],-r['cappedDistanceReduction'],r['rgb']))
        best=ranked[0] if ranked else None
        if best:additions.append(best['rgb'])
        reports.append(dict(group=gi,contour=contour,bodies=bodies,interiorPixels=len(ll),
                            sourceSupportedInteriorPixels=int(support.sum()),
                            baselineCoveredPixels=int((~uncovered).sum()),
                            baselineCoverage=float((~uncovered).mean()),
                            candidateCoveredPixels=int((~uncovered).sum())+(best['gainPixels'] if best else 0),
                            candidateCoverage=float((~uncovered).mean())+(best['gainFraction'] if best else 0),
                            distinctActualInteriorRGBs=len(candidates),novelActualInteriorRGBs=int(novel.sum()),
                            admissibleCandidates=len(ranked),selected=best,topCandidates=ranked[:12]))
    return additions, dict(eligible=True,diagnostic=diagnostic,semantic=semantic,groups=reports)


def validate_additions(evidence, additions, rgb=None):
    """Bind appended colours to repeated finite source bodies and native witnesses.

    Structure is checked during warm restoration; the batch additionally supplies
    the already loaded native RGB to independently check the recorded pixels.
    """
    if isinstance(evidence,dict) and evidence.get('version')=='certified-bright-native-palette-v1':
        from certified_bright_palette import validate as validate_bright
        return validate_bright(evidence,additions,rgb)
    if (not isinstance(evidence,dict) or evidence.get('eligible') is not True
            or evidence.get('diagnostic',{}).get('mechanism')!='confirmed-gradient-body'
            or evidence.get('diagnostic',{}).get('sourceObservation',{}).get('identified') is not True):
        raise ValueError('Missing independently confirmed native palette evidence')
    selected=[];groups=set()
    def colour(value):
        return isinstance(value,list) and len(value)==3 and all(type(v) is int and 0<=v<=255 for v in value)
    def witness(xy, expected):
        if not isinstance(xy,list) or len(xy)!=2 or any(type(v) is not int or v<0 for v in xy):
            raise ValueError('Invalid native palette witness coordinate')
        if rgb is not None:
            x,y=xy
            if y>=rgb.shape[0] or x>=rgb.shape[1] or rgb[y,x].tolist()!=expected:
                raise ValueError('Native palette RGB witness differs from source')
    for group in evidence.get('groups',[]):
        chosen=group.get('selected')
        if chosen is None:continue
        identity=group.get('group')
        if type(identity) is not int or identity in groups:raise ValueError('Duplicate native palette group')
        groups.add(identity)
        if not group.get('contour',{}).get('identified'):raise ValueError('Unconfirmed native palette group')
        bodies=group.get('bodies',[]);by={v['component']:v for v in bodies}
        if len(by)<POLICY['minimumSourceCertifiedComponents']:raise ValueError('Insufficient finite native bodies')
        c=chosen.get('rgb');gain=chosen.get('gainPixels',0);n=group.get('interiorPixels',0)
        if (not colour(c) or n<=0 or gain<max(POLICY['minimumGainPixels'],POLICY['minimumGainFraction']*n)
                or group.get('candidateCoveredPixels',0)-group.get('baselineCoveredPixels',0)!=gain):
            raise ValueError('Invalid native palette colour/gain certificate')
        components=chosen.get('components',[]);witnesses=chosen.get('witnesses',[])
        if (len(set(components))!=len(components) or len(components)<POLICY['minimumRepeatedComponents']
                or set(components)!={v.get('component') for v in witnesses}
                or len(witnesses)!=len(components) or any(v not in by for v in components)):
            raise ValueError('Insufficient repeated native palette witnesses')
        for v in witnesses:
            if (v.get('sourceSupportedNewPixels',0)<POLICY['minimumGainPixelsPerComponent']
                    or not colour(v.get('rgb')) or v.get('deltaE',float('inf'))>POLICY['coverageDeltaE']):
                raise ValueError('Invalid supported native palette witness')
            witness(v.get('xy'),v['rgb'])
        if chosen.get('exactRGBWitnessComponent') not in by:raise ValueError('Missing exact native body witness')
        witness(chosen.get('exactRGBWitnessXY'),c)
        selected.append(c)
    if not selected or additions!=selected:raise ValueError('Palette additions do not match one selected RGB per source group')
