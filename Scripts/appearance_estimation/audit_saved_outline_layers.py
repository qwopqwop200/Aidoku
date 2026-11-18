"""Evaluation-only ordered physical-layer metrics. Never imported by inference."""
import argparse
from pathlib import Path
import numpy as np
from optimize_appearance import read,save,assign_splits,split,digest
from source_appearance import lab


def compare_layers(outline,observed):
    expected=outline.get('layers') or []
    if len(expected)<2:return dict(expectedMultilayer=False,emittedMultilayer=len(observed)>1)
    count_matches=len(observed)==len(expected)
    result=dict(expectedMultilayer=True,emittedMultilayer=len(observed)>1,countMatches=count_matches,
        orderedColoursWithin10=False,orderedWidthsInIntervals=False,orderedWidthsWithin1Px=False)
    if not count_matches:return result
    colours=[float(np.linalg.norm(lab([g['rgb']])-lab([p['rgb']]))) for g,p in zip(expected,observed)]
    widths=[float(p['widthPx']) for p in observed]
    intervals=[g.get('widthRangePx') for g in expected]
    width_valid=all(r is not None for r in intervals)
    inside=width_valid and all(r[0]<=w<=r[1] for r,w in zip(intervals,widths))
    near=width_valid and all(r[0]-1<=w<=r[1]+1 for r,w in zip(intervals,widths))
    result.update(orderedColourDeltaE=colours,orderedColoursWithin10=all(e<=10 for e in colours),
        orderedWidthsInIntervals=bool(inside),orderedWidthsWithin1Px=bool(near),
        nominalGTWidthPx=outline.get('widthPx'),sumGTLayerWidthsPx=float(sum(g['widthPx'] for g in expected)),
        observedTotalWidthPx=sum(widths),
        nominalWidthDiffersFromLayerSum=abs((outline.get('widthPx') or 0)-sum(g['widthPx'] for g in expected))>.5)
    if width_valid:
        lo=sum(g[0] for g in intervals);hi=sum(g[1] for g in intervals)
        result.update(sumGTLayerWidthIntervalPx=[lo,hi],observedTotalInSumInterval=lo<=sum(widths)<=hi)
    return result


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--gt',type=Path,required=True);ap.add_argument('--predictions',type=Path,required=True);ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args();rows=read(args.gt)['items'];assign_splits(rows);pred=read(args.predictions)['items']
    if [r['itemID'] for r in rows]!=[r['itemID'] for r in pred]:raise ValueError('Item correspondence changed')
    cases=[]
    for r,p in zip(rows,pred):
        observed=p['outline'].get('observedLayers') or []
        evidence=compare_layers(r['outline'],observed)
        if evidence['expectedMultilayer'] or evidence['emittedMultilayer']:
            cases.append(dict(itemID=r['itemID'],split=split(r),comparison=evidence,GTOutline=r['outline'],observedLayers=observed))
    metrics={}
    for group in ['train','dev','test','all']:
        select=[r['comparison'] for r in cases if group=='all' or r['split']==group]
        expected=[r for r in select if r['expectedMultilayer']];emitted=[r for r in select if r['emittedMultilayer']]
        colour=sum(r.get('orderedColoursWithin10',False) for r in select)
        strict=sum(r.get('orderedColoursWithin10',False) and r.get('orderedWidthsInIntervals',False) for r in select)
        approximate=sum(r.get('orderedColoursWithin10',False) and r.get('orderedWidthsWithin1Px',False) for r in select)
        metrics[group]=dict(expectedMultilayer=len(expected),emittedMultilayer=len(emitted),falseMultilayer=sum(not r['expectedMultilayer'] for r in emitted),
            orderedColourMatches=colour,orderedColourAndStrictWidthMatches=strict,orderedColourAndApproximateWidthMatches=approximate,
            completeOrderedLayerRecall=approximate/max(1,len(expected)),emittedOrderedColourPrecision=colour/max(1,len(emitted)))
    args.out.parent.mkdir(parents=True,exist_ok=True)
    save(args.out,dict(items=cases,metrics=metrics,comparesActualSavedOutputs=True,GTChanged=False,
        predictionSHA256=digest(args.predictions),GTSHA256=digest(args.gt),
        widthTarget='Ordered per-layer GT intervals; physical total compared to their summed intervals, never an inconsistent nominal scalar'))
    print(metrics,flush=True)


if __name__=='__main__':main()
