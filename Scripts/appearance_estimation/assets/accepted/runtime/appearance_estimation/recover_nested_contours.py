"""Source topology recovery and audit of final saved outputs; preserve all GT and merge geometry."""
from width_resolution import predict as predict_width,native_features as native_width_features
import argparse
import copy
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import pickle
import numpy as np
from PIL import Image
from optimize_appearance import read,save,assign_splits,split,evaluate_predictions,digest,objective
from nested_outline import recover_presence,VERSION
from calibrate_width import measure,width_features

WIDTH=None


def init_width(path):
    global WIDTH
    with Path(path).open('rb') as f:WIDTH=pickle.load(f)


def worker(job):
    source,pred,features,masks=job
    if pred['outline']['present']:return pred
    packet=read(features)['packet'];rgb=np.asarray(Image.open(source['crop']).convert('RGB'))
    mask=np.asarray(Image.open(Path(masks)/(source['itemID']+'.png')))>0
    result=recover_presence(rgb,mask,pred,source['fontPixels'],source['individualPolygonsCrop'])
    if not result['outline']['present']:return result
    evidence,vector=measure(rgb,mask,result['fill']['rgb'],result['outline']['rgb'])
    normal=native_width_features(WIDTH,rgb,mask,result,packet['fontPixels'],source['individualPolygonsCrop'])
    value=float(predict_width(WIDTH,[width_features(packet,result,vector,WIDTH)],normal=None if normal is None else [normal])[0]);radius=WIDTH['uncertaintyRadiusPx']
    result['outline'].update(widthPx=value,widthRangePx=[max(0,value-radius),value+radius],measurementEvidence=evidence)
    return result


def main():
    ap=argparse.ArgumentParser()
    for k in ['gt','estimator','features','masks']:ap.add_argument('--'+k,type=Path,required=True)
    ap.add_argument('--jobs',type=int,default=8);args=ap.parse_args()
    path=args.estimator/'predictions-with-width.json';before=digest(path);data=read(path);pred=data['items'];rows=read(args.gt)['items'];assign_splits(rows)
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in pred]:raise ValueError('Item correspondence changed')
    fields=['itemID','crop','fontPixels','individualPolygonsCrop']
    jobs=[({k:r[k] for k in fields},p,args.features/(r['itemID']+'.json'),str(args.masks)) for r,p in zip(rows,pred)]
    with ProcessPoolExecutor(max_workers=args.jobs,initializer=init_width,initargs=(args.estimator/'width-model.pkl',)) as pool:corrected=list(pool.map(worker,jobs,chunksize=8))
    packets=[read(args.features/(r['itemID']+'.json'))['packet'] for r in rows]
    old=evaluate_predictions(rows,packets,pred);new=evaluate_predictions(rows,packets,corrected)
    # DEV is the only admission partition. TEST results remain descriptive and do not select the head.
    previous=old['dev']['outlinePresence'];current=new['dev']['outlinePresence']
    if current['FP']>previous['FP'] or current['FN']>previous['FN']:raise ValueError('DEV outline presence regressed')
    dev_width=[i for i,r in enumerate(rows) if split(r)=='dev' and r['outline']['present'] is True and r['outline'].get('widthRangePx')]
    def width_hits(values):
        return sum(rows[i]['outline']['widthRangePx'][0]<=values[i]['outline']['widthPx']<=rows[i]['outline']['widthRangePx'][1] for i in dev_width)
    if width_hits(corrected)<width_hits(pred):raise ValueError('DEV emitted width interval coverage regressed')
    if digest(path)!=before:raise RuntimeError('Estimator changed during source topology audit')
    records=[dict(itemID=r['itemID'],split=split(r),GTOutlinePresent=r['outline']['present'],
        beforeWidthPx=p['outline']['widthPx'],afterWidthPx=q['outline']['widthPx'],evidence=q['outline']['nestedContourEvidence'])
        for r,p,q in zip(rows,pred,corrected) if p['outline']['present']!=q['outline']['present']]
    data['items']=corrected;save(path,data)
    best=read(args.estimator/'BEST.json');best.setdefault('baseRoleMetricsBeforeSourceTopology',old);best['metrics']=new;best['devObjective']=objective(new['dev']);save(args.estimator/'BEST.json',best)
    width_path=args.estimator/'WIDTH-RESULTS.json';width=read(width_path);width.setdefault('beforeSourceTopologyRecovery',copy.deepcopy(width['selected']))
    for group in ['train','dev','test','all']:
        selected=[i for i,r in enumerate(rows) if (group=='all' or split(r)==group) and r['outline']['present'] is True and r['outline'].get('widthPx') is not None]
        values=np.array([corrected[i]['outline']['widthPx'] for i in selected]);target=np.array([rows[i]['outline']['widthPx'] for i in selected]);ranges=np.array([rows[i]['outline']['widthRangePx'] for i in selected])
        error=np.abs(values-target);inside=(values>=ranges[:,0])&(values<=ranges[:,1]);present=np.array([corrected[i]['outline']['present'] for i in selected])
        width['selected'][group].update(MAEPx=float(error.mean()),medianAbsoluteErrorPx=float(np.median(error)),withinGTRange=float(inside.mean()),
            jointPresentAndWidthInRange=float((inside&present).mean()),withinGTRangePlus1Px=float(((values>=ranges[:,0]-1)&(values<=ranges[:,1]+1)).mean()))
    save(width_path,width)
    modelpath=args.estimator/'width-model.pkl'
    with modelpath.open('rb') as f:model=pickle.load(f)
    model['sourceNestedContourVersion']=VERSION;tmp=modelpath.with_suffix('.pkl.tmp')
    with tmp.open('wb') as f:pickle.dump(model,f)
    tmp.replace(modelpath)
    save(args.estimator/'NESTED-CONTOUR-RESULTS.json',dict(items=records,changedItems=len(records),sourceVersion=VERSION,
        before=old,after=new,GTAtInference=False,GTChanged=False,productionAppChanged=False,sourcePredictionSHA256=before,
        notes=['All recovery decisions use RGB and predicted masks only.','Classifier probabilities remain raw; final presence and width are re-audited.','Previously examined corpus, not an unseen-data generalization test.']))
    print('Recovered contours',len(records),'DEV',previous,'->',current,flush=True)


if __name__=='__main__':main()
