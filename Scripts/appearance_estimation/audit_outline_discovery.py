"""Experimental ordered-profile audit; colour correction candidates are evaluated separately from ring count."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import numpy as np
from PIL import Image
from optimize_appearance import read,save,assign_splits,split,digest
from source_appearance import lab
from outline_layer_discovery import measure


def worker(job):
    source,p,feature,masks=job
    packet=read(feature)['packet'];rgb=np.asarray(Image.open(source['crop']).convert('RGB'))
    mask=np.asarray(Image.open(Path(masks)/(source['itemID']+'.png')))>0
    return measure(rgb,mask,p,source['fontPixels'],packet['colors'],source['individualPolygonsCrop'])


def primary(e,p,support=.65,min_width=1):
    candidate=e.get('primaryContourProposal')
    if not candidate or candidate['profiles']<40 or candidate['directionalSectors']<3 or candidate['sharpProfileSupport']<support or candidate['medianColourCoreWidthPx']<min_width:return None
    if np.linalg.norm(lab([candidate['rgb']])-lab([p['outline']['rgb']]))<=10:return None
    return candidate


def main():
    ap=argparse.ArgumentParser()
    for k in ['gt','estimator','features','masks','out']:ap.add_argument('--'+k,type=Path,required=True)
    ap.add_argument('--jobs',type=int,default=8);args=ap.parse_args();args.out.mkdir(parents=True,exist_ok=True)
    rows=read(args.gt)['items'];assign_splits(rows);path=args.estimator/'predictions-with-width.json';before=digest(path);pred=read(path)['items']
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in pred]:raise ValueError('Item correspondence changed')
    fields=['itemID','crop','fontPixels','individualPolygonsCrop'];jobs=[({k:r[k] for k in fields},p,args.features/(r['itemID']+'.json'),str(args.masks)) for r,p in zip(rows,pred)]
    evidence=[]
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        for n,e in enumerate(pool.map(worker,jobs,chunksize=4),1):
            evidence.append(e)
            if n%500==0:print('outline-order-evidence',n,flush=True)
    if before!=digest(path):raise RuntimeError('Champion changed during audit')
    records=[];metrics={}
    for r,p,e in zip(rows,pred,evidence):
        proposal=primary(e,p)
        if proposal or e['reliable'] or len(r['outline'].get('layers') or [])>1:
            records.append(dict(itemID=r['itemID'],split=split(r),GTOutline=r['outline'],sourceRGB=p['outline']['rgb'],
                primaryCorrectionProposal=proposal,evidence=e))
    for group in ['train','dev','test','all']:
        cases=[(r,p,e) for r,p,e in zip(rows,pred,evidence) if (group=='all' or split(r)==group) and r['outline']['present'] is True]
        old=[];new=[];changes=0
        for r,p,e in cases:
            candidate=primary(e,p);proposed=candidate['rgb'] if candidate else p['outline']['rgb'];changes+=candidate is not None
            old.append(float(np.linalg.norm(lab([p['outline']['rgb']])-lab([r['outline']['rgb']]))));new.append(float(np.linalg.norm(lab([proposed])-lab([r['outline']['rgb']]))))
        metrics[group]=dict(positiveRegions=len(cases),colourChanges=changes,
            retainedWithin10=float(np.mean(np.array(old)<=10)),proposedWithin10=float(np.mean(np.array(new)<=10)),
            retainedMeanDeltaE=float(np.mean(old)),proposedMeanDeltaE=float(np.mean(new)),
            improvedFromWrongToCorrect=int(np.sum((np.array(old)>10)&(np.array(new)<=10))),
            regressedFromCorrectToWrong=int(np.sum((np.array(old)<=10)&(np.array(new)>10))))
    save(args.out/'RESULTS.json',dict(items=records,metrics=metrics,GTAtInference=False,appliedToChampion=False,
        sourcePredictionSHA256=before,sourceCodeSHA256=digest(Path(__file__).with_name('outline_layer_discovery.py')),
        exploratory=True,primarySupportThreshold=.65,minimumPrimaryColourCorePx=1))
    print(metrics,flush=True)


if __name__=='__main__':main()
