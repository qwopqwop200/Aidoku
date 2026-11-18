"""Attach a paired source palette without deleting original paint evidence or scalar estimates."""
import argparse
from pathlib import Path
import pickle
import shutil
from optimize_appearance import read,save,digest,assign_splits,split
from paint_palette_metrics import measure,predicted_colours
from source_fill_palette import attach


def main():
    ap=argparse.ArgumentParser()
    for key in ['gt','estimator','features','model','validation']:ap.add_argument('--'+key,type=Path,required=True)
    args=ap.parse_args();validation=read(args.validation)
    with args.model.open('rb') as f:model=pickle.load(f)
    for field,name in [('appearanceModelSHA256','model.pkl'),('pixelRoleModelSHA256','pixel-role-model.pkl')]:
        if model[field]!=digest(args.estimator/name):raise ValueError('Source fill palette/model pairing changed')
    path=args.estimator/'predictions-with-width.json';before=digest(path)
    if model['sourcePredictionSHA256']!=before:raise ValueError('Source fill palette/prediction pairing changed')
    data=read(path);rows=read(args.gt)['items'];assign_splits(rows)
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in data['items']]:raise ValueError('Source fill palette correspondence changed')
    for row,p in zip(rows,data['items']):
        entry=read(args.features/(row['itemID']+'.json'))
        if entry['identity']['sourceRGBSHA256']!=row['cropSHA256']:raise ValueError('Source fill palette/RGB changed')
        attach(entry['packet'],p,model)
    actual={}
    for group in ['train','dev','test']:
        indices=[i for i,r in enumerate(rows) if split(r)==group];pp=[data['items'][i] for i in indices]
        actual[group]=measure([rows[i] for i in indices],pp,[predicted_colours(p) for p in pp])
        if actual[group]!=validation['metrics'][group]['selected']:raise ValueError('Actual source palette differs from validated output')
    if digest(path)!=before:raise RuntimeError('Checkpoint changed while attaching source fill palette')
    save(path,data)
    target=args.estimator/'source-fill-palette-model.pkl'
    if target.resolve()!=args.model.resolve():shutil.copyfile(args.model,target)
    save(args.estimator/'SOURCE-FILL-PALETTE-RESULTS.json',dict(selected=actual,baseline={g:validation['metrics'][g]['baseline'] for g in actual},
        acceptedOnDEV=validation['acceptedOnDEV'],calibrationNoOp=validation.get('calibrationNoOp',False),
        sourceFeatureCount=validation['featureCount'],GTAtInference=False,GTChanged=False,primaryColoursPreserved=True,
        allPixelRoleEvidencePreserved=True,validationSHA256=digest(args.validation),threshold=model['threshold'],
        appearanceModelSHA256=model['appearanceModelSHA256'],pixelRoleModelSHA256=model['pixelRoleModelSHA256']))
    print('Source fill palettes attached',len(rows),'actual TEST',actual['test'],flush=True)


if __name__=='__main__':main()
