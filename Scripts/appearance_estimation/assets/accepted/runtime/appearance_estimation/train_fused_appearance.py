"""Train appearance rankers with explicit RF/soft segmentation/bbox inputs; grouped TRAIN-only fitting."""
import argparse
from pathlib import Path
import pickle
import time
import numpy as np
from optimize_appearance import (read,save,digest,assign_splits,train_ranker,train_presence,
    batch_predictions,evaluate,objective,threshold_statistics)
from fused_source_appearance import VERSION
import fused_source_appearance


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
    started=time.monotonic()
    packets=[];rf_models=set()
    for row in rows:
        value=read(cache/(row['itemID']+'.json'))
        if value['itemID']!=row['itemID'] or value['packet']['version']!=VERSION:raise ValueError('Missing/stale RF fusion packet')
        if value['identity']['implementationSHA256']!=digest(Path(fused_source_appearance.__file__)):raise ValueError('Fusion source implementation changed; regenerate prepared features')
        if value['identity']['sourceRGBSHA256']!=row['cropSHA256'] or digest(row['crop'])!=row['cropSHA256']:raise ValueError('Source RGB mismatch')
        if value['identity']['predictedMaskSHA256']!=digest(args.masks/(row['itemID']+'.png')):raise ValueError('Predicted mask changed; regenerate fused source features')
        packets.append(value['packet']);rf_models.add(value['identity']['RFModelWeightsSHA256'])
    if len(rf_models)!=1:raise ValueError('Mixed RF model weights in source features')
    rf_weights=next(iter(rf_models))
    fusion=read(args.out/'FUSION-SOURCE-POLICY.json')
    if fusion['itemCount']!=len(rows) or not fusion['RFAndSoftPixelEvidenceDirectlyConsumed']:raise ValueError('Incomplete fusion source inputs')
    save(args.out/'SOURCE-POLICY.json',dict(GTAtInference=False,GTUsedForTrainingAndEvaluation=True,
        inputMaskSource=str(args.masks.resolve()),GTMaskAtInference=False,fixedGTLocalization=True,
        sourceContextMaxEachSide=.15,wholePagesOpened=False,pageSpecificRules=False,newCNN=False,
        splitting='Connected groups of identical source pages OR identical crops; group-hash train60/dev20/test20; historical corpus previously inspected',
        productionAppChanged=False,featureVersion=VERSION,inputGTSHA256=digest(args.gt),
        directRFEvidenceChannels=27,softSegmentationChannels=2,sourceOCRConfidenceChannels=8,exactMergedBBox=True,bboxActsAsHardClip=False,rfModelWeightsSHA256=rf_weights))
    baseline,_=evaluate(rows,packets,{})
    save(args.out/'BASELINE.json',baseline)
    best=None;score=-1;history=[];heads={};head_scores={};head_background_context=False;head_background_supervision=False
    for iteration in range(args.rounds):
        search=iteration+args.search_offset
        configuration=dict(leaves=[7,15,23,31][search%4],iterations=60+(search//4%6)*30,
                           regularization=[10.,5.,2.,1.][search%4],seed=47+search//24)
        print('training',iteration+1,configuration,flush=True)
        configuration['conditionedBackground']=search%8<4
        configuration['perPaintBackgroundSupervision']=(search//8)%2==1
        model={'featureVersion':VERSION,'conditionedBackground':configuration['conditionedBackground'],'perPaintBackgroundSupervision':configuration['perPaintBackgroundSupervision'],'rfModelWeightsSHA256':rf_weights};model['fill']=train_ranker(rows,packets,'fill',configuration)
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
                if role=='background':head_background_context=model['conditionedBackground'];head_background_supervision=model.get('perPaintBackgroundSupervision',False)
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
    joint=dict(heads,featureVersion=VERSION,conditionedBackground=head_background_context,perPaintBackgroundSupervision=head_background_supervision,rfModelWeightsSHA256=rf_weights)
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
