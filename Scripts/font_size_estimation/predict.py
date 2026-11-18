"""Apply a trusted calibrated model to a source-only bbox crop manifest."""
import argparse
import concurrent.futures
from contextlib import nullcontext
import hashlib
import json
from pathlib import Path
import numpy as np
from PIL import Image
from estimator import features,load_model,predict_matrix,prediction_groups
from source_evidence import measure_evidence,predicted_mask,row_source_text
from physical_consensus import measurement_plan,apply_source_evidence


def measure_row(job):
    row,version=job
    with Image.open(row['crop']) as im:rgb=np.asarray(im.convert('RGB'))
    return features(rgb,row['bboxInCrop'],row['priorReferenceFontPx'],version=version)


def measure_physical_row(job):
    row,spec=job;source_text=row_source_text(row)
    if not source_text or not row.get('predictedMask'):return np.zeros(66)
    if hashlib.sha256(Path(row['crop']).read_bytes()).hexdigest()!=row.get('cropSHA256'):raise ValueError('Physical font crop identity differs')
    with Image.open(row['crop']) as im:rgb=np.asarray(im.convert('RGB'))
    own=predicted_mask(row['predictedMask'],row['sourceImageSHA256'],row['pageSize']);x,y,right,bottom=row['cropBounds']
    signal=measure_evidence(spec,rgb,row['bboxInCrop'],row['priorReferenceFontPx'],source_text,own[y:bottom,x:right])
    return np.zeros(66) if signal is None else signal


def measure_cluster_row(job):
    row,bundle,native,template=job
    from source_clusters import measure_cluster_evidence,EVIDENCE_COUNT
    if not row.get('predictedMask') or not row.get('sourceRole'):
        return np.zeros(EVIDENCE_COUNT)
    source_text=row_source_text(row)
    confidence=row.get('sourceConfidence')
    if 'sourceOCR' in row:
        meta=row['sourceOCR'];raw=Path(meta['path']).read_bytes()
        if hashlib.sha256(raw).hexdigest()!=meta['SHA256']:raise ValueError('Source OCR packet identity differs')
        packet=json.loads(raw);confidence=next((r.get('confidence') for r in packet['regions'] if r['id']==row['regionID']),None)
    if hashlib.sha256(Path(row['crop']).read_bytes()).hexdigest()!=row.get('cropSHA256'):raise ValueError('Source cluster crop identity differs')
    with Image.open(row['crop']) as im:rgb=np.asarray(im.convert('RGB'))
    owned=predicted_mask(row['predictedMask'],row['sourceImageSHA256'],row['pageSize'])
    x,y,right,bottom=row['cropBounds'];bx,by,w,h=row['bboxInCrop'];width,height=row['pageSize']
    center=[(x+bx+w/2)/width,(y+by+h/2)/height]
    return measure_cluster_evidence(bundle,rgb,row['bboxInCrop'],row['priorReferenceFontPx'],source_text,
        owned[y:bottom,x:right],native,confidence,row['sourceRole'],center,template)


def main():
    p=argparse.ArgumentParser();p.add_argument('--model',type=Path,required=True);p.add_argument('--manifest',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--jobs',type=int,default=1);a=p.parse_args();rows=json.loads(a.manifest.read_text())['items'];bundle=load_model(a.model)
    if bundle.get('optimizedGraph'):
        from optimized_runtime import manifest_packets,infer_packets
        packets=manifest_packets(bundle,rows)
        values,stages=infer_packets(bundle,packets,prediction_groups(rows),return_stages=True)
        result=dict(model=str(a.model.absolute()),featureVersion=4,GTFieldsRead=False,GTMaskUsed=False,
            optimizedFontGraph=bundle['optimizedGraph']['version'],optimizedStages=list(stages),
            sourceOnlyFreshInference=True,items=[dict(itemID=r['itemID'],fontSizePx=float(v),
            priorReferenceFontPx=r['priorReferenceFontPx']) for r,v in zip(rows,values)])
        a.out.parent.mkdir(exist_ok=True,parents=True)
        a.out.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
        return
    spec={k:bundle[k] for k in ('physicalConsensus','physicalReferenceFonts')} if bundle.get('physicalConsensus') else None
    priors=[r['priorReferenceFontPx'] for r in rows];groups=prediction_groups(rows)
    with concurrent.futures.ProcessPoolExecutor(max_workers=a.jobs) if a.jobs>1 else nullcontext(None) as pool:
        mapper=pool.map if pool is not None else map
        X=np.asarray(list(mapper(measure_row,[(r,bundle['featureVersion']) for r in rows])))
        baseline=predict_matrix(bundle,X,priors,groups,finalize=False) if rows else np.array([])
        texts=[row_source_text(r) for r in rows] if spec else ['']*len(rows)
        plan=measurement_plan(bundle,baseline,groups,texts);ids=np.flatnonzero(plan);evidence=np.zeros((len(rows),66))
        if len(ids):evidence[ids]=list(mapper(measure_physical_row,[(rows[i],spec) for i in ids]))
        cluster_evidence=None
        if rows and bundle.get('sourceClustering'):
            cluster_evidence=np.asarray(list(mapper(measure_cluster_row,[(row,bundle,X[i],evidence[i] if plan[i] else None) for i,row in enumerate(rows)])))
    values=apply_source_evidence(bundle,baseline,priors,groups,evidence)
    from font_clusters import apply_final_clustering
    values=apply_final_clustering(bundle,baseline,values,groups,X,cluster_evidence)
    result=dict(model=str(a.model.absolute()),featureVersion=bundle['featureVersion'],GTFieldsRead=False,GTMaskUsed=False,sourceEvidenceItems=int((evidence[:,-2]>0).sum()),sourceMeasurementsRequested=int(plan.sum()),sourceClusterMeasurementsRequested=len(rows) if bundle.get('sourceClustering') else 0,sourceClusterEvidenceItems=0 if cluster_evidence is None else int(((cluster_evidence[:,230:233].sum(axis=1)==1)&(cluster_evidence[:,233:289].sum(axis=1)>0)).sum()),items=[dict(itemID=r['itemID'],fontSizePx=float(v),priorReferenceFontPx=r['priorReferenceFontPx']) for r,v in zip(rows,values)])
    a.out.parent.mkdir(exist_ok=True,parents=True);a.out.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')


if __name__=='__main__':main()
