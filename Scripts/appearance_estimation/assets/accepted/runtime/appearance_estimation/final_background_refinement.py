"""Final post-head background RGB refinement from source-only observations.

Pure return-value API. Warm predictions are restored to their pre-correction RGB
before computing source features. No other head is recomputed or changed.
"""
import copy
import hashlib
from pathlib import Path

import cv2
import numpy as np
from source_appearance import lab

VERSION = 'final-source-background-refinement-v5'
V4_VERSION = 'final-source-background-refinement-v4'
PREVIOUS_VERSION = 'final-source-background-refinement-v3'
OLDER_VERSION = 'final-source-background-refinement-v2'
LEGACY_VERSION = 'final-source-background-refinement-v1'
from source_local_background_fusion import (MODEL_VERSION as FUSED_MODEL_VERSION,
    FEATURE_VERSION as FUSED_FEATURE_VERSION, FEATURE_NAMES as FUSED_FEATURE_NAMES,
    EXTRA_FEATURE_NAMES, extra_features)
MODEL_VERSION = 'local-exterior-palette-primary-ranker-v1'
RELATIVE_MODEL_VERSION = 'local-exterior-relative-colour-primary-ranker-v3'
import relative_background_quality as relative_quality
import glyph_background_quality as glyph_quality
import directional_background_quality as directional_quality
DIRECTIONAL_MODEL_VERSION = 'local-exterior-directional-glyph-relative-ranker-v5'
GLYPH_MODEL_VERSION = 'local-exterior-glyph-near-relative-ranker-v4'
MODEL_NAMES = ('model.pkl', 'pixel-role-model.pkl', 'width-model.pkl',
               'source-fill-palette-model.pkl', 'final-background-model.pkl',
               'background-palette.pkl')


def helper_sha256():
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def validate_policy(policy, modelIdentities):
    if policy.get('version') != VERSION or policy.get('modelVersion') not in (MODEL_VERSION,FUSED_MODEL_VERSION,RELATIVE_MODEL_VERSION,GLYPH_MODEL_VERSION,DIRECTIONAL_MODEL_VERSION):
        raise ValueError('Final background policy/version mismatch')
    if policy.get('helperSHA256') != helper_sha256():
        raise ValueError('Final background helper changed; regenerate policy')
    if set(modelIdentities) != set(MODEL_NAMES) or policy.get('modelIdentities') != modelIdentities:
        raise ValueError('Final background model pairing mismatch')
    if any(not isinstance(v, str) or len(v) != 64 for v in modelIdentities.values()):
        raise ValueError('Final background model identity missing')
    if policy.get('sourceArtifactSHA256') != modelIdentities['final-background-model.pkl']:
        raise ValueError('Final background artifact identity mismatch')
    if not policy.get('enabled'):
        raise ValueError('Final background policy is disabled')
    if policy['modelVersion'] in (FUSED_MODEL_VERSION,RELATIVE_MODEL_VERSION,GLYPH_MODEL_VERSION,DIRECTIONAL_MODEL_VERSION) and policy.get('localFusionHelperSHA256')!=fusion_helper_sha256():
        raise ValueError('Final background local-fusion helper changed')
    if policy['modelVersion'] in (RELATIVE_MODEL_VERSION,GLYPH_MODEL_VERSION,DIRECTIONAL_MODEL_VERSION) and policy.get('relativeQualityHelperSHA256')!=relative_helper_sha256():
        raise ValueError('Final background relative-quality helper changed')
    if policy['modelVersion'] in (GLYPH_MODEL_VERSION,DIRECTIONAL_MODEL_VERSION):
        expected=dict(glyphQualityVersion=glyph_quality.VERSION,glyphQualityHelperSHA256=glyph_quality.helper_hashes(),glyphSourceFeatureCount=24,glyphPairFeatureCount=504,featureVersion=FUSED_FEATURE_VERSION,featureCount=102)
        if any(policy.get(k)!=v for k,v in expected.items()):
            raise ValueError('Final background glyph policy/source schema changed')
    if policy['modelVersion']==DIRECTIONAL_MODEL_VERSION:
        expected=dict(directionalQualityVersion=directional_quality.VERSION,directionalSourceVersion=directional_quality.SOURCE_VERSION,directionalQualityHelperSHA256=directional_quality.helper_hashes(),directionalSourceFeatureCount=150,directionalPairFeatureCount=600,directionalGate=directional_quality.GATE)
        if any(policy.get(k)!=v for k,v in expected.items()):
            raise ValueError('Final background directional policy/source schema changed')


def fusion_helper_sha256():
    return hashlib.sha256(Path(__file__).with_name('source_local_background_fusion.py').read_bytes()).hexdigest()



def relative_helper_sha256():
    return hashlib.sha256(Path(__file__).with_name('relative_background_quality.py').read_bytes()).hexdigest()


def requires_source(model):
    return model.get('version') in (FUSED_MODEL_VERSION,RELATIVE_MODEL_VERSION,GLYPH_MODEL_VERSION,DIRECTIONAL_MODEL_VERSION)


def validate_model(model):
    version=model.get('version')
    if version==MODEL_VERSION:
        if model.get('featureCount')!=15:raise ValueError('Final background legacy feature count mismatch')
    elif version in (FUSED_MODEL_VERSION,RELATIVE_MODEL_VERSION,GLYPH_MODEL_VERSION,DIRECTIONAL_MODEL_VERSION):
        if (model.get('featureVersion')!=FUSED_FEATURE_VERSION or model.get('featureCount')!=102
                or model.get('baseFeatureCount')!=15 or model.get('extraFeatureCount')!=87
                or tuple(model.get('featureNames',()))!=FUSED_FEATURE_NAMES
                or tuple(model.get('extraFeatureNames',()))!=EXTRA_FEATURE_NAMES
                or model.get('helperSHA256')!=fusion_helper_sha256()):
            raise ValueError('Final background fused source contract mismatch')
        if version in (RELATIVE_MODEL_VERSION,GLYPH_MODEL_VERSION,DIRECTIONAL_MODEL_VERSION):
            quality=model.get('relativeQualityModel')
            relative_quality.validate_model(quality)
            if (quality['helperSHA256']!=relative_helper_sha256()
                    or relative_quality.SOURCE_FEATURE_NAMES!=FUSED_FEATURE_NAMES):
                raise ValueError('Relative background helper/source descriptor pairing mismatch')
    else:raise ValueError('Final background classifier/source feature mismatch')
    if version in (GLYPH_MODEL_VERSION,DIRECTIONAL_MODEL_VERSION):
        glyph_quality.validate(model.get('glyphQualityModel'))
        base=model.get('classifier')
        if getattr(base,'n_features_in_',None)!=102 or not np.array_equal(getattr(base,'classes_',None),[0,1]) or not callable(getattr(base,'predict_proba',None)):
            raise ValueError('Glyph background requires binary102-feature base classifier with positive class1')
    if version==DIRECTIONAL_MODEL_VERSION:
        directional_quality.validate(model.get('directionalQualityModel'))
    for key in ('maximumIncumbentScore','minimumNewScore'):
        threshold=model.get('configuration',{}).get(key)
        if not isinstance(threshold,(int,float)) or not np.isfinite(threshold) or not 0<=threshold<=1:
            raise ValueError('Invalid final background decision threshold')


def make_policy(folder,model,source_artifact_path):
    validate_model(model);folder=Path(folder);source_artifact_path=Path(source_artifact_path)
    identities={name:hashlib.sha256((folder/name).read_bytes()).hexdigest() for name in MODEL_NAMES}
    source_hash=hashlib.sha256(source_artifact_path.read_bytes()).hexdigest()
    if identities['final-background-model.pkl']!=source_hash:
        raise ValueError('Frozen final background artifact copy mismatch')
    policy=dict(enabled=True,version=VERSION,modelVersion=model['version'],helperSHA256=helper_sha256(),
        modelIdentities=identities,sourceArtifactSHA256=source_hash,sourceArtifact=str(source_artifact_path.resolve()),
        configuration=dict(model['configuration']),GTAtInference=False,
        stage='Final background scalar after earlier heads, before independent primary/outer source observations',
        backgroundIndexSemantics='Original ranker provenance; emitted RGB is post-head',
        warmSemantics='Restore previousRGB and remove own evidence before recomputing',
        sourceSummary='Native local exterior; fused models also use exact-local RF27, soft segmentation and OCR; no geometry clip or resampling')
    if requires_source(model):
        policy.update(localFusionHelperSHA256=fusion_helper_sha256(),featureVersion=FUSED_FEATURE_VERSION,featureCount=102)
    if model['version'] in (RELATIVE_MODEL_VERSION,GLYPH_MODEL_VERSION,DIRECTIONAL_MODEL_VERSION):
        policy.update(relativeQualityHelperSHA256=relative_helper_sha256(),relativeQualityVersion=relative_quality.VERSION,relativeFeatureVersion=relative_quality.FEATURE_VERSION,relativeFeatureCount=relative_quality.FEATURE_COUNT)
    if model['version'] in (GLYPH_MODEL_VERSION,DIRECTIONAL_MODEL_VERSION):
        policy.update(glyphQualityVersion=glyph_quality.VERSION,glyphQualityHelperSHA256=glyph_quality.helper_hashes(),glyphSourceFeatureCount=24,glyphPairFeatureCount=504,sourceSummary='Native exterior X102 plus24 glyph-near low-text supports including inside own predicted mask; no new RGB palette or geometry clipping')
    if model['version']==DIRECTIONAL_MODEL_VERSION:
        policy.update(directionalQualityVersion=directional_quality.VERSION,directionalSourceVersion=directional_quality.SOURCE_VERSION,directionalQualityHelperSHA256=directional_quality.helper_hashes(),directionalSourceFeatureCount=150,directionalPairFeatureCount=600,directionalGate=directional_quality.GATE,sourceSummary='Native exterior X102 plus glyph24 plus directional24; frozen V4 choice followed by separate .95 directional comparator; existing RGB palette only')
    validate_policy(policy,identities)
    return policy


def restore_baseline(prediction):
    result = copy.deepcopy(prediction)
    background = result['background']
    prior = background.get('primaryCorrectionEvidence')
    if prior is not None:
        if prior.get('version') not in (VERSION, V4_VERSION, PREVIOUS_VERSION, OLDER_VERSION, LEGACY_VERSION, MODEL_VERSION, FUSED_MODEL_VERSION, RELATIVE_MODEL_VERSION, GLYPH_MODEL_VERSION, DIRECTIONAL_MODEL_VERSION):
            raise ValueError('Unknown primary background correction provenance')
        previous = prior.get('previousRGB')
        if not isinstance(previous, list) or len(previous) != 3:
            raise ValueError('Missing pre-correction background RGB')
        background['rgb'] = list(previous)
        del background['primaryCorrectionEvidence']
    return result


def source_summaries(rgb, own, context, packet, prediction, font_pixels):
    """Exact frozen local summary and source_features visible/border fractions.

    Follows background_palette.source_features float32 rounding; avoids that
    function's unrelated rank features and sampling/mass calculation entirely.
    """
    rgb = np.asarray(rgb)
    own = np.asarray(own, dtype=bool)
    context = own if context is None else np.asarray(context, dtype=bool)
    if rgb.dtype != np.uint8 or rgb.shape != own.shape + (3,) or context.shape != own.shape:
        raise ValueError('Expected aligned native uint8 RGB and predicted masks')
    if np.any(own & ~context):
        raise ValueError('Context exclusion must include own predicted text mask')
    if not np.isfinite(font_pixels) or font_pixels <= 0:
        raise ValueError('Invalid source font scale')
    colours = prediction['background']['colors']
    lookup = {tuple(c): i for i, c in enumerate(packet['colors'])}
    try:
        indices = [lookup[tuple(c)] for c in colours]
    except KeyError as error:
        raise ValueError('Background palette differs from source packet') from error
    pixels = cv2.cvtColor(rgb.astype(np.float32) / 255, cv2.COLOR_RGB2LAB)
    visible = ~context
    border = np.zeros(own.shape, bool)
    border[[0, -1], :] = True
    border[:, [0, -1]] = True
    colour_lab = lab(packet['colors'])
    exterior = dict(visibleColourFraction=[], borderColourFraction=[])
    for i in indices:
        close = ((pixels - colour_lab[i]) ** 2).sum(2) <= 100
        exterior['visibleColourFraction'].append(float(np.float32((close & visible).sum() / max(1, visible.sum()))))
        exterior['borderColourFraction'].append(float(np.float32((close & visible & border).sum() / max(1, (visible & border).sum()))))
    distance = cv2.distanceTransform((~own).astype(np.uint8), cv2.DIST_L2, 3)
    radius = float(np.clip(font_pixels * .12, 2, 12))
    eligible = (distance > 0) & (distance <= radius) & visible
    local_pixels = pixels[eligible]
    all_colours = colours + [prediction['background']['rgb']]
    best = np.full(len(local_pixels), np.inf, np.float32)
    assigned = np.zeros(len(local_pixels), np.int16)
    close_counts = []
    for i, colour in enumerate(lab(all_colours)):
        d = ((local_pixels - colour) ** 2).sum(1)
        update = d < best
        best[update] = d[update]
        assigned[update] = i
        close_counts.append(int((d <= 100).sum()))
    mass = np.bincount(assigned[best <= 100], minlength=len(all_colours)) / max(1, len(local_pixels))
    local = dict(pixelCount=int(len(local_pixels)), radiusPx=radius, nearestMass=mass.tolist(),
        colourFraction=[v / max(1, len(local_pixels)) for v in close_counts],
        matchedFraction=float((best <= 100).mean()) if len(best) else 0.,
        policy='All native pixels outside predicted text union within 0.12 font-px (clamped 2..12) of own predicted text. No new palette colours or sampling.')
    return local, exterior


def feature_matrix(prediction, local, exterior):
    colours = list(prediction['background']['colors']) + [prediction['background']['rgb']]
    labs = lab(colours)
    n = len(colours)
    role = prediction['pixelRoleEvidence']['roles']['background'].get('observedColours') or []
    if role:
        d = np.linalg.norm(labs[:, None, :] - lab([o['rgb'] for o in role])[None, :, :], axis=2)
        nearest = d.argmin(1)
        role_distance = d.min(1) / 100
        role_mass = np.array([role[j]['observedMass'] for j in nearest])
    else:
        role_distance, role_mass = np.ones(n) * 2, np.zeros(n)
    weights = list(prediction['background']['observedContextWeights'])
    nearest = int(np.linalg.norm(labs[:-1] - labs[-1], axis=1).argmin())
    mass = np.array(weights + [weights[nearest]])
    visible = np.array(exterior['visibleColourFraction'] + [exterior['visibleColourFraction'][nearest]])
    border = np.array(exterior['borderColourFraction'] + [exterior['borderColourFraction'][nearest]])
    x = np.column_stack([labs / 100, mass, visible, border,
        local['nearestMass'], local['colourFraction'],
        np.asarray(local['colourFraction']) / max(max(local['colourFraction']), 1e-6),
        role_distance, role_mass,
        np.linalg.norm(labs - lab([prediction['fill']['rgb']])[0], axis=1) / 100,
        np.linalg.norm(labs - lab([prediction['outline']['rgb']])[0], axis=1) / 100
            if prediction['outline'].get('rgb') else np.ones(n),
        np.full(n, local['matchedFraction']), np.full(n, np.log1p(local['pixelCount']) / 10)])
    return colours, x.astype(np.float32)


def apply(rgb, own, context, packet, prediction, model, font_pixels, source_arrays=None):
    """Return final prediction; only background RGB/provenance may differ."""
    validate_model(model)
    fused=requires_source(model)
    if fused and source_arrays is None:raise ValueError('Final background fusion requires aligned source RF/segmentation/OCR')
    result = restore_baseline(prediction)
    background = result['background']
    if not background.get('colors') or not background.get('observedContextWeights'):
        return result
    # Warm final outputs may already contain later native heads. Restore only
    # a descriptor view; their emitted fields remain byte-for-byte untouched.
    from source_gradient_contour import restore_baseline as restore_primary
    from source_outer_shell import restore_baseline as restore_outer
    descriptor = restore_primary(restore_outer(result)) if fused else result
    local, exterior = source_summaries(rgb, own, context, packet, descriptor, font_pixels)
    colours, x = feature_matrix(descriptor, local, exterior)
    if fused:
        arrays={name:np.asarray(source_arrays[name],np.float32) for name in ('rf','segPrimary','segBoundary','ocr')}
        x=np.column_stack([x,extra_features(rgb,own,context,colours,font_pixels,arrays)]).astype(np.float32)
    if not np.isfinite(x).all():
        raise ValueError('Non-finite final background source features')
    scores = model['classifier'].predict_proba(x)[:, 1]
    old = len(scores) - 1
    best = int(np.argmax(scores))
    config = model['configuration']
    baseline=best if scores[old] <= config['maximumIncumbentScore'] and scores[best] >= config['minimumNewScore'] else old
    chosen=baseline;quality=None
    if model['version'] in (RELATIVE_MODEL_VERSION,GLYPH_MODEL_VERSION,DIRECTIONAL_MODEL_VERSION):
        chosen,quality=relative_quality.choose(colours,x,baseline,model['relativeQualityModel'])
    v3_chosen=chosen;glyph_evidence=None
    if model['version'] in (GLYPH_MODEL_VERSION,DIRECTIONAL_MODEL_VERSION):
        from glyph_background import features as glyph_features
        extra,glyph_source=glyph_features(rgb,own,context,colours,font_pixels,arrays)
        chosen,glyph_evidence=glyph_quality.choose(colours,np.column_stack([x,extra]).astype(np.float32),v3_chosen,glyph_source['observed'],model['glyphQualityModel'])
        glyph_evidence['sourceObservation']=glyph_source
    v4_chosen=chosen;directional_evidence=None
    if model['version']==DIRECTIONAL_MODEL_VERSION:
        from directional_background import features as directional_features
        directional_extra,directional_source=directional_features(rgb,own,context,colours,font_pixels,arrays)
        directional_x=np.column_stack([x,extra,directional_extra]).astype(np.float32)
        chosen,directional_evidence=directional_quality.choose(colours,directional_x,v4_chosen,directional_source['observed'],model['directionalQualityModel'])
        directional_evidence['sourceObservation']=directional_source
    if colours[chosen] != background['rgb']:
        previous = list(background['rgb'])
        background['rgb'] = list(colours[chosen])
        background['primaryCorrectionEvidence'] = dict(version=VERSION, modelVersion=model['version'],
            sourceOnly=True, GTAtInference=False, previousRGB=previous,
            score=float(scores[chosen]), incumbentScore=float(scores[old]), configuration=dict(config),
            sourcePaletteIndex=chosen, backgroundIndexSemantics='Original ranker provenance; final RGB is post-head')
        if quality is not None:
            background['primaryCorrectionEvidence'].update(v2BaselineIndex=baseline,v2BaselineRGB=list(colours[baseline]),
                binaryScoreSemantics='Frozen V2 within10 candidate probability, distinct from relative colour quality',
                relativeQualityEvidence=quality)
        if glyph_evidence is not None:
            background['primaryCorrectionEvidence'].update(v3BaselineIndex=v3_chosen,v3BaselineRGB=list(colours[v3_chosen]),glyphQualityEvidence=glyph_evidence)
        if directional_evidence is not None:
            background['primaryCorrectionEvidence'].update(v4BaselineIndex=v4_chosen,v4BaselineRGB=list(colours[v4_chosen]),directionalQualityEvidence=directional_evidence)
    return result
