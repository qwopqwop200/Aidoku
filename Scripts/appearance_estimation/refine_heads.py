"""Extend automatic per-field model-family search without touching inference GT."""
import argparse
from pathlib import Path
import pickle
from optimize_appearance import read,save,assign_splits,train_ranker,train_presence,evaluate,objective,batch_predictions,threshold_statistics


def reference_colour_trial(model,reference,role):
    if reference.get('featureVersion')!=model.get('featureVersion'):raise ValueError('Reference colour/source feature contract mismatch')
    trial=dict(model);trial[role]=reference[role]
    if role=='background':
        trial['conditionedBackground']=reference.get('conditionedBackground',False)
        trial['perPaintBackgroundSupervision']=reference.get('perPaintBackgroundSupervision',False)
    return trial


def main():
    parser=argparse.ArgumentParser()
    for k in ['gt','out']:parser.add_argument('--'+k,type=Path,required=True)
    parser.add_argument('--reference-model',type=Path)
    args=parser.parse_args();rows=read(args.gt)['items'];assign_splits(rows)
    packets=[read(args.out/'features'/(r['itemID']+'.json'))['packet'] for r in rows]
    with (args.out/'model.pkl').open('rb') as f:model=pickle.load(f)
    reference=None
    if args.reference_model:
        with args.reference_model.open('rb') as f:reference=pickle.load(f)
        if reference.get('featureVersion')!=model.get('featureVersion'):raise ValueError('Reference presence/source feature contract mismatch')
    before=read(args.out/'BEST.json');save(args.out/'BEFORE-REFINEMENT.json',before)
    report,_=evaluate(rows,packets,model);history=[]
    for role in ['fill','outline','background']:
        selected=(report['dev'][role]['within10'],-report['dev'][role]['deltaEMedian'])
        if reference is not None:
            trial=reference_colour_trial(model,reference,role);metrics,_=evaluate(rows,packets,trial)
            quality=(metrics['dev'][role]['within10'],-metrics['dev'][role]['deltaEMedian'])
            history.append(dict(role=role,configuration=dict(family='reference-incumbent'),metrics=metrics,selected=quality>selected))
            if quality>selected:model=trial;selected=quality;report=metrics
        for depth in [8,16,24]:
            for leaf in [5,20]:
                config=dict(family='extra-trees',depth=depth,minLeaf=leaf,conditionedBackground=model.get('conditionedBackground',False),perPaintBackgroundSupervision=model.get('perPaintBackgroundSupervision',False))
                candidate=train_ranker(rows,packets,role,config,model['fill'],model['outline'])
                trial=dict(model);trial[role]=candidate;metrics,_=evaluate(rows,packets,trial)
                score=(metrics['dev'][role]['within10'],-metrics['dev'][role]['deltaEMedian'])
                history.append(dict(role=role,configuration=config,metrics=metrics,selected=score>selected))
                if score>selected:model=trial;selected=score;report=metrics
                save(args.out/'REFINEMENT-HISTORY.json',dict(iterations=history))
                save(args.out/'PROGRESS.json',dict(stage='per-field-family-refinement',completed=len(history),total=18+(3 if reference is not None else 0)))
                print('refinement',role,depth,leaf,'dev',score[0],flush=True)
    presence_selection={}
    for role in ['outline','shadow']:
        # Refit on the exact final colour-head predictions, using TRAIN only.
        incumbent=model.get(role+'Presence');threshold=float(model.get(role+'Threshold',.5))
        initial=threshold_statistics(rows,batch_predictions(packets,model),role,[threshold])[0]
        metric='positiveF1' if role=='shadow' else 'balancedAccuracy'
        choice=(incumbent,threshold);best=(initial[metric],initial['precision']);selected_config=dict(family='incumbent')
        if reference is not None and reference.get(role+'Presence') is not None:
            trial=dict(model);trial[role+'Presence']=reference[role+'Presence'];source_predictions=batch_predictions(packets,trial)
            for s in threshold_statistics(rows,source_predictions,role,[float(reference.get(role+'Threshold',.5)),.03,.05,.1,.15,.2,.3,.4,.5,.6,.7,.8,.9]):
                quality=(s[metric],s['precision'])
                if quality>best:best=quality;choice=(reference[role+'Presence'],s['threshold']);selected_config=dict(family='reference-incumbent')
        for config in [dict(leaves=7,iterations=100,regularization=10),dict(leaves=15,iterations=150,regularization=10),
                       dict(family='extra-trees',depth=8,minLeaf=5),dict(family='extra-trees',depth=16,minLeaf=5)]:
            classifier=train_presence(rows,packets,model,role,config)
            trial=dict(model);trial[role+'Presence']=classifier
            predictions=batch_predictions(packets,trial)
            for s in threshold_statistics(rows,predictions,role,[.03,.05,.1,.15,.2,.3,.4,.5,.6,.7,.8,.9]):
                threshold=s['threshold']
                quality=s['positiveF1'] if role=='shadow' else s['balancedAccuracy']
                score=(quality,s['precision'])
                if score>best:best=score;choice=(classifier,threshold);selected_config=config
        model[role+'Presence'],model[role+'Threshold']=choice
        presence_selection[role]=dict(incumbentMetric=initial[metric],selectedMetric=best[0],selectedConfiguration=selected_config,incumbentSelected=choice[0] is incumbent)
        print('refined-presence',role,best,'threshold',choice[1],flush=True)
    report,predictions=evaluate(rows,packets,model)
    save(args.out/'REFINEMENT-RESULTS.json',dict(metrics=report,devObjective=objective(report['dev']),
        presenceSelection=presence_selection,GTAtInference=False,trainedOn='TRAIN only',selectedOn='DEV only'))
    if objective(report['dev'])>=before['devObjective']:
        with (args.out/'model.pkl').open('wb') as f:pickle.dump(model,f)
        save(args.out/'BEST.json',dict(iteration='refined-independent-heads',devObjective=objective(report['dev']),metrics=report))
        save(args.out/'predictions.json',dict(schema='source-appearance-predictions-v1',itemCount=len(rows),GTAtInference=False,
            items=[dict(itemID=r['itemID'],**p) for r,p in zip(rows,predictions)]))
    print('refinement-complete',report['dev'],flush=True)
    save(args.out/'PROGRESS.json',dict(stage='field-refinement-complete',selectedDevObjective=max(before['devObjective'],objective(report['dev']))))


if __name__=='__main__':main()
