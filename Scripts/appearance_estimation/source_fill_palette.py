"""Multi-label observed fill-colour support from existing RF/seg/OCR/bbox candidate evidence."""
import numpy as np
from source_appearance import lab

VERSION='source-full-fusion-fill-palette-v1'


def features(packet,prediction):
    colours=lab(packet['colors']);context=[]
    for role in ['fill','outline','background']:
        delta=colours-lab([prediction[role]['rgb']])[0]
        context.append(np.column_stack([delta/100,np.linalg.norm(delta,axis=1)/100]))
    context.append(np.tile([float(prediction['outline']['present']),prediction['outline']['probability']],(len(colours),1)))
    return np.column_stack([np.asarray(packet['features'],np.float32),*context]).astype(np.float32)


def augment(packet,prediction,model,scores=None):
    if model['version']!=VERSION or packet['version']!=model['sourceFeatureVersion']:raise ValueError('Source fill palette feature contract mismatch')
    if model.get('pruneThreshold',0) or model.get('requiresPixelRoleSupport'):raise ValueError('Unvalidated fill-palette pruning/support policy')
    baseline=prediction.get('pixelRoleEvidence',{}).get('roles',{}).get('fill',{}).get('observedColours',[])
    selected=[dict(b) for b in baseline]
    if model['threshold']>1:return selected
    if scores is None:scores=model['classifier'].predict_proba(features(packet,prediction))[:,1]
    for index in np.argsort(-scores):
        if scores[index]<model['threshold']:break
        rgb=packet['colors'][index];current=[prediction['fill']['rgb']]+[v['rgb'] for v in selected]
        if np.linalg.norm(lab(current)-lab([rgb])[0],axis=1).min()<=model['mergeDelta']:continue
        selected.append(dict(rgb=rgb,sourcePaletteProbability=float(scores[index])))
        if len(selected)>=model['limit']:break
    return selected


def attach(packet,prediction,model):
    selected=augment(packet,prediction,model)
    baseline=prediction.get('pixelRoleEvidence',{}).get('roles',{}).get('fill',{}).get('observedColours',[])
    prediction['fill'].update(colors=[prediction['fill']['rgb']]+[c['rgb'] for c in selected],
        representation='source-fusion-observed-palette',paletteVersion=VERSION)
    prediction['sourceFillPaletteEvidence']=dict(version=VERSION,GTAtInference=False,primaryColourPreserved=True,
        pixelRoleColoursPreserved=True,retainedPixelRoleColours=len(baseline),addedColours=selected[len(baseline):],
        role='Source observed colour hypotheses; not a spatial substyle or intrinsic shadow decomposition')
    return prediction
