"""Audit source-only profile proposals; labelled-case selection is diagnostic, not runtime admission."""
import argparse
from pathlib import Path
import pickle
import time
import numpy as np
from PIL import Image
from optimize_appearance import read,save,assign_splits,split,digest
from source_appearance import role_features,lab
from source_edge_profiles import measure
from shadow_template_fit import estimate as template_estimate
from shadow_component_fit import estimate as component_estimate


def main():
    parser=argparse.ArgumentParser()
    for name in ['gt','estimator','masks','features','out']:parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--method',choices=['profiles','template','components'],default='profiles')
    args=parser.parse_args();args.out.mkdir(exist_ok=True,parents=True)
    initial_hashes={name:digest(args.estimator/name) for name in ['model.pkl','predictions-with-width.json']}
    rows=read(args.gt)['items'];assign_splits(rows);saved=read(args.estimator/'predictions-with-width.json')['items']
    if [r['itemID'] for r in rows]!=[r['itemID'] for r in saved]:raise ValueError('Item correspondence changed')
    with (args.estimator/'model.pkl').open('rb') as f:model=pickle.load(f)
    # Include all current admissions, all labelled positives and deterministic negative controls.
    selected={i for i,(r,p) in enumerate(zip(rows,saved)) if p['shadow']['present'] or r['shadow']['present'] is True}
    for group in ['train','dev','test']:
        controls=[i for i,r in enumerate(rows) if split(r)==group and r['shadow']['present'] is False]
        selected.update(sorted(controls,key=lambda i:rows[i]['cropSHA256'])[:10])
    records=[];start=time.monotonic()
    for i in sorted(selected):
        r,p=rows[i],saved[i];packet=read(args.features/(r['itemID']+'.json'))['packet']
        scores=model['fill'].predict_proba(role_features(packet,'fill'))[:,1]
        other=[c for c,s in zip(packet['colors'],scores) if s>.6 and np.linalg.norm(lab([c])-lab([p['outline']['rgb']]))>10]
        rgb=np.asarray(Image.open(r['crop']).convert('RGB'));mask=np.asarray(Image.open(args.masks/(r['itemID']+'.png')))>0
        if args.method in ['template','components']:
            estimator=component_estimate if args.method=='components' else template_estimate
            evidence=estimator(rgb,mask,p,r['fontPixels'],r['individualPolygonsCrop'])
        else:
            evidence=measure(rgb,mask,p['fill']['rgb'],p['outline']['rgb'],p['outline']['present'],r['fontPixels'],
                r['individualPolygonsCrop'],other,p['background']['rgb'])
        records.append(dict(itemID=r['itemID'],split=split(r),currentShadowPresent=p['shadow']['present'],
            GTShadow=r['shadow'],currentOutlineWidthPx=p['outline']['widthPx'],GTOutline=r['outline'],
            proposal=evidence,originalCrop=r['crop']))
        print(r['itemID'],'gate',p['shadow']['present'],'offset',evidence.get('offsetPx'),'RGB',evidence.get('observedCompositeRGB'),'outline',evidence.get('outlineRunPx',evidence.get('fittedCoreExpansionPx')),flush=True)
    report={}
    for group in ['train','dev','test','all']:
        cases=[r for r in records if split_filter(r,group)]
        offsets=[r for r in cases if r['GTShadow'].get('offsetPx') is not None and r['GTShadow']['present'] is True]
        available=[r for r in offsets if r['proposal'].get('offsetPx') is not None]
        colours=[r for r in cases if r['GTShadow'].get('rgb') is not None and r['GTShadow']['present'] is True]
        colour_available=[r for r in colours if r['proposal'].get('observedCompositeRGB') is not None]
        report[group]=dict(knownOffsets=len(offsets),proposedOffsets=len(available),
            offsetL1PixelsMean=float(np.mean([np.abs(np.array(r['GTShadow']['offsetPx'])-r['proposal']['offsetPx']).sum() for r in available])) if available else None,
            gatedOffsetCoverage=sum(r['currentShadowPresent'] for r in available),knownObservedColours=len(colours),proposedColours=len(colour_available),
            colourDeltaEMean=float(np.mean([np.linalg.norm(lab([r['GTShadow']['rgb']])-lab([r['proposal']['observedCompositeRGB']])) for r in colour_available])) if colour_available else None,
            controlDirectionalProposals=sum(r['GTShadow']['present'] is False and r['proposal'].get('directionalEvidence',r['proposal'].get('identified',False)) for r in cases))
    if any(digest(args.estimator/name)!=value for name,value in initial_hashes.items()):
        raise RuntimeError('Champion changed during audit; refusing mixed-snapshot metrics')
    save(args.out/'RESULTS.json',dict(diagnostics=report,items=records,GTAtInference=False,GTChanged=False,
        appliedToChampion=False,GTPositiveSelectionUsedOnlyForDiagnosticAudit=True,seconds=time.monotonic()-start,
        inputGTSHA256=digest(args.gt),inputModelSHA256=digest(args.estimator/'model.pkl')))
    print(report,flush=True)


def split_filter(row,group):return group=='all' or row['split']==group


if __name__=='__main__':main()
