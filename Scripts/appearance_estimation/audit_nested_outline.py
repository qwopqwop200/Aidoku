"""Audit bounded source contour recovery without feeding labels into measurement."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import numpy as np
from PIL import Image
from optimize_appearance import read,save,digest,assign_splits,split
from nested_outline import measure


def worker(job):
    source,pred,masks=job
    if pred['outline']['present']:return None
    rgb=np.asarray(Image.open(source['crop']).convert('RGB'));mask=np.asarray(Image.open(Path(masks)/(source['itemID']+'.png')))>0
    return measure(rgb,mask,pred,source['fontPixels'],source['individualPolygonsCrop'])


def main():
    ap=argparse.ArgumentParser()
    for k in ['gt','estimator','masks','out']:ap.add_argument('--'+k,type=Path,required=True)
    ap.add_argument('--jobs',type=int,default=8);args=ap.parse_args();args.out.mkdir(exist_ok=True,parents=True)
    path=args.estimator/'predictions-with-width.json';before=digest(path);rows=read(args.gt)['items'];assign_splits(rows);pred=read(path)['items']
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in pred]:raise ValueError('Identity mismatch')
    fields=['itemID','crop','fontPixels','individualPolygonsCrop'];jobs=[({k:r[k] for k in fields},p,str(args.masks)) for r,p in zip(rows,pred)]
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:evidence=list(pool.map(worker,jobs,chunksize=8))
    records=[dict(itemID=r['itemID'],split=split(r),GTOutline=r['outline'],evidence=e) for r,e in zip(rows,evidence) if e and e['reliable']]
    metrics={}
    for group in ['train','dev','test','all']:
        cases=[r for r in records if group=='all' or r['split']==group]
        metrics[group]=dict(proposed=len(cases),GTOutlinePresent=sum(r['GTOutline']['present'] is True for r in cases),
            GTOutlineAbsent=sum(r['GTOutline']['present'] is False for r in cases),GTOutlineUnknown=sum(r['GTOutline']['present'] is None for r in cases))
    if before!=digest(path):raise RuntimeError('Champion changed during audit')
    save(args.out/'RESULTS.json',dict(items=records,metrics=metrics,sourcePredictionSHA256=before,GTAtInference=False,appliedToChampion=False))
    print(metrics,flush=True)


if __name__=='__main__':main()
