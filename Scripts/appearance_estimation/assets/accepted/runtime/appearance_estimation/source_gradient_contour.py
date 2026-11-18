"""Source-only final contour RGB recovery using confirmed gradient fill bodies."""
import copy
import hashlib
from pathlib import Path
import numpy as np
from source_appearance import lab
from source_bright_ring import propose as bright_proposals,eligible as bright_eligible,corroborate as bright_corroboration,VERSION as BRIGHT_VERSION
from source_gradient_core import propose,select_components,VERSION as CORE_VERSION
from native_gradient_contour import measure,VERSION as CONTOUR_VERSION
from pixel_role_estimation import features
from paint_feature_context import feature_prediction
from owned_palette import POLICY as FILL_PALETTE_POLICY, _from_fresh_contour, validate_additions

VERSION='source-confirmed-primary-contour-v2'
POLICY_VERSION='source-confirmed-contour-owned-palette-v6'
PALETTE_TAG='gradientPaletteCorrection'
MODEL_NAMES=('model.pkl','pixel-role-model.pkl','width-model.pkl','source-fill-palette-model.pkl','background-palette.pkl','final-background-model.pkl')
HELPERS=('source_native_primary_quality.py','source_native_primary_features.py','native_medoid.py','native_core.py','source_outer_shell.py','source_outer_shell_geometry.py','certified_interior_palette.py','certified_bright_primary.py','certified_bright_palette.py','source_gradient_contour.py','owned_palette.py','paint_palette_metrics.py','source_gradient_core.py','native_gradient_contour.py','pixel_role_estimation.py','paint_feature_context.py','source_appearance.py','source_bright_ring.py')


def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def helper_hashes():return {name:digest(Path(__file__).with_name(name)) for name in HELPERS}


def make_policy(folder):
    from certified_bright_primary import POLICY as primary_policy,VERSION as primary_version
    from certified_interior_palette import POLICY as pruning_policy,VERSION as pruning_version,MINIMUM_PIXELS
    folder=Path(folder)
    from source_native_primary_quality import validate_artifacts, MODEL_SHA256, VERSION as QUALITY_VERSION
    validate_artifacts()
    return dict(nativePrimaryQualityVersion=QUALITY_VERSION,nativePrimaryQualityModelSHA256=MODEL_SHA256,interiorPalettePruningPolicy={**pruning_policy,'minimumNativePixels':MINIMUM_PIXELS},interiorPalettePruningVersion=pruning_version,primaryFillPolicy=primary_policy,primaryFillVersion=primary_version,enabled=True,version=POLICY_VERSION,sourceContourVersion=VERSION,
        fillPalettePolicy=copy.deepcopy(FILL_PALETTE_POLICY),coreVersion=CORE_VERSION,contourVersion=CONTOUR_VERSION,brightRingVersion=BRIGHT_VERSION,
        helperSHA256=helper_hashes(),modelIdentities={name:digest(folder/name) for name in MODEL_NAMES},
        GTAtInference=False,stage='Final source stage: contour RGB, owned append-only palette, then certified primary, interior palette pruning, and learned native primary; warm native quality is peeled before pruning and certified primary and native palette restoration',
        indexSemantics='outlineIndex preserves original ranker provenance; RGB is the final source-composite estimate')


def validate_policy(policy,model_identities):
    from certified_bright_primary import POLICY as primary_policy,VERSION as primary_version
    from certified_interior_palette import POLICY as pruning_policy,VERSION as pruning_version,MINIMUM_PIXELS
    from source_native_primary_quality import validate_artifacts, MODEL_SHA256, VERSION as QUALITY_VERSION
    validate_artifacts()
    if policy.get('nativePrimaryQualityVersion')!=QUALITY_VERSION or policy.get('nativePrimaryQualityModelSHA256')!=MODEL_SHA256:raise ValueError('Native primary quality policy mismatch')
    if policy.get('interiorPalettePruningPolicy')!={**pruning_policy,'minimumNativePixels':MINIMUM_PIXELS} or policy.get('interiorPalettePruningVersion')!=pruning_version:raise ValueError('Interior palette pruning policy mismatch')
    if policy.get('primaryFillPolicy')!=primary_policy or policy.get('primaryFillVersion')!=primary_version:raise ValueError('Certified primary fill policy mismatch')
    if (not policy.get('enabled') or policy.get('version')!=POLICY_VERSION
            or policy.get('sourceContourVersion')!=VERSION or policy.get('fillPalettePolicy')!=FILL_PALETTE_POLICY
            or policy.get('coreVersion')!=CORE_VERSION or policy.get('contourVersion')!=CONTOUR_VERSION or policy.get('brightRingVersion')!=BRIGHT_VERSION):
        raise ValueError('Native gradient contour policy/version mismatch')
    if policy.get('helperSHA256')!=helper_hashes():raise ValueError('Native gradient contour implementation changed; regenerate policy')
    if set(model_identities)!=set(MODEL_NAMES) or policy.get('modelIdentities')!=model_identities:raise ValueError('Native gradient contour checkpoint pairing mismatch')


def restore_baseline(prediction):
    from certified_bright_primary import restore_baseline as restore_primary_fill
    result=restore_primary_fill(prediction);outline=result['outline'];prior=outline.get('gradientContourCorrection')
    if prior is not None:
        if prior.get('version') not in (VERSION,'source-confirmed-gradient-primary-contour-v1') or len(prior.get('previousRGB',[]))!=3:raise ValueError('Invalid warm gradient-contour provenance')
        outline['rgb']=list(prior['previousRGB']);del outline['gradientContourCorrection']
    fill=result['fill'];palette_prior=fill.get(PALETTE_TAG)
    if palette_prior is not None:
        if (not isinstance(palette_prior,dict) or palette_prior.get('version') not in (POLICY_VERSION,'source-confirmed-contour-owned-palette-v5','source-confirmed-contour-owned-palette-v4','source-confirmed-contour-owned-palette-v3')
                or palette_prior.get('policyVersion') not in (FILL_PALETTE_POLICY['version'],'independent-contour-native-marginal-coverage-v1')
                or palette_prior.get('primaryRGB')!=fill['rgb']
                or not isinstance(palette_prior.get('previousColors'),list)
                or not isinstance(palette_prior.get('addedRGB'),list)
                or fill.get('colors')!=palette_prior['previousColors']+palette_prior['addedRGB']):
            raise ValueError('Invalid warm gradient-palette provenance')
        validate_additions(palette_prior.get('sourceEvidence'),palette_prior['addedRGB'])
        fill['colors']=copy.deepcopy(palette_prior['previousColors']);del fill[PALETTE_TAG]
    return result


def trusted_groups(rgb,mask,arrays,geometry,prediction,pixel_model,packet,groups):
    context=feature_prediction(rgb,mask,packet,geometry,pixel_model)
    threshold=pixel_model.get('roleProbabilityThresholds',{}).get('fill',pixel_model['probabilityThreshold'])
    column=np.flatnonzero(pixel_model['classifier'].classes_==0)
    if len(column)!=1:raise ValueError('Native contour requires the source fill role')
    accepted=[];evidence=[];w=mask.shape[1]
    for group in groups:
        positions=[c['seedXY'][1]*w+c['seedXY'][0] for c in group]
        matrix,names=features(rgb,mask,arrays['rf'],arrays['segPrimary'],arrays['segBoundary'],arrays['ocr'],geometry,
            context if context is not None else prediction,positions)
        if names!=pixel_model['featureNames']:raise ValueError('Native contour pixel feature contract mismatch')
        probabilities=pixel_model['classifier'].predict_proba(matrix)[:,int(column[0])]
        seeds=[];confirmed=[]
        for component,probability in zip(group,probabilities):
            x,y=component['seedXY']
            if rgb[y,x].astype(int).tolist()!=component['seedRGB']:raise ValueError('Native gradient seed RGB changed')
            # The same quantized RF channels arrive as fp16 in CLI and fp32 in replay.
            # Promote scalars before multiplication so source evidence is identical.
            owner=max(float(arrays['rf'][y,x,15])*float(arrays['rf'][y,x,16]),float(arrays['rf'][y,x,17])*float(arrays['rf'][y,x,18]))
            segmentation=float(max(arrays['segPrimary'][y,x],arrays['segBoundary'][y,x]));ocr=arrays['ocr'][y,x]
            supported=owner>=.001 and segmentation>=.5 and ocr[0]>0 and (ocr[1]==0 or ocr[2]>=.2) and (ocr[3]==0 or ocr[4]>=.2)
            keep=bool(probability>=threshold and supported)
            seeds.append(dict(xy=component['seedXY'],rawFillProbability=float(probability),rfOwner=owner,
                softSegmentation=segmentation,ocrBox=float(ocr[0]),confirmed=keep))
            if keep:confirmed.append(component)
        if len(confirmed)>=3:accepted.append(confirmed)
        evidence.append(dict(confirmedSeeds=len(confirmed),seeds=seeds))
    return accepted,dict(sourceFillThreshold=float(threshold),groups=evidence,rawClassifierProbabilitiesChanged=False)


def refine_gradient(rgb,mask,arrays,geometry,prediction,pixel_model,packet):
    result=restore_baseline(prediction)
    if not result['outline']['present']:return result,dict(version=VERSION,applied=False,reason='Outline presence is off; this head only refines colour')
    font=float(geometry['fontPixels'])
    if not np.isfinite(font) or font<=0:raise ValueError('Invalid native gradient font scale')
    components=propose(rgb,mask,result,geometry.get('polygons'),font);groups=select_components(components)
    if not groups:return result,dict(version=VERSION,applied=False,gradientGroups=0,reason='No independently repeated gradient fill bodies')
    groups,semantic=trusted_groups(rgb,mask,arrays,geometry,result,pixel_model,packet,groups)
    if not groups:return result,dict(version=VERSION,applied=False,semantic=semantic,reason='Source ownership/known fill seeds do not corroborate gradient bodies')
    observation=measure(rgb,groups,font)
    delta=float(np.linalg.norm(lab([observation['rgb']])-lab([result['outline']['rgb']]))) if observation['identified'] else None
    report=dict(version=VERSION,applied=bool(observation['identified'] and delta>10),sourceObservation=observation,
        semantic=semantic,colourDifferenceFromRankerDeltaE=delta,GTAtInference=False)
    if report['applied']:
        previous=list(result['outline']['rgb']);result['outline']['rgb']=list(observation['rgb'])
        result['outline']['gradientContourCorrection']=dict(version=VERSION,previousRGB=previous,sourceEvidence=report,
            interpretation='Observed bounded source-composite contour RGB; intrinsic pigment and width are not reidentified',
            preservedFields='Original index, classifier probability, presence, nominal width/interval and every other style output')
    return result,report


def needs_source(rgb,mask,geometry,prediction,packet):
    base=restore_baseline(prediction)
    if not base['outline']['present']:return False
    if bright_eligible(base) and bright_proposals(rgb,mask,geometry.get('polygons'),geometry['fontPixels'],packet['colors'],base)['proposals']:return True
    return bool(select_components(propose(rgb,mask,base,geometry.get('polygons'),geometry['fontPixels'])))


def _refine_contour(rgb,mask,arrays,geometry,prediction,pixel_model,packet):
    base=restore_baseline(prediction)
    result,diagnostic=refine_gradient(rgb,mask,arrays,geometry,base,pixel_model,packet)
    if diagnostic.get('sourceObservation',{}).get('identified'):
        return result,dict(diagnostic,mechanism='confirmed-gradient-body')
    if not bright_eligible(base):return result,diagnostic
    candidate=bright_proposals(rgb,mask,geometry.get('polygons'),geometry['fontPixels'],packet['colors'],base)
    for proposal in candidate['proposals']:
        source=bright_corroboration(proposal,arrays)
        if not source['accepted']:continue
        x,y=proposal['nativeRGBWitnessXY']
        if rgb[y,x].astype(int).tolist()!=proposal['rgb']:raise ValueError('Bright contour native colour witness changed')
        delta=float(np.linalg.norm(lab([proposal['rgb']])-lab([base['outline']['rgb']])))
        summary={k:v for k,v in proposal.items() if k not in ['holes','corePositions','ringPositions','semanticSupportPending']}
        summary['holes']=[{k:v for k,v in hole.items() if k not in ['corePositions','ringPositions']} for hole in proposal['holes']]
        summary['sourceSupportPositionsSHA256']=hashlib.sha256(np.asarray(proposal['corePositions']+proposal['ringPositions'],np.int64).tobytes()).hexdigest()
        report=dict(version=VERSION,mechanism='bounded-bright-interiors',applied=delta>10,sourceObservation=summary,semantic=source,
            colourDifferenceFromRankerDeltaE=delta,GTAtInference=False)
        if report['applied']:
            previous=list(base['outline']['rgb']);base['outline']['rgb']=list(proposal['rgb'])
            base['outline']['gradientContourCorrection']=dict(version=VERSION,previousRGB=previous,sourceEvidence=report,
                interpretation='Observed native contour RGB supported by bounded bright interiors; no inferred intrinsic pigment or width',
                preservedFields='Original index, classifier probability, presence, nominal width/interval and every other style output')
        return base,report
    return result,dict(diagnostic,brightRingCandidateCount=len(candidate['proposals']),brightRingConfirmed=False)


def refine(rgb,mask,arrays,geometry,prediction,pixel_model,packet):
    """Existing contour semantics plus one frozen source-only palette append per group.

    The fresh contour diagnostic is handed directly to the helper in memory.
    Own warm palette provenance is restored before any prescreen/feature extraction.
    No candidate-index, primary fill, outline-layer, background, width or shadow
    replacement is performed by the palette extension.
    """
    base=restore_baseline(prediction)
    result,diagnostic=_refine_contour(rgb,mask,arrays,geometry,base,pixel_model,packet)
    if 'representation' not in base['fill']:
        from source_native_primary_quality import attach as attach_native_quality
        result,quality_evidence=attach_native_quality(rgb,mask,geometry,result)
        return result,dict(diagnostic,nativePrimaryQuality=quality_evidence,fillPaletteObservation=dict(eligible=False,
            reason='Legacy fill has no source-fusion palette to extend',groups=[]))
    additions,evidence=_from_fresh_contour(rgb,mask,arrays,geometry,base,pixel_model,packet,diagnostic)
    if additions:
        fill=result['fill'];previous=fill.get('colors')
        if (fill.get('representation')!='source-fusion-observed-palette'
                or not isinstance(previous,list) or not previous or previous[0]!=fill['rgb']):
            raise ValueError('Owned gradient palette requires the existing emitted source-fusion palette contract')
        fill['colors']=copy.deepcopy(previous)+copy.deepcopy(additions)
        fill[PALETTE_TAG]=dict(version=POLICY_VERSION,policyVersion=FILL_PALETTE_POLICY['version'],
            primaryRGB=copy.deepcopy(fill['rgb']),previousColors=copy.deepcopy(previous),
            addedRGB=copy.deepcopy(additions),sourceEvidence=evidence)
    from certified_bright_primary import attach as attach_primary
    result,primary_evidence=attach_primary(rgb,mask,arrays,geometry,result,diagnostic)
    from certified_interior_palette import attach as attach_pruning
    result,pruning_evidence=attach_pruning(rgb,mask,arrays,geometry,result,diagnostic)
    from source_native_primary_quality import attach as attach_native_quality
    result,quality_evidence=attach_native_quality(rgb,mask,geometry,result)
    return result,dict(diagnostic,fillPaletteObservation=evidence,fillPrimaryObservation=primary_evidence,fillPalettePruningObservation=pruning_evidence,nativePrimaryQuality=quality_evidence)
