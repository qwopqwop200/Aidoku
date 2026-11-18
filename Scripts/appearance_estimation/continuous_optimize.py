"""Continuous bounded-storage search; publish only DEV-improving complete champions."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
from optimize_appearance import read,save,objective,assign_splits,split
from paint_palette_metrics import measure as measure_paint_palette,predicted_colours
import primary_colour_quality

FILES=['model.pkl','width-model.pkl','BEST.json','WIDTH-RESULTS.json','predictions.json',
       'predictions-with-width.json','REPORT.json','HISTORY.json','GROUPED-SPLITS.json',
       'SOURCE-POLICY.json','SHADOW-CALIBRATION.json','REFINEMENT-HISTORY.json',
       'background-palette.pkl','BACKGROUND-PALETTE-RESULTS.json','OUTLINE-LAYERS-RESULTS.json','NESTED-CONTOUR-RESULTS.json','PRIMARY-CONTOUR-RESULTS.json','ORDERED-LAYER-RESULTS.json','FUSION-SOURCE-POLICY.json','ACTUAL-FUSION-USAGE.json','pixel-role-model.pkl','PIXEL-ROLE-RESULTS.json','BOUNDED-PROFILE-RESULTS.json','FILL-PALETTE-THRESHOLD.json','FILL-PALETTE-GUARD.json','source-fill-palette-model.pkl','SOURCE-FILL-PALETTE-RESULTS.json','PIXEL-CONTEXT-SELECTION.json']
FILES += ['SHADOW-OBSERVATION-POLICY.json','SHADOW-PARAMETER-RESULTS.json',
          'final-background-model.pkl','FINAL-BACKGROUND-POLICY.json','FINAL-BACKGROUND-RESULTS.json',
          'NATIVE-GRADIENT-CONTOUR-POLICY.json','NATIVE-GRADIENT-CONTOUR-RESULTS.json']
FILES += ['NATIVE-OUTER-SHELL-POLICY.json','NATIVE-OUTER-SHELL-RESULTS.json','PRIMARY-COLOUR-GUARD.json']
SCORE_VERSION='actual-emitted-source-style-directional-background-v24'


def copy_checkpoint(source,destination):
    destination.mkdir(exist_ok=True,parents=True)
    for name in FILES:
        if (source/name).exists():
            temporary=destination/(name+'.copying')
            shutil.copyfile(source/name,temporary);temporary.replace(destination/name)


def dev_metrics(folder):
    report=read(folder/'BEST.json')['metrics']['dev']
    shadow=folder/'SHADOW-PARAMETER-RESULTS.json'
    if shadow.exists():
        presence=read(shadow).get('finalPresence',{}).get('dev')
        if presence is not None:report={**report,'shadowPresence':presence}
    final=folder/'FINAL-BACKGROUND-RESULTS.json'
    if final.exists():report={**report,'background':{**report['background'],**read(final)['selected']['dev']}}
    return report


def background_colour_metrics(folder,rows):
    import numpy as np
    from source_appearance import lab
    predictions=read(folder/'predictions-with-width.json')['items']
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in predictions]:raise ValueError('Background output correspondence changed')
    output={}
    for group in ['train','dev']:
        errors=[]
        for row,prediction in zip(rows,predictions):
            if split(row)!=group:continue
            target=row['background'].get('colors') or [row['background']['rgb']]
            errors.append(float(np.linalg.norm(lab(target)-lab([prediction['background']['rgb']])[0],axis=1).min()))
        output[group]=dict(meanDeltaE=float(np.mean(errors)),within10=float(np.mean(np.asarray(errors)<=10)))
    return output


def background_colour_guard(before,after):
    return all(after[g]['within10']>=before[g]['within10'] and after[g]['meanDeltaE']<=before[g]['meanDeltaE']+1e-12 for g in ['train','dev'])


def primary_colour_metrics(folder,rows):
    return primary_colour_quality.measure(rows,read(folder/'predictions-with-width.json')['items'],split)


def improves_quality(candidate,best,background_after,background_before,primary_after=None,primary_before=None):
    if candidate>best+1e-12:return True
    if abs(candidate-best)>1e-12:return False
    before=background_before['dev']['meanDeltaE'];after=background_after['dev']['meanDeltaE']
    if after<before-1e-9:return True
    return (abs(after-before)<=1e-9 and primary_after is not None and primary_before is not None
            and primary_colour_quality.strictly_improves(primary_before,primary_after))


def score(folder):
    report=dev_metrics(folder)
    width=read(folder/'WIDTH-RESULTS.json')['selected']['dev']['withinGTRange']
    base=.85*objective(report)+.15*width
    palette=folder/'BACKGROUND-PALETTE-RESULTS.json'
    value=.9*base+.1*read(palette)['selected']['dev']['meanBackgroundPixelCoverage'] if palette.exists() else base
    role=folder/'PIXEL-ROLE-RESULTS.json'
    value=.95*value+.05*read(role)['selected']['dev']['macroF1'] if role.exists() else value
    fill=folder/'SOURCE-FILL-PALETTE-RESULTS.json'
    if fill.exists():
        quality=read(fill)['selected']['dev']
        native=folder/'NATIVE-GRADIENT-CONTOUR-RESULTS.json'
        if native.exists():quality=read(native).get('fillPaletteMetrics',{}).get('selected',{}).get('dev',quality)
        value=.98*value+.02*(quality['colourRecall']+quality['annotatedColourPrecision'])/2
    shadow=folder/'SHADOW-PARAMETER-RESULTS.json'
    value=.99*value
    if shadow.exists():
        quality=read(shadow)['metrics']['dev']
        value+=.01*((quality['colour']['within10IncludingMissing'] or 0)+(quality['offset']['within2IncludingMissing'] or 0))/2
    layer=folder/'ORDERED-LAYER-RESULTS.json';quality=0.
    if layer.exists():
        observed=read(layer)['metrics']['dev']
        matched=observed['orderedColourAndApproximateWidthMatches']
        quality=2*matched/max(1,observed['expectedMultilayer']+observed['emittedMultilayer'])
    return .995*value+.005*quality


def shadow_parameter_guard(old,new):
    for group in ['train','dev']:
        # Legacy checkpoints have no final-presence audit; never lose a known audit.
        before=old.get('finalPresence',{}).get(group)
        after=new.get('finalPresence',{}).get(group)
        if before is not None:
            if after is None or after['TP']<before['TP'] or after['FP']>before['FP']:return False
        if new['knownNegativeRGBEmissions'][group]>old['knownNegativeRGBEmissions'][group]:return False
        for field,count in [('colour','within10Count'),('offset','within2PxCount')]:
            before=old['metrics'][group][field];after=new['metrics'][group][field]
            old_items={v['itemID']:v for v in before.get('items',[])}
            new_items={v['itemID']:v for v in after.get('items',[])}
            for key,value in old_items.items():
                candidate=new_items.get(key,{})
                if value.get('emitted') is True and candidate.get('emitted') is not True:return False
                if value.get('within10') is True and candidate.get('within10') is not True:return False
                if field=='offset' and value.get('errorPx') is not None and value['errorPx']<=2 and (candidate.get('errorPx') is None or candidate['errorPx']>2):return False
            if field=='offset' and before.get('meanErrorPx') is not None:
                if after.get('meanErrorPx') is None or after['meanErrorPx']>before['meanErrorPx']+1e-9:return False
            if after[count]<before[count]:return False
            if after[count]/max(1,after['emitted'])<before[count]/max(1,before['emitted']):return False
    return True


def fill_palette_scores(folder,rows):
    prediction=read(folder/'predictions-with-width.json')['items']
    if [r['itemID'] for r in rows]!=[p['itemID'] for p in prediction]:raise ValueError('Palette evaluation correspondence changed')
    indices=[i for i,r in enumerate(rows) if split(r)=='dev']
    selected=[prediction[i] for i in indices]
    return measure_paint_palette([rows[i] for i in indices],selected,
        [predicted_colours(p) for p in selected])


def palette_target_guard(rows,old,new):
    """Preserve every incumbent TRAIN/DEV target hit, including secondary paints."""
    import numpy as np
    from source_appearance import lab
    from paint_palette_metrics import targets as paint_targets
    if len(rows)!=len(old) or len(old)!=len(new):return False
    for row,a,b in zip(rows,old,new):
        if row['itemID']!=a['itemID'] or a['itemID']!=b['itemID']:return False
        if split(row) not in ('train','dev'):continue
        target=lab(paint_targets(row))
        colours=lambda p:[p['fill']['rgb']]+[v['rgb'] for v in predicted_colours(p)]
        before=np.linalg.norm(target[:,None]-lab(colours(a))[None],axis=2).min(1)
        after=np.linalg.norm(target[:,None]-lab(colours(b))[None],axis=2).min(1)
        if np.any((before<=10)&(after>10)):return False
        first=np.linalg.norm(target-lab([a['fill']['rgb']])[0],axis=1).min()
        second=np.linalg.norm(target-lab([b['fill']['rgb']])[0],axis=1).min()
        if first<=10 and second>10:return False
    return True


def native_palette_guard(report):
    metrics=report.get('fillPaletteMetrics')
    if metrics is None:return True
    gain=added=primary_gain=0
    for group in ('train','dev'):
        old,new=metrics['baseline'][group],metrics['selected'][group]
        if new['emittedColours']-new['validColours']>old['emittedColours']-old['validColours']:return False
        if new['coveredColours']<old['coveredColours']:return False
        gain+=new['coveredColours']-old['coveredColours']
        added+=new['emittedColours']-old['emittedColours']
        before=report.get('baseline',{}).get(group,{}).get('fill',{})
        after=report.get('selected',{}).get(group,{}).get('fill',{})
        if before.get('n') and before.get('n')==after.get('n'):
            primary_gain+=before['n']*(after.get('within10',0)-before.get('within10',0))
    return added<=0 or gain>0 or primary_gain>1e-9


def main():
    parser=argparse.ArgumentParser()
    for k in ['gt','masks','out']:parser.add_argument('--'+k,type=Path,required=True)
    parser.add_argument('--cycles',type=int,default=0,help='0 continues until stopped')
    parser.add_argument('--rounds',type=int,default=8)
    parser.add_argument('--fused',action='store_true',help='Use prepared RF/soft segmentation/OCR/bbox source features for every optimisation cycle')
    parser.add_argument('--source-root',type=Path)
    parser.add_argument('--ocr-evidence',type=Path)
    args=parser.parse_args();root=args.out.resolve();scripts=Path(__file__).resolve().parent
    lock=(root/'continuous.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    champion=root/'champion'
    if not (champion/'REPORT.json').exists():copy_checkpoint(root,champion)
    pixel_roles=args.fused and args.source_root is not None and args.ocr_evidence is not None
    if (champion/'pixel-role-model.pkl').exists() and not pixel_roles:parser.error('A pixel-role checkpoint requires --fused, --source-root and --ocr-evidence for paired recalibration')
    previous=read(root/'LOOP-STATE.json') if (root/'LOOP-STATE.json').exists() else {}
    cycle=previous.get('completedCycles',0);history=previous.get('history',[])
    for entry in history:entry.setdefault('scoreVersion','legacy-source-style-width-v1')
    source_hash=hashlib.sha256(args.gt.read_bytes()).hexdigest()
    palette_rows=read(args.gt)['items'];assign_splits(palette_rows)
    names=['source_appearance.py','optimize_appearance.py','refine_heads.py','calibrate_shadow.py','calibrate_width.py','build_report.py',
        'background_palette.py','train_background_palette.py','outline_layers.py','shadow_template_fit.py',
        'audit_outline_layers.py','apply_outline_layers.py','nested_outline.py','recover_nested_contours.py','outline_layer_discovery.py','recover_primary_contours.py','audit_saved_outline_layers.py','fused_source_appearance.py','source_confidence_evidence.py','train_fused_appearance.py','audit_fusion_usage.py','source_profile_sampling.py','pixel_role_estimation.py','train_pixel_roles.py','apply_pixel_roles.py','paint_palette_metrics.py','calibrate_pixel_palette_threshold.py','source_fill_palette.py','train_source_fill_palette.py','apply_source_fill_palette.py','infer_appearance.py','width_context.py','paint_feature_context.py','retain_pixel_feature_context.py','select_pixel_feature_context.py','background_blend.py']
    names += ['primary_colour_quality.py','forest_width_consensus.py','adaptive_normal_width.py','width_resolution.py','continuous_optimize.py','source_shadow_observation.py','shadow_displacement_evidence.py','apply_source_shadow.py','audit_shadow_parameters.py','shadow_template_fit.py']
    names += ['native_colour_neighborhoods.py']
    names += ['local_source_core.py','shadow_glow_profiles.py','shadow_background_normalization.py','source_shadow_presence.py']
    if (champion/'final-background-model.pkl').exists():names += ['final_background_refinement.py','source_local_background_fusion.py','relative_background_quality.py','glyph_background.py','glyph_background_quality.py','directional_background.py','directional_background_quality.py','apply_final_background.py']
    if (champion/'NATIVE-GRADIENT-CONTOUR-POLICY.json').exists():names += ['source_native_primary_quality.py','source_native_primary_features.py','native_medoid.py','native_core.py','certified_interior_palette.py','certified_bright_primary.py','certified_bright_palette.py','owned_palette.py','source_gradient_core.py','native_gradient_contour.py','source_gradient_contour.py','source_bright_ring.py','apply_gradient_contour.py']
    if (champion/'NATIVE-OUTER-SHELL-POLICY.json').exists():names += ['source_outer_shell.py','source_outer_shell_geometry.py','source_outer_shell_policy.py','apply_outer_shell.py']
    code_hash={n:hashlib.sha256((scripts/n).read_bytes()).hexdigest() for n in names}
    state=dict(pid=os.getpid(),stage='starting',completedCycles=cycle,continuous=args.cycles==0,
               champion=str(champion),championDevScore=score(champion),history=history,
               scoreVersion=SCORE_VERSION)
    state['championBackgroundMeanDeltaE']=background_colour_metrics(champion,palette_rows)['dev']['meanDeltaE']
    state['championPrimaryMeanDeltaE']=primary_colour_metrics(champion,palette_rows)['dev']['meanDeltaE']
    child=None;stopped=False
    def stop(signum,frame):
        nonlocal stopped
        stopped=True
        if child is not None and child.poll() is None:
            try:os.killpg(child.pid,signal.SIGTERM)
            except ProcessLookupError:pass
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    def publish(stage):
        state.update(stage=stage,updatedUnix=time.time());save(root/'LOOP-STATE.json',state)
    publish('running')
    # Champion viewer is independent of candidates overwritten during the next search.
    subprocess.run([sys.executable,str(scripts/'build_report.py'),'--gt',str(args.gt),'--out',str(champion)],check=True)
    while not stopped and (args.cycles==0 or cycle<args.cycles):
        if hashlib.sha256(args.gt.read_bytes()).hexdigest()!=source_hash or any(hashlib.sha256((scripts/n).read_bytes()).hexdigest()!=h for n,h in code_hash.items()):
            publish('input-or-code-changed-relaunch-required');return
        cycle+=1;start=time.monotonic();state['cycle']=cycle;accepted=False;failure=None
        minimum_validity=max(.98,read(champion/'BACKGROUND-PALETTE-RESULTS.json')['selected']['dev']['selectedColourValidity']) if (champion/'BACKGROUND-PALETTE-RESULTS.json').exists() else .98
        shared=['--gt',str(args.gt),'--out',str(root)]
        commands=[('role-search',[str(scripts/('train_fused_appearance.py' if args.fused else 'optimize_appearance.py')),*shared,'--masks',str(args.masks),'--rounds',str(args.rounds),'--search-offset',str(cycle*args.rounds),'--jobs','8']),
                  ('family-search',[str(scripts/'refine_heads.py'),*shared,'--reference-model',str(champion/'model.pkl')]),
                  ('shadow-calibration',[str(scripts/'calibrate_shadow.py'),*shared,'--reference-model',str(champion/'model.pkl')]),
                  ('width-calibration',[str(scripts/'calibrate_width.py'),*shared,'--masks',str(args.masks),'--jobs','8','--background-reference-model',str(champion/'model.pkl')]),
                  ('nested-contour-recovery',[str(scripts/'recover_nested_contours.py'),'--gt',str(args.gt),'--estimator',str(root),
                    '--features',str(root/'features'),'--masks',str(args.masks),'--jobs','8']),
                  ('primary-contour-recovery',[str(scripts/'recover_primary_contours.py'),'--gt',str(args.gt),'--estimator',str(root),
                    '--features',str(root/'features'),'--masks',str(args.masks),'--jobs','8']),
                  ('outline-ring-audit',[str(scripts/'audit_outline_layers.py'),'--gt',str(args.gt),'--estimator',str(root),
                    '--features',str(root/'features'),'--masks',str(args.masks),'--out',str(root/'outline-ring-audit'),'--jobs','8']),
                  ('outline-ring-attachment',[str(scripts/'apply_outline_layers.py'),'--estimator',str(root),'--audit',str(root/'outline-ring-audit/RESULTS.json'),'--reference-champion',str(champion)]),
                  ('background-palette',[str(scripts/'train_background_palette.py'),'--gt',str(args.gt),'--estimator',str(root),
                    '--features',str(root/'features'),'--masks',str(args.masks),'--out',str(root/'background-palette'),'--apply-to',str(root),'--jobs','8',
                    '--search-offset',str(cycle*3),'--min-colour-validity',str(minimum_validity)]),
                  ('ordered-layer-audit',[str(scripts/'audit_saved_outline_layers.py'),'--gt',str(args.gt),
                    '--predictions',str(root/'predictions-with-width.json'),'--out',str(root/'ORDERED-LAYER-RESULTS.json')]),
                  ('saved-output-audit',[str(scripts/'build_report.py'),*shared])]
        if pixel_roles:
            point_args=['--gt',str(args.gt),'--source-root',str(args.source_root),'--estimator',str(root),
                '--masks',str(args.masks),'--ocr-evidence',str(args.ocr_evidence),'--jobs','8']
            commands[-1:-1]=[
                ('pixel-role-training',[str(scripts/'train_pixel_roles.py'),*point_args,'--out',str(root/'pixel-roles')]),
                ('pixel-palette-threshold',[str(scripts/'calibrate_pixel_palette_threshold.py'),*point_args,
                    '--model',str(root/'pixel-roles/pixel-role-model.pkl'),'--out',str(root/'FILL-PALETTE-THRESHOLD.json')]),
                ('pixel-role-attachment',[str(scripts/'apply_pixel_roles.py'),*point_args,'--model',str(root/'pixel-roles/pixel-role-model.pkl'),
                    '--validation',str(root/'pixel-roles/RESULTS.json')]),
                ('pixel-context-selection',[str(scripts/'select_pixel_feature_context.py'),*point_args,'--reference-estimator',str(champion)]),
                ('source-fill-palette-training',[str(scripts/'train_source_fill_palette.py'),'--gt',str(args.gt),'--estimator',str(root),
                    '--features',str(root/'features'),'--out',str(root/'source-fill-palette')]),
                ('source-fill-palette-attachment',[str(scripts/'apply_source_fill_palette.py'),'--gt',str(args.gt),'--estimator',str(root),
                    '--features',str(root/'features'),'--model',str(root/'source-fill-palette/source-fill-palette-model.pkl'),
                    '--validation',str(root/'source-fill-palette/RESULTS.json')]),
                ('observed-shadow-parameters',[str(scripts/'apply_source_shadow.py'),'--gt',str(args.gt),'--estimator',str(root),
                    '--source-root',str(args.source_root),'--masks',str(args.masks),'--ocr-evidence',str(args.ocr_evidence)])]
        if (champion/'final-background-model.pkl').exists():
            commands[-1:-1]=[('final-background-refinement',[str(scripts/'apply_final_background.py'),'--gt',str(args.gt),'--estimator',str(root),
                '--features',str(root/'features'),'--masks',str(args.masks),'--model',str(champion/'final-background-model.pkl'),*(['--source-root',str(args.source_root),'--ocr-evidence',str(args.ocr_evidence)] if args.source_root is not None and args.ocr_evidence is not None else []),'--jobs','4'])]
        if (champion/'NATIVE-GRADIENT-CONTOUR-POLICY.json').exists():
            commands[-1:-1]=[('native-gradient-contour',[str(scripts/'apply_gradient_contour.py'),'--gt',str(args.gt),'--estimator',str(root),
                '--features',str(root/'features'),'--masks',str(args.masks),'--source-root',str(args.source_root),
                '--ocr-evidence',str(args.ocr_evidence),'--jobs','4'])]
        if (champion/'NATIVE-OUTER-SHELL-POLICY.json').exists():
            threshold=read(champion/'NATIVE-OUTER-SHELL-POLICY.json')['minimumExcessCoherence']
            commands=[c for c in commands if c[0]!='ordered-layer-audit']
            commands[-1:-1]=[
                ('native-visible-outer-shell',[str(scripts/'apply_outer_shell.py'),'--gt',str(args.gt),'--estimator',str(root),
                    '--features',str(root/'features'),'--masks',str(args.masks),'--source-root',str(args.source_root),
                    '--ocr-evidence',str(args.ocr_evidence),'--threshold',str(threshold),'--jobs','4']),
                ('ordered-layer-audit',[str(scripts/'audit_saved_outline_layers.py'),'--gt',str(args.gt),
                    '--predictions',str(root/'predictions-with-width.json'),'--out',str(root/'ORDERED-LAYER-RESULTS.json')])]
        if args.fused:
            first_packet=next(iter(sorted((root/'features').glob('*.json'))))
            commands.insert(3,('fused-input-usage-audit',[str(scripts/'audit_fusion_usage.py'),'--model',str(root/'model.pkl'),
                '--packet',str(first_packet),'--out',str(root/'ACTUAL-FUSION-USAGE.json')]))
        try:
            with (root/'CYCLE.log').open('w') as log:
                for stage,command in commands:
                    if stopped:break
                    publish(stage);child=subprocess.Popen([sys.executable,*command],stdout=log,stderr=log,start_new_session=True)
                    status=child.wait();child=None
                    if status:raise RuntimeError(f'{stage} exited {status}')
            if not stopped:
                if hashlib.sha256(args.gt.read_bytes()).hexdigest()!=source_hash or any(hashlib.sha256((scripts/n).read_bytes()).hexdigest()!=h for n,h in code_hash.items()):
                    copy_checkpoint(champion,root);publish('input-or-code-changed-relaunch-required');return
                candidate=score(root);best=score(champion)
                old=dev_metrics(champion);new=dev_metrics(root)
                guards=all(new[r]['within10']>=old[r]['within10'] for r in ['fill','outline','background'])
                guards &= new['outlinePresence']['balancedAccuracy']>=old['outlinePresence']['balancedAccuracy']
                def shadow_f1(report):
                    s=report['shadowPresence'];return 2*s['TP']/max(1,2*s['TP']+s['FP']+s['FN'])
                guards &= shadow_f1(new)>=shadow_f1(old)
                guards &= read(root/'WIDTH-RESULTS.json')['selected']['dev']['withinGTRange']>=read(champion/'WIDTH-RESULTS.json')['selected']['dev']['withinGTRange']
                palette=read(root/'BACKGROUND-PALETTE-RESULTS.json')['selected']['dev']
                guards &= palette['selectedColourValidity']>=minimum_validity
                if (champion/'BACKGROUND-PALETTE-RESULTS.json').exists():
                    guards &= palette['meanBackgroundPixelCoverage']>=read(champion/'BACKGROUND-PALETTE-RESULTS.json')['selected']['dev']['meanBackgroundPixelCoverage']
                if (champion/'ORDERED-LAYER-RESULTS.json').exists():
                    layer_old=read(champion/'ORDERED-LAYER-RESULTS.json')['metrics']['dev'];layer_new=read(root/'ORDERED-LAYER-RESULTS.json')['metrics']['dev']
                    guards &= layer_new['orderedColourAndApproximateWidthMatches']>=layer_old['orderedColourAndApproximateWidthMatches']
                    guards &= layer_new['emittedMultilayer']-layer_new['orderedColourMatches']<=layer_old['emittedMultilayer']-layer_old['orderedColourMatches']
                    for group in ['train','dev']:
                        a=read(champion/'ORDERED-LAYER-RESULTS.json')['metrics'][group]
                        b=read(root/'ORDERED-LAYER-RESULTS.json')['metrics'][group]
                        guards &= b['orderedColourAndStrictWidthMatches']>=a['orderedColourAndStrictWidthMatches']
                        guards &= b['falseMultilayer']<=a['falseMultilayer']
                        guards &= b['emittedMultilayer']-b['orderedColourAndApproximateWidthMatches']<=a['emittedMultilayer']-a['orderedColourAndApproximateWidthMatches']
                if (champion/'PIXEL-ROLE-RESULTS.json').exists():
                    point_old=read(champion/'PIXEL-ROLE-RESULTS.json')['selected']['dev'];point_new=read(root/'PIXEL-ROLE-RESULTS.json')['selected']['dev']
                    guards &= point_new['macroF1']>=point_old['macroF1'] and point_new['accuracy']>=point_old['accuracy']
                    guards &= all(point_new['confusion'][i][i]>=point_old['confusion'][i][i] for i in range(4))
                    paint_old=fill_palette_scores(champion,palette_rows);paint_new=fill_palette_scores(root,palette_rows)
                    guards &= paint_new['colourRecall']>=paint_old['colourRecall'] and paint_new['annotatedColourPrecision']>=paint_old['annotatedColourPrecision']
                    per_item=palette_target_guard(palette_rows,read(champion/'predictions-with-width.json')['items'],read(root/'predictions-with-width.json')['items'])
                    guards &= per_item
                    save(root/'FILL-PALETTE-GUARD.json',dict(oldDEV=paint_old,candidateDEV=paint_new,TRAINDEVPerItemPrimaryAndPaletteHitsPreserved=per_item))
                if (champion/'SHADOW-PARAMETER-RESULTS.json').exists():
                    guards &= shadow_parameter_guard(read(champion/'SHADOW-PARAMETER-RESULTS.json'),read(root/'SHADOW-PARAMETER-RESULTS.json'))
                native_palette=root/'NATIVE-GRADIENT-CONTOUR-RESULTS.json'
                if native_palette.exists():guards &= native_palette_guard(read(native_palette))
                background_old=background_colour_metrics(champion,palette_rows);background_new=background_colour_metrics(root,palette_rows)
                guards &= background_colour_guard(background_old,background_new)
                primary_old=primary_colour_metrics(champion,palette_rows);primary_new=primary_colour_metrics(root,palette_rows)
                primary_preserved=primary_colour_quality.preserves(primary_old,primary_new)
                guards &= primary_preserved
                save(root/'PRIMARY-COLOUR-GUARD.json',dict(version=primary_colour_quality.VERSION,
                    baseline=primary_old,candidate=primary_new,passed=primary_preserved,
                    semantics='Actual emitted primary RGB; palette additions cannot improve this metric'))
                if guards and improves_quality(candidate,best,background_new,background_old,primary_new,primary_old):
                    copy_checkpoint(root,champion);accepted=True
                    subprocess.run([sys.executable,str(scripts/'build_report.py'),'--gt',str(args.gt),'--out',str(champion)],check=True)
                else:copy_checkpoint(champion,root)
        except Exception as error:
            failure=str(error);copy_checkpoint(champion,root)
        state['completedCycles']=cycle;state['championDevScore']=score(champion)
        state['championBackgroundMeanDeltaE']=background_colour_metrics(champion,palette_rows)['dev']['meanDeltaE']
        state['championPrimaryMeanDeltaE']=primary_colour_metrics(champion,palette_rows)['dev']['meanDeltaE']
        history.append(dict(cycle=cycle,accepted=accepted,seconds=time.monotonic()-start,error=failure,
                            championDevScore=state['championDevScore'],scoreVersion=state['scoreVersion']))
        state['history']=history[-256:];publish('between-cycles' if not stopped else 'stopped')
        print(json.dumps(history[-1]),flush=True)
        if failure and not stopped:time.sleep(15)
    publish('stopped' if stopped else 'cycle-limit-complete')


if __name__=='__main__':main()
