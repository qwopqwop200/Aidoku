"""Publish a whole-corpus-validated bounded sampler and refresh emitted evidence only."""
import argparse
import copy
from pathlib import Path
import pickle
import numpy as np
from PIL import Image
from optimize_appearance import read,save,digest
from outline_layers import measure,attach,VERSION
from outline_layer_discovery import correct_primary,PRIMARY_VERSION
from nested_outline import recover_presence


def main():
    ap=argparse.ArgumentParser()
    for name in ['gt','estimator','features','masks','audit']:ap.add_argument('--'+name,type=Path,required=True)
    args=ap.parse_args();audit=read(args.audit);path=args.estimator/'predictions-with-width.json';prior_hash=digest(path)
    if audit['sourcePredictionSHA256']!=prior_hash or audit['changes']:raise ValueError('Paired corpus validation does not match retained output')
    data=read(path);before=copy.deepcopy(data);raw={p['itemID']:p for p in read(args.estimator/'predictions.json')['items']};rows={r['itemID']:r for r in read(args.gt)['items']};updated=[]
    for p in data['items']:
        has_layers=bool(p['outline'].get('observedLayers'));has_primary=bool(p['outline'].get('primaryContourEvidence'))
        if not(has_layers or has_primary):continue
        r=rows[p['itemID']];packet=read(args.features/(r['itemID']+'.json'))['packet'];rgb=np.asarray(Image.open(r['crop']).convert('RGB'));mask=np.asarray(Image.open(args.masks/(r['itemID']+'.png')))>0
        if has_layers:
            evidence=measure(rgb,mask,p,r['fontPixels'],packet['colors'],r['individualPolygonsCrop'])
            assert evidence['reliable']
            assert [(v['rgb'],v['widthPx']) for v in evidence['layers']]==[(v['rgb'],v['widthPx']) for v in p['outline']['observedLayers']]
            attach(p,evidence)
        if has_primary:
            source=recover_presence(rgb,mask,raw[p['itemID']],r['fontPixels'],r['individualPolygonsCrop'])
            proposal=correct_primary(rgb,mask,source,packet,r['individualPolygonsCrop'])
            assert proposal['outline']['rgb']==p['outline']['rgb']
            p['outline']['primaryContourEvidence']=proposal['outline']['primaryContourEvidence']
        updated.append(p['itemID'])
    for a,b in zip(before['items'],data['items']):
        for role in ['fill','outline','background']:assert a[role]['rgb']==b[role]['rgb']
        assert a['outline']['widthPx']==b['outline']['widthPx'] and a['outline']['present']==b['outline']['present'] and a['shadow']==b['shadow']
    modelpath=args.estimator/'width-model.pkl'
    with modelpath.open('rb') as f:model=pickle.load(f)
    model.update(sourceOutlineLayersVersion=VERSION,sourcePrimaryContourVersion=PRIMARY_VERSION)
    with modelpath.with_suffix('.tmp').open('wb') as f:pickle.dump(model,f)
    modelpath.with_suffix('.tmp').replace(modelpath);save(path,data)
    layerpath=args.estimator/'OUTLINE-LAYERS-RESULTS.json';layers=read(layerpath);layers.update(sourceVersion=VERSION,boundedProfileValidationSHA256=digest(args.audit));save(layerpath,layers)
    primarypath=args.estimator/'PRIMARY-CONTOUR-RESULTS.json';primary=read(primarypath);primary.update(sourceVersion=PRIMARY_VERSION,boundedProfileValidationSHA256=digest(args.audit));save(primarypath,primary)
    save(args.estimator/'BOUNDED-PROFILE-RESULTS.json',dict(regionsValidated=len(data['items']),changedSemanticOutputs=0,refreshedEvidence=updated,
        excludedUnobservedCoordinates=audit['unobservedCoordinates'],GTChanged=False,inputContextExpanded=False,
        validationSHA256=digest(args.audit),sourcePredictionBeforeSHA256=prior_hash))
    print('Bounded profiles published; scalar outputs unchanged',len(data['items']),flush=True)


if __name__=='__main__':main()
