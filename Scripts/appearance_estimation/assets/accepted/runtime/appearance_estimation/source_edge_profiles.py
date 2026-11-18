"""Source-pixel cross-sections for observable contour bands and shadow displacement."""
import cv2
import numpy as np
from scipy import ndimage
from scipy.special import ndtr
from scipy.optimize import least_squares
from source_appearance import lab

VERSION='owned-source-edge-profiles-v2'
DIRECTIONS={'right':(1,0),'left':(-1,0),'down':(0,1),'up':(0,-1)}


def measure(rgb,mask,fill,outline,outline_present,font_pixels,polygons=None,other_fills=None,background=None):
    if rgb.shape[:2]!=mask.shape:raise ValueError('Source RGB/predicted-mask shape mismatch')
    h,w=mask.shape;roi=np.ones(mask.shape,np.uint8)
    if polygons:
        roi[:]=0;cv2.fillPoly(roi,[np.rint(p).astype(np.int32) for p in polygons],1)
    image_lab=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    exterior=lab([background])[0] if background is not None else None
    fill_lab=lab([fill])[0]
    contrast_colours=([outline] if outline_present and outline is not None else [])+([background] if background is not None else [])
    tolerance=min([18.]+[max(3.,float(np.linalg.norm(fill_lab-lab([c])[0]))*.35) for c in contrast_colours])
    core=(((image_lab-fill_lab)**2).sum(2)<=tolerance**2)&mask.astype(bool)&roi.astype(bool)
    if outline_present and outline is not None:
        ring=((image_lab-lab([outline])[0])**2).sum(2)<=8**2
        closed=cv2.morphologyEx(ring.astype(np.uint8),cv2.MORPH_CLOSE,np.ones((3,3),np.uint8))>0
        inside=ndimage.binary_fill_holes(closed)&~closed
        enclosed=core&inside
        if enclosed.sum()>=max(12,core.sum()*.25):core=enclosed
    blockers=core.copy()
    for c in other_fills or []:
        blockers|=(((image_lab-lab([c])[0])**2).sum(2)<=10**2)&mask.astype(bool)&roi.astype(bool)
    maximum=max(10,min(48,round(font_pixels*.35)))
    per_direction={};all_colours=[];observed_strokes=[];curves={}
    for name,(dx,dy) in DIRECTIONS.items():
        y,x=np.where(core);ny=y+dy;nx=x+dx;py=y-dy;px=x-dx
        valid=(ny>=0)&(ny<h)&(nx>=0)&(nx<w)&(py>=0)&(py<h)&(px>=0)&(px<w)
        y,x,ny,nx,py,px=[a[valid] for a in [y,x,ny,nx,py,px]]
        valid=~core[ny,nx]&core[py,px]
        y,x=y[valid],x[valid]
        if len(y)>1024:
            indices=np.linspace(0,len(y)-1,1024).astype(int);y,x=y[indices],x[indices]
        widths=[];fringes=[];colours=[];contrasts=[];usable=0;direction_curves=[]
        for yy,xx in zip(y,x):
            distance=np.arange(1,maximum+1);ys=yy+dy*distance;xs=xx+dx*distance
            valid=(ys>=0)&(ys<h)&(xs>=0)&(xs<w);ys,xs=ys[valid],xs[valid]
            if len(ys)<7:continue
            blocked=np.flatnonzero(blockers[ys,xs])
            if len(blocked):ys,xs=ys[:blocked[0]],xs[:blocked[0]]
            if len(ys)<7:continue
            values=image_lab[ys,xs];background=np.median(values[-3:],axis=0)
            if np.linalg.norm(values[-3:]-background,axis=1).max()>5:continue
            # Local dark artwork/shadow cannot silently become the exterior reference.
            if exterior is not None and np.linalg.norm(background-exterior)>8:continue
            usable+=1;start=end=0
            if outline_present and outline is not None:
                matches=np.linalg.norm(values-lab([outline])[0],axis=1)<=4
                positions=np.flatnonzero(matches[:3])
                if not len(positions):continue
                start=int(positions[0]);end=start
                while end<len(matches) and matches[end]:end+=1
            reference=np.median(rgb[ys[-3:],xs[-3:]].astype(float),axis=0)
            ratio=(reference-rgb[ys,xs].astype(float))/np.maximum(reference,32)
            signal=np.clip(np.median(ratio,axis=1),0,1)
            disagreement=np.ptp(ratio,axis=1)
            signal[:start]=np.nan
            signal[disagreement>.1]=np.nan
            record=np.full(maximum,np.nan);record[:len(signal)]=signal
            direction_curves.append(record)
            if outline_present and outline is not None and end>=len(values)-3:
                fringes.append(0.);continue
            if end>=len(values)-3:continue
            # A contiguous darker band must return to a stable local exterior.
            dark=background[0]-values[:,0]
            index=end
            while index<len(values)-2 and dark[index]>=3:index+=1
            length=index-end
            if length:
                peak=end+int(np.argmax(dark[end:index]))
                if dark[peak]<6:length=0
            if length:
                colour=rgb[ys[peak],xs[peak]].astype(float)
                colours.append(colour);all_colours.append(colour);contrasts.append(float(dark[peak]))
                if outline_present and outline is not None:
                    widths.append(float(end-start));observed_strokes.append(float(end-start))
            fringes.append(float(length))
        # Fringes are often occluded at concave corners; robust upper quantile retains exposed edges.
        q=float(np.quantile(fringes,.65)) if fringes else 0.
        per_direction[name]=dict(usableRays=usable,profileRays=len(fringes),fringeRays=sum(v>0 for v in fringes),
            fringeExtentPx=q,medianOutlineRunPx=float(np.median(widths)) if widths else None,
            medianContrastL=float(np.median(contrasts)) if contrasts else None)
        curves[name]=direction_curves
    supported=all(per_direction[d]['profileRays']>=12 for d in DIRECTIONS)
    displacement=[per_direction['right']['fringeExtentPx']-per_direction['left']['fringeExtentPx'],
                  per_direction['down']['fringeExtentPx']-per_direction['up']['fringeExtentPx']]
    colours=np.asarray(all_colours)
    centre=np.median(colours,axis=0) if len(colours) else None
    spread=float(np.median(np.linalg.norm(lab(colours)-lab([centre]),axis=1))) if len(colours) else None
    extent_directional=supported and max(abs(v) for v in displacement)>=1 and len(colours)>=16
    coherent=centre is not None and spread<=12
    fitted=fit_displacement(curves,font_pixels,outline_present)
    directional=fitted.get('identified',False)
    return dict(version=VERSION,sourceOnly=True,GTAtInference=False,perDirection=per_direction,
        offsetPx=fitted.get('offsetPx') if directional else None,
        observedExtentDifferencePx=[float(v) for v in displacement] if extent_directional else None,
        conditionalBlackShadowFit=fitted,
        observedCompositeRGB=np.rint(centre).astype(int).tolist() if coherent and len(colours)>=16 else None,
        colourDispersionDeltaE=spread,fringeSamples=len(colours),directionalEvidence=directional,
        outlineRunPx=float(np.median(observed_strokes)) if len(observed_strokes)>=16 else None,
        opacity=None,blurRadiusPx=None,
        limitations='Cross-section evidence only. Complex artwork, unobservable white-on-white borders or symmetric glows can leave displacement unidentified; composite colour is not intrinsic layer colour.')


def fit_displacement(curves,font_pixels,outlined):
    """Fit occluded Gaussian edge profiles, not the extent of a thresholded dark fringe."""
    positions=[];observations=[];directions=[];counts={}
    for direction,values in curves.items():
        counts[direction]=len(values)
        if len(values)<12:continue
        matrix=np.asarray(values);n=np.isfinite(matrix).sum(0);valid=n>=max(8,len(values)*.35)
        for index in np.flatnonzero(valid):
            positions.append(index+1);observations.append(float(np.nanmedian(matrix[:,index])));directions.append(DIRECTIONS[direction])
    if any(n<12 for n in counts.values()) or len(positions)<24:
        return dict(identified=False,reason='Insufficient stable exterior profiles in opposing directions',profileCounts=counts)
    t=np.asarray(positions);data=np.asarray(observations);normal=np.asarray(directions)
    if np.max(data)<.025:return dict(identified=False,reason='No measurable neutral attenuation profile',profileCounts=counts)
    maximum=min(12,max(4,font_pixels*.2));maximum_width=min(20,max(4,font_pixels*.2))
    def render(parameters):
        wx,wy,dx,dy,sigma,alpha=parameters
        width=np.where(normal[:,0]!=0,wx,wy) if outlined else np.zeros(len(t))
        shift=normal[:,0]*dx+normal[:,1]*dy
        return alpha*ndtr((t-width)/.5)*ndtr((width+shift-t)/sigma)
    best=None
    for dx,dy in [(2,2),(-2,2),(2,-2),(-2,-2)]:
        initial=[min(4,maximum_width-.1),min(4,maximum_width-.1),dx,dy,1.5,max(.05,min(.8,float(np.max(data))))]
        result=least_squares(lambda p:render(p)-data,initial,
            bounds=([0,0,-maximum,-maximum,.3,.01],[maximum_width,maximum_width,maximum,maximum,min(10,maximum),.95]),
            loss='soft_l1',f_scale=.02,max_nfev=350)
        if best is None or result.cost<best.cost:best=result
    fitted=render(best.x);rms=float(np.sqrt(np.mean((data-fitted)**2)))
    wx,wy,dx,dy,sigma,alpha=map(float,best.x)
    identified=rms<=.035 and max(abs(dx),abs(dy))>=.75 and max(abs(dx),abs(dy))<maximum-.1
    return dict(identified=identified,offsetPx=[dx,dy] if identified else None,fitRMSE=rms,
        observedOutlineBoundaryPx=[wx,wy] if outlined else None,conditionalSigmaPx=sigma,conditionalOpacity=alpha,
        hypothesis='Neutral black shadow; these photometric parameters are conditional, not identified intrinsic opacity/blur',profileCounts=counts)
