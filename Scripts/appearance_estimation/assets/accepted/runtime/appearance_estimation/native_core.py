"""Native eroded foreground-core representative; geometry/colour estimates only, no labels."""
import cv2
import numpy as np
from source_appearance import lab
from native_medoid import medoid
VERSION='largest-native-foreground-eroded-core-primary-v1'
CONFIGS=[dict(name=f'core{margin}-shift{shift}',margin=margin,shift=shift) for margin in [1.,1.5] for shift in [0.,3.]]
POLICY=dict(minimumComponentPixels=3,minimumCorePixels=3,connectivity=8,sourceOnly=True,GTAtInference=False)

def infer(rgb,mask,prediction,polygons):
 if rgb.dtype!=np.uint8 or rgb.shape!=mask.shape+(3,) or mask.dtype!=bool:raise ValueError('Native aligned RGB and predicted mask required')
 roi=np.zeros(mask.shape,np.uint8)
 for polygon in polygons:cv2.fillPoly(roi,[np.rint(polygon).astype(np.int32)],1)
 ll=lab(rgb.reshape(-1,3)).reshape(*mask.shape,3);current=lab([prediction['fill']['rgb']])[0]
 other=list(prediction['background'].get('colors') or [prediction['background']['rgb']])
 if prediction['outline']['present']:other.append(prediction['outline']['rgb'])
 foreground=mask&roi.astype(bool)&(np.linalg.norm(ll-current,axis=2)<np.min([np.linalg.norm(ll-c,axis=2) for c in lab(other)],axis=0))
 n,labels,stats,_=cv2.connectedComponentsWithStats(foreground.astype(np.uint8),connectivity=8)
 identities=[i for i in range(1,n) if stats[i,cv2.CC_STAT_AREA]>=3];out={}
 if not identities:return {c['name']:dict(nativeRGB=None,evidence=dict(eligible=False,reason='No foreground component')) for c in CONFIGS}
 identity=max(identities,key=lambda i:int(stats[i,cv2.CC_STAT_AREA]));body=labels==identity;depth=cv2.distanceTransform(body.astype(np.uint8),cv2.DIST_L2,5)
 for margin in [1.,1.5]:
  yy,xx=np.where(body&(depth>margin))
  if len(xx)>=3:
   colour,report=medoid(rgb[yy,xx]);position=int(np.flatnonzero(np.all(rgb[yy,xx]==colour,axis=1))[0]);difference=float(np.linalg.norm(lab([colour])[0]-current))
   evidence=dict(version=VERSION,eligible=True,component=identity,componentPixels=int(body.sum()),corePixels=len(xx),coreMarginPx=margin,maximumNativeDepthPx=float(depth.max()),nativeRGB=colour,nativeXY=[int(xx[position]),int(yy[position])],medoid=report,GTAtInference=False)
  else:colour=None;difference=0.;evidence=dict(eligible=False,reason='No native geometric core',componentPixels=int(body.sum()),corePixels=len(xx),coreMarginPx=margin)
  for shift in [0.,3.]:out[f'core{margin}-shift{shift}']=dict(nativeRGB=colour if difference>=shift else None,evidence=evidence,primaryDifferenceDeltaE=difference)
 return out
