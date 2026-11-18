"""Source-observability peer correction; no GT groups, words or page rules."""
import math
import numpy as np


def body_count_from_metrics(metrics):
    # Counts reconstructed from ratios may be 2.0000000000000004. Preserve the
    # original integer category count before applying discrete support gates.
    return float(max(0,round(float(np.expm1(metrics[0])*(metrics[1]+metrics[2]-metrics[3]+metrics[4]+metrics[5])))))


def correct_sparse_peers(predictions,priors,groups,counts,confidence,policy):
    original=np.asarray(predictions,float);priors=np.asarray(priors,float);counts=np.asarray(counts,float);confidence=np.asarray(confidence,float);groups=np.asarray(groups);out=original.copy()
    valid=np.isfinite(counts)&np.isfinite(confidence)&(confidence>=policy['minimumConfidence'])
    for group in set(groups):
        ids=np.flatnonzero(groups==group);queries=ids[valid[ids]&(counts[ids]<=policy['maximumSparseCount'])];anchors=ids[valid[ids]&(counts[ids]>=policy['minimumAnchorCount'])]
        for i in queries:
            peers=anchors[(anchors!=i)&(np.abs(np.log(priors[anchors]/priors[i]))<=math.log(policy['maximumPriorRatio']))]
            if len(peers)<policy['minimumPeers']:continue
            values=original[peers]
            if values.max()/values.min()>policy['maximumPeerSpread']:continue
            canonical=float(np.median(values))
            if max(canonical/original[i],original[i]/canonical)>policy['maximumMoveRatio']:continue
            strength=policy['strength']
            if strength==0 or math.isclose(canonical,original[i],rel_tol=1e-12,abs_tol=1e-12):continue
            out[i]=canonical if strength==1 else math.exp((1-strength)*math.log(original[i])+strength*math.log(canonical))
    return out
