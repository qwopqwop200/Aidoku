"""Attach source-pixel role/colour evidence while preserving retained scalar outputs and all GT."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import pickle
import shutil
import sys
import numpy as np
from PIL import Image
from optimize_appearance import read,save,digest,assign_splits,split
from source_confidence_evidence import raster
from pixel_role_estimation import describe,features
from paint_feature_context import feature_prediction
from source_appearance import lab
from train_pixel_roles import role_id,statistics

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'segmentation'))
from source_boundary_votes import SourceBoundaryVotes
from prepare_full_rf import load_case_features
VOTES=None;MODEL=None


def initialize(root,path):
    global VOTES,MODEL
    root=Path(root);VOTES=SourceBoundaryVotes(root/'boundary-lean',root/'deep-classifier-observations',root/'edge-context60-native',root/'edge-context60-observations')
    with Path(path).open('rb') as f:MODEL=pickle.load(f)


def worker(job):
    source,observation,prediction,root,ocr_folder=job
    rgb=np.asarray(Image.open(source['crop']).convert('RGB'));mask=np.asarray(Image.open(source['mask']))>0
    if digest(source['crop'])!=source['cropSHA256']:raise ValueError('Original RGB changed')
    p,q,_=VOTES.load(observation);rf=load_case_features(observation,Path(root)/'boundary-lean')
    ocr=raster(Path(ocr_folder)/(source['page']+'.json.gz'),source['sourceImageSHA256'],source['pageSize'],source['cropBounds'])
    geometry=dict(polygons=source['individualPolygonsCrop'],mergedPolygon=source['mergedPolygonCrop'],fontPixels=source['fontPixels'])
    context=None
    if MODEL.get('featureContext'):
        entry=read(source['featurePacket'])
        if entry['identity']['sourceRGBSHA256']!=source['cropSHA256']:raise ValueError('Pixel context/source RGB changed')
        context=feature_prediction(rgb,mask,entry['packet'],geometry,MODEL)
    description=describe(rgb,mask,rf,p,q,ocr,geometry,prediction,MODEL,feature_prediction=context)
    if not source.get('validatePoints'):return description
    positions=[];truth=[]
    for anchor in source['evaluationAnchors']:
        x,y=[int(round(v)) for v in anchor['xy']];target=role_id(anchor['role'])
        if target is None or not(0<=x<mask.shape[1] and 0<=y<mask.shape[0]):continue
        if anchor.get('rgb') is not None and np.linalg.norm(lab([rgb[y,x]])-lab([anchor['rgb']]))>10:continue
        positions.append(y*mask.shape[1]+x);truth.append(target)
    predicted=[]
    if positions:
        xx,names=features(rgb,mask,rf,p,q,ocr,geometry,context if context is not None else prediction,positions)
        if names!=MODEL['featureNames']:raise ValueError('Point validation/source feature schema changed')
        predicted=MODEL['classifier'].classes_[MODEL['classifier'].predict_proba(xx).argmax(1)].astype(int).tolist()
    return dict(description=description,truth=truth,predicted=predicted)


def main():
    ap=argparse.ArgumentParser()
    for k in ['gt','source-root','estimator','masks','ocr-evidence','model','validation']:ap.add_argument('--'+k,type=Path,required=True)
    ap.add_argument('--validate-points',action='store_true')
    ap.add_argument('--jobs',type=int,default=8);args=ap.parse_args()
    validation=read(args.validation)
    if not validation['acceptedOnDEV']:raise ValueError('Pixel-role head did not improve held-out source-point roles')
    with args.model.open('rb') as f:model=pickle.load(f)
    if model['appearanceModelSHA256']!=digest(args.estimator/'model.pkl'):raise ValueError('Pixel-role/base estimator mismatch')
    path=args.estimator/'predictions-with-width.json';before=digest(path);data=read(path);rows=read(args.gt)['items']
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in data['items']]:raise ValueError('Item correspondence changed')
    obs={r['id']:{k:r[k] for k in ['id','rgb','rf','width','height','polygons','fontPixels']} for r in read(args.source_root/'boundary-lean/evaluation-manifest.json')['items']}
    fields=['itemID','page','crop','cropSHA256','sourceImageSHA256','pageSize','cropBounds','individualPolygonsCrop','mergedPolygonCrop','fontPixels'];jobs=[]
    for r,p in zip(rows,data['items']):
        source={k:r[k] for k in fields};source['mask']=str(args.masks/(r['itemID']+'.png'))
        if model.get('featureContext'):source['featurePacket']=str(args.estimator/'features'/(r['itemID']+'.json'))
        if args.validate_points:source.update(validatePoints=True,evaluationAnchors=r['review'].get('anchors') or [])
        jobs.append((source,obs[r['itemID']],p,str(args.source_root),str(args.ocr_evidence)))
    values=[]
    with ProcessPoolExecutor(max_workers=args.jobs,initializer=initialize,initargs=(str(args.source_root),str(args.model))) as pool:
        for n,value in enumerate(pool.map(worker,jobs,chunksize=4),1):
            values.append(value)
            if n%500==0:print('source role/colour descriptions',n,flush=True)
    if digest(path)!=before:raise RuntimeError('Retained checkpoint changed during source inference')
    selected=validation['selected']
    if args.validate_points:
        assign_splits(rows);selected={}
        for group in ['train','dev','test']:
            actual=[v for r,v in zip(rows,values) if split(r)==group]
            truth=np.concatenate([np.asarray(v['truth'],int) for v in actual]);predicted=np.concatenate([np.asarray(v['predicted'],int) for v in actual]);selected[group]=statistics(truth,predicted)
    for p,value in zip(data['items'],values):p['pixelRoleEvidence']=value['description'] if args.validate_points else value
    save(path,data);shutil.copyfile(args.model,args.estimator/'pixel-role-model.pkl')
    save(args.estimator/'PIXEL-ROLE-RESULTS.json',dict(baseline=validation['baseline'],selected=selected,
        regionCount=len(rows),pointQueriesReevaluated=args.validate_points,featureContextPolicy=(model.get('featureContext') or {}).get('version'),trainingConfiguration=model.get('trainingConfiguration'),roleProbabilityThresholds=model.get('roleProbabilityThresholds',{}),trainPointCounts=validation['trainPointCounts'],sourceFeatureCount=validation['sourceFeatureCount'],
        GTAtInference=False,GTChanged=False,legacyScalarOutputsPreserved=True,
        scope='Held-out annotated pixel-role queries; dense sampled role palettes are observations, not a full-mask IoU measurement',
        shadowPhysicalParametersStillUnidentified=True,validationSHA256=digest(args.validation),sourcePredictionBeforeSHA256=before))
    print('Source role/colour descriptions attached',len(values),flush=True)


if __name__=='__main__':main()
