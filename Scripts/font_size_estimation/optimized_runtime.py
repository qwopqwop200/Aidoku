"""Fresh crop/image adapters for the operational optimized source-font graph."""
import hashlib
import math
from pathlib import Path

import numpy as np
from PIL import Image

from estimator import features
from source_evidence import predicted_mask, measure_evidence, row_source_text
from source_clusters import measure_cluster_evidence
from optimized_graph import predict_optimized


def measure_packet(bundle, rgb, bbox, prior, text, ownership, page_size, center,
                   source_hash, confidence, role, style=None, member_polygons=None):
    native = features(rgb,bbox,prior,version=4)
    template = measure_evidence(bundle,rgb,bbox,prior,text,ownership)
    if template is None:
        template = np.zeros(66)
    evidence = measure_cluster_evidence(bundle,rgb,bbox,prior,text,ownership,native,
                                        confidence,role,center,template=template)
    return dict(rgb=rgb,bbox=list(bbox),prior=float(prior),text=text,ownership=ownership,
                native=native,evidence=evidence,pageSize=list(page_size),
                sourceGroup=source_hash,sourceHash=source_hash,confidence=confidence,role=role,
                style=style,memberPolygons=member_polygons)


def infer_packets(bundle, packets, groups=None, return_stages=False, *,
                  return_context=False, source_observations=None):
    """Optionally append a SourceFontContext to the existing result tuple.

    Context alone returns (values, context); with stages the result is
    (values, stages, context). Stages are predictions, never fresh signals.
    Observations are optional actual caller records in packet order.
    """
    from source_font_context import make_context, ordered_observations
    observations=ordered_observations(source_observations,len(packets))
    if source_observations is not None and not return_context:
        raise ValueError('Source observations require return_context=True')
    if not packets:
        result=np.empty(0)
        if return_context:
            context=make_context(packets,[],result,bundle['optimizedGraph']['measurementSpec'],{},observations)
            return (result,{},context) if return_stages else (result,context)
        return (result,{}) if return_stages else result
    from optimized_measurements import measure_packets
    native=np.asarray([p['native'] for p in packets]);evidence=np.asarray([p['evidence'] for p in packets])
    priors=np.asarray([p['prior'] for p in packets]);sizes=np.asarray([p['pageSize'] for p in packets])
    hashes=np.asarray([p['sourceHash'] for p in packets]);groups=hashes if groups is None else groups
    signals=measure_packets(packets,bundle['optimizedGraph']['measurementSpec'])
    identities=bundle['optimizedGraph'].get('sourceIdentityGroups',{})
    source_ids=np.asarray([identities.get(str(h),str(h)) for h in hashes])
    original_priors=priors.copy() if return_context else None
    result=predict_optimized(bundle,native,evidence,priors,groups,sizes,signals,
                             source_ids=source_ids,return_stages=return_stages)
    if return_context:
        values=result[0] if return_stages else result
        context=make_context(packets,original_priors,values,
                             bundle['optimizedGraph']['measurementSpec'],signals,observations)
        return (*result,context) if return_stages else (result,context)
    return result


def estimate_page(bundle, items, source_path, source_hash, model_path,
                  source_texts=None,mask_metadata=None,source_confidences=None,source_roles=None, *,
                  return_context=False, source_observations=None):
    """Return unchanged receipts, or (receipts, context) when explicitly requested."""
    from source_font_context import ordered_observations
    observations=ordered_observations(source_observations,len(items))
    if source_observations is not None and not return_context:
        raise ValueError('Source observations require return_context=True')
    if not items:
        if return_context:
            _,context=infer_packets(bundle,[],return_context=True,source_observations=observations)
            return [],context
        return []
    if source_texts is None or mask_metadata is None or source_confidences is None or source_roles is None:
        raise ValueError('Optimized font inference requires original OCR, predicted ownership, confidence and role')
    if hashlib.sha256(Path(source_path).read_bytes()).hexdigest()!=source_hash:
        raise ValueError('Font source image identity differs')
    packets=[]
    with Image.open(source_path) as source:
        ownership=predicted_mask(mask_metadata,source_hash,source.size)
        width,height=source.size
        for item in items:
            x,y,w,h=item['frame'];prior=item['fontReference']
            if not all(math.isfinite(v) for v in (x,y,w,h,prior)) or min(w,h,prior)<=0:
                raise ValueError('Invalid optimized font source geometry')
            left=max(0,math.floor(x-.15*w));top=max(0,math.floor(y-.15*h))
            right=min(width,math.ceil(x+1.15*w));bottom=min(height,math.ceil(y+1.15*h))
            rgb=np.asarray(source.crop((left,top,right,bottom)).convert('RGB'))
            packets.append(measure_packet(bundle,rgb,[x-left,y-top,w,h],prior,
                source_texts.get(item['id'],''),ownership[top:bottom,left:right],source.size,
                [(x+w/2)/width,(y+h/2)/height],source_hash,
                source_confidences.get(item['id']),source_roles.get(item['id']),
                style=item.get('sourcePredictedStyle'),
                member_polygons=[[[px-left,py-top] for px,py in polygon] for polygon in item.get('sourceMemberPolygons',[])]))
            packets[-1].update(cropOrigin=[left,top],cropBounds=[left,top,right,bottom],
                               sourceOrder=len(packets)-1,sourceRegionID=item['id'])
    if return_context:
        values,stages,context=infer_packets(bundle,packets,return_stages=True,
            return_context=True,source_observations=observations)
    else:
        values,stages=infer_packets(bundle,packets,return_stages=True)
    receipts=[]
    for i,(item,value) in enumerate(zip(items,values)):
        prior=item['fontReference'];item['fontReference']=float(value)
        receipts.append(dict(id=item['id'],priorFontReference=prior,fontReference=float(value),
                             fontEstimator=str(Path(model_path).absolute()),GTFontLabelsUsed=False,
                             optimizedFontGraph=bundle['optimizedGraph']['version'],
                             optimizedStages=list(stages),physicalEvidenceAvailable=bool(packets[i]['evidence'][228]),
                             sourceClusterEvidenceAvailable=bool(packets[i]['evidence'][230:233].sum()==1),
                             sourceOnlyFreshInference=True))
    return (receipts,context) if return_context else receipts


def manifest_packets(bundle, rows):
    """Source-crop CLI adapter; input annotation fields are never read."""
    import json
    packets=[]
    for row in rows:
        raw=Path(row['crop']).read_bytes()
        if hashlib.sha256(raw).hexdigest()!=row['cropSHA256']:
            raise ValueError('Font source crop identity differs')
        with Image.open(row['crop']) as image:
            rgb=np.asarray(image.convert('RGB'))
        source_hash=row['sourceImageSHA256'];width,height=row['pageSize']
        whole=predicted_mask(row['predictedMask'],source_hash,(width,height))
        left,top,right,bottom=row['cropBounds'];own=whole[top:bottom,left:right]
        if own.shape!=rgb.shape[:2]:raise ValueError('Font crop ownership geometry differs')
        confidence=row.get('sourceConfidence')
        if 'sourceOCR' in row:
            meta=row['sourceOCR'];raw=Path(meta['path']).read_bytes()
            if hashlib.sha256(raw).hexdigest()!=meta['SHA256']:raise ValueError('Font source OCR identity differs')
            confidence=next((r.get('confidence') for r in json.loads(raw)['regions'] if r['id']==row['regionID']),None)
        text=row_source_text(row);x,y,w,h=row['bboxInCrop']
        packets.append(measure_packet(bundle,rgb,[x,y,w,h],row['priorReferenceFontPx'],text,own,
                       (width,height),[(left+x+w/2)/width,(top+y+h/2)/height],source_hash,
                       confidence,row.get('sourceRole'),style=row.get('sourcePredictedStyle'),
                       member_polygons=row.get('memberPolygonsCrop')))
        packets[-1].update(cropOrigin=[left,top],cropBounds=[left,top,right,bottom],
                           sourceOrder=len(packets)-1,sourceRegionID=row.get('regionID'))
    return packets
