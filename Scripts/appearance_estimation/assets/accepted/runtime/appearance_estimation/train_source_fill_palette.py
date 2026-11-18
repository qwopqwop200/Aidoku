"""Supervise every TRAIN fill/substyle colour; choose confidence using DEV exclusively."""
import argparse
from pathlib import Path
import pickle
import numpy as np
from optimize_appearance import read,save,digest,assign_splits,split
from sklearn.ensemble import HistGradientBoostingClassifier
from paint_palette_metrics import targets,measure
from source_appearance import lab
from source_fill_palette import features,augment,VERSION


def main():
    ap=argparse.ArgumentParser()
    for k in ['gt','estimator','features','out']:ap.add_argument('--'+k,type=Path,required=True)
    args=ap.parse_args();args.out.mkdir(exist_ok=True,parents=True)
    rows=read(args.gt)['items'];assign_splits(rows);pred=read(args.estimator/'predictions-with-width.json')['items']
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in pred]:raise ValueError('Item correspondence changed')
    initial=dict(appearanceModelSHA256=digest(args.estimator/'model.pkl'),pixelRoleModelSHA256=digest(args.estimator/'pixel-role-model.pkl'),sourcePredictionSHA256=digest(args.estimator/'predictions-with-width.json'))
    packets=[];train_x=[];train_y=[];weights=[];source_version=None
    for row,p in zip(rows,pred):
        entry=read(args.features/(row['itemID']+'.json'));packet=entry['packet'];identity=entry['identity'];packets.append(packet)
        if entry['itemID']!=row['itemID'] or identity['sourceRGBSHA256']!=row['cropSHA256']:raise ValueError('Source pixel correspondence changed')
        source_version=packet['version']
        if split(row)!='train':continue
        colour_distance=np.linalg.norm(lab(packet['colors'])[:,None,:]-lab(targets(row))[None,:,:],axis=2)
        distance=colour_distance.min(1)
        # Each GT paint independently supervises its closest source colour cores.
        # Nearby antialias shades no longer become positives merely by being within 10.
        tolerance=np.minimum(10,np.maximum(3,colour_distance.min(0)+1))
        positives=(colour_distance<=tolerance[None,:]).any(1)
        known=(distance<=10)|(distance>=15);xx=features(packet,p)[known];yy=positives[known].astype(int)
        if not yy.any():continue
        ww=np.where(yy,.5/max(1,yy.sum()),.5/max(1,(1-yy).sum()))
        train_x.append(xx);train_y.append(yy);weights.append(ww)
    x=np.concatenate(train_x);y=np.concatenate(train_y);weight=np.concatenate(weights);weight*=len(weight)/weight.sum()
    dev=[i for i,r in enumerate(rows) if split(r)=='dev'];rr=[rows[i] for i in dev];pp=[pred[i] for i in dev]
    baseline=measure(rr,pp,[p['pixelRoleEvidence']['roles']['fill']['observedColours'] for p in pp]);best=(baseline['colourRecall'],0.,baseline['annotatedColourPrecision']);winner=None;history=[]
    for leaves in [7,15,23]:
        classifier=HistGradientBoostingClassifier(max_leaf_nodes=leaves,max_iter=140,min_samples_leaf=25,l2_regularization=10,early_stopping=False,random_state=89).fit(x,y,sample_weight=weight)
        dev_scores={i:classifier.predict_proba(features(packets[i],pred[i]))[:,1] for i in dev}
        for prune_threshold in [0]:
            for threshold in [.5,.7,.85,.95,.98,.995]:
                model=dict(version=VERSION,sourceFeatureVersion=source_version,classifier=classifier,threshold=threshold,pruneThreshold=prune_threshold,pruneBackgroundDelta=20,mergeDelta=10,limit=12)
                metric=measure(rr,pp,[augment(packets[i],pred[i],model,dev_scores[i]) for i in dev]);quality=(metric['colourRecall'],-prune_threshold,metric['annotatedColourPrecision'])
                history.append(dict(leaves=leaves,threshold=threshold,pruneThreshold=prune_threshold,dev=metric))
                if metric['annotatedColourPrecision']>=baseline['annotatedColourPrecision'] and quality>best:best=quality;winner=dict(model=model,leaves=leaves,dev=metric)
            print('full-source fill',leaves,'prune',prune_threshold,'best',best,flush=True)

    final=dict(appearanceModelSHA256=digest(args.estimator/'model.pkl'),pixelRoleModelSHA256=digest(args.estimator/'pixel-role-model.pkl'),sourcePredictionSHA256=digest(args.estimator/'predictions-with-width.json'))
    if initial!=final:raise RuntimeError('Checkpoint changed during palette training')
    report=dict(identity=initial,baselineDEV=baseline,history=history,acceptedOnDEV=winner is not None,trainCandidates=len(y),featureCount=x.shape[1],GTAtInference=False,GTChanged=False,selection='Each TRAIN fill colour independently selects its closest observed colour cores; DEV recall first, least pruning second, precision third, with baseline precision floor; TEST descriptive only',metrics={})
    for group in ['train','dev','test']:
        indices=[i for i,r in enumerate(rows) if split(r)==group];gg=[rows[i] for i in indices];predictions=[pred[i] for i in indices]
        report['metrics'][group]=dict(baseline=measure(gg,predictions,[p['pixelRoleEvidence']['roles']['fill']['observedColours'] for p in predictions]),
            oracle=measure(gg,predictions,[[dict(rgb=c) for c in packets[i]['colors']] for i in indices]))
        report['metrics'][group]['selected']=measure(gg,predictions,[augment(packets[i],pred[i],winner['model']) for i in indices]) if winner else report['metrics'][group]['baseline']
    if winner:
        model=winner['model'];model.update(initial);report.update(threshold=model['threshold'],pruneThreshold=model['pruneThreshold'],leaves=winner['leaves'])
        with (args.out/'source-fill-palette-model.pkl').open('wb') as f:pickle.dump(model,f)
    else:
        # Explicitly paired no-op preserves a complete checkpoint when no added colour is validated.
        model=dict(version=VERSION,sourceFeatureVersion=source_version,classifier=classifier,threshold=1.1,pruneThreshold=0,mergeDelta=10,limit=12,**initial)
        with (args.out/'source-fill-palette-model.pkl').open('wb') as f:pickle.dump(model,f)
        report.update(threshold=1.1,pruneThreshold=0,calibrationNoOp=True)
    save(args.out/'RESULTS.json',report);print('accepted',report['acceptedOnDEV'],report['metrics'],flush=True)


if __name__=='__main__':main()
