"""Re-evaluate a validated pixel head behind its independent source colour encoder.

The encoder is a fitted source model, never cached per-item predictions or GT styles.
"""
import argparse
from pathlib import Path
import pickle
from optimize_appearance import read,save,digest
from paint_feature_context import VERSION
from pixel_role_estimation import VERSION as PIXEL_VERSION


def main():
    ap=argparse.ArgumentParser()
    for key in ['gt','estimator','reference-estimator','out']:ap.add_argument('--'+key,type=Path,required=True)
    args=ap.parse_args();args.out.mkdir(exist_ok=True,parents=True);reference=args.reference_estimator
    gt_hash=digest(args.gt)
    for folder in [reference,args.estimator]:
        if read(folder/'SOURCE-POLICY.json')['inputGTSHA256']!=gt_hash:raise ValueError('Retained pixel calibration requires unchanged GT supervision')
    with (reference/'pixel-role-model.pkl').open('rb') as f:pixel=pickle.load(f)
    with (reference/'model.pkl').open('rb') as f:role=pickle.load(f)
    with (args.estimator/'model.pkl').open('rb') as f:target=pickle.load(f)
    if pixel['appearanceModelSHA256']!=digest(reference/'model.pkl'):raise ValueError('Reference pixel/appearance pairing changed')
    if pixel['version']!=PIXEL_VERSION:raise ValueError('Unsupported retained pixel source schema')
    context=pixel.get('featureContext')
    if context is None:
        with (reference/'width-model.pkl').open('rb') as f:width=pickle.load(f)
        context=dict(version=VERSION,roleModel=role,pipelinePolicy={k:width[k] for k in ['sourceNestedContourVersion','sourcePrimaryContourVersion'] if k in width},
            roleModelSHA256=digest(reference/'model.pkl'))
    if context['version']!=VERSION or context['roleModel'].get('featureVersion')!=target.get('featureVersion'):raise ValueError('Independent pixel/source context contract mismatch')
    if context['roleModel'].get('rfModelWeightsSHA256')!=target.get('rfModelWeightsSHA256'):raise ValueError('Retained source encoder requires compatible RF evidence weights')
    pixel.update(featureContext=context,appearanceModelSHA256=digest(args.estimator/'model.pkl'),retainedTRAINClassifier=True,
        referencePixelModelSHA256=digest(reference/'pixel-role-model.pkl'),supervisionGTSHA256=gt_hash)
    with (args.out/'pixel-role-model.pkl').open('wb') as f:pickle.dump(pixel,f)
    report=read(reference/'PIXEL-ROLE-RESULTS.json')
    report.update(acceptedOnDEV=True,retainedValidatedReference=True,actualPointReevaluationRequired=True,
        GTAtInference=False,GTChanged=False,sourceEncoderVersion=VERSION,supervisionGTSHA256=gt_hash)
    save(args.out/'VALIDATION.json',report)
    print('Prepared source encoder + retained TRAIN pixel classifier; actual point/crop validation still required',flush=True)


if __name__=='__main__':main()
