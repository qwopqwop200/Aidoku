"""Observable glyph-body dimensions, including bodies enclosed by outlines."""
import math
import cv2
import numpy as np


FEATURE_COUNT=56


def height_mode(heights,unit):
    values=sorted(float(x) for x in heights if .18*unit<=x<=1.8*unit)
    if not values:return (0.,0.,0.)
    bands=[]
    for value in values:
        if not bands or value/bands[-1][-1]>=1.8:bands.append([])
        bands[-1].append(value)
    supported=[band for band in bands if len(band)>=2]
    chosen=(supported or bands)[-1]
    return float(np.median(chosen)),float(np.std(np.log(chosen))),float(len(chosen))


def glyph_body_features(rgb,bbox,prior,ownership,with_modes=False):
    if ownership.shape!=rgb.shape[:2]:raise ValueError('Glyph ownership geometry differs')
    x,y,w,h=bbox;target=rgb;own=ownership
    if not target.size:raise ValueError('Empty glyph target')
    scale=min(1.,640/max(target.shape[:2]));unit=prior*scale
    if scale<1:
        target=cv2.resize(target,None,fx=scale,fy=scale,interpolation=cv2.INTER_AREA);own=cv2.resize(own.astype(np.uint8),(target.shape[1],target.shape[0]),interpolation=cv2.INTER_NEAREST)>0
    rx,ry,rw,rh=np.array([x,y,w,h])*scale
    def belongs(sx,sy,sw,sh):
        overlap=max(0,min(sx+sw,rx+rw)-max(sx,rx))*max(0,min(sy+sh,ry+rh)-max(sy,ry))
        return overlap>=.5*sw*sh
    lo=target.min(axis=2);hi=target.max(axis=2);cores=[hi<100,(lo>180)&(hi.astype(float)-lo<45)];channels=[]
    for core in cores:
        binary=(core&own).astype(np.uint8)
        _,_,stats,_=cv2.connectedComponentsWithStats(binary,8);components=[]
        for sx,sy,sw,sh,area in stats[1:]:
            if area>=max(3,unit**2*.002) and area<binary.size*.65 and belongs(sx,sy,sw,sh):components.append((sh/scale,sw/scale,math.sqrt(area)/scale))
        channels.append(components)
        # Closed bright outlines can enclose glyph bodies with the very same
        # colour as the page behind them; intensity components miss these.
        contours,hierarchy=cv2.findContours(core.astype(np.uint8),cv2.RETR_CCOMP,cv2.CHAIN_APPROX_SIMPLE);holes=[]
        if hierarchy is not None:
            for i,contour in enumerate(contours):
                parent=hierarchy[0,i,3]
                if parent<0:continue
                area=cv2.contourArea(contour);sx,sy,sw,sh=cv2.boundingRect(contour);px,py,pw,ph=cv2.boundingRect(contours[parent])
                if area<max(3,unit**2*.002) or area>=core.size*.65 or not belongs(sx,sy,sw,sh):continue
                region=np.zeros((sh,sw),np.uint8);shifted=contour-np.array([[[sx,sy]]]);cv2.drawContours(region,[shifted],-1,1,-1)
                inside_support=own[sy:sy+sh,sx:sx+sw][region>0].mean()
                if inside_support<.5:
                    # An erasure mask can correctly contain only the outline
                    # when the glyph fill matches the surrounding background.
                    # Ownership of the enclosing contour still witnesses body
                    # geometry; requiring owned interior pixels loses it.
                    border=np.zeros((ph,pw),np.uint8);outer=contours[parent]-np.array([[[px,py]]]);cv2.drawContours(border,[outer],-1,1,1)
                    if own[py:py+ph,px:px+pw][border>0].mean()<.8:continue
                holes.append((sh/scale,sw/scale,math.sqrt(area)/scale))
        channels.append(holes)
    features=[]
    for values in channels:
        if not values:features.extend([0.]*14);continue
        array=np.asarray(values);features.extend(np.quantile(array,[.25,.5,.75,.95],axis=0).T.ravel().tolist());features.extend([len(values),1.])
    if with_modes:
        modes=[height_mode([x[0] for x in values],prior) for values in channels]
        dark=float((cores[0]&own).sum())/max(1,int(own.sum()));light=float((cores[1]&own).sum())/max(1,int(own.sum()))
        if (~own).any():
            background=float(np.median(target[~own].mean(axis=1)))
            dark*=background/255;light*=(255-background)/255
        chosen=(3 if modes[3][0]>0 else 2) if light>=dark else (0 if modes[0][0]>0 else 1)
        features.extend([x for mode in modes for x in mode]+[float(chosen)])
    return np.asarray(features,float)
