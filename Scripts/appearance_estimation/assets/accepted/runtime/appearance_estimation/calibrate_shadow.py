"""Rare positive shadow calibration: source evidence, DEV F1, no per-page exceptions."""
import argparse
from pathlib import Path
import pickle
import numpy as np
from optimize_appearance import read,save,assign_splits,split,train_presence,evaluate,objective,digest,evaluate_predictions


def width_snapshot_matches(snapshot,predictions,model_sha,item_ids):
    if len(snapshot['items'])!=len(predictions) or [p['itemID'] for p in snapshot['items']]!=item_ids:return False
    if model_sha and snapshot.get('sourceRoleModelSHA256')==model_sha:return True
    return all(all(old[f]['rgb']==new[f]['rgb'] for f in ['fill','outline','background']) and
        old['outline']['present']==new['outline']['present'] for old,new in zip(snapshot['items'],predictions))


def main():
    parser=argparse.ArgumentParser()
    for k in ['gt','out']:parser.add_argument('--'+k,type=Path,required=True)
    parser.add_argument('--reference-model',type=Path,help='Evaluate the previous retained source head alongside fresh fits')
    args=parser.parse_args();rows=read(args.gt)['items'];assign_splits(rows)
    packets=[read(args.out/'features'/(r['itemID']+'.json'))['packet'] for r in rows]
    prior_model_hash=digest(args.out/'model.pkl')
    with (args.out/'model.pkl').open('rb') as f:model=pickle.load(f)
    current_report,_=evaluate(rows,packets,model);save(args.out/'SHADOW-BEFORE.json',current_report)
    mask=np.array([split(r)=='dev' and r['shadow']['present'] is not None for r in rows])
    labels=np.array([r['shadow']['present'] is True for r in rows])[mask]
    best=(-1,-1,-1);selected=None;history=[]
    incumbent=model.get('shadowPresence');incumbent_threshold=float(model.get('shadowThreshold',.5))
    reference=None
    if args.reference_model:
        with args.reference_model.open('rb') as f:reference=pickle.load(f)
        if reference.get('featureVersion')!=model.get('featureVersion'):raise ValueError('Reference shadow/source feature contract mismatch')
    configurations=[dict(family='incumbent'),dict(family='reference-incumbent'),dict(leaves=7,iterations=100,regularization=10),dict(leaves=15,iterations=150,regularization=10),
                   dict(family='extra-trees',depth=8,minLeaf=5),dict(family='extra-trees',depth=16,minLeaf=5)]
    for config in configurations:
        family=config.get('family')
        if family=='incumbent':classifier=incumbent
        elif family=='reference-incumbent':classifier=reference.get('shadowPresence') if reference is not None else None
        else:classifier=train_presence(rows,packets,model,'shadow',config)
        if classifier is None:continue
        trial=dict(model);trial['shadowPresence']=classifier
        _,predictions=evaluate(rows,packets,trial)
        scores=np.array([p['shadow']['probability'] for p in predictions])[mask]
        original_threshold=None
        if classifier is incumbent:original_threshold=incumbent_threshold
        elif family=='reference-incumbent':original_threshold=float(reference.get('shadowThreshold',.5))
        thresholds=[original_threshold,*np.linspace(.02,.98,49)] if original_threshold is not None else np.linspace(.02,.98,49)
        for threshold in thresholds:
            flags=scores>=threshold;tp=int((flags&labels).sum());fp=int((flags&~labels).sum());fn=int((~flags&labels).sum())
            score=(2*tp/max(1,2*tp+fp+fn),tp/max(1,tp+fp),tp/max(1,tp+fn))
            history.append(dict(configuration=config,threshold=float(threshold),devTP=tp,devFP=fp,devFN=fn,devF1=score[0]))
            if score>best:best=score;selected=(classifier,float(threshold));selected_configuration=config
    model['shadowPresence'],model['shadowThreshold']=selected
    report,predictions=evaluate(rows,packets,model)
    with (args.out/'model.pkl').open('wb') as f:pickle.dump(model,f)
    save(args.out/'BEST.json',dict(iteration='independent-heads-shadow-F1',devObjective=objective(report['dev']),metrics=report,
        selectionObjective='colour accuracy + balanced outline presence + positive shadow F1'))
    save(args.out/'predictions.json',dict(schema='source-appearance-predictions-v1',itemCount=len(rows),GTAtInference=False,
        items=[dict(itemID=r['itemID'],**p) for r,p in zip(rows,predictions)]))
    width_path=args.out/'predictions-with-width.json'
    if width_path.exists():
        with_width=read(width_path)
        compatible=width_snapshot_matches(with_width,predictions,prior_model_hash,[r['itemID'] for r in rows])
        if compatible:
            for old,new in zip(with_width['items'],predictions):old['shadow']=new['shadow']
            with_width['sourceRoleModelSHA256']=digest(args.out/'model.pkl')
            save(width_path,with_width)
            raw_report=report;report=evaluate_predictions(rows,packets,with_width['items'])
            saved=read(args.out/'BEST.json');saved['modelOnlyMetrics']=raw_report;saved['metrics']=report
            saved['devObjective']=objective(report['dev']);save(args.out/'BEST.json',saved)
        else:
            # This generated artifact is invalidated; the next width stage recomputes it.
            width_path.unlink()
    save(args.out/'SHADOW-CALIBRATION.json',dict(selection='DEV positive F1, then precision/recall',history=history,metrics=report,
        devPositiveF1=best[0],incumbentIncluded=incumbent is not None,referenceIncumbentIncluded=reference is not None,incumbentSelected=selected[0] is incumbent,selectedConfiguration=selected_configuration,shadowGTPositives=sum(r['shadow']['present'] is True for r in rows)))
    print('shadow-F1',best,report['test']['shadowPresence'],flush=True)


if __name__=='__main__':main()
