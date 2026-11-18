"""Native background support near confident predicted glyphs, including mask interiors."""
import cv2
import numpy as np
from source_appearance import lab

VERSION='native-glyph-near-background-support-v1'
POLICY=dict(minimumSeedPixels=3,minimumSegPrimary=.7,minimumRFOwner=.001,
            minimumOCRSupport=.2,maximumBackgroundSegPrimary=.2,
            radius='clip(.08*fontPixels,2,8)',outerRadiusFactor=3.,colourDeltaE=10.,
            neighbourPolicy='context union minus own predicted mask',GTAtInference=False)
GLOBAL=('observed','logSeedPixelsDiv10','seedFractionOfOwn','seedSegMean','seedRFOwnerMean','seedOCRMean')
LOCAL=('colourFraction','weightedColourMass','insideOwnFraction','segMean','boundaryMean','balloonMean','frameMean','OCRMean')
FEATURE_NAMES=GLOBAL+tuple(scale+'.'+name for scale in ('near','outer') for name in LOCAL)+('minimumColourDistanceFromSeedDivRadius','insideMinusOutsideColourFraction')

def features(rgb,own,context,colours,font,arrays):
    if rgb.dtype!=np.uint8 or own.dtype!=bool or rgb.shape!=own.shape+(3,):raise ValueError('Expected native aligned RGB and predicted mask')
    context=np.asarray(context,bool)
    if context.shape!=own.shape or np.any(own&~context):raise ValueError('Invalid predicted context union')
    colours=np.asarray(colours)
    if colours.ndim!=2 or colours.shape[1]!=3 or not len(colours) or not np.isfinite(colours).all() or np.any(colours<0) or np.any(colours>255):raise ValueError('Invalid existing palette')
    if not np.isfinite(font) or font<=0:raise ValueError('Invalid source font scale')
    shapes=dict(rf=own.shape+(27,),ocr=own.shape+(8,),segPrimary=own.shape,segBoundary=own.shape)
    for name,shape in shapes.items():
        a=np.asarray(arrays[name])
        if a.shape!=shape or not np.isfinite(a).all() or np.any(a<0) or np.any(a>1.001):raise ValueError('Invalid native source probabilities: '+name)
    rf=arrays['rf'];seg=arrays['segPrimary'];boundary=arrays['segBoundary'];ocr=arrays['ocr'][:,:,0]
    owner=np.maximum(rf[:,:,15]*rf[:,:,16],rf[:,:,17]*rf[:,:,18])
    seeds=own&(seg>=.7)&(owner>=.001)&(ocr>.2)
    n=int(seeds.sum());observed=n>=3
    if not observed:return np.zeros((len(colours),len(FEATURE_NAMES)),np.float32),dict(version=VERSION,observed=False,seedPixels=n)
    radius=float(np.clip(.08*font,2,8));distance=cv2.distanceTransform((~seeds).astype(np.uint8),cv2.DIST_L2,5)
    eligible=(distance>0)&(distance<=3*radius)&(seg<.2)&~(context&~own)
    native=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    signal=[seg,boundary,rf[:,:,6],rf[:,:,9],ocr]
    global_values=[1,np.log1p(n)/10,n/max(1,int(own.sum())),float(seg[seeds].mean()),float(owner[seeds].mean()),float(ocr[seeds].mean())]
    weight=np.exp(-distance/radius)*(1-seg)*(1-boundary)**2
    rows=[]
    for colour in lab(colours):
        close=np.linalg.norm(native-colour,axis=2)<=10
        values=list(global_values)
        for scale in (1.,3.):
            ring=eligible&(distance<=scale*radius);selected=ring&close;count=int(selected.sum());denom=max(1,int(ring.sum()))
            values.extend([count/denom,float(weight[selected].sum()/max(1e-12,float(weight[ring].sum()))),float(own[selected].mean()) if count else 0.])
            values.extend(float(a[selected].mean()) if count else 0. for a in signal)
        positions=eligible&close
        values.append(float(distance[positions].min()/radius) if positions.any() else 3.)
        inner=eligible&own;outer=eligible&~own
        values.append(float((inner&close).sum()/max(1,int(inner.sum()))-(outer&close).sum()/max(1,int(outer.sum()))))
        rows.append(values)
    result=np.asarray(rows,np.float32)
    if result.shape!=(len(colours),24) or not np.isfinite(result).all():raise ValueError('Invalid glyph-near descriptor')
    return result,dict(version=VERSION,observed=True,seedPixels=n,eligiblePixels=int(eligible.sum()),insideOwnPixels=int((eligible&own).sum()),radius=radius,GTAtInference=False,sourceContextExpanded=False)
