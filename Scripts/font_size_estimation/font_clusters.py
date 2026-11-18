"""Final exact page-local font sizes; no GT font-group labels are consulted."""
import math
import numpy as np
from physical_consensus import predicted_cohorts


def finalize_sizes(baseline,proposed,groups,lock_ratio=1.+1e-10,quantum=0.):
    before=np.asarray(baseline,float);values=np.asarray(proposed,float).copy();groups=np.asarray(groups)
    if before.shape!=values.shape or len(groups)!=len(values) or not np.isfinite(before).all() or not np.isfinite(values).all() or (before<=0).any() or (values<=0).any():raise ValueError('Invalid final font sizes')
    if not math.isfinite(quantum) or quantum<0 or not math.isfinite(lock_ratio) or lock_ratio<1:raise ValueError('Invalid font cluster policy')
    # Preserve shared membership through subsequent corrections, including rows
    # without their own glyph evidence. Choose one canonical value before
    # rounding so a rounding boundary cannot split an existing source cohort.
    for ids in predicted_cohorts(before,groups,lock_ratio):
        corrected=ids[np.abs(values[ids]-before[ids])>1e-8]
        values[ids]=float(np.median(values[corrected if len(corrected) else ids]))
    if quantum>0:values=np.maximum(quantum,np.round(values/quantum)*quantum)
    return values


def apply_final_clustering(bundle,baseline,proposed,groups,native=None,cluster_evidence=None):
    policy=bundle.get('finalClustering')
    values=finalize_sizes(baseline,proposed,groups,**policy) if policy else proposed
    from source_clusters import apply_source_clustering
    return apply_source_clustering(bundle,values,groups,native,cluster_evidence)
