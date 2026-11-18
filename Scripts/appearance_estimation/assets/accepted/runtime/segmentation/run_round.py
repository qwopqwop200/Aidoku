#!/usr/bin/env python3
"""Bounded, resumable calibration/native evaluation after an external fit.

One round only. A round never promotes itself into the application and never
changes GT. The coordinator chooses subsequent general algorithm experiments.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import signal

from evaluate_gt import read,save,sha


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--training-pid',type=int)
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('--minimum-recall',type=float,default=.999)
    parser.add_argument('--calibration-recall',type=float)
    parser.add_argument('--point-only',action='store_true',help='DEV point constraint; retain separate heldout metrics')
    parser.add_argument('--reuse-dev-probabilities',action='store_true')
    parser.add_argument('--classifier-cache',type=Path)
    parser.add_argument('--classifier-cache-ready',type=Path,help='Wait for a completed source-observation parity receipt')
    parser.add_argument('--policy',type=Path,help='Evaluate a declared global completion policy without recalibrating')
    args=parser.parse_args();out=args.out.resolve();scripts=Path(__file__).parent
    lock=(out/'.round.lock').open('a')
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    def interrupted(signum,frame):
        raise SystemExit(128+signum)
    signal.signal(signal.SIGTERM,interrupted)
    state=dict(status='waiting-for-training',productionEnabled=False,GTChanged=False,steps=[])
    save(out/'ROUND-STATE.json',state)
    try:
        while not (out/'full-rf-PIXEL-MODEL-TRAINING.json').exists():
            if args.training_pid is None:raise RuntimeError('Training receipt missing')
            try:os.kill(args.training_pid,0)
            except ProcessLookupError:raise RuntimeError('Training exited without a receipt')
            time.sleep(2)
        def run(name,script,*arguments):
            print(f'Starting {name}',flush=True)
            state.update(status='running',step=name);save(out/'ROUND-STATE.json',state)
            start=time.monotonic()
            with (out/f'{name}.log').open('a') as log:
                proc=subprocess.Popen([sys.executable,str(scripts/script),*map(str,arguments)],
                    stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
                try:
                    code=proc.wait()
                    if code:raise subprocess.CalledProcessError(code,proc.args)
                except BaseException:
                    if proc.poll() is None:
                        os.killpg(proc.pid,signal.SIGTERM);proc.wait()
                    raise
            state['steps'].append(dict(name=name,seconds=time.monotonic()-start))
            save(out/'ROUND-STATE.json',state)
        if args.reuse_dev_probabilities:
            receipt=read(out/'full-rf-DEV-PREDICTION-RUN.json')
            if (receipt.get('modelSHA256')!=sha(out/'full-rf-pixel-fusion-model.json') or
                    receipt.get('manifestSHA256')!=sha(out/'evaluation-manifest.json') or
                    receipt['instances']!=sum(r['split']=='dev' for r in read(out/'evaluation-manifest.json')['items'])):
                raise ValueError('DEV probability cache provenance mismatch')
            state['steps'].append(dict(name='reuse-source-bound-dev-probabilities',seconds=0))
        else:
            run('predict-dev','pixel_rfdetr_fusion.py','predict-dev','--out',out,'--full-rf','--jobs',args.jobs)
        calibration_floor=args.calibration_recall or args.minimum_recall
        extra=[] if args.point_only else ['--source-bootstrap']
        if args.policy:
            calibration=args.policy.resolve()
        else:
            run('calibrate','hysteresis_completion.py','--out',out,'--results',out/'calibration',
                '--minimum-recall',calibration_floor,'--dense','--kernel','ellipse','--objective','microIoU',*extra)
            calibration=out/'calibration/HYSTERESIS-DENSE-ELLIPSE-SEARCH.json'
        chosen=read(calibration)['selected']
        if chosen is None:raise RuntimeError('No candidate meets source-bootstrap recall floor')
        run('export','export_forest.py','--out',out,'--full-rf','--recall-first','--calibration-report',calibration)
        save(out/'FROZEN-CANDIDATE.json',dict(modelSHA256=sha(out/'recall-full-rf-native-pixel-forest.json'),
            manifestSHA256=sha(out/'evaluation-manifest.json'),selectionSplit='provided-global-policy' if args.policy else 'dev',
            testUsedForSelection=bool(args.policy),
            sourceBootstrap=not args.point_only and not args.policy,minimumRecall=args.minimum_recall,
            calibrationRecallFloor=calibration_floor,productionEnabled=False))
        if args.classifier_cache_ready:
            state.update(status='waiting-for-classifier-cache',step='source-observation-parity')
            save(out/'ROUND-STATE.json',state)
            while True:
                if args.classifier_cache_ready.exists():
                    ready=read(args.classifier_cache_ready)
                    if not ready.get('passed',False):raise RuntimeError('Source observation parity failed')
                    if ready.get('complete',False):break
                time.sleep(2)
        reports={}
        for split in ['dev','test','train']:
            cache_arguments=['--classifier-cache',args.classifier_cache] if args.classifier_cache else []
            run(f'native-{split}','native_predict.py','--out',out,'--recall-first','--split',split,'--jobs',args.jobs,*cache_arguments)
            run(f'score-{split}','evaluate_gt.py','score','--out',out,'--predictions',out/f'recall-full-rf-native-{split}','--split',split)
            reports[split]=read(out/f'recall-full-rf-native-{split}-scores.json')['all']
        tp,fp,fn=[sum(r[k] for r in reports.values()) for k in ['TP','FP','FN']]
        all_metrics=dict(instances=sum(r['instances'] for r in reports.values()),TP=tp,FP=fp,FN=fn,
            recall=tp/max(1,tp+fn),microIoU=tp/max(1,tp+fp+fn),precision=tp/max(1,tp+fp),
            macroIoU=sum(r['macroIoU']*r['instances'] for r in reports.values())/sum(r['instances'] for r in reports.values()))
        result=dict(status='evaluated',all=all_metrics,bySplit=reports,selected=chosen,
            meetsAllRecallFloor=all_metrics['recall']>=args.minimum_recall,
            meetsTestRecallFloor=reports['test']['recall']>=args.minimum_recall,
            minimumRecall=args.minimum_recall,productionEnabled=False,fullProductionPipeline=False,
            calibrationRecallFloor=calibration_floor if not args.policy else None,
            sourceBootstrapRequired=not args.point_only and not args.policy,
            parameterSelection='provided global policy; previously observed corpus' if args.policy else 'development calibration',
            GTChanged=False,modelSHA256=sha(out/'recall-full-rf-native-pixel-forest.json'))
        save(out/'ROUND-RESULT.json',result);state.update(status='evaluated',result=result)
        print(json.dumps(result,indent=2),flush=True)
    except Exception as error:
        state.update(status='failed',error=str(error));raise
    finally:
        save(out/'ROUND-STATE.json',state)


if __name__=='__main__':main()
