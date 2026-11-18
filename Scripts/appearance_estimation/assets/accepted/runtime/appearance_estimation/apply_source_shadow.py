"""Attach observed source shadow parameters; GT styles are evaluated only afterwards."""
import argparse
import copy
import json
from pathlib import Path
import pickle
import sys
import numpy as np
from PIL import Image
from optimize_appearance import read,save,assign_splits,digest,split
from source_shadow_observation import attach_with_width_context as attach,VERSION
from source_shadow_presence import restore_baseline,calibrate,apply as apply_presence,emitted_metrics,VERSION as PRESENCE_VERSION
from shadow_displacement_evidence import VERSION as DISPLACEMENT_VERSION
from audit_shadow_parameters import measure
from source_confidence_evidence import raster

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'segmentation'))
from source_boundary_votes import SourceBoundaryVotes
from prepare_full_rf import load_case_features


def main():
    ap=argparse.ArgumentParser()
    for name in ['gt','estimator','source-root','masks','ocr-evidence']:ap.add_argument('--'+name,type=Path,required=True)
    args=ap.parse_args();folder=args.estimator
    rows=read(args.gt)['items'];grouping=assign_splits(rows)
    original=read(folder/'predictions-with-width.json');output=copy.deepcopy(original)
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in output['items']]:raise ValueError('Shadow/source identities differ')
    for prediction in output['items']:restore_baseline(prediction)
    baseline=copy.deepcopy(output)
    appearance_hash=digest(folder/'model.pkl');pixel_hash=digest(folder/'pixel-role-model.pkl')
    with (folder/'pixel-role-model.pkl').open('rb') as handle:model=pickle.load(handle)
    if model['appearanceModelSHA256']!=appearance_hash:raise ValueError('Source/pixel-role model pairing changed')
    with (folder/'width-model.pkl').open('rb') as handle:width_model=pickle.load(handle)
    root=args.source_root
    observations={r['id']:r for r in read(root/'boundary-lean/evaluation-manifest.json')['items']}
    votes=SourceBoundaryVotes(root/'boundary-lean',root/'deep-classifier-observations',root/'edge-context60-native',root/'edge-context60-observations')
    processed=[]
    for row,prediction in zip(rows,output['items']):
        if not prediction['shadow']['present']:continue
        # No GT colour, parameter, annotation, substyle or pixel anchor enters attach().
        crop=Path(row['crop']);maskpath=args.masks/(row['itemID']+'.png')
        entry=read(folder/'features'/(row['itemID']+'.json'));identity=entry['identity']
        if digest(crop)!=row['cropSHA256'] or identity['sourceRGBSHA256']!=row['cropSHA256']:raise ValueError('Source RGB mismatch')
        if digest(maskpath)!=identity['predictedMaskSHA256']:raise ValueError('Predicted mask mismatch')
        rgb=np.asarray(Image.open(crop).convert('RGB'));mask=np.asarray(Image.open(maskpath))>0
        observation=observations[row['itemID']]
        primary,boundary,_=votes.load(observation);rf=load_case_features(observation,root/'boundary-lean')
        ocr=raster(args.ocr_evidence/(row['page']+'.json.gz'),row['sourceImageSHA256'],row['pageSize'],row['cropBounds'])
        arrays=dict(rf=rf,segPrimary=primary,segBoundary=boundary,ocr=ocr)
        geometry=dict(polygons=identity['polygons'],mergedPolygon=identity['mergedPolygon'],fontPixels=entry['packet']['fontPixels'])
        attach(rgb,mask,arrays,geometry,prediction,model,entry['packet'],width_model=width_model)
        processed.append(prediction['itemID'])
    # GT is used only for TRAIN/DEV calibration after all source-only observations.
    calibration=calibrate(rows,output['items'])
    threshold=calibration['threshold']
    for prediction in output['items']:apply_presence(prediction,threshold)
    final_presence=emitted_metrics(rows,output['items'])
    stripped=copy.deepcopy(output)
    role_changes=[]
    for p,before,raw in zip(stripped['items'],baseline['items'],original['items']):
        role=p.get('pixelRoleEvidence',{}).get('roles',{}).get('shadowComposite')
        before_role=before.get('pixelRoleEvidence',{}).get('roles',{}).get('shadowComposite')
        expected=copy.deepcopy(before_role)
        if not p['shadow']['present'] and expected is not None:
            expected['confidentSamples']=0;expected['observedColours']=[]
        if role!=expected:raise ValueError('Unexpected shadowComposite output changed')
        raw_role=raw.get('pixelRoleEvidence',{}).get('roles',{}).get('shadowComposite')
        if role!=raw_role:
            role_changes.append(dict(itemID=p['itemID'],baselineRestored=before_role!=raw_role,
                presenceFiltered=role!=before_role))
        if before_role is not None:p['pixelRoleEvidence']['roles']['shadowComposite']=copy.deepcopy(before_role)
        p['shadow']=copy.deepcopy(before['shadow'])
    if stripped!=baseline:raise ValueError('A non-shadow output changed')
    if appearance_hash!=digest(folder/'model.pkl') or pixel_hash!=digest(folder/'pixel-role-model.pkl'):raise ValueError('Checkpoint changed during source replay')
    report=measure(rows,output['items'])
    negatives={g:sum(split(r)==g and r['shadow']['present'] is False and p['shadow']['present'] and p['shadow'].get('rgb') is not None for r,p in zip(rows,output['items'])) for g in ['train','dev','test']}
    identities={name:digest(folder/name) if (folder/name).exists() else None for name in ['model.pkl','pixel-role-model.pkl','width-model.pkl','source-fill-palette-model.pkl']}
    policy=dict(enabled=True,version=VERSION,displacementVersion=DISPLACEMENT_VERSION,
        presenceVersion=PRESENCE_VERSION,minimumUncorroboratedProbability=threshold,
        presenceHelperSHA256=digest(Path(__file__).with_name('source_shadow_presence.py')),
        modelIdentities=identities,
        sourceHelperSHA256=digest(Path(__file__).with_name('source_shadow_observation.py')),
        nativePrimaryQualityHelperSHA256=digest(Path(__file__).with_name('source_native_primary_quality.py')),
        latePaletteHelperSHA256=digest(Path(__file__).with_name('certified_interior_palette.py')),
        latePrimaryHelperSHA256=digest(Path(__file__).with_name('certified_bright_primary.py')),
        displacementHelperSHA256=digest(Path(__file__).with_name('shadow_displacement_evidence.py')),
        nativeColourNeighborhoodsSHA256=digest(Path(__file__).with_name('native_colour_neighborhoods.py')),
        localCoreHelperSHA256=digest(Path(__file__).with_name('local_source_core.py')),
        glowHelperSHA256=digest(Path(__file__).with_name('shadow_glow_profiles.py')),
        backgroundNormalizationSHA256=digest(Path(__file__).with_name('shadow_background_normalization.py')),
        sourceCoreHelperSHA256=digest(Path(__file__).with_name('shadow_template_fit.py')),
        semantics='Observed source-composite RGB and component-validated visible-paint displacement; intrinsic blur/opacity remain unknown')
    save(folder/'SHADOW-OBSERVATION-POLICY.json',policy)
    save(folder/'SHADOW-PARAMETER-RESULTS.json',dict(metrics=report,knownNegativeRGBEmissions=negatives,
        presenceCalibration=calibration,finalPresence=final_presence,
        processedSourceItems=processed,itemCount=len(rows),grouping=grouping,GTAtInference=False,GTChanged=False,
        nonShadowOutputsUnchanged=True,
        nonShadowParityException=dict(path='pixelRoleEvidence.roles.shadowComposite',items=role_changes,
            semantics='Restore raw baseline role evidence before attach; clear confidentSamples/observedColours only when final shadow.present is false'),
        sourceContextExpanded=False,policy=policy,
        limitation='Fixed GT-derived crop benchmark; sparse RGB/offset labels, no RGB-labelled TEST examples; historical corpus already inspected'))
    save(folder/'predictions-with-width.json',output)
    print('Observed shadow parameters',report['dev'],flush=True)


if __name__=='__main__':main()
