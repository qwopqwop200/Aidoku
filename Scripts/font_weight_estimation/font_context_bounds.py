"""Sampled source-em uncertainty for independently corroborated pixel rescues.

Reuse actual same-call raw/fill/band observations. One source-font bin is two
pixels. Confidence bounds open only central-image proof gates; they never turn
a confidence-only polarity decision into bold. Stem bounds require central
added-stem confirmation. Directional proof retains all frozen contrast/ray/page
criteria. No GT, page IDs, new head, fitted parameter, or display-em change.
The sampled maximum is not a certified bound over every independent combination.
"""
import numpy as np

from features import page_context, render_policy
from fill_body import measure as measure_fill


def refine_page(bundle, packets, ems, signals, observations, predictions):
    if not predictions or not bundle.get('sourceBandHeads'):
        return predictions
    raw=np.asarray(observations['raw'],float)
    bands=np.asarray(observations['bands'],float)
    fill=np.asarray(observations['fill71'],float)
    ems=np.asarray(ems,float)
    count=len(packets)
    if raw.shape!=(count,866) or fill.shape!=(count,71) or len(predictions)!=count:
        raise ValueError('Source-em bound observation batch differs')
    result=[dict(p) for p in predictions]
    low=np.maximum(1.,ems-2.)
    high=ems+2.
    polarity=bundle['primary']['polarity']
    actual=np.asarray([p['polarityRescueScore'] for p in predictions],float)
    upper=actual.copy()
    def probabilities(values):
        x=page_context(np.c_[raw[:,:597],values,raw[:,604:]])
        if x.shape[1]!=polarity['featureCount']:raise ValueError('Source polarity bound feature layout differs')
        return polarity['model'].predict_proba(x)[:,1]
    alternative=[]
    for values in (low,high):
        measured=np.array([measure_fill(p['rgb'],p['bbox'],em,p['ownership'],p['style'],version=1)
                           for p,em in zip(packets,values)])
        alternative.append(measured)
        upper=np.maximum(upper,probabilities(measured))
    # Each peer's font may quantize independently; keep the complete real page
    # while changing one actually measured fill row, never a fabricated feature.
    for measured in alternative:
        for i in range(count):
            variant=fill.copy();variant[i]=measured[i]
            upper=np.maximum(upper,probabilities(variant))
    policies=[bundle.get('referenceInkPolicy'),*bundle.get('referenceInkAdditionalPolicies',[])]
    # Context uncertainty may relax a stricter gate only when the nominal
    # source already satisfies an accepted image-policy confidence floor.
    # A peer's changed font bin cannot manufacture evidence from zero support.
    floors=[p['minimumExistingScore'] for p in policies if p and
            p.get('existingScoreField')=='polarityRescueScore']
    nominal_floor=min(floors) if floors else float('inf')
    from reference_ink_source import infer_page as reference_infer
    for policy in policies:
        if not policy or policy.get('existingScoreField')!='polarityRescueScore':continue
        floor=policy['minimumExistingScore']
        selected=[i for i,p in enumerate(result) if p['sourceWeight']=='regular' and
                  nominal_floor<=actual[i]<floor<=upper[i]]
        if not selected:continue
        priors=[dict(result[i],polarityRescueScore=float(upper[i])) for i in selected]
        inferred=reference_infer([packets[i] for i in selected],ems[selected],priors,bundle['referenceInkPairs'],policy)
        for i,value in zip(selected,inferred):
            value.update(polarityRescueScore=float(actual[i]),sourcePolaritySampledUpperConfidence=float(upper[i]),
                         sourceEmConfidenceBoundUsed=True)
            result[i]=value
    policy=bundle.get('softInkPolicy')
    if policy:
        floor=policy['minimumExistingScore']
        selected=[i for i,p in enumerate(result) if p['sourceWeight']=='regular' and actual[i]<floor<=upper[i]]
        if selected:
            from soft_ink_source import infer_page as soft_infer
            values=soft_infer([packets[i] for i in selected],ems[selected],
                [dict(result[i],polarityRescueScore=float(upper[i])) for i in selected],bundle['referenceInkPairs'],policy)
            for i,value in zip(selected,values):
                value.update(polarityRescueScore=float(actual[i]),sourcePolaritySampledUpperConfidence=float(upper[i]),
                             sourceEmConfidenceBoundUsed=True)
                result[i]=value
    # A learned stem head may use uncertainty only with central independent
    # glyph-band reconstruction proof. Confidence-only polarity stays unchanged.
    stem=bundle['stem']
    selected=[i for i,p in enumerate(result) if p['sourceWeight']=='regular' and p['addedStemConfirmed']]
    from weight_bands import measure as measure_bands
    angles=np.asarray(signals['angles131'],float)
    for i in selected:
        maximum=float(result[i]['stemRescueScore'])
        for em in (low[i],high[i]):
            variant=bands.copy()
            p=packets[i]
            variant[i]=measure_bands(p['rgb'],p['bbox'],em,p['text'],p['ownership'],p['style'],bundle['referencePairs'],angles[i])
            values=variant if stem['rawFeatureCount']==variant.shape[1] else np.c_[raw,variant]
            x=page_context(values)
            if x.shape[1]!=stem['featureCount']:raise ValueError('Source stem bound layout differs')
            maximum=max(maximum,float(stem['model'].predict_proba(x)[i,1]))
        if maximum>=stem['threshold']:
            result[i].update(render_policy('bold'))
            result[i].update(sourceEmStemBoundRescueApplied=True,sourceStemSampledUpperConfidence=maximum)
    policy=bundle.get('directionalInkPolicy')
    if policy:
        from directional_ink_rules import measure_source_page,classify_page
        base=bundle['primary']['primary']
        before=[]
        for p in predictions:
            row=dict(p)
            if row['sourceWeight']!='mixed':
                model_bold=(row['boldScore']>=base['threshold'] or row['physicalCorrection'] or
                    row['polarityRescueApplied'] or row['stemRescueApplied'] or row['confirmedStemRescueApplied'])
                row['sourceWeight']='bold' if model_bold else 'regular'
            before.append(row)
        observed=measure_source_page(packets,low,policy)
        promoted=classify_page(observed,before,policy)
        for i,good in enumerate(promoted):
            if good and result[i]['sourceWeight']=='regular':
                result[i].update(render_policy('bold'))
                result[i].update(sourceEmDirectionalBoundRescueApplied=True)
    return result
