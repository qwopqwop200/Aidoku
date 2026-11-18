"""Tune source fill-palette confidence on DEV only; other role thresholds stay unchanged."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import pickle
import sys
import numpy as np
from PIL import Image
from optimize_appearance import read,save,digest,assign_splits,split
from pixel_role_estimation import features,describe
from paint_palette_metrics import measure
import apply_pixel_roles as source
THRESHOLDS=[.8,.85,.9,.95,.98]


class CachedProbabilities:
    def __init__(self,classes,scores):self.classes_=classes;self.scores=scores
    def predict_proba(self,x):
        if len(x)!=len(self.scores):raise ValueError('Source palette sampling changed')
        return self.scores


def worker(job):
    row,obs,pred,root,ocr_folder=job
    rgb=np.asarray(Image.open(row['crop']).convert('RGB'));mask=np.asarray(Image.open(row['mask']))>0
    if digest(row['crop'])!=row['cropSHA256']:raise ValueError('Original RGB changed')
    p,q,_=source.VOTES.load(obs);rf=source.load_case_features(obs,Path(root)/'boundary-lean')
    ocr=source.raster(Path(ocr_folder)/(row['page']+'.json.gz'),row['sourceImageSHA256'],row['pageSize'],row['cropBounds'])
    geometry=dict(polygons=row['individualPolygonsCrop'],mergedPolygon=row['mergedPolygonCrop'],fontPixels=row['fontPixels'])
    positions=np.arange(0,mask.size,max(1,int(np.ceil(mask.size/4096))),dtype=np.int64)
    x,names=features(rgb,mask,rf,p,q,ocr,geometry,pred,positions)
    if names!=source.MODEL['featureNames']:raise ValueError('Source feature contract changed')
    cached=CachedProbabilities(source.MODEL['classifier'].classes_,source.MODEL['classifier'].predict_proba(x));result=[]
    for threshold in THRESHOLDS:
        model=dict(source.MODEL,classifier=cached,roleProbabilityThresholds=dict(fill=threshold))
        result.append(describe(rgb,mask,rf,p,q,ocr,geometry,pred,model)['roles']['fill']['observedColours'])
    return result


def main():
    ap=argparse.ArgumentParser()
    for k in ['gt','estimator','model','source-root','masks','ocr-evidence','out']:ap.add_argument('--'+k,type=Path,required=True)
    ap.add_argument('--jobs',type=int,default=8);args=ap.parse_args();rows=read(args.gt)['items'];assign_splits(rows)
    pred=read(args.estimator/'predictions-with-width.json')['items']
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in pred]:raise ValueError('Item correspondence changed')
    with args.model.open('rb') as f:model=pickle.load(f)
    if model['appearanceModelSHA256']!=digest(args.estimator/'model.pkl'):raise ValueError('Model pairing changed')
    initial_model=digest(args.model);prediction_hash=digest(args.estimator/'predictions-with-width.json')
    indices=[i for i,r in enumerate(rows) if split(r)=='dev'];rr=[rows[i] for i in indices];pp=[pred[i] for i in indices]
    obs={r['id']:{k:r[k] for k in ['id','rgb','rf','width','height','polygons','fontPixels']} for r in read(args.source_root/'boundary-lean/evaluation-manifest.json')['items']}
    fields=['itemID','page','crop','cropSHA256','sourceImageSHA256','pageSize','cropBounds','individualPolygonsCrop','mergedPolygonCrop','fontPixels'];jobs=[]
    for r,p in zip(rr,pp):
        s={k:r[k] for k in fields};s['mask']=str(args.masks/(r['itemID']+'.png'));jobs.append((s,obs[r['itemID']],p,str(args.source_root),str(args.ocr_evidence)))
    with ProcessPoolExecutor(max_workers=args.jobs,initializer=source.initialize,initargs=(str(args.source_root),str(args.model))) as pool:values=list(pool.map(worker,jobs,chunksize=4))
    reports=[dict(threshold=t,dev=measure(rr,pp,[v[i] for v in values])) for i,t in enumerate(THRESHOLDS)]
    base=reports[0]['dev'];eligible=[r for r in reports if r['dev']['colourRecall']>=base['colourRecall']]
    best=max(eligible,key=lambda r:(r['dev']['annotatedColourPrecision'],r['dev']['colourRecall'],-r['threshold']))
    if digest(args.model)!=initial_model or digest(args.estimator/'predictions-with-width.json')!=prediction_hash:raise RuntimeError('Source checkpoint changed during calibration')
    model['roleProbabilityThresholds']=dict(model.get('roleProbabilityThresholds',{}),fill=best['threshold'])
    with args.model.open('wb') as f:pickle.dump(model,f)
    save(args.out,dict(selectedOnDEV=best,history=reports,TESTUsedForSelection=False,GTAtInference=False,GTChanged=False,sourcePixelRoleModelSHA256=initial_model))
    print('pixel fill threshold selected',best,flush=True)


if __name__=='__main__':main()
