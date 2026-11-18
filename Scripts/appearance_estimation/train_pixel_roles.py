"""GT points supervise TRAIN only; pixel inference reads source evidence, never annotation points."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import pickle
import sys
import time
import numpy as np
from PIL import Image
from optimize_appearance import read,save,digest,assign_splits,split
from pixel_role_estimation import features,VERSION,ROLE_NAMES
from source_appearance import lab
from source_confidence_evidence import raster
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import confusion_matrix,f1_score

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'segmentation'))
from source_boundary_votes import SourceBoundaryVotes
from prepare_full_rf import load_case_features
VOTES=None


def initialize(root):
    global VOTES
    root=Path(root);VOTES=SourceBoundaryVotes(root/'boundary-lean',root/'deep-classifier-observations',root/'edge-context60-native',root/'edge-context60-observations')


def role_id(name):
    if name in ['fill','fill-black','fill-blue','fill-white','fill-pink','fill-secondary']:return 0
    if name in ['outline','outline-outer','outline-edge']:return 1
    if name in ['background','background-secondary']:return 2
    if name in ['shadow','shadow-composite']:return 3
    return None


def worker(job):
    source,observation,prediction,anchors,root,ocr_folder=job;root=Path(root)
    rgb=np.asarray(Image.open(source['crop']).convert('RGB'));mask=np.asarray(Image.open(source['mask']))>0
    if digest(source['crop'])!=source['cropSHA256']:raise ValueError('Original RGB changed')
    h,w=mask.shape;positions=[];targets=[];skipped=0
    for a in anchors:
        x,y=map(lambda x:int(round(x)),a['xy']);target=role_id(a['role'])
        if target is None or not(0<=x<w and 0<=y<h):skipped+=1;continue
        if a.get('rgb') is not None and np.linalg.norm(lab([rgb[y,x]])-lab([a['rgb']]))>10:skipped+=1;continue
        positions.append(y*w+x);targets.append(target)
    if not positions:return dict(itemID=source['itemID'],x=[],y=[],baseline=[],skipped=skipped,names=None)
    p,q,_=VOTES.load(observation);rf=load_case_features(observation,root/'boundary-lean')
    ocr=raster(Path(ocr_folder)/(source['page']+'.json.gz'),source['sourceImageSHA256'],source['pageSize'],source['cropBounds'])
    geometry=dict(polygons=source['individualPolygonsCrop'],mergedPolygon=source['mergedPolygonCrop'],fontPixels=source['fontPixels'])
    x,names=features(rgb,mask,rf,p,q,ocr,geometry,prediction,positions)
    pixels=cv2_lab_pixels(rgb,positions);colours=lab([prediction[r]['rgb'] for r in ['fill','outline','background']])
    distance=np.linalg.norm(pixels[:,None,:]-colours[None,:,:],axis=2);baseline=distance.argmin(1)
    baseline[~mask.ravel()[positions]]=2
    return dict(itemID=source['itemID'],x=x,y=np.asarray(targets,np.int32),baseline=baseline,skipped=skipped,names=names)


def cv2_lab_pixels(rgb,positions):
    import cv2
    return cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB).reshape(-1,3)[positions]


def statistics(y,pred):
    cm=confusion_matrix(y,pred,labels=np.arange(4))
    return dict(n=len(y),accuracy=float(np.mean(y==pred)),macroF1=float(f1_score(y,pred,labels=[0,1,2],average='macro',zero_division=0)),
        confusion=cm.tolist(),roles=ROLE_NAMES)


def preserves_role_hits(candidate, incumbent):
    """Do not trade a rare shadow/fill role for a better global average."""
    a=np.asarray(candidate['confusion']);b=np.asarray(incumbent['confusion'])
    return bool(np.all(np.diag(a)>=np.diag(b)))


def main():
    ap=argparse.ArgumentParser()
    for k in ['gt','source-root','estimator','masks','ocr-evidence','out']:ap.add_argument('--'+k,type=Path,required=True)
    ap.add_argument('--jobs',type=int,default=8);args=ap.parse_args();args.out.mkdir(exist_ok=True,parents=True)
    rows=read(args.gt)['items'];assign_splits(rows);pred=read(args.estimator/'predictions-with-width.json')['items']
    if [r['itemID'] for r in rows]!=[r['itemID'] for r in pred]:raise ValueError('Item correspondence changed')
    obs={r['id']:{k:r[k] for k in ['id','rgb','rf','width','height','polygons','fontPixels']} for r in read(args.source_root/'boundary-lean/evaluation-manifest.json')['items']}
    fields=['itemID','page','crop','cropSHA256','sourceImageSHA256','pageSize','cropBounds','individualPolygonsCrop','mergedPolygonCrop','fontPixels'];jobs=[]
    for r,p in zip(rows,pred):
        source={k:r[k] for k in fields};source['mask']=str(args.masks/(r['itemID']+'.png'))
        jobs.append((source,obs[r['itemID']],p,r['review'].get('anchors') or [],str(args.source_root),str(args.ocr_evidence)))
    outputs=[];start=time.monotonic()
    with ProcessPoolExecutor(max_workers=args.jobs,initializer=initialize,initargs=(str(args.source_root),)) as pool:
        for n,result in enumerate(pool.map(worker,jobs,chunksize=4),1):
            outputs.append(result)
            if n%500==0:print('source pixel role points',n,flush=True)
    x=np.concatenate([r['x'] for r in outputs if len(r['y'])]);y=np.concatenate([r['y'] for r in outputs if len(r['y'])]);baseline=np.concatenate([r['baseline'] for r in outputs if len(r['y'])])
    groups=np.concatenate([np.repeat(split(row),len(r['y'])) for row,r in zip(rows,outputs) if len(r['y'])]);names=next(r['names'] for r in outputs if r['names'])
    np.savez_compressed(args.out/'point-features.npz',x=x,y=y,baseline=baseline,groups=groups)
    train=groups=='train';dev=groups=='dev';history=[];best=None;best_score=(-1,-1);best_pred=None
    configurations=[(7,False,100,10,5),(15,False,100,10,5),(7,True,100,10,5),(15,True,100,10,5),
        (7,False,160,10,5),(11,False,160,15,8),(15,False,160,20,10),(7,False,160,30,15)]
    for leaves,balanced,iterations,regularization,minimum in configurations:
        model=HistGradientBoostingClassifier(max_leaf_nodes=leaves,max_iter=iterations,min_samples_leaf=minimum,l2_regularization=regularization,early_stopping=False,
            class_weight='balanced' if balanced else None,random_state=71)
        model.fit(x[train],y[train]);prediction=model.predict(x);report={g:statistics(y[groups==g],prediction[groups==g]) for g in ['train','dev','test']}
        history.append(dict(leaves=leaves,balanced=balanced,iterations=iterations,regularization=regularization,minSamplesLeaf=minimum,metrics=report));quality=(report['dev']['macroF1'],report['dev']['accuracy'])
        if quality>best_score and (best is None or preserves_role_hits(report['dev'],selected['dev'])):
            best_score=quality;best=model;best_pred=prediction;selected=report;selected_configuration={k:v for k,v in history[-1].items() if k!='metrics'}
        print('pixel-role fit',leaves,balanced,'DEV',report['dev']['accuracy'],report['dev']['macroF1'],flush=True)
    base={g:statistics(y[groups==g],baseline[groups==g]) for g in ['train','dev','test']}
    accepted=selected['dev']['macroF1']>base['dev']['macroF1'] and selected['dev']['accuracy']>=base['dev']['accuracy']
    artifact=dict(version=VERSION,featureNames=names,classifier=best,probabilityThreshold=.8,
        appearanceModelSHA256=digest(args.estimator/'model.pkl'),GTAtInference=False,trainOnly=True,trainingConfiguration=selected_configuration)
    with (args.out/'pixel-role-model.pkl').open('wb') as f:pickle.dump(artifact,f)
    save(args.out/'RESULTS.json',dict(baseline=base,selected=selected,history=history,acceptedOnDEV=accepted,
        trainPointCounts=np.bincount(y[train],minlength=4).tolist(),skippedUncertainOrMismatchedPoints=sum(r['skipped'] for r in outputs),
        sourceFeatureCount=x.shape[1],sourceGeometryBenchmark=True,GTAtInference=False,GTChanged=False,
        shadowSupervisionSparse=True,selectedConfiguration=selected_configuration,selection='DEV macro F1 with no per-role hit-count regression from the incumbent; TEST descriptive only',seconds=time.monotonic()-start))
    print('pixel-role result',selected,'baseline',base,'accepted',accepted,flush=True)


if __name__=='__main__':main()
