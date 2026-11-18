#!/usr/bin/env python3
"""Continue one source-cross-fitted boundary experiment, without promotion."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import time

from evaluate_gt import read,save


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--base',type=Path,required=True)
    parser.add_argument('--cache',type=Path,required=True)
    parser.add_argument('--oof',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--producer-pid',type=int)
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('--rich-evidence',action='store_true')
    parser.add_argument('--trees',type=int,default=32)
    parser.add_argument('--depth',type=int,default=10)
    parser.add_argument('--minimum-samples',type=int,default=128)
    parser.add_argument('--training-cache',type=Path)
    parser.add_argument('--hard-samples',type=int,default=0)
    args=parser.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    state=dict(status='waiting-for-cross-fitted-observations',productionEnabled=False,GTChanged=False)
    save(out/'WORKFLOW-STATE.json',state)
    try:
        while not (args.oof/'OOF-COMPLETE.json').exists():
            if args.producer_pid:
                try:os.kill(args.producer_pid,0)
                except ProcessLookupError:raise RuntimeError('OOF producer exited without a completed receipt')
            time.sleep(2)
        scripts=Path(__file__).parent
        state['status']='fitting-contextual-boundary';save(out/'WORKFLOW-STATE.json',state)
        subprocess.run([sys.executable,str(scripts/'boundary_refiner.py'),'--base',str(args.base.resolve()),
            '--cache',str(args.cache.resolve()),'--out',str(out),'--training-probabilities',str(args.oof.resolve()),
            '--jobs',str(args.jobs),'--trees',str(args.trees),'--depth',str(args.depth),
            '--minimum-samples',str(args.minimum_samples),
            '--hard-samples',str(args.hard_samples),
            *(['--training-cache',str(args.training_cache.resolve())] if args.training_cache else []),
            *(['--rich-evidence'] if args.rich_evidence else [])],check=True)
        state['status']='evaluating-frozen-heldout';save(out/'WORKFLOW-STATE.json',state)
        subprocess.run([sys.executable,str(scripts/'evaluate_refiner.py'),'--base',str(args.base.resolve()),
            '--cache',str(args.cache.resolve()),'--out',str(out),'--split','test','--jobs',str(args.jobs)],check=True)
        state.update(status='research-evaluated',test=read(out/'RESEARCH-TEST-RESULT.json')['all'],nativeMasksProduced=False)
    except Exception as error:
        state.update(status='failed',error=str(error));raise
    finally:save(out/'WORKFLOW-STATE.json',state)


if __name__=='__main__':main()
