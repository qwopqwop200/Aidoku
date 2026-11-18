"""Source-only physical font evidence; no training or GT imports."""
import numpy as np
import unicodedata


def predicted_cohorts(before,groups,ratio):
    groups=np.asarray(groups)
    for group in set(groups):
        ids=np.flatnonzero(groups==group);ordered=ids[np.argsort(before[ids],kind='stable')];clusters=[]
        for i in ordered:
            if not clusters or before[i]/before[clusters[-1][0]]>ratio:clusters.append([])
            clusters[-1].append(i)
        for cluster in clusters:yield np.asarray(cluster)


def measurement_plan(bundle,before,groups,source_texts):
    policy=bundle.get('physicalConsensus');plan=np.zeros(len(before),bool)
    if not policy:return plan
    minimum_chars=2 if policy['consensus']=='concordant' else 1
    possible=np.array([len({c for c in unicodedata.normalize('NFC',text or '') if not c.isspace() and unicodedata.category(c)[0] not in 'MCPZS'})>=minimum_chars for text in source_texts])
    if len(possible)!=len(before):raise ValueError('Source text count differs')
    for ids in predicted_cohorts(np.asarray(before),groups,policy.get('cohortRatio',1.02)):
        if possible[ids].sum()>=policy.get('minWitnesses',2):plan[ids]=True
    return plan


def apply_source_evidence(bundle,before,priors,groups,evidence=None):
    policy=bundle.get('physicalConsensus')
    if not policy or evidence is None:return before
    evidence=np.asarray(evidence,float)
    if evidence.shape!=(len(before),66) or not np.isfinite(evidence).all():raise ValueError('Invalid physical font evidence')
    expert,confidence,spread,valid=reference_expert(evidence,0,policy['consensus'])
    return grouped_correction(before,priors,expert,confidence,spread,valid,evidence[:,-2]>0,groups,
                              policy['threshold'],policy['agreement'],policy['strength'],policy['clip'],
                              policy.get('cohortRatio',1.02),policy.get('minWitnesses',2),policy.get('maxFontSpread',.15))


def reference_expert(features,power,consensus='best'):
    bank=np.asarray(features)[:,:64].reshape(-1,4,16)
    if consensus=='best':factors=bank[:,:,12];scores=bank[:,:,13]
    elif consensus=='concordant':factors=bank[:,:,1];scores=bank[:,:,3]
    else:raise ValueError('Unknown template consensus')
    weights=np.maximum(scores,0.)**power if power else (factors>0).astype(float)
    weights*=factors>0;denominator=weights.sum(axis=1)
    logs=np.log(np.maximum(factors,1e-6));average=np.divide((weights*logs).sum(axis=1),denominator,out=np.zeros(len(bank)),where=denominator>0)
    confidence=np.divide((weights*scores).sum(axis=1),denominator,out=np.zeros(len(bank)),where=denominator>0)
    spread=np.ptp(logs,axis=1)
    valid=denominator>0
    if consensus=='concordant':
        # Different reference fonts can share the same false radical match.
        # Require two source glyphs as well as cross-font scale agreement.
        glyph_spread=np.log(np.maximum(bank[:,:,2],1e-6)/np.maximum(bank[:,:,0],1e-6)).max(axis=1)
        spread=np.maximum(spread,glyph_spread);valid&=np.asarray(features)[:,-1]>=1.
    return np.exp(average),confidence,spread,valid


def blend(before,prior,expert,confidence,spread,valid,threshold,maximum_spread,strength,limit):
    keep=valid&(confidence>=threshold)&(spread<=maximum_spread)
    result=np.asarray(before).copy()
    result[keep]*=np.exp(np.clip(strength*np.log(prior[keep]*expert[keep]/before[keep]),-limit,limit))
    return result


def grouped_correction(before,prior,expert,confidence,spread,valid,available,groups,threshold,agreement,strength,limit,cohort_ratio=1.02,min_witnesses=2,max_font_spread=.15):
    before=np.asarray(before,float);prior=np.asarray(prior,float);groups=np.asarray(groups)
    result=before.copy()
    trusted=valid&available&(confidence>=threshold)&(spread<=max_font_spread)
    delta=np.log(np.maximum(prior*expert,1e-12)/before)
    for ids in predicted_cohorts(before,groups,cohort_ratio):
        witnesses=ids[trusted[ids]]
        if len(witnesses)<min_witnesses:continue
        corrections=delta[witnesses]
        if np.ptp(corrections)>agreement:continue
        adjustment=float(np.clip(strength*np.median(corrections),-limit,limit))
        apply=ids[available[ids]];result[apply]*=np.exp(adjustment)
    return result


