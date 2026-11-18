"""Native directional exterior witnesses around source-confirmed glyph bodies.

Experiment only: no GT, candidate-derived ray placement or full-page inputs.
"""
import cv2
import numpy as np
from source_appearance import lab
VERSION='directional-glyph-exterior-background-v1'
POLICY=dict(segSeed=.7,rfOwner=.001,ocrSeed=.2,segExterior=.2,boundaryExterior=.2,minimumSeeds=3,directions=8,radius='clip(.4*font,4,24)',consecutiveExterior=2,deltaE=10)
FEATURE_NAMES=('observed','logBodies','witnessFraction','meanWitnessDistanceDivRadius','witnessColourFraction','medianBodyFraction','q10BodyFraction','minimumBodyFraction','bodiesWithHalfSupport','opposingFraction','sectorCoverage','witnessMeanDeltaEDiv100','witnessMedianDeltaEDiv100','witnessQ10DeltaEDiv100','witnessQ90DeltaEDiv100','nearestHalfFraction','farthestHalfFraction','witnessDistanceWeightedFraction','meanRFText','meanRFBalloon','meanRFFrame','meanSegPrimary','meanSegBoundary','meanOCR')

def features(rgb,own,context,colours,font,arrays):
    if rgb.dtype!=np.uint8 or rgb.shape!=own.shape+(3,) or own.dtype!=bool:raise ValueError('native aligned source expected')
    if context.shape!=own.shape or np.any(own&~context) or not np.isfinite(font) or font<=0:raise ValueError('invalid context/font')
    rf=arrays['rf'];seg=arrays['segPrimary'];bound=arrays['segBoundary'];ocr=arrays['ocr'][:,:,0]
    seed=own&(seg>=.7)&(np.maximum(rf[:,:,15]*rf[:,:,16],rf[:,:,17]*rf[:,:,18])>=.001)&(ocr>.2)
    if seed.sum()<3:return np.zeros((len(colours),24),np.float32),dict(observed=False,seedPixels=int(seed.sum()))
    n,labels,stats,_=cv2.connectedComponentsWithStats(seed.astype(np.uint8),8)
    radius=float(np.clip(.4*font,4,24));h,w=own.shape;directions=np.column_stack([np.cos(np.arange(8)*np.pi/4),np.sin(np.arange(8)*np.pi/4)])
    valid=(seg<.2)&(bound<.2)&~(context&~own)
    witnesses=[];bodies=0
    for label in range(1,n):
        if stats[label,cv2.CC_STAT_AREA]<3:continue
        yy,xx=np.where(labels==label);coords=np.column_stack([xx,yy]);center=coords.mean(0);body=bodies;bodies+=1
        for sector,direction in enumerate(directions):
            projections=(coords-center)@direction;edge=coords[int(np.argmax(projections))];last=None;run=[]
            for distance in np.arange(1,radius+.5,.5):
                point=np.rint(edge+direction*distance).astype(int);x,y=map(int,point)
                if last==(x,y):continue
                last=(x,y)
                if x<0 or y<0 or x>=w or y>=h:break
                if context[y,x] and not own[y,x]:break
                if valid[y,x]:
                    run.append((x,y,float(np.linalg.norm(point-edge))))
                    if len(run)==2:
                        for a,b,dist in run:witnesses.append((body,sector,a,b,dist))
                        break
                else:run=[]
    if not witnesses:return np.zeros((len(colours),24),np.float32),dict(observed=False,seedPixels=int(seed.sum()),bodies=bodies)
    z=np.asarray(witnesses);x=z[:,2].astype(int);y=z[:,3].astype(int);body=z[:,0].astype(int);sector=z[:,1].astype(int);distance=z[:,4]
    pixels=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)[y,x]
    common=[1,np.log1p(bodies),len(z)/max(1,16*bodies),float(distance.mean()/radius)]
    rows=[]
    for colour in lab(colours):
        error=np.linalg.norm(pixels-colour,axis=1);close=error<=10
        fractions=np.array([close[body==b].mean() if (body==b).any() else 0. for b in range(bodies)])
        counts=np.array([np.bincount(sector[(body==b)&close],minlength=8)>0 for b in range(bodies)])
        opposite=(counts[:,:4]&counts[:,4:]).sum()/max(1,4*bodies)
        half=distance<=np.median(distance);weight=1/(1+distance)
        vals=common+[float(close.mean()),float(np.median(fractions)),float(np.quantile(fractions,.1)),float(fractions.min()),float((fractions>=.5).mean()),float(opposite),float((counts.sum(0)>0).mean()),float(error.mean()/100),float(np.median(error)/100),float(np.quantile(error,.1)/100),float(np.quantile(error,.9)/100),float(close[half].mean()),float(close[~half].mean()) if (~half).any() else 0.,float(weight[close].sum()/weight.sum())]
        a=close
        signals=[rf[:,:,15],rf[:,:,6],rf[:,:,9],seg,bound,ocr]
        vals.extend(float(v[y[a],x[a]].mean()) if a.any() else 0. for v in signals)
        rows.append(vals)
    result=np.asarray(rows,np.float32)
    if result.shape!=(len(colours),24) or not np.isfinite(result).all():raise ValueError('invalid directional descriptor')
    return result,dict(observed=True,seedPixels=int(seed.sum()),bodies=bodies,witnesses=len(witnesses),radius=radius)
