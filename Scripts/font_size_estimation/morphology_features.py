"""Source-only multi-scale stroke grouping; no glyph identity or GT mask."""
import math
import cv2
import numpy as np


FEATURE_COUNT=144


def grouped_body_features(rgb,bbox,prior):
    if not math.isfinite(prior) or prior<=0:raise ValueError('Invalid prior em')
    x,y,w,h=bbox
    if min(w,h)<=0:raise ValueError('Empty bbox')
    target=rgb[max(0,int(y)):min(rgb.shape[0],math.ceil(y+h)),
               max(0,int(x)):min(rgb.shape[1],math.ceil(x+w))]
    if not target.size:raise ValueError('Target outside crop')
    scale=min(1.,640/max(target.shape[:2]))
    if scale<1:target=cv2.resize(target,None,fx=scale,fy=scale,interpolation=cv2.INTER_AREA)
    unit=scale*prior;lo=target.min(axis=2);hi=target.max(axis=2)
    cores=[hi<100,(lo>180)&(hi.astype(float)-lo<45)]
    result=[]
    for core in cores:
        for fraction in (.04,.1,.2):
            # Odd kernels and explicit padding avoid an even-kernel translation
            # and avoid eroding letters merely because a bbox touches them.
            radius=max(1,round(unit*fraction/2));size=radius*2+1
            for kw,kh in ((size,1),(1,size),(size,size)):
                pad=max(kw,kh)//2
                mask=np.pad(core.astype(np.uint8),pad)
                closed=cv2.morphologyEx(mask,cv2.MORPH_CLOSE,np.ones((kh,kw),np.uint8),borderType=cv2.BORDER_CONSTANT,borderValue=0)
                closed=closed[pad:pad+core.shape[0],pad:pad+core.shape[1]]
                _,_,stats,_=cv2.connectedComponentsWithStats(closed,8)
                stats=stats[1:]
                stats=stats[(stats[:,4]>=max(3,unit**2*.003))&(stats[:,4]<core.size*.65)]
                if not len(stats):result.extend([0.]*8);continue
                # Measure boundary contact instead of silently losing clipped
                # bodies. Background-sized components were excluded above.
                for values in (np.maximum(stats[:,2],stats[:,3])/unit,np.minimum(stats[:,2],stats[:,3])/unit):
                    result.extend(np.quantile(values,[.25,.5,.75]).tolist())
                boundary=(stats[:,0]==0)|(stats[:,1]==0)|(stats[:,0]+stats[:,2]>=core.shape[1])|(stats[:,1]+stats[:,3]>=core.shape[0])
                result.extend([len(stats)/max(1.,w*h/prior**2),float(boundary.mean())])
    return np.asarray(result,dtype=np.float64)
