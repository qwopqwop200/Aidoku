"""Standalone inference takes RGB, a predicted mask, optional geometry, and frozen models. Never GT."""
from width_resolution import predict as predict_width,native_features as native_width_features
import argparse
import json
from pathlib import Path
import pickle
import numpy as np
from PIL import Image
from optimize_appearance import save,digest
from pixel_role_estimation import describe as describe_pixel_roles
from source_fill_palette import attach as attach_fill_palette
from paint_feature_context import feature_prediction
from fused_source_appearance import extract as fused_extract,VERSION as FUSED_VERSION
from source_appearance import extract,predict
from calibrate_width import measure,width_features
from outline_layer_discovery import correct_primary,PRIMARY_VERSION,refresh_conditioned_background
from nested_outline import recover_presence,VERSION as NESTED_VERSION
from outline_layers import measure as measure_layers,attach as attach_layers,VERSION as LAYER_VERSION
from background_palette import source_features as background_features,describe as describe_background
from source_shadow_observation import attach_with_width_context as attach_source_shadow,validate_policy as validate_shadow_policy
from source_shadow_presence import apply as refine_source_shadow_presence
from source_gradient_contour import refine as refine_gradient_contour,validate_policy as validate_gradient_contour_policy
from final_background_refinement import apply as refine_final_background,validate_policy as validate_final_background_policy


from source_outer_shell import refine as refine_outer_shell
from source_outer_shell_policy import validate_policy as validate_outer_shell_policy


def main():
    parser=argparse.ArgumentParser()
    for name in ['image','mask','out']:parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--model',type=Path)
    parser.add_argument('--estimator',type=Path,help='Checkpoint directory or a root containing ACTIVE-ESTIMATOR.json')
    parser.add_argument('--pixel-role-model',type=Path)
    parser.add_argument('--source-fill-palette-model',type=Path)
    parser.add_argument('--width-model',type=Path)
    parser.add_argument('--final-background-model',type=Path)
    parser.add_argument('--geometry',type=Path,help='JSON with optional detected polygons and fontPixels only')
    parser.add_argument('--background-palette-model',type=Path)
    parser.add_argument('--source-evidence',type=Path,help='Aligned source-only NPZ: RF 27 planes, primary/boundary probabilities, OCR confidence maps and RGB hash')
    parser.add_argument('--source-shadow-observation',action='store_true',help='Estimate observed shadow RGB and component-validated visible displacement from complete source evidence')
    parser.add_argument('--context-mask',type=Path,help='Optional union of all predicted text masks aligned to this crop')
    args=parser.parse_args();shadow_policy=None;final_background_policy=None;gradient_contour_policy=None;outer_shell_policy=None
    if args.estimator:
        if args.model:parser.error('Provide one estimator directory or one explicit model file')
        active=args.estimator/'ACTIVE-ESTIMATOR.json'
        checkpoint=Path(json.loads(active.read_text())['checkpoint']) if active.exists() else args.estimator
        args.model=checkpoint/'model.pkl'
        if not args.pixel_role_model and (checkpoint/'pixel-role-model.pkl').exists():args.pixel_role_model=checkpoint/'pixel-role-model.pkl'
        if not args.source_fill_palette_model and (checkpoint/'source-fill-palette-model.pkl').exists():args.source_fill_palette_model=checkpoint/'source-fill-palette-model.pkl'
        if not args.width_model and (checkpoint/'width-model.pkl').exists():args.width_model=checkpoint/'width-model.pkl'
        if not args.background_palette_model and (checkpoint/'background-palette.pkl').exists():args.background_palette_model=checkpoint/'background-palette.pkl'
        if not args.final_background_model and (checkpoint/'final-background-model.pkl').exists():args.final_background_model=checkpoint/'final-background-model.pkl'
        if (checkpoint/'FINAL-BACKGROUND-POLICY.json').exists():final_background_policy=json.loads((checkpoint/'FINAL-BACKGROUND-POLICY.json').read_text())
        if (checkpoint/'NATIVE-GRADIENT-CONTOUR-POLICY.json').exists():gradient_contour_policy=json.loads((checkpoint/'NATIVE-GRADIENT-CONTOUR-POLICY.json').read_text())
        if (checkpoint/'NATIVE-OUTER-SHELL-POLICY.json').exists():outer_shell_policy=json.loads((checkpoint/'NATIVE-OUTER-SHELL-POLICY.json').read_text())
        if (checkpoint/'SHADOW-OBSERVATION-POLICY.json').exists():
            shadow_policy=json.loads((checkpoint/'SHADOW-OBSERVATION-POLICY.json').read_text())
    if not args.model:parser.error('--model or --estimator is required')
    geometry=json.loads(args.geometry.read_text()) if args.geometry else {}
    rgb=np.asarray(Image.open(args.image).convert('RGB'));mask=np.asarray(Image.open(args.mask))>0
    source_arrays=None
    with args.model.open('rb') as f:model=pickle.load(f)
    if model.get('featureVersion')==FUSED_VERSION:
        if not args.source_evidence:raise ValueError('RF fusion model requires original aligned RF/soft segmentation/OCR evidence')
        with np.load(args.source_evidence,allow_pickle=False) as evidence:
            if str(evidence['sourceRGBSHA256'].item())!=digest(args.image):raise ValueError('Source evidence/RGB identity mismatch')
            if str(evidence['predictedMaskSHA256'].item())!=digest(args.mask):raise ValueError('Source evidence/predicted mask mismatch')
            evidence_geometry=json.loads(str(evidence['geometryJSON'].item()))
            if geometry and geometry!=evidence_geometry:raise ValueError('Source evidence/bbox geometry mismatch')
            geometry=evidence_geometry
            if model.get('rfModelWeightsSHA256') and str(evidence['rfModelWeightsSHA256'].item())!=model['rfModelWeightsSHA256']:raise ValueError('RF model/evidence weights mismatch')
            source_arrays={k:evidence[k] for k in ['rf','segPrimary','segBoundary','ocr']}
            packet=fused_extract(rgb,mask,source_arrays['rf'],source_arrays['segPrimary'],source_arrays['segBoundary'],
                geometry.get('polygons'),geometry.get('fontPixels'),merged_polygon=geometry.get('mergedPolygon'),ocr_maps=source_arrays['ocr'])
    elif str(model.get('featureVersion','')).startswith('source-palette-rf-seg-geometry'):
        raise ValueError('Unsupported RF fusion feature version; regenerate source features and model together')
    else:
        packet=extract(rgb,mask,geometry.get('polygons'),geometry.get('fontPixels'))
    result=predict(packet,model)
    if args.width_model:
        with args.width_model.open('rb') as f:width=pickle.load(f)
        if width.get('featureVersion',packet['version'])!=packet['version']:
            raise ValueError('Width model/source feature contract mismatch')
        if width.get('sourceNestedContourVersion'):
            if width['sourceNestedContourVersion']!=NESTED_VERSION:raise ValueError('Nested contour/source feature contract mismatch')
            result=recover_presence(rgb,mask,result,packet['fontPixels'],geometry.get('polygons'))
        if width.get('sourcePrimaryContourVersion'):
            if width['sourcePrimaryContourVersion']!=PRIMARY_VERSION:raise ValueError('Primary contour/source feature contract mismatch')
            previous=result
            result=correct_primary(rgb,mask,result,packet,geometry.get('polygons'))
            result=refresh_conditioned_background(result,previous,packet,model)
        if result['outline']['present']:
            evidence,vector=measure(rgb,mask,result['fill']['rgb'],result['outline']['rgb'])
            normal=native_width_features(width,rgb,mask,result,packet['fontPixels'],geometry.get('polygons'))
            value=float(predict_width(width,[width_features(packet,result,vector,width)],normal=None if normal is None else [normal])[0])
            radius=width['uncertaintyRadiusPx'];result['outline'].update(widthPx=value,
                widthRangePx=[max(0,value-radius),value+radius],measurementEvidence=evidence)
            if width.get('sourceOutlineLayersVersion'):
                if width['sourceOutlineLayersVersion']!=LAYER_VERSION:raise ValueError('Outline ring/source feature contract mismatch')
                attach_layers(result,measure_layers(rgb,mask,result,packet['fontPixels'],packet['colors'],geometry.get('polygons')))
    if not result['outline']['present']:
        result['outline'].update(widthPx=0,widthRangePx=[0,0])
    if args.background_palette_model:
        with args.background_palette_model.open('rb') as f:background=pickle.load(f)
        if background['sourceFeatureVersion']!=packet['version']:raise ValueError('Background palette/source feature contract mismatch')
        context=np.asarray(Image.open(args.context_mask))>0 if args.context_mask else mask
        features,mass=background_features(rgb,mask,context,packet,result)
        result['background'].update(describe_background(packet,result,features,mass,background))
        result['background']['contextExclusionPolicy']='caller-predicted-text-union' if args.context_mask else 'own-predicted-mask-only'
    if args.pixel_role_model:
        if source_arrays is None:raise ValueError('Pixel-role estimation requires complete source RF/pixel/OCR evidence')
        with args.pixel_role_model.open('rb') as f:pixel_role=pickle.load(f)
        if pixel_role['appearanceModelSHA256']!=digest(args.model):raise ValueError('Pixel-role head and appearance model are different checkpoints')
        result['pixelRoleEvidence']=describe_pixel_roles(rgb,mask,source_arrays['rf'],source_arrays['segPrimary'],source_arrays['segBoundary'],
            source_arrays['ocr'],geometry,result,pixel_role,feature_prediction=feature_prediction(rgb,mask,packet,geometry,pixel_role))
    if args.source_fill_palette_model:
        if not args.pixel_role_model:raise ValueError('Source fill palette requires its paired pixel-role model')
        with args.source_fill_palette_model.open('rb') as f:fill_palette=pickle.load(f)
        if fill_palette['appearanceModelSHA256']!=digest(args.model) or fill_palette['pixelRoleModelSHA256']!=digest(args.pixel_role_model):raise ValueError('Source fill palette and appearance/pixel-role model pairing changed')
        attach_fill_palette(packet,result,fill_palette)
    if args.source_shadow_observation or shadow_policy and shadow_policy.get('enabled'):
        if source_arrays is None or not args.pixel_role_model:
            raise ValueError('Source shadow observation requires aligned RF/segmentation/OCR and the paired pixel-role model')
        if shadow_policy:
            paths={'model.pkl':args.model,'pixel-role-model.pkl':args.pixel_role_model,'width-model.pkl':args.width_model,
                'source-fill-palette-model.pkl':args.source_fill_palette_model}
            validate_shadow_policy(shadow_policy,{name:digest(path) if path else None for name,path in paths.items()})
        if result['shadow']['present']:
            attach_source_shadow(rgb,mask,source_arrays,geometry,result,pixel_role,packet,width_model=width if args.width_model else None)
        refine_source_shadow_presence(result,shadow_policy['minimumUncorroboratedProbability'] if shadow_policy else 0.)
    if args.final_background_model:
        if not args.background_palette_model or not args.pixel_role_model:raise ValueError('Final background refinement requires paired source palette and pixel-role evidence')
        if final_background_policy:
            paths={'model.pkl':args.model,'pixel-role-model.pkl':args.pixel_role_model,'width-model.pkl':args.width_model,
                'source-fill-palette-model.pkl':args.source_fill_palette_model,'final-background-model.pkl':args.final_background_model,
                'background-palette.pkl':args.background_palette_model}
            validate_final_background_policy(final_background_policy,{name:digest(path) if path else None for name,path in paths.items()})
        with args.final_background_model.open('rb') as handle:final_background=pickle.load(handle)
        context=np.asarray(Image.open(args.context_mask))>0 if args.context_mask else mask
        result=refine_final_background(rgb,mask,context,packet,result,final_background,packet['fontPixels'],source_arrays=source_arrays)
    if gradient_contour_policy:
        if source_arrays is None or not args.pixel_role_model:raise ValueError('Native gradient contour requires paired source RF/seg/OCR and pixel-role model')
        paths={'model.pkl':args.model,'pixel-role-model.pkl':args.pixel_role_model,'width-model.pkl':args.width_model,
            'source-fill-palette-model.pkl':args.source_fill_palette_model,'background-palette.pkl':args.background_palette_model,
            'final-background-model.pkl':args.final_background_model}
        validate_gradient_contour_policy(gradient_contour_policy,{name:digest(path) if path else None for name,path in paths.items()})
        result,primary_diagnostic=refine_gradient_contour(rgb,mask,source_arrays,geometry,result,pixel_role,packet)
    if outer_shell_policy:
        if not gradient_contour_policy:raise ValueError('Native secondary shell requires current source primary observation')
        validate_outer_shell_policy(outer_shell_policy,{name:digest(path) if path else None for name,path in paths.items()},digest(checkpoint/'NATIVE-GRADIENT-CONTOUR-POLICY.json'))
        result,_=refine_outer_shell(rgb,geometry,result,primary_diagnostic,outer_shell_policy['minimumExcessCoherence'])
    save(args.out,result)


if __name__=='__main__':main()
