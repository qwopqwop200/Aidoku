"""Pointwise source RF/vote fusion, no additional mask dilation."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import time

import cv2
import numpy as np
from PIL import Image

from audit_kernel_free_completion import component_candidates,metrics
from evaluate_gt import read,save,sha
from prepare_full_rf import native_grids
from rf_weak_rescue import sample_points
from source_boundary_votes import SourceBoundaryVotes

cv2.setNumThreads(1)
RF_BINS=np.array([0,1e-6,1e-5,1e-4,.001,.0025,.005,.01,.025,.05,.1,.15,.2,.3,.4,.5,.6,.7,.8,.9,1.01],np.float32)
CONTEXT=None


def initialize(root):
    global CONTEXT
    root=Path(root);best=read(root/'BEST-RESULT.json')
    CONTEXT=(root,(root/best['modelPackage']).parent,
        SourceBoundaryVotes(root/'boundary-lean',root/'deep-classifier-observations',root/'edge-context60-native',root/'edge-context60-observations'))


def measure(row):
    root,native,votes=CONTEXT;p,q,ink=votes.load(row)
    base=np.fromfile(native/'native-masks'/f'{row["id"]}.u8',np.uint8).reshape(p.shape)
    base=component_candidates(base)['fillHoles']>0;positions=np.flatnonzero((~base).ravel())
    folder=root/'boundary-lean/rf-full/crops';case=read(folder/f'{row["id"]}.json');source=native_grids(str((folder/case['nativeGrids']).resolve()))
    x=positions%row['width']+case['cropBounds'][0];y=positions//row['width']+case['cropBounds'][1];width,height=case['pageSize']
    text=sample_points(source['globalGrids'][0],x,y,width,height)
    sfx=sample_points(source['globalGrids'][3],x,y,width,height)
    support=np.maximum(text,sfx);rb=np.searchsorted(RF_BINS,support,side='right')-1
    pv=np.rint(p.ravel()[positions]*64).astype(np.int64);qv=np.rint(q.ravel()[positions]*48).astype(np.int64)
    iv=(ink.ravel()[positions]>0).astype(np.int64)
    code=((pv*49+qv)*2+iv)*len(RF_BINS)+rb
    if sha(row['target'])!=row['targetSHA256']:raise ValueError('GT changed')
    gt=np.asarray(Image.open(row['target']))>0;positive=gt.ravel()[positions]
    shape=(65,49,2,len(RF_BINS));size=int(np.prod(shape))
    hist=np.stack([np.bincount(code[positive],minlength=size).reshape(shape),np.bincount(code[~positive],minlength=size).reshape(shape)])
    baseline=np.array([np.count_nonzero(base&gt),np.count_nonzero(base&~gt),np.count_nonzero(~base&gt)],np.int64)
    return row['split'],baseline,hist


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--root',type=Path,required=True);ap.add_argument('--out',type=Path,required=True);ap.add_argument('--jobs',type=int,default=4)
    args=ap.parse_args();rows=read(args.root/'boundary-lean/evaluation-manifest.json')['items'];start=time.monotonic()
    hist={s:np.zeros((2,65,49,2,len(RF_BINS)),np.int64) for s in ['train','dev','test']};base={s:np.zeros(3,np.int64) for s in hist}
    with ProcessPoolExecutor(max_workers=args.jobs,initializer=initialize,initargs=(args.root.resolve(),)) as pool:
        for i,(split,c,h) in enumerate(pool.map(measure,rows,chunksize=8)):
            base[split]+=c;hist[split]+=h
            if (i+1)%500==0:print(f'Kernel-free source signals {i+1}/{len(rows)}',flush=True)
    counts={}
    for split,h in hist.items():
        # Rejected iff p<P AND q<Q AND no native support (if enabled) AND RF<R.
        prefix=np.pad(h.cumsum(1).cumsum(2).cumsum(3).cumsum(4),((0,0),(1,0),(1,0),(1,0),(1,0)))
        counts[split]=prefix
    trials=[]
    for p in [1,2,4,8,16,32,65]:
        for q in [1,2,4,8,16,32,49]:
            for use_native in [False,True]:
                for r,threshold in enumerate(RF_BINS[1:],1):
                    measured={}
                    for split,h in hist.items():
                        rejected=counts[split][:,p,q,1 if use_native else 2,r]
                        tp,fp=h.sum(axis=(1,2,3,4))-rejected
                        measured[split]=base[split]+[tp,fp,-tp]
                    trials.append(dict(primaryVotes=p,boundaryVotes=q,includeNative=use_native,minimumRF=float(threshold),
                        all=metrics(sum(measured.values())),bySplit={s:metrics(c) for s,c in measured.items()}))
    eligible=[t for t in trials if t['all']['microIoU']>=.7]
    selected=max(eligible,key=lambda t:(t['all']['recall'],t['all']['microIoU'])) if eligible else None
    exact=[t for t in trials if t['all']['FN']==0];exact_best=max(exact,key=lambda t:t['all']['microIoU']) if exact else None
    save(args.out/'RESULT.json',dict(selectedRecallAtIoU70=selected,bestExactRecall100=exact_best,
        trialCount=len(trials),trials=trials,baseline=metrics(sum(base.values())),GTAtInference=False,GTChanged=False,
        extraDilationKernel=False,sourceSignalsAuthenticated=True,caseSpecificRules=False,
        observedCorpusOnly=True,seconds=time.monotonic()-start))
    np.savez_compressed(args.out/'COUNTS.npz',**hist,**{s+'_base':c for s,c in base.items()})
    print(dict(selectedRecallAtIoU70=selected,bestExactRecall100=exact_best,seconds=time.monotonic()-start),flush=True)


if __name__=='__main__':main()
