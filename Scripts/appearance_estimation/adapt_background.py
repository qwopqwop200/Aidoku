"""Evaluate a source-role-conditioned background estimator against a frozen champion."""
import argparse
from pathlib import Path
import pickle
import time
from optimize_appearance import read,save,assign_splits,train_ranker,train_presence,evaluate,objective,batch_predictions,threshold_statistics
from continuous_optimize import copy_checkpoint


def main():
    parser=argparse.ArgumentParser()
    for name in ['gt','baseline','features','width-features','out']:parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args();start=time.monotonic();args.out.mkdir(exist_ok=True,parents=True)
    copy_checkpoint(args.baseline,args.out)
    for name,path in [('features',args.features),('width-features',args.width_features)]:
        link=args.out/name
        if not link.exists():link.symlink_to(path.resolve(),target_is_directory=True)
    rows=read(args.gt)['items'];assign_splits(rows)
    packets=[read(args.features/(r['itemID']+'.json'))['packet'] for r in rows]
    with (args.baseline/'model.pkl').open('rb') as f:model=pickle.load(f)
    baseline,_=evaluate(rows,packets,model);history=[];selected=(-1,-float('inf'));head=None
    for leaves in [7,15,23]:
        for count in [80,150]:
            config=dict(leaves=leaves,iterations=count,regularization=10.,conditionedBackground=True)
            candidate=train_ranker(rows,packets,'background',config,model['fill'],model['outline'])
            trial=dict(model,background=candidate,conditionedBackground=True)
            report,_=evaluate(rows,packets,trial);stats=report['dev']['background'];score=(stats['within10'],-stats['deltaEMedian'])
            history.append(dict(configuration=config,metrics=report))
            if score>selected:selected=score;head=candidate
            save(args.out/'BACKGROUND-CONTEXT-HISTORY.json',dict(before=baseline,iterations=history))
            print('background-context',leaves,count,'dev',stats['within10'],'test',report['test']['background']['within10'],flush=True)
    model.update(background=head,conditionedBackground=True)
    for role in ['outline','shadow']:
        quality_key='positiveF1' if role=='shadow' else 'balancedAccuracy'
        best=(-1,-1);chosen=None
        for config in [dict(leaves=7,iterations=100,regularization=10.),dict(leaves=15,iterations=150,regularization=10.),
                       dict(family='extra-trees',depth=8,minLeaf=5),dict(family='extra-trees',depth=16,minLeaf=5)]:
            classifier=train_presence(rows,packets,model,role,config)
            trial=dict(model);trial[role+'Presence']=classifier;predictions=batch_predictions(packets,trial)
            for stats in threshold_statistics(rows,predictions,role,[.03,.05,.1,.15,.2,.3,.4,.5,.6,.7,.8,.9]):
                score=(stats[quality_key],stats['precision'])
                if score>best:best=score;chosen=(classifier,stats['threshold'])
        model[role+'Presence'],model[role+'Threshold']=chosen
    report,predictions=evaluate(rows,packets,model)
    with (args.out/'model.pkl').open('wb') as f:pickle.dump(model,f)
    save(args.out/'BEST.json',dict(iteration='role-conditioned-background',devObjective=objective(report['dev']),metrics=report))
    save(args.out/'predictions.json',dict(schema='source-appearance-predictions-v1',itemCount=len(rows),GTAtInference=False,
        items=[dict(itemID=r['itemID'],**p) for r,p in zip(rows,predictions)]))
    save(args.out/'BACKGROUND-CONTEXT-RESULTS.json',dict(before=baseline,after=report,seconds=time.monotonic()-start,
        chosenOn='DEV only',inferenceUsesGT=False,backgroundConditionedOn='selected source fill and outline predictions'))
    print('background-context-complete',report['dev'],flush=True)


if __name__=='__main__':main()
