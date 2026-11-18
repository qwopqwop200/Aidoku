"""Evaluate every annotated paint colour, rather than any one matching colour.

Source histograms are extracted without GT styles; labels enter only scoring.
"""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import pickle
import sys
import numpy as np
from PIL import Image
from optimize_appearance import read, save, digest, assign_splits, split
from pixel_role_estimation import features
from source_appearance import lab
from paint_palette_metrics import targets,measure
from source_confidence_evidence import raster
import apply_pixel_roles as source


def histogram(pixels, weights):
    if len(pixels)<8:return []
    codes=(pixels.astype(np.int32)//16)@np.array([256,16,1])
    mass=np.bincount(codes,weights=weights,minlength=4096);total=mass.sum();result=[]
    for code in np.argsort(-mass)[:128]:
        if mass[code]<max(.002*total,1):break
        member=pixels[codes==code]
        # Pick an actual observed sample, never invent a channel-wise median colour.
        median=np.median(member,axis=0);rgb=member[np.argmin(np.sum((member.astype(float)-median)**2,axis=1))]
        result.append(dict(rgb=rgb.astype(int).tolist(),observedMass=float(mass[code]/total)))
    return result


def collect(job):
    row,obs,pred,root,ocr_folder=job
    rgb=np.asarray(Image.open(row['crop']).convert('RGB'));mask=np.asarray(Image.open(row['mask']))>0
    if digest(row['crop'])!=row['cropSHA256']:raise ValueError('Source RGB changed')
    p,q,_=source.VOTES.load(obs);rf=source.load_case_features(obs,Path(root)/'boundary-lean')
    ocr=raster(Path(ocr_folder)/(row['page']+'.json.gz'),row['sourceImageSHA256'],row['pageSize'],row['cropBounds'])
    geometry=dict(polygons=row['individualPolygonsCrop'],mergedPolygon=row['mergedPolygonCrop'],fontPixels=row['fontPixels'])
    positions=np.arange(0,mask.size,max(1,int(np.ceil(mask.size/4096))),dtype=np.int64)
    x,names=features(rgb,mask,rf,p,q,ocr,geometry,pred,positions)
    if names!=source.MODEL['featureNames']:raise ValueError('Source feature contract changed')
    scores=source.MODEL['classifier'].predict_proba(x);column=np.flatnonzero(source.MODEL['classifier'].classes_==0)[0]
    probability=scores[:,column];selected=probability>=source.MODEL['probabilityThreshold']
    return dict(itemID=row['itemID'],bins=histogram(rgb.reshape(-1,3)[positions][selected],probability[selected]))


def palette(bins, minimum_mass=.02, merge_delta=8., limit=8):
    selected=[]
    for b in bins:
        if b['observedMass']<minimum_mass:continue
        nearby=next((g for g in selected if np.linalg.norm(lab([g['rgb']])[0]-lab([b['rgb']])[0])<=merge_delta),None)
        if nearby is not None:nearby['observedMass']+=b['observedMass']
        elif len(selected)<limit:selected.append(dict(b))
    return selected



def main():
    ap=argparse.ArgumentParser()
    for k in ['gt','estimator','source-root','masks','ocr-evidence','out']:ap.add_argument('--'+k,type=Path,required=True)
    ap.add_argument('--jobs',type=int,default=8);args=ap.parse_args();args.out.mkdir(exist_ok=True,parents=True)
    rows=read(args.gt)['items'];assign_splits(rows);pred=read(args.estimator/'predictions-with-width.json')['items']
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in pred]:raise ValueError('Item correspondence changed')
    model=args.estimator/'pixel-role-model.pkl';cache=args.out/'source-histograms.json'
    identity=dict(model=digest(model),predictions=digest(args.estimator/'predictions-with-width.json'),gt=digest(args.gt))
    if cache.exists() and read(cache)['identity']==identity:values=read(cache)['items']
    else:
        obs={r['id']:{k:r[k] for k in ['id','rgb','rf','width','height','polygons','fontPixels']} for r in read(args.source_root/'boundary-lean/evaluation-manifest.json')['items']}
        fields=['itemID','page','crop','cropSHA256','sourceImageSHA256','pageSize','cropBounds','individualPolygonsCrop','mergedPolygonCrop','fontPixels'];jobs=[]
        for r,p in zip(rows,pred):
            s={k:r[k] for k in fields};s['mask']=str(args.masks/(r['itemID']+'.png'));jobs.append((s,obs[r['itemID']],p,str(args.source_root),str(args.ocr_evidence)))
        values=[]
        with ProcessPoolExecutor(max_workers=args.jobs,initializer=source.initialize,initargs=(str(args.source_root),str(model))) as pool:
            for n,value in enumerate(pool.map(collect,jobs,chunksize=4),1):
                values.append(value)
                if n%500==0:print('source fill histograms',n,flush=True)
        if identity!=dict(model=digest(model),predictions=digest(args.estimator/'predictions-with-width.json'),gt=digest(args.gt)):
            raise RuntimeError('Checkpoint changed during source histogram extraction')
        save(cache,dict(identity=identity,items=values,GTStylesAtInference=False))
    reports={};policies=[dict(minimum_mass=m,merge_delta=d,limit=limit) for m in [.01,.02,.04] for d in [6.,10.] for limit in [8,16]]
    baseline=[p.get('pixelRoleEvidence',{}).get('roles',{}).get('fill',{}).get('observedColours',[]) for p in pred]
    for g in ['train','dev','test']:
        indices=[i for i,r in enumerate(rows) if split(r)==g];rr=[rows[i] for i in indices];pp=[pred[i] for i in indices]
        reports[g]=dict(baseline=measure(rr,pp,[baseline[i] for i in indices]),candidates=[])
        for policy in policies:reports[g]['candidates'].append(dict(policy=policy,metrics=measure(rr,pp,[palette(values[i]['bins'],**policy) for i in indices])))
    base=reports['dev']['baseline'];eligible=[r for r in reports['dev']['candidates'] if r['metrics']['colourRecall']>=base['colourRecall'] and r['metrics']['annotatedColourPrecision']>=base['annotatedColourPrecision']]
    best=max(eligible,key=lambda r:(r['metrics']['colourRecall'],r['metrics']['annotatedColourPrecision'])) if eligible else None
    save(args.out/'RESULTS.json',dict(metrics=reports,selectedOnDEV=best,identity=identity,
        caveat='Colour annotation coverage, not dense pixel IoU; GT palette can be incomplete; TEST descriptive only',GTChanged=False))
    print('DEV baseline',base,'selected',best,flush=True)
    if best:print('TEST selected',next(x for x in reports['test']['candidates'] if x['policy']==best['policy']),flush=True)


if __name__=='__main__':main()
