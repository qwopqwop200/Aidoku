"""Source physical paint plus bounded RF/pixel/OCR evidence and repeated displacement."""
import cv2
import numpy as np
import hashlib
from pathlib import Path
from source_appearance import lab
from pixel_role_estimation import features,VERSION as PIXEL_VERSION
from paint_feature_context import feature_prediction
from shadow_displacement_evidence import estimate,VERSION as DISPLACEMENT_VERSION
from native_colour_neighborhoods import clusters,dominant_neighborhood
from shadow_glow_profiles import estimate as measure_glow,POLICIES as GLOW_POLICIES
from shadow_background_normalization import estimate_observed as observed_glow_colour
from source_shadow_presence import VERSION as PRESENCE_VERSION

VERSION='source-observed-shadow-parameters-v4'


def add_neighborhoods(result,rgb,positions,probability,physical,near,pixel_model):
    threshold=pixel_model.get('roleProbabilityThresholds',{}).get('shadowComposite',pixel_model['probabilityThreshold'])
    hypotheses=[];support={}
    for name,selected in [('physical-neighborhood',physical.ravel()[positions]),
                          ('confident-role-neighborhood',near.ravel()[positions]&(probability>=threshold))]:
        colours=clusters(rgb.reshape(-1,3)[positions[selected]],1+probability[selected])
        dominant=dominant_neighborhood(colours)
        support[name]=dict(colours=colours,dominanceRatio=2.,clearDominant=dominant is not None)
        if dominant is not None:hypotheses.append(dict(dominant,origin=name))
    result['candidateHypotheses']=hypotheses;result['sourcePaletteSupport']=support
    return result


def validate_policy(policy,model_identities):
    if policy.get('version')!=VERSION or policy.get('displacementVersion')!=DISPLACEMENT_VERSION:
        raise ValueError('Source shadow observation version mismatch')
    if policy.get('presenceVersion')!=PRESENCE_VERSION:
        raise ValueError('Source shadow presence version mismatch')
    threshold=policy.get('minimumUncorroboratedProbability')
    if not isinstance(threshold,(int,float)) or not np.isfinite(threshold) or not 0<=threshold<=1:
        raise ValueError('Invalid source shadow presence threshold')
    if policy.get('modelIdentities')!=model_identities:
        raise ValueError('Source shadow checkpoint pairing mismatch')
    from source_native_primary_quality import validate_artifacts
    validate_artifacts()
    for key,name in [('nativePrimaryQualityHelperSHA256','source_native_primary_quality.py'),('latePaletteHelperSHA256','certified_interior_palette.py'),('latePrimaryHelperSHA256','certified_bright_primary.py'),('sourceHelperSHA256','source_shadow_observation.py'),('presenceHelperSHA256','source_shadow_presence.py'),('displacementHelperSHA256','shadow_displacement_evidence.py'),
                     ('nativeColourNeighborhoodsSHA256','native_colour_neighborhoods.py'),
                     ('localCoreHelperSHA256','local_source_core.py'),('glowHelperSHA256','shadow_glow_profiles.py'),
                     ('backgroundNormalizationSHA256','shadow_background_normalization.py'),('sourceCoreHelperSHA256','shadow_template_fit.py')]:
        if policy.get(key)!=hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest():
            raise ValueError('Source shadow implementation changed; regenerate checkpoint policy')


def propose(rgb,mask,source_arrays,geometry,prediction,pixel_model,packet):
    result=dict(version=VERSION,available=False,rgb=None,GTAtInference=False)
    if not prediction['shadow']['present']:return dict(result,reason='Source shadow presence is off')
    if pixel_model['version']!=PIXEL_VERSION:raise ValueError('Shadow/pixel-role source contract mismatch')
    h,w=mask.shape;f=float(geometry.get('fontPixels') or min(h,w))
    radius=max(4,min(24,round(.2*f)));reference_radius=max(3,min(12,round(.08*f)))
    positions=np.arange(0,h*w,max(1,int(np.ceil(h*w/4096))),dtype=np.int64)
    y,x=positions//w,positions%w
    positions=positions[(x>=reference_radius)&(x<w-reference_radius)&(y>=reference_radius)&(y<h-reference_radius)]
    if not len(positions):return dict(result,reason='No bounded source samples')
    context=feature_prediction(rgb,mask,packet,geometry,pixel_model)
    matrix,names=features(rgb,mask,source_arrays['rf'],source_arrays['segPrimary'],source_arrays['segBoundary'],source_arrays['ocr'],
        geometry,context if context is not None else prediction,positions)
    if names!=pixel_model['featureNames']:raise ValueError('Shadow pixel-role feature names changed')
    column=np.flatnonzero(pixel_model['classifier'].classes_==3)
    if not len(column):return dict(result,reason='Source classifier has no shadow-composite class')
    probability=pixel_model['classifier'].predict_proba(matrix)[:,column[0]]
    il=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    paints=[prediction['fill']['rgb']]+prediction['fill'].get('colors',[])
    if prediction['outline']['present']:paints.append(prediction['outline']['rgb'])
    close=np.zeros(mask.shape,bool)
    for colour in paints:close|=np.linalg.norm(il-lab([colour])[0],axis=2)<=10
    paint=close&mask
    owned=np.ones(mask.shape,np.uint8)
    if geometry.get('polygons'):
        owned[:]=0;cv2.fillPoly(owned,[np.rint(p).astype(np.int32) for p in geometry['polygons']],1)
    n,labels=cv2.connectedComponents(paint.astype(np.uint8),connectivity=8)
    seeded=np.bincount(labels[owned>0],minlength=n)>=3;seeded[0]=False;paint=seeded[labels]
    if paint.sum()<20:return dict(result,reason='Insufficient owned source paint')
    distance=cv2.distanceTransform((~paint).astype(np.uint8),cv2.DIST_L2,5)
    reference=cv2.dilate(rgb,np.ones((reference_radius*2+1,reference_radius*2+1),np.uint8)).astype(np.float32)
    ref_lab=cv2.cvtColor(reference/255,cv2.COLOR_RGB2LAB)
    ratios=(reference-rgb.astype(float))/np.maximum(reference,32)
    physical=(distance>0)&(distance<=radius)&~close&(ref_lab[:,:,0]-il[:,:,0]>=5)&(np.ptp(ratios,axis=2)<=.1)&(ratios.min(2)>=0)
    near=(distance>0)&(distance<=radius)&~close
    def finish(value):return add_neighborhoods(value,rgb,positions,probability,physical,near,pixel_model)
    selected=physical.ravel()[positions]
    pixels=rgb.reshape(-1,3)[positions[selected]]
    # Sparse shadow-role supervision must not erase independently observed paint.
    # Every actual sample contributes one vote; source-model support adds at most one.
    weights=1+probability[selected];coords=positions[selected]
    if len(pixels)<30:return finish(dict(result,reason='Insufficient physical fringe support',samples=len(pixels)))
    codes=(pixels.astype(np.int32)//16)@np.array([256,16,1]);mass=np.bincount(codes,weights=weights,minlength=4096)
    if not np.isfinite(mass).all() or mass.sum()<=0:return finish(dict(result,reason='No finite source-role mass'))
    code=int(mass.argmax());member=codes==code
    if member.sum()<8 or mass[code]<max(.05*mass.sum(),1):return finish(dict(result,reason='Insufficient observed colour-mode support'))
    xy=np.column_stack([coords[member]%w,coords[member]//w]);_,counts=np.unique(np.floor(xy/max(1,f)).astype(int),axis=0,return_counts=True)
    repeated=int((counts>=3).sum())
    if repeated<2:return finish(dict(result,reason='Observed colour does not repeat across source cells'))
    actual=pixels[member];median=np.median(actual,axis=0);colour=actual[np.argmin(((actual.astype(float)-median)**2).sum(1))].astype(int).tolist()
    return finish(dict(result,available=True,reason='Native neutral fringe with bounded RF/pixel/OCR support',rgb=colour,
        samples=len(pixels),modeSamples=int(member.sum()),repeatedSpatialBins=repeated,observedMass=float(mass[code]/mass.sum()),
        meanSourceShadowRoleProbability=float(probability[selected][member].mean()),weightPolicy='one native vote plus bounded source-role probability'))


def attach(rgb,mask,source_arrays,geometry,prediction,pixel_model,packet):
    proposal=propose(rgb,mask,source_arrays,geometry,prediction,pixel_model,packet)
    evidence=estimate(rgb,mask,prediction,float(geometry.get('fontPixels') or min(mask.shape)),proposal['rgb'],geometry.get('polygons'))
    trials=[]
    # Preserve an already validated legacy source estimate; new hypotheses fill gaps.
    if not evidence['identified']:
        best=None;score=None;seen=[]
        for candidate in proposal.get('candidateHypotheses',[]):
            colour=candidate['rgb']
            if colour in seen:continue
            seen.append(colour)
            trial=estimate(rgb,mask,prediction,float(geometry.get('fontPixels') or min(mask.shape)),colour,geometry.get('polygons'))
            trials.append(dict(candidate=candidate,evidence=trial))
            if trial['identified']:
                quality=(trial['sourceValidationF1'],trial['sourceTrainingF1'])
                if score is None or quality>score:score=quality;best=trial
        if best is not None:evidence=best
    prediction['shadow']['sourceObservation']=dict(version=VERSION,proposal=proposal,displacement=evidence,candidateTrials=trials)
    if evidence['identified']:
        shadow=prediction['shadow']
        if shadow.get('rgb') is None:
            shadow['rgb']=evidence['observedCompositeRGB'];shadow['rgbInterpretation']='observed-source-composite'
        if shadow.get('offsetPx') is None:
            shadow['offsetPx']=evidence['offsetPx'];shadow['offsetInterpretation']='component-validated-visible-paint-displacement'
    shadow=prediction['shadow']
    if shadow['present'] and (shadow.get('rgb') is None or shadow.get('rgbInterpretation')=='observed-dark-shadow-core-on-mixed-background') and not prediction['outline']['present']:
        # A global background mode cannot rule out finite local glyph boundaries.
        contrast=float(np.linalg.norm(lab([prediction['fill']['rgb']])[0]-lab([prediction['background']['rgb']])[0]))
        if contrast<8:
            profile=measure_glow(rgb,mask,prediction,float(geometry.get('fontPixels') or min(mask.shape)),geometry.get('polygons'),GLOW_POLICIES[0])
            paint=None
            if profile['identified'] and profile.get('coreEvidence',{}).get('usedLocalFallback'):
                paint=observed_glow_colour(profile['positiveProfileLogs'],profile['componentEvidence'],prediction['background']['rgb'])
                if paint['identified']:
                    shadow['rgb']=paint['rgb'];shadow['rgbInterpretation']='observed-dark-shadow-core-on-mixed-background'
            # Keep bounded summary evidence; source ray logs remain experiment artifacts.
            summary={k:v for k,v in profile.items() if k!='positiveProfileLogs'}
            shadow['sourceObservation']['diffuseGlow']=dict(profile=summary,paint=paint)
    return prediction


def attach_with_width_context(rgb,mask,source_arrays,geometry,prediction,pixel_model,packet,width_model=None):
    """Observe shadow paint in its independent source-geometry context.

    The emitted style width remains caller-owned. Only this head's shadow result
    is transferred back, following the same pattern as the frozen colour context.
    """
    from certified_bright_primary import restore_baseline as restore_late_fill
    descriptor=restore_late_fill(prediction)
    if width_model is None or width_model.get('adaptiveNormalRefinement') is None:
        attach(rgb,mask,source_arrays,geometry,descriptor,pixel_model,packet)
        prediction['shadow']=descriptor['shadow']
        return prediction
    import copy
    from calibrate_width import measure as measure_width,width_features
    from width_resolution import reference_predict
    _,vector=measure_width(rgb,mask,descriptor['fill']['rgb'],descriptor['outline']['rgb'])
    source_width=float(reference_predict(width_model,[width_features(packet,descriptor,vector,width_model)])[0]) if prediction['outline']['present'] else 0.
    observed=copy.deepcopy(descriptor);emitted=observed['outline']['widthPx'];observed['outline']['widthPx']=source_width
    attach(rgb,mask,source_arrays,geometry,observed,pixel_model,packet)
    observed['shadow'].setdefault('sourceObservation',{})['widthContext']=dict(
        version='independent-source-geometry-for-adaptive-width-v1',sourceOnly=True,GTAtInference=False,
        referenceWidthPx=source_width,emittedStyleWidthPx=emitted,
        semantics='Existing base source regressor silhouette, independent of the replacement nominal-width head')
    prediction['shadow']=observed['shadow']
    return prediction
