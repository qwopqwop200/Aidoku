"""Confidence refinement with independent native structure; no region-ID rules."""
import copy
import math

VERSION='source-shadow-confidence-and-structure-v1'


def baseline_present(prediction):
    shadow=prediction['shadow'];prior=shadow.get('sourceObservation',{}).get('presenceRefinement',{})
    return bool(prior.get('baselinePresent',shadow['present']))


def independent_support(prediction):
    observed=prediction['shadow'].get('sourceObservation',{})
    return bool(observed.get('displacement',{}).get('identified') or
        (observed.get('diffuseGlow') or {}).get('profile',{}).get('identified'))


def decision(prediction,threshold):
    probability=float(prediction['shadow']['probability'])
    if not math.isfinite(probability) or not 0<=probability<=1:raise ValueError('Invalid source shadow confidence')
    return baseline_present(prediction) and (probability>=threshold or independent_support(prediction))


def restore_baseline(prediction):
    shadow=prediction['shadow'];prior=shadow.get('sourceObservation',{}).get('presenceRefinement')
    if prior:
        shadow['present']=bool(prior['baselinePresent'])
        role=prior.get('rawShadowRoleEvidence')
        if role is not None:prediction.setdefault('pixelRoleEvidence',{}).setdefault('roles',{})['shadowComposite']=copy.deepcopy(role)
    return prediction


def apply(prediction,threshold):
    shadow=prediction['shadow'];base=baseline_present(prediction);support=independent_support(prediction)
    role=prediction.get('pixelRoleEvidence',{}).get('roles',{}).get('shadowComposite')
    prior=shadow.get('sourceObservation',{}).get('presenceRefinement',{})
    raw=copy.deepcopy(prior.get('rawShadowRoleEvidence',role))
    shadow['present']=decision(prediction,threshold)
    shadow.setdefault('sourceObservation',{})['presenceRefinement']=dict(version=VERSION,baselinePresent=base,
        baselineProbability=float(shadow['probability']),minimumUncorroboratedProbability=float(threshold),
        independentNativeSupport=support,rawShadowRoleEvidence=raw)
    shadow['probabilityInterpretation']='pre-refinement-region-classifier-probability'
    if not shadow['present'] and role is not None:
        role['confidentSamples']=0;role['observedColours']=[]
    return prediction


def metrics(rows,predictions,group,threshold=None,emitted=False):
    from optimize_appearance import split
    values=dict(TP=0,FP=0,FN=0,TN=0)
    for row,prediction in zip(rows,predictions):
        if split(row)!=group or row['shadow']['present'] is None:continue
        expected=bool(row['shadow']['present'])
        actual=bool(prediction['shadow']['present']) if emitted else baseline_present(prediction) if threshold is None else decision(prediction,threshold)
        key='TP' if expected and actual else 'FN' if expected else 'FP' if actual else 'TN'
        values[key]+=1
    tp,fp,fn,tn=[values[k] for k in ['TP','FP','FN','TN']]
    values.update(precision=tp/max(1,tp+fp),recall=tp/max(1,tp+fn),positiveF1=2*tp/max(1,2*tp+fp+fn),
        accuracy=(tp+tn)/max(1,tp+fp+fn+tn),balancedAccuracy=(tp/max(1,tp+fn)+tn/max(1,tn+fp))/2)
    return values


def calibrate(rows,predictions):
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in predictions]:raise ValueError('Presence calibration correspondence mismatch')
    baseline={g:metrics(rows,predictions,g) for g in ['train','dev']};history=[];winner=0.;best=None
    for threshold in [0.,.5,.6,.7,.8,.9]:
        current={g:metrics(rows,predictions,g,threshold) for g in ['train','dev']}
        eligible=all(current[g]['TP']>=baseline[g]['TP'] and current[g]['FP']<=baseline[g]['FP'] for g in current)
        quality=(current['dev']['positiveF1'],current['dev']['precision'],current['train']['positiveF1'],-threshold)
        history.append(dict(threshold=threshold,metrics=current,eligible=eligible))
        if eligible and (best is None or quality>best):winner=threshold;best=quality
    return dict(version=VERSION,threshold=winner,baseline=baseline,history=history,
        selected={g:metrics(rows,predictions,g,winner) for g in ['train','dev','test']},
        selection='TRAIN/DEV no lost positives or added false positives; DEV F1/precision, TRAIN F1, lowest threshold; TEST descriptive only',
        GTAtInference=False)


def emitted_metrics(rows,predictions):
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in predictions]:raise ValueError('Emitted presence correspondence mismatch')
    return {g:metrics(rows,predictions,g,emitted=True) for g in ['train','dev','test']}
