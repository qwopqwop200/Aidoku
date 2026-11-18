"""Attach independently audited source ring evidence; leave all legacy predictions untouched."""
import argparse
import pickle
from pathlib import Path
from optimize_appearance import read,save,digest
from outline_layers import attach,VERSION


def check_dev_admission(current,previous=None):
    if current['falsePositive']!=0:raise ValueError('DEV layer precision regressed; retain existing estimator')
    if previous is not None and current['truePositive']<previous['truePositive']:
        raise ValueError('DEV layer recall regressed; retain existing estimator')


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--estimator',type=Path,required=True);ap.add_argument('--audit',type=Path,required=True);ap.add_argument('--reference-champion',type=Path)
    args=ap.parse_args();audit=read(args.audit);path=args.estimator/'predictions-with-width.json'
    if digest(path)!=audit['sourcePredictionSHA256']:raise ValueError('Audit and estimator are different snapshots')
    previous=None
    if args.reference_champion and (args.reference_champion/'OUTLINE-LAYERS-RESULTS.json').exists():
        previous=read(args.reference_champion/'OUTLINE-LAYERS-RESULTS.json')['metrics']['dev']
    check_dev_admission(audit['metrics']['dev'],previous)
    prediction=read(path);proposals={r['itemID']:r['proposal'] for r in audit['items'] if r['proposal']['reliable']}
    if any(e['version']!=VERSION for e in proposals.values()):raise ValueError('Ring evidence/source version changed')
    for row in prediction['items']:
        if row['itemID'] in proposals:attach(row,proposals[row['itemID']])
    # This additive head deliberately does not replace legacy nominal width: some GT total widths
    # conflict with their sum of layer widths. Preserve both physical evidence and old benchmark.
    modelpath=args.estimator/'width-model.pkl'
    with modelpath.open('rb') as f:model=pickle.load(f)
    model['sourceOutlineLayersVersion']=VERSION
    tmp=modelpath.with_suffix('.pkl.tmp')
    with tmp.open('wb') as f:pickle.dump(model,f)
    tmp.replace(modelpath);save(path,prediction)
    save(args.estimator/'OUTLINE-LAYERS-RESULTS.json',dict(metrics=audit['metrics'],itemCount=len(proposals),
        GTAtInference=False,GTChanged=False,legacyPredictionsPreserved=True,sourceVersion=VERSION,
        exploratoryBenchmark=True,sourceAuditSHA256=digest(args.audit),
        scalarWidthSemanticsConflict='Nominal total width and sum of labelled layers are not always consistent; physical total is separate'))
    print('Attached source ring evidence',len(proposals),flush=True)


if __name__=='__main__':main()
