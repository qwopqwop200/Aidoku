"""Exploratory whole-set multi-ring audit; labels never enter source measurement."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import numpy as np
from PIL import Image
from optimize_appearance import read,save,assign_splits,split,digest
from outline_layers import measure


def worker(job):
    source,prediction,feature,masks=job
    packet=read(feature)['packet'];rgb=np.asarray(Image.open(source['crop']).convert('RGB'))
    mask=np.asarray(Image.open(Path(masks)/(source['itemID']+'.png')))>0
    return measure(rgb,mask,prediction,source['fontPixels'],packet['colors'],source['individualPolygonsCrop'])


def main():
    ap=argparse.ArgumentParser()
    for k in ['gt','estimator','features','masks','out']:ap.add_argument('--'+k,type=Path,required=True)
    ap.add_argument('--jobs',type=int,default=8);args=ap.parse_args()
    args.out.mkdir(parents=True,exist_ok=True)
    rows=read(args.gt)['items'];assign_splits(rows);path=args.estimator/'predictions-with-width.json';before=digest(path)
    predictions=read(path)['items']
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in predictions]:raise ValueError('Item correspondence changed')
    fields=['itemID','crop','fontPixels','individualPolygonsCrop']
    jobs=[({k:r[k] for k in fields},p,args.features/(r['itemID']+'.json'),str(args.masks)) for r,p in zip(rows,predictions)]
    evidence=[]
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        for n,e in enumerate(pool.map(worker,jobs,chunksize=8),1):
            evidence.append(e)
            if n%500==0:print('normal-outline-evidence',n,flush=True)
    if digest(path)!=before:raise RuntimeError('Champion changed during audit')
    records=[dict(itemID=r['itemID'],split=split(r),GTOutline=r['outline'],proposal=e) for r,e in zip(rows,evidence) if e['reliable'] or len(r['outline'].get('layers') or [])>1]
    metrics={}
    for group in ['train','dev','test','all']:
        indices=[i for i,r in enumerate(rows) if group=='all' or split(r)==group]
        multi=[i for i in indices if len(rows[i]['outline'].get('layers') or [])>1];accepted=[i for i in indices if evidence[i]['reliable']]
        metrics[group]=dict(regions=len(indices),GTMultilayerCount=len(multi),accepted=len(accepted),
            truePositive=sum(i in multi for i in accepted),falsePositive=sum(i not in multi for i in accepted),
            falseNegative=sum(i not in accepted for i in multi))
    width_metrics={}
    for group in ['train','dev','test','all']:
        cases=[i for i,r in enumerate(rows) if (group=='all' or split(r)==group) and r['outline']['present'] is True and r['outline'].get('widthPx') is not None]
        current=np.array([predictions[i]['outline']['widthPx'] for i in cases]);target=np.array([rows[i]['outline']['widthPx'] for i in cases]);ranges=np.array([rows[i]['outline']['widthRangePx'] for i in cases])
        corrected=np.array([evidence[i]['totalWidthPx'] if evidence[i]['reliable'] else predictions[i]['outline']['widthPx'] for i in cases])
        width_metrics[group]={}
        for name,values in [('retained',current),('sourceRings',corrected)]:
            width_metrics[group][name]=dict(MAEPx=float(np.abs(values-target).mean()),withinGTRange=float(((values>=ranges[:,0])&(values<=ranges[:,1])).mean()))
    save(args.out/'RESULTS.json',dict(metrics=metrics,widthMetrics=width_metrics,items=records,appliedToChampion=False,GTAtInference=False,
        exploratory=True,sourcePredictionSHA256=before))
    print(metrics,flush=True)


if __name__=='__main__':main()
