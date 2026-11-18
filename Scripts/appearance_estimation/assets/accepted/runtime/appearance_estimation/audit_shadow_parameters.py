"""Measure emitted shadow parameters, explicitly counting abstentions as missing."""
import argparse
from pathlib import Path
import numpy as np
from optimize_appearance import read,save,assign_splits,split,digest
from source_appearance import lab


def measure(rows,predictions):
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in predictions]:
        raise ValueError('Shadow parameter item correspondence changed')
    result={}
    for group in ['train','dev','test','all']:
        colour=[];offset=[];positives=0
        for row,prediction in zip(rows,predictions):
            if group!='all' and split(row)!=group:continue
            gt=row['shadow'];actual=prediction['shadow']
            if gt['present'] is not True:continue
            positives+=1
            if gt.get('rgb') is not None:
                delta=None
                if actual['present'] and actual.get('rgb') is not None:
                    delta=float(np.linalg.norm(lab([gt['rgb']])[0]-lab([actual['rgb']])[0]))
                colour.append(dict(itemID=row['itemID'],deltaE=delta,emitted=delta is not None,
                    within10=delta is not None and delta<=10))
            if gt.get('offsetPx') is not None:
                error=None
                if actual['present'] and actual.get('offsetPx') is not None:
                    error=float(np.linalg.norm(np.asarray(gt['offsetPx'])-np.asarray(actual['offsetPx'])))
                offset.append(dict(itemID=row['itemID'],errorPx=error,emitted=error is not None))
        errors=[r['errorPx'] for r in offset if r['emitted']]
        result[group]=dict(shadowPositiveCount=positives,
            colour=dict(labelled=len(colour),emitted=sum(r['emitted'] for r in colour),
                missing=sum(not r['emitted'] for r in colour),within10Count=sum(r['within10'] for r in colour),
                within10IncludingMissing=sum(r['within10'] for r in colour)/len(colour) if colour else None,items=colour),
            offset=dict(labelled=len(offset),emitted=len(errors),missing=len(offset)-len(errors),
                meanErrorPx=float(np.mean(errors)) if errors else None,
                within2PxCount=sum(e<=2 for e in errors),
                within2IncludingMissing=sum(e<=2 for e in errors)/len(offset) if offset else None,items=offset))
    return result


def main():
    ap=argparse.ArgumentParser()
    for field in ['gt','predictions','out']:ap.add_argument('--'+field,type=Path,required=True)
    args=ap.parse_args();rows=read(args.gt)['items'];groups=assign_splits(rows)
    predictions=read(args.predictions)['items']
    report=dict(metrics=measure(rows,predictions),grouping=groups,
        GTSHA256=digest(args.gt),predictionsSHA256=digest(args.predictions),
        policy='Only actual emitted shadow.rgb and shadow.offsetPx count; role-palette hypotheses are not scalar parameter predictions; missing is never a success',
        limitations=['Sparse colour labels; per-split support counts determine the measurable scope.',
            'GT intrinsic opacity/blur are unlabelled and cannot establish accuracy.',
            'Historical grouped corpus is not unseen external validation.'])
    save(args.out,report)
    print(report['metrics']['all'])


if __name__=='__main__':main()
