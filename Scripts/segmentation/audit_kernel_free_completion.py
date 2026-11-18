"""Compare source-component completion without an extra dilation kernel."""
import argparse
from pathlib import Path
import time

import cv2
import numpy as np
from PIL import Image

from evaluate_gt import read,save,sha

cv2.setNumThreads(1)


def component_candidates(mask):
    contours,_=cv2.findContours(mask,cv2.RETR_EXTERNAL,cv2.CHAIN_APPROX_SIMPLE)
    holes=np.zeros_like(mask);hulls=np.zeros_like(mask);boxes=np.zeros_like(mask)
    cv2.drawContours(holes,contours,-1,255,cv2.FILLED)
    for contour in contours:
        cv2.fillConvexPoly(hulls,cv2.convexHull(contour),255)
        x,y,w,h=cv2.boundingRect(contour);boxes[y:y+h,x:x+w]=255
    whole=np.zeros_like(mask)
    if contours:
        x,y,w,h=cv2.boundingRect(np.concatenate(contours));whole[y:y+h,x:x+w]=255
    return dict(baseline=mask,fillHoles=holes,componentConvexHull=hulls,componentBounds=boxes,sourceForegroundBounds=whole)


def metrics(c):
    tp,fp,fn=map(int,c)
    return dict(TP=tp,FP=fp,FN=fn,recall=tp/max(1,tp+fn),microIoU=tp/max(1,tp+fp+fn))


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--root',type=Path,required=True);ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args();root=args.root;best=read(root/'BEST-RESULT.json');native=(root/best['modelPackage']).parent
    rows=read(root/'boundary-lean/evaluation-manifest.json')['items'];totals={};records=[];start=time.monotonic()
    for ordinal,row in enumerate(rows):
        mask=np.fromfile(native/'native-masks'/f'{row["id"]}.u8',np.uint8).reshape(row['height'],row['width'])
        candidates=component_candidates(mask)
        if sha(row['target'])!=row['targetSHA256']:raise ValueError('GT changed')
        gt=np.asarray(Image.open(row['target']))>0;record=dict(id=row['id'],split=row['split'],counts={})
        for name,value in candidates.items():
            pred=value>0
            if np.any((mask>0)&~pred):raise ValueError('Completion removed source foreground')
            c=np.array([np.count_nonzero(pred&gt),np.count_nonzero(pred&~gt),np.count_nonzero(~pred&gt)],np.int64)
            totals.setdefault(name,{s:np.zeros(3,np.int64) for s in ['train','dev','test']})[row['split']]+=c
            record['counts'][name]=c.tolist()
        records.append(record)
        if (ordinal+1)%500==0:print(f'Kernel-free components {ordinal+1}/{len(rows)}',flush=True)
    baseline=sum(totals['baseline'].values())
    if tuple(baseline)!=tuple(best['best']['all'][k] for k in ['TP','FP','FN']):raise ValueError('Baseline changed')
    result=dict(instances=len(rows),GTChanged=False,GTAtInference=False,caseSpecificRules=False,
        extraDilationKernel=False,wholePagesRead=False,sourceModelPackage=best['modelPackage'],
        productionChanged=False,seconds=time.monotonic()-start,
        candidates={name:dict(all=metrics(sum(by.values())),bySplit={s:metrics(c) for s,c in by.items()}) for name,by in totals.items()},records=records)
    save(args.out/'RESULT.json',result);print(result['candidates'],flush=True)


if __name__=='__main__':main()
