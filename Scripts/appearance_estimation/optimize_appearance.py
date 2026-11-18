"""Grouped GT evaluation and bounded-memory iterative source-appearance calibration."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import pickle
import sys
import time
import numpy as np
from PIL import Image

os.environ.setdefault('OMP_NUM_THREADS','1')
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
# These optional pandas accelerators are unused; host copies predate NumPy 2.
for optional_accelerator in ['pyarrow','bottleneck','numexpr']:
    sys.modules.setdefault(optional_accelerator,None)
from sklearn.ensemble import HistGradientBoostingClassifier, HistGradientBoostingRegressor, ExtraTreesClassifier
from source_appearance import VERSION, extract, heuristic, lab, predict, rank, role_features, summary_features


def read(path):
    return json.loads(Path(path).read_text())


def save(path, value):
    path=Path(path)
    tmp=path.with_suffix(path.suffix+'.tmp')
    tmp.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
    tmp.replace(path)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def split(row):
    if 'evaluationSplit' in row:
        return row['evaluationSplit']
    # Identical pages and exact duplicate pixels remain on the same side of every split.
    code=int(hashlib.sha256(('appearance-v1:'+row['sourceImageSHA256']).encode()).hexdigest()[:8],16)%10
    return 'train' if code<6 else 'dev' if code<8 else 'test'


def assign_splits(rows):
    parent={r['sourceImageSHA256']:r['sourceImageSHA256'] for r in rows}
    def find(key):
        while parent[key]!=key:
            parent[key]=parent[parent[key]];key=parent[key]
        return key
    crops={}
    for row in rows:
        image=row['sourceImageSHA256'];crop=row['cropSHA256']
        if crop in crops:
            a,b=find(image),find(crops[crop]);parent[max(a,b)]=min(a,b)
        else:crops[crop]=image
    for row in rows:
        group=find(row['sourceImageSHA256'])
        code=int(hashlib.sha256(('appearance-v1:'+group).encode()).hexdigest()[:8],16)%10
        row['evaluationSplit']='train' if code<6 else 'dev' if code<8 else 'test'
        row['evaluationGroup']=group
    for field in ['sourceImageSHA256','cropSHA256']:
        membership={}
        for row in rows:
            membership.setdefault(row[field],set()).add(split(row))
        if any(len(v)>1 for v in membership.values()):raise ValueError('Grouped split leaked exact source pixels')
    return dict(groupCount=len({r['evaluationGroup'] for r in rows}),exactSourceAndCropCrossSplitLeaks=0,
        itemCounts={s:sum(split(r)==s for r in rows) for s in ['train','dev','test']})


def collect_one(payload):
    row, folder, masks=payload
    cache=Path(folder)/(row['itemID']+'.json')
    mask=Path(masks)/(row['itemID']+'.png')
    identity=dict(version=VERSION,implementationSHA256=digest(Path(__file__).with_name('source_appearance.py')),cropSHA256=digest(row['crop']),predictedMaskSHA256=digest(mask),
                  polygons=row['individualPolygonsCrop'],fontPixels=row['fontPixels'])
    if identity['cropSHA256']!=row['cropSHA256']:
        raise ValueError('Source crop changed')
    if cache.exists():
        prior=read(cache)
        if prior.get('identity')==identity:
            return prior
    rgb=np.asarray(Image.open(row['crop']).convert('RGB'))
    predicted=np.asarray(Image.open(mask))>0
    packet=extract(rgb,predicted,row['individualPolygonsCrop'],row['fontPixels'])
    output=dict(itemID=row['itemID'],identity=identity,packet=packet)
    save(cache,output)
    return output


def targets(row, role):
    field=row[role]
    return field.get('colors') or ([field['rgb']] if field.get('rgb') is not None else [])


def color_errors(packet, row, role):
    t=targets(row,role)
    if not t:
        return None
    return np.linalg.norm(lab(packet['colors'])[:,None,:]-lab(t)[None,:,:],axis=2).min(1)


def train_ranker(rows,packets,role,configuration,fill_model=None,outline_model=None):
    features, labels, weights=[],[],[]
    contextual_background=role=='background' and configuration.get('conditionedBackground',False)
    fills=batch_rank(fill_model,packets,'fill') if role=='outline' or contextual_background else [None]*len(rows)
    outlines=batch_rank(outline_model,packets,'outline',fills) if contextual_background else [None]*len(rows)
    for row,p,fill,outline in zip(rows,packets,fills,outlines):
        if split(row)!='train' or role=='outline' and row['outline']['present'] is not True:
            continue
        errors=color_errors(p,row,role)
        if errors is None or errors.min()>15:
            continue
        x=role_features(p,role,fill,outline)
        if role=='background' and configuration.get('perPaintBackgroundSupervision',False):
            delta=np.linalg.norm(lab(p['colors'])[:,None,:]-lab(targets(row,role))[None,:,:],axis=2)
            tolerance=np.minimum(10,np.maximum(3,delta.min(0)+1))
            y=(delta<=tolerance[None,:]).any(1).astype(int)
        else:y=(errors<=max(3.,float(errors.min()+1))).astype(int)
        if role=='outline':
            y[fill]=0
        if not y.any():
            continue
        features.extend(x);labels.extend(y)
        weights.extend(np.where(y, .5/max(1,y.sum()), .5/max(1,(1-y).sum())))
    if configuration.get('family')=='extra-trees':
        model=ExtraTreesClassifier(n_estimators=96,max_depth=configuration['depth'],
            min_samples_leaf=configuration['minLeaf'],max_features=.8,n_jobs=8,random_state=configuration.get('seed',47))
    else:
        model=HistGradientBoostingClassifier(max_leaf_nodes=configuration['leaves'],max_iter=configuration['iterations'],
            l2_regularization=configuration['regularization'],learning_rate=.1,early_stopping=False,random_state=configuration.get('seed',47))
    model.fit(np.asarray(features),np.asarray(labels),sample_weight=np.asarray(weights)*len(weights))
    return model


def train_presence(rows,packets,model,role,configuration):
    x,y=[],[]
    source_predictions=batch_predictions(packets,model)
    for row,p,q in zip(rows,packets,source_predictions):
        if split(row)!='train' or row[role]['present'] is None:
            continue
        f,o,b=q['fillIndex'],q['outlineIndex'],q['backgroundIndex']
        x.append(summary_features(p,f,o,b));y.append(int(row[role]['present']))
    if configuration.get('family')=='extra-trees':
        classifier=ExtraTreesClassifier(n_estimators=128,max_depth=configuration['depth'],
            min_samples_leaf=configuration['minLeaf'],class_weight='balanced',n_jobs=8,random_state=47)
    else:
        classifier=HistGradientBoostingClassifier(max_leaf_nodes=min(configuration['leaves'],15),
            max_iter=configuration['iterations'],l2_regularization=configuration['regularization'],
            class_weight='balanced',early_stopping=False,random_state=47)
    classifier.fit(np.asarray(x),np.asarray(y))
    return classifier


def batch_rank(classifier,packets,role,fill=None,outline=None):
    lengths=[len(p['colors']) for p in packets];bounds=np.r_[0,np.cumsum(lengths)]
    if classifier is None:
        return [heuristic(p)[['fill','outline','background'].index(role)] for p in packets]
    x=np.concatenate([role_features(p,role,fill[i] if fill is not None else None,
        outline[i] if outline is not None else None) for i,p in enumerate(packets)])
    scores=classifier.predict_proba(x)[:,1]
    if role=='outline' and fill is not None:scores[bounds[:-1]+fill]=-1
    return [int(scores[bounds[i]:bounds[i+1]].argmax()) for i in range(len(packets))]


def batch_predictions(packets,model):
    fill=batch_rank(model.get('fill'),packets,'fill')
    outline=batch_rank(model.get('outline'),packets,'outline',fill)
    background=batch_rank(model.get('background'),packets,'background',fill,outline) if model.get('conditionedBackground') else batch_rank(model.get('background'),packets,'background')
    x=np.array([summary_features(p,f,o,b) for p,f,o,b in zip(packets,fill,outline,background)])
    op=model['outlinePresence'].predict_proba(x)[:,1] if 'outlinePresence' in model else np.full(len(x),.8)
    sp=model['shadowPresence'].predict_proba(x)[:,1] if 'shadowPresence' in model else np.zeros(len(x))
    return [dict(fillIndex=f,outlineIndex=o,backgroundIndex=b,fill=dict(rgb=p['colors'][f]),
        outline=dict(present=bool(a>=model.get('outlineThreshold',.5)),rgb=p['colors'][o],probability=float(a),widthPx=None,widthRangePx=None),
        background=dict(rgb=p['colors'][b]),shadow=dict(present=bool(s>=model.get('shadowThreshold',.5)),probability=float(s),
        rgb=None,offsetPx=None,blurRadiusPx=None,opacity=None),inferenceUsesGT=False,sourceOnly=True)
        for p,f,o,b,a,s in zip(packets,fill,outline,background,op,sp)]


def threshold_statistics(rows,predictions,role,thresholds,group='dev'):
    selected=[i for i,r in enumerate(rows) if split(r)==group and r[role]['present'] is not None]
    labels=np.array([rows[i][role]['present'] for i in selected],bool)
    scores=np.array([predictions[i][role]['probability'] for i in selected])
    results=[]
    for threshold in thresholds:
        flags=scores>=threshold
        tp=int((flags&labels).sum());fp=int((flags&~labels).sum());fn=int((~flags&labels).sum());tn=int((~flags&~labels).sum())
        results.append(dict(threshold=float(threshold),TP=tp,FP=fp,FN=fn,TN=tn,
            balancedAccuracy=.5*(tp/max(1,tp+fn)+tn/max(1,tn+fp)),precision=tp/max(1,tp+fp),
            positiveF1=2*tp/max(1,2*tp+fp+fn)))
    return results


def evaluate(rows,packets,model):
    predictions=batch_predictions(packets,model)
    return evaluate_predictions(rows,packets,predictions),predictions


def evaluate_predictions(rows,packets,predictions):
    output={}
    for group in ['train','dev','test','all']:
        selected=[i for i,r in enumerate(rows) if group=='all' or split(r)==group]
        report=dict(items=len(selected))
        for role in ['fill','outline','background']:
            distances=[];ceiling=[]
            for i in selected:
                row=rows[i]
                if role=='outline' and row[role]['present'] is not True:
                    continue
                e=color_errors(packets[i],row,role)
                if e is not None:
                    emitted=predictions[i][role].get('rgb')
                    distance=float(np.linalg.norm(lab([emitted])[0]-lab(targets(row,role)),axis=1).min()) if emitted is not None else float('inf')
                    distances.append(distance)
                    ceiling.append(float(e.min()))
            report[role]=dict(n=len(distances),deltaEMedian=float(np.median(distances)),
                deltaE90=float(np.quantile(distances,.9)),within10=float(np.mean(np.array(distances)<=10)),
                candidateCeilingWithin10=float(np.mean(np.array(ceiling)<=10)))
        for role in ['outline','shadow']:
            pairs=[(rows[i][role]['present'],predictions[i][role]['present']) for i in selected if rows[i][role]['present'] is not None]
            tp=sum(a is True and b for a,b in pairs);fp=sum(a is False and b for a,b in pairs)
            fn=sum(a is True and not b for a,b in pairs);tn=sum(a is False and not b for a,b in pairs)
            report[role+'Presence']=dict(TP=tp,FP=fp,FN=fn,TN=tn,accuracy=(tp+tn)/max(1,len(pairs)),
                recall=tp/max(1,tp+fn),precision=tp/max(1,tp+fp),balancedAccuracy=.5*(tp/max(1,tp+fn)+tn/max(1,tn+fp)))
        output[group]=report
    return output


def objective(report):
    s=report['shadowPresence'];f1=2*s['TP']/max(1,2*s['TP']+s['FP']+s['FN'])
    return sum(report[r]['within10'] for r in ['fill','outline','background'])/3*.75 + report['outlinePresence']['balancedAccuracy']*.2 + f1*.05


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--gt',type=Path,required=True)
    parser.add_argument('--masks',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=8)
    parser.add_argument('--rounds',type=int,default=3)
    parser.add_argument('--search-offset',type=int,default=0)
    parser.add_argument('--limit',type=int)
    args=parser.parse_args();args.out.mkdir(exist_ok=True,parents=True)
    cache=args.out/'features';cache.mkdir(exist_ok=True)
    gt=read(args.gt);rows=gt['items'][:args.limit] if args.limit else gt['items']
    split_report=assign_splits(rows);save(args.out/'GROUPED-SPLITS.json',split_report)
    # No label/style/anchor fields are passed to the extraction workers.
    allowed=['itemID','crop','cropSHA256','individualPolygonsCrop','fontPixels']
    source=[{k:r[k] for k in allowed} for r in rows]
    started=time.monotonic();collected=[]
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        for n,packet in enumerate(pool.map(collect_one,[(r,str(cache),str(args.masks)) for r in source],chunksize=4),1):
            collected.append(packet)
            if n%100==0 or n==len(rows):
                save(args.out/'PROGRESS.json',dict(stage='source-feature-extraction',completed=n,total=len(rows),seconds=time.monotonic()-started))
                print('source-features',n,'/',len(rows),round(time.monotonic()-started,1),flush=True)
    packets=[r['packet'] for r in collected]
    save(args.out/'SOURCE-POLICY.json',dict(GTAtInference=False,GTUsedForTrainingAndEvaluation=True,
        inputMaskSource=str(args.masks.resolve()),GTMaskAtInference=False,fixedGTLocalization=True,
        sourceContextMaxEachSide=.15,wholePagesOpened=False,pageSpecificRules=False,newCNN=False,
        splitting='Connected groups of identical source pages OR identical crops; group-hash train60/dev20/test20; historical corpus previously inspected',
        productionAppChanged=False,featureVersion=VERSION,inputGTSHA256=digest(args.gt)))
    baseline,_=evaluate(rows,packets,{})
    save(args.out/'BASELINE.json',baseline)
    best=None;score=-1;history=[];heads={};head_scores={};head_background_context=False
    for iteration in range(args.rounds):
        search=iteration+args.search_offset
        configuration=dict(leaves=[7,15,23,31][search%4],iterations=60+(search//4%6)*30,
                           regularization=[10.,5.,2.,1.][search%4],seed=47+search//24)
        print('training',iteration+1,configuration,flush=True)
        configuration['conditionedBackground']=search%8<4
        model={'featureVersion':VERSION,'conditionedBackground':configuration['conditionedBackground']};model['fill']=train_ranker(rows,packets,'fill',configuration)
        model['outline']=train_ranker(rows,packets,'outline',configuration,model['fill'])
        model['background']=train_ranker(rows,packets,'background',configuration,model['fill'],model['outline'])
        model['outlinePresence']=train_presence(rows,packets,model,'outline',configuration)
        model['shadowPresence']=train_presence(rows,packets,model,'shadow',configuration)
        # Thresholds are selected on DEV only; rare shadow positives never hidden by aggregate accuracy.
        source_predictions=batch_predictions(packets,model)
        choices=threshold_statistics(rows,source_predictions,'outline',[.1,.2,.3,.4,.5,.6,.7])
        model['outlineThreshold']=max(choices,key=lambda s:s['balancedAccuracy'])['threshold']
        report,predictions=evaluate(rows,packets,model)
        candidate=objective(report['dev'])
        for role in ['fill','outline','background']:
            quality=(report['dev'][role]['within10'],-report['dev'][role]['deltaEMedian'])
            if role not in head_scores or quality>head_scores[role]:
                head_scores[role]=quality;heads[role]=model[role]
                if role=='background':head_background_context=model['conditionedBackground']
        history.append(dict(iteration=iteration+1,configuration=configuration,devObjective=candidate,metrics=report))
        if candidate>score:
            score=candidate;best=model
            with (args.out/'model.pkl').open('wb') as f:pickle.dump(model,f)
            save(args.out/'predictions.json',dict(schema='source-appearance-predictions-v1',itemCount=len(rows),
                GTAtInference=False,items=[dict(itemID=r['itemID'],**p) for r,p in zip(rows,predictions)]))
            save(args.out/'BEST.json',history[-1])
        save(args.out/'HISTORY.json',dict(iterations=history,bestDevObjective=score,seconds=time.monotonic()-started))
        save(args.out/'PROGRESS.json',dict(stage='model-calibration',completedRounds=iteration+1,requestedRounds=args.rounds,bestDevObjective=score))
        print('iteration',iteration+1,'dev',round(candidate,5),'test fill/outline/background',
              [round(report['test'][r]['within10'],4) for r in ['fill','outline','background']],flush=True)
    # Select role heads independently on DEV, then refit presence using those exact source predictions.
    joint=dict(heads,featureVersion=VERSION,conditionedBackground=head_background_context)
    config=dict(leaves=7,iterations=100,regularization=10.)
    for role in ['outline','shadow']:
        joint[role+'Presence']=train_presence(rows,packets,joint,role,config)
        source_predictions=batch_predictions(packets,joint)
        choices=threshold_statistics(rows,source_predictions,role,[.05,.1,.15,.2,.3,.4,.5,.6,.7,.8,.9])
        key='positiveF1' if role=='shadow' else 'balancedAccuracy'
        joint[role+'Threshold']=max(choices,key=lambda s:(s[key],s['precision'],s['threshold']))['threshold']
    report,predictions=evaluate(rows,packets,joint)
    candidate=objective(report['dev'])
    save(args.out/'INDEPENDENT-HEADS.json',dict(metrics=report,devObjective=candidate,
        selectedHeadScores=head_scores,GTAtInference=False,selection='DEV only, independently per field'))
    if candidate>=score:
        with (args.out/'model.pkl').open('wb') as f:pickle.dump(joint,f)
        save(args.out/'predictions.json',dict(schema='source-appearance-predictions-v1',itemCount=len(rows),
            GTAtInference=False,items=[dict(itemID=r['itemID'],**p) for r,p in zip(rows,predictions)]))
        save(args.out/'BEST.json',dict(iteration='independent-heads',devObjective=candidate,metrics=report))
        score=candidate
    print('independent-heads dev',round(candidate,5),'best',round(score,5),flush=True)
    save(args.out/'PROGRESS.json',dict(stage='calibration-complete',rounds=args.rounds,seconds=time.monotonic()-started))


if __name__=='__main__':
    main()
