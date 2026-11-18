"""Operational accepted font graph: fresh source signals, frozen models only."""
import numpy as np
from optimized_base import predict_base


GRAPH_VERSION = 'accepted-font198-v1'


def predict_optimized(bundle, native, evidence, priors, groups, page_sizes,
                      signals, source_ids=None, return_stages=False):
    graph = bundle.get('optimizedGraph')
    if not graph or graph.get('version') != GRAPH_VERSION:
        raise ValueError('Optimized font model graph version mismatch')
    from optimized_early import predict_early
    from optimized_late import predict_late
    priors=np.asarray(priors,float);native=np.asarray(native,float);evidence=np.asarray(evidence,float)
    groups=np.asarray(groups);page_sizes=np.asarray(page_sizes,float)
    if page_sizes.shape!=(len(priors),2) or not np.isfinite(page_sizes).all() or (page_sizes<=0).any():
        raise ValueError('Invalid source page dimensions for optimized fonts')
    point, values, affinities = predict_base(graph['baseModel'],graph['pairModel'],graph['clusteringPolicy'],native,evidence,priors,groups)
    signals = dict(signals, pair_affinities=affinities)
    early = predict_early(values,point,native,evidence,priors,groups,page_sizes,signals,
                          graph['earlyModels'],graph['earlyPolicies'],return_stages=return_stages)
    if return_stages:
        early, early_stages = early
    late = predict_late(early,point,native,evidence,priors,groups,page_sizes,signals,
                        graph['lateModels'],graph['latePolicies'],source_ids=source_ids,
                        return_stages=return_stages)
    if return_stages:
        late,late_stages=late
    late=np.asarray(late,float)
    if late.shape!=priors.shape or not np.isfinite(late).all() or (late<=0).any():
        raise ValueError('Optimized font graph produced invalid sizes')
    if return_stages:
        return late,dict(point56=point,cluster61=values,**early_stages,**late_stages)
    return late
