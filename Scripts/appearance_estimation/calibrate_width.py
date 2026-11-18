"""Original-pixel width evidence and TRAIN-only robust width calibration."""
from width_resolution import predict as predict_width,project as project_width,RESOLUTIONS,VERSION as WIDTH_RESOLUTION_VERSION,helper_sha256 as width_helper_sha256
import width_resolution
import argparse
from concurrent.futures import ProcessPoolExecutor
import json
from pathlib import Path
import pickle
import sys
import numpy as np
from PIL import Image
from optimize_appearance import read,save,split,digest,assign_splits
from source_appearance import summary_features
from width_context import background_index,VERSION as CONTEXT_VERSION
from sklearn.ensemble import HistGradientBoostingRegressor, ExtraTreesRegressor

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'style_gt'))
from recheck_helper import outline_evidence


def measure(rgb,mask,fill,outline):
    evidence=outline_evidence(rgb,mask,fill,outline)
    q=evidence.get('coreRunPx',{})
    vector=[float(evidence.get('reliable',False)),float(evidence.get('suggestedWidthPx',0)),
            *[float(q.get(k,0)) for k in ['p10','p25','median','p75']],
            float(evidence.get('medianTransitionPx',0)),np.log1p(evidence.get('usableRays',0))]
    return evidence,vector


def worker(payload):
    item,folder=payload
    cache=Path(folder)/(item['itemID']+'.json')
    identity={k:item[k] for k in ['cropSHA256','predictedMaskSHA256','fill','outline']}
    if cache.exists():
        prior=read(cache)
        if prior['identity']==identity:return prior
    rgb=np.asarray(Image.open(item['crop']).convert('RGB'))
    mask=np.asarray(Image.open(item['mask']))>0
    evidence,vector=measure(rgb,mask,item['fill'],item['outline'])
    result=dict(itemID=item['itemID'],identity=identity,evidence=evidence,vector=vector)
    save(cache,result);return result


def width_features(packet,prediction,vector,context_model=None):
    f=packet['fontPixels']
    return np.r_[vector,[f,np.log1p(f)],np.asarray(vector[1:7])/max(1,f),
                 summary_features(packet,prediction['fillIndex'],prediction['outlineIndex'],background_index(packet,prediction,context_model))]


def adaptive_jobs(rows,predictions,packets,masks):
    """Explicit source whitelist: never send the labelled row to a worker."""
    return [dict(itemID=r['itemID'],crop=r['crop'],cropSHA256=r['cropSHA256'],
                 mask=str(masks/(r['itemID']+'.png')),
                 predictedMaskSHA256=digest(masks/(r['itemID']+'.png')),
                 fill=p['fill']['rgb'],outline=p['outline']['rgb'],
                 present=p['outline']['present'],fontPixels=packet['fontPixels'],
                 polygons=r.get('individualPolygonsCrop'))
            for r,p,packet in zip(rows,predictions,packets)]


def adaptive_worker(payload):
    item,folder,extension=payload
    from adaptive_normal_width import VERSION as measurement_version,measure as measure_normal,features as normal_features
    helper_hash=digest(Path(__file__).with_name('adaptive_normal_width.py'))
    if extension['helperSHA256']!=helper_hash or extension['measurementVersion']!=measurement_version:
        raise ValueError('Adaptive native width helper changed')
    identity={k:item[k] for k in ['cropSHA256','predictedMaskSHA256','fill','outline',
                                 'present','fontPixels','polygons']}
    identity.update(helperSHA256=helper_hash,measurementVersion=measurement_version,
                    version=extension['version'])
    if digest(item['crop'])!=item['cropSHA256'] or digest(item['mask'])!=item['predictedMaskSHA256']:
        raise ValueError('Adaptive native width source changed')
    cache=Path(folder)/(item['itemID']+'.json')
    if cache.exists():
        prior=read(cache)
        if prior.get('identity')==identity:return prior
    rgb=np.asarray(Image.open(item['crop']).convert('RGB'))
    mask=np.asarray(Image.open(item['mask']))>0
    evidence=measure_normal(rgb,mask,item['fill'],item['outline'],item['present'],
                            item['fontPixels'],polygons=item['polygons'])
    vector=np.asarray(normal_features(evidence,item['fontPixels']),dtype=float)
    if vector.shape!=(50,) or not np.isfinite(vector).all():
        raise ValueError('Invalid adaptive native width feature vector')
    if not item['present']:vector=np.zeros(50,dtype=float)
    result=dict(itemID=item['itemID'],identity=identity,vector=vector.tolist())
    save(cache,result)
    return result


def adaptive_matrix(incumbent,rows,predictions,packets,masks,out,jobs):
    if incumbent.get('adaptiveNormalRefinement') is None:return None
    validated=width_resolution.validate_adaptive(incumbent)
    cache=out/'adaptive-normal-width-features';cache.mkdir(exist_ok=True)
    source_jobs=adaptive_jobs(rows,predictions,packets,masks)
    # Measurements never need the fitted forest (or any labelled row data).
    extension={k:validated[k]
               for k in ['version','helperSHA256','measurementVersion']}
    with ProcessPoolExecutor(max_workers=jobs) as pool:
        measured=list(pool.map(adaptive_worker,[(item,str(cache),extension) for item in source_jobs],chunksize=4))
    if [m['itemID'] for m in measured]!=[p['itemID'] for p in predictions]:
        raise ValueError('Adaptive native width feature identities differ')
    return np.asarray([m['vector'] for m in measured],dtype=float)



def select_output_resolution(raw_values,presence,target,ranges,train,dev,baseline_values):
    """TRAIN/DEV only: retain hits and MAE, rank DEV hits then MAE."""
    def selection_metrics(values):
        emitted=np.where(presence,values,0.);result={}
        for name,selected in [('train',train),('dev',dev)]:
            value=emitted[selected];lo,hi=ranges[selected].T
            result[name]=dict(hits=int(((value>=lo)&(value<=hi)).sum()),MAEPx=float(abs(value-target[selected]).mean()))
        return result
    baseline=selection_metrics(baseline_values)
    history=[];chosen=None;quality=None;selected_values=None
    for resolution in RESOLUTIONS:
        values=project_width(raw_values,resolution);report=selection_metrics(values)
        eligible=all(report[g]['hits']>=baseline[g]['hits'] and report[g]['MAEPx']<=baseline[g]['MAEPx']+1e-12 for g in ['train','dev'])
        history.append(dict(resolutionPx=resolution,metrics=report,eligible=eligible))
        candidate=(report['dev']['hits'],-report['dev']['MAEPx'],-resolution)
        if eligible and (quality is None or candidate>quality):
            chosen=resolution;quality=candidate;selected_values=values
    if chosen is None:raise ValueError('No non-regressing native width resolution retained')
    return chosen,selected_values,dict(baseline=baseline,candidates=history,TESTUsedForSelection=False)


def main():
    parser=argparse.ArgumentParser()
    for name in ['gt','masks','out']:parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=8)
    parser.add_argument('--background-reference-model',type=Path,help='Optional source colour encoder for width features, independently selected on DEV')
    args=parser.parse_args();rows=read(args.gt)['items'];assign_splits(rows);pred=read(args.out/'predictions.json')['items']
    if [r['itemID'] for r in rows]!=[r['itemID'] for r in pred]:raise ValueError('Prediction/GT identities differ')
    packets=[read(args.out/'features'/(r['itemID']+'.json'))['packet'] for r in rows]
    cache=args.out/'width-features';cache.mkdir(exist_ok=True)
    # Whitelisted source inputs; no GT widths/colors reach the evidence worker.
    jobs=[dict(itemID=r['itemID'],crop=r['crop'],cropSHA256=r['cropSHA256'],
        mask=str(args.masks/(r['itemID']+'.png')),predictedMaskSHA256=digest(args.masks/(r['itemID']+'.png')),
        fill=p['fill']['rgb'],outline=p['outline']['rgb']) for r,p in zip(rows,pred)]
    measured=[]
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        for n,result in enumerate(pool.map(worker,[(r,str(cache)) for r in jobs],chunksize=4),1):
            measured.append(result)
            if n%500==0:
                print('width-evidence',n,flush=True)
                save(args.out/'PROGRESS.json',dict(stage='original-pixel-width-evidence',completed=n,total=len(rows)))
    x=np.array([width_features(p,q,e['vector']) for p,q,e in zip(packets,pred,measured)])
    y=np.array([r['outline'].get('widthPx') or 0 for r in rows]);ranges=np.array([r['outline'].get('widthRangePx') or [0,0] for r in rows])
    valid=np.array([r['outline']['present'] is True and r['outline'].get('widthPx') is not None for r in rows])
    groups=np.array([split(r) for r in rows]);train=valid&(groups=='train');dev=valid&(groups=='dev')
    baseline=np.array([m['evidence'].get('suggestedWidthPx',p['fontPixels']*.08) for m,p in zip(measured,packets)])
    def metrics(values):
        result={}
        emitted=np.where(np.array([p['outline']['present'] for p in pred]),values,0.)
        for group in ['train','dev','test','all']:
            select=valid&((groups==group) if group!='all' else True)
            error=np.abs(emitted[select]-y[select]);inside=(emitted[select]>=ranges[select,0])&(emitted[select]<=ranges[select,1])
            joint=inside&np.array([p['outline']['present'] for p in pred])[select]
            result[group]=dict(n=int(select.sum()),MAEPx=float(error.mean()),medianAbsoluteErrorPx=float(np.median(error)),
                withinGTRange=float(inside.mean()),jointPresentAndWidthInRange=float(joint.mean()),
                withinGTRangePlus1Px=float(((emitted[select]>=ranges[select,0]-1)&(emitted[select]<=ranges[select,1]+1)).mean()),
                latentWidthMAEPx=float(np.abs(values[select]-y[select]).mean()),
                directRayEvidenceCoverage=float(np.mean(x[select,0]>0)))
        return result
    history=[dict(method='raw-source-rays-or-font-fallback',metrics=metrics(baseline))]
    contexts=[('final-background',None,x)];incumbent=None;prior_path=args.out/'width-model.pkl'
    if prior_path.exists():
        with prior_path.open('rb') as f:incumbent=pickle.load(f)
        if incumbent.get('featureVersion')!=packets[0]['version']:incumbent=None
        elif incumbent.get('backgroundContextRanker') is not None:
            contexts.append(('incumbent-background',incumbent,np.array([width_features(p,q,e['vector'],incumbent) for p,q,e in zip(packets,pred,measured)])))
    if args.background_reference_model:
        with args.background_reference_model.open('rb') as f:reference=pickle.load(f)
        if reference.get('featureVersion')!=packets[0]['version']:raise ValueError('Reference background/source feature contract mismatch')
        context=dict(backgroundContextRanker=reference['background'],backgroundContextConditioned=reference.get('conditionedBackground',False),backgroundContextVersion=CONTEXT_VERSION,backgroundContextSourceSHA256=digest(args.background_reference_model))
        contexts.append(('independent-background',context,np.array([width_features(p,q,e['vector'],context) for p,q,e in zip(packets,pred,measured)])))
    best=None;score=(-1,-float('inf'));bestvalues=None;best_context=None;best_adaptive=None;normal=None
    if incumbent is not None:
        prior_x=np.array([width_features(p,q,e['vector'],incumbent) for p,q,e in zip(packets,pred,measured)])
        if incumbent['regressor'].n_features_in_==prior_x.shape[1]:
            normal=adaptive_matrix(incumbent,rows,pred,packets,args.masks,args.out,args.jobs)
            prior_values=predict_width(incumbent,prior_x,normal=normal) if normal is not None else predict_width(incumbent,prior_x)
            prior_report=metrics(prior_values)
            history.append(dict(method='incumbent-regressor',metrics=prior_report))
            best=incumbent['regressor'];bestvalues=prior_values;bestreport=prior_report;score=(prior_report['dev']['withinGTRange'],-prior_report['dev']['MAEPx']);best_context=incumbent if incumbent.get('backgroundContextRanker') is not None else None
            best_adaptive=incumbent.get('adaptiveNormalRefinement')
    for context_name,context_model,context_x in contexts:
        for leaves in [7,15,23]:
            for target_policy in ['nominal','interval-midpoint','narrow-range-weighted']:
                target=y if target_policy!='interval-midpoint' else ranges.mean(1)
                weights=1/(.5+ranges[:,1]-ranges[:,0]) if target_policy=='narrow-range-weighted' else np.ones(len(y))
                model=HistGradientBoostingRegressor(max_leaf_nodes=leaves,max_iter=100,l2_regularization=10,
                    loss='absolute_error',early_stopping=False,random_state=47)
                model.fit(context_x[train],target[train],sample_weight=weights[train]);values=np.maximum(.25,model.predict(context_x));report=metrics(values)
                candidate=(report['dev']['withinGTRange'],-report['dev']['MAEPx'])
                history.append(dict(method='source-evidence-regression',context=context_name,leaves=leaves,targetPolicy=target_policy,metrics=report))
                if candidate>score:score=candidate;best=model;bestvalues=values;bestreport=report;best_context=context_model;best_adaptive=None
        # Source-ray reliability and paint transitions have nonlinear interactions.
        # Compare a second tabular family under the same TRAIN/DEV contract.
        for leaf in [2,5]:
            model=ExtraTreesRegressor(n_estimators=192,min_samples_leaf=leaf,
                max_features=1.,random_state=47,n_jobs=args.jobs)
            model.fit(context_x[train],y[train]);values=np.maximum(.25,model.predict(context_x));report=metrics(values)
            candidate=(report['dev']['withinGTRange'],-report['dev']['MAEPx'])
            history.append(dict(method='source-evidence-extra-trees',context=context_name,
                minSamplesLeaf=leaf,targetPolicy='nominal',metrics=report))
            if candidate>score:score=candidate;best=model;bestvalues=values;bestreport=report;best_context=context_model;best_adaptive=None
    # Calibrate one global native width resolution, without querying TEST labels.
    raw_x=np.array([width_features(p,q,e['vector'],best_context) for p,q,e in zip(packets,pred,measured)])
    selected_model=dict(regressor=best)
    if best_adaptive is not None:selected_model['adaptiveNormalRefinement']=best_adaptive
    raw_values=width_resolution.raw(selected_model,raw_x,normal=normal) if best_adaptive is not None else width_resolution.raw(selected_model,raw_x)
    presence=np.array([p['outline']['present'] for p in pred])
    chosen,bestvalues,resolution_selection=select_output_resolution(raw_values,presence,y,ranges,train,dev,bestvalues)
    bestreport=metrics(bestvalues)
    residual=np.abs(bestvalues[dev&presence]-y[dev&presence]);radius=float(np.quantile(residual,.9))
    artifact=dict(regressor=best,uncertaintyRadiusPx=radius,featureVersion=packets[0]['version'],
        outputResolutionPx=chosen,outputResolutionVersion=WIDTH_RESOLUTION_VERSION,
        outputResolutionHelperSHA256=width_helper_sha256(),
        outputResolutionSelection=resolution_selection)
    if best_adaptive is not None:artifact['adaptiveNormalRefinement']=best_adaptive
    if best_context is not None:artifact.update({k:v for k,v in best_context.items() if k.startswith('backgroundContext')})
    with (args.out/'width-model.pkl').open('wb') as f:pickle.dump(artifact,f)
    save(args.out/'WIDTH-RESULTS.json',dict(history=history,selected=bestreport,dev90AbsoluteResidualPx=radius,
        GTAtInference=False,trainOnly=True,GTWidthRangesAreApproximate=True,incumbentIncluded=incumbent is not None,outputResolutionPx=chosen,outputResolutionSelection=artifact['outputResolutionSelection'],independentBackgroundContext=best_context is not None))
    for p,value,m in zip(pred,bestvalues,measured):
        p['outline']['widthPx']=float(value) if p['outline']['present'] else 0
        p['outline']['widthRangePx']=[max(0,float(value)-radius),float(value)+radius] if p['outline']['present'] else [0,0]
        p['outline']['measurementEvidence']=m['evidence']
    save(args.out/'predictions-with-width.json',dict(schema='source-appearance-predictions-v1',itemCount=len(rows),GTAtInference=False,
        sourceRoleModelSHA256=digest(args.out/'model.pkl'),items=pred))
    print(json.dumps(bestreport),flush=True)
    save(args.out/'PROGRESS.json',dict(stage='width-calibration-complete',configurations=len(history)-1))


if __name__=='__main__':main()
