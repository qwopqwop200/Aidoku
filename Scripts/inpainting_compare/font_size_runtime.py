"""Estimate source em for render requests without consulting font-size GT."""
import math
import sys
from pathlib import Path


def estimate_page(items, source_path, source_hash, model_path,source_texts=None,mask_metadata=None,source_confidences=None,source_roles=None, *,
                  return_context=False, source_observations=None):
    """Opt in to (receipts, SourceFontContext) on the optimized graph only.

    Original observations must be supplied directly in item order. No weight
    classifier is invoked and no bold/render policy is changed here.
    """
    import numpy as np
    from PIL import Image
    sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'font_size_estimation'))
    from estimator import features,load_model,predict_matrix
    from source_evidence import measure_evidence,predicted_mask
    bundle=load_model(model_path)
    if bundle.get('optimizedGraph'):
        from optimized_runtime import estimate_page as optimized_estimate_page
        if return_context or source_observations is not None:
            return optimized_estimate_page(bundle,items,source_path,source_hash,model_path,
                source_texts,mask_metadata,source_confidences,source_roles,
                return_context=return_context,source_observations=source_observations)
        return optimized_estimate_page(bundle,items,source_path,source_hash,model_path,source_texts,mask_metadata,source_confidences,source_roles)
    if return_context or source_observations is not None:
        raise NotImplementedError('Source font context requires the optimized source graph')
    if not items:return []
    measured=[];priors=[];evidence=[];packets=[]
    use_evidence=bool((bundle.get('physicalConsensus') or bundle.get('sourceClustering')) and source_texts is not None and mask_metadata is not None)
    if use_evidence:
        import hashlib
        if hashlib.sha256(Path(source_path).read_bytes()).hexdigest()!=source_hash:raise ValueError('Font source image identity differs')
    with Image.open(source_path) as source:
        owned=predicted_mask(mask_metadata,source_hash,source.size) if use_evidence else None
        for item in items:
            x,y,w,h=item['frame'];left=max(0,math.floor(x-.15*w));top=max(0,math.floor(y-.15*h));right=min(source.width,math.ceil(x+1.15*w));bottom=min(source.height,math.ceil(y+1.15*h))
            crop=np.asarray(source.crop((left,top,right,bottom)).convert('RGB'))
            prior=item['fontReference'];priors.append(prior)
            measured.append(features(crop,[x-left,y-top,w,h],prior,version=bundle['featureVersion']))
            if use_evidence:packets.append((crop,[x-left,y-top,w,h],prior,source_texts.get(item['id'],''),owned[top:bottom,left:right]))
    groups=[source_hash]*len(items);baseline=predict_matrix(bundle,np.asarray(measured),priors,groups,finalize=False)
    from physical_consensus import apply_source_evidence,measurement_plan
    plan=measurement_plan(bundle,baseline,groups,[source_texts.get(i['id'],'') for i in items]) if use_evidence else np.zeros(len(items),bool)
    for index in range(len(items)):
        value=measure_evidence(bundle,*packets[index]) if plan[index] else None
        evidence.append(np.zeros(66) if value is None else value)
    physical=apply_source_evidence(bundle,baseline,priors,groups,np.asarray(evidence))
    from font_clusters import apply_final_clustering
    cluster_evidence=None
    if bundle.get('sourceClustering') and use_evidence:
        from source_clusters import measure_cluster_evidence
        cluster_evidence=[]
        with Image.open(source_path) as source:
            width,height=source.size
        for index,item in enumerate(items):
            crop,bbox,prior,text,ownership=packets[index]
            x,y,w,h=item['frame'];center=[(x+w/2)/width,(y+h/2)/height]
            cluster_evidence.append(measure_cluster_evidence(bundle,crop,bbox,prior,text,ownership,
                measured[index],(source_confidences or {}).get(item['id']),
                (source_roles or {}).get(item['id']),center,
                template=evidence[index] if plan[index] else None))
        cluster_evidence=np.asarray(cluster_evidence)
    values=apply_final_clustering(bundle,baseline,physical,groups,np.asarray(measured),cluster_evidence)
    receipts=[]
    for item,prior,value,old,signal,requested,adjusted in zip(items,priors,values,baseline,evidence,plan,physical):
        item['fontReference']=float(value)
        receipts.append(dict(id=item['id'],priorFontReference=prior,fontReference=float(value),fontEstimator=str(Path(model_path).absolute()),GTFontLabelsUsed=False,physicalEvidenceAvailable=bool(signal[-2]),physicalMeasurementRequested=bool(requested),physicalCorrectionApplied=bool(abs(adjusted-old)>1e-8),fontClusterApplied=bool(abs(value-adjusted)>1e-8),sourceClusterEvidenceAvailable=bool(cluster_evidence is not None and cluster_evidence[len(receipts),230:233].sum()==1 and cluster_evidence[len(receipts),233:289].sum()>0)))
    return receipts
