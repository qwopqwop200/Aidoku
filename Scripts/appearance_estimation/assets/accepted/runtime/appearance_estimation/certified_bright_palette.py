"""Native finite outline-hole palette witnesses; no labels, IDs or file access."""
import cv2
import numpy as np
from scipy import ndimage
from source_appearance import lab
from paint_palette_metrics import predicted_colours
from owned_palette import supported
VERSION='certified-bright-native-palette-v1'
POLICY=dict(outlineDeltaE=10.,closingKernel=3,minimumComponentPixels=6,
    minimumPolygonSeedPixels=3,minimumMaskFraction=.8,interiorDistanceGreaterThan=1.5,
    minimumBodies=3,minimumContourChroma=20.,contourHueCosine=.96,contourLightnessSpan=30.,coverageDeltaE=10.,noveltyDeltaE=6.,labBin=6.,
    minimumGainPixels=12,minimumGainFraction=.02,minimumRepeatedBodies=2,
    minimumSupportedGainPerBody=3,sourceOnly=True,GTAtInference=False)

def propose(rgb,mask,arrays,geometry,prediction):
    if rgb.dtype!=np.uint8 or rgb.shape!=mask.shape+(3,) or mask.dtype!=bool:raise ValueError('Native aligned RGB/mask required')
    h,w=mask.shape
    for key,shape in dict(rf=(h,w,27),segPrimary=(h,w),segBoundary=(h,w),ocr=(h,w,8)).items():
        a=np.asarray(arrays[key]);assert a.shape==shape and np.isfinite(a).all()
    if not prediction['outline']['present']:return dict(eligible=False,bodies=[],reason='No source outline')
    il=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    outline=lab([prediction['outline']['rgb']])[0];chroma=float(np.linalg.norm(outline[1:]))
    if chroma<20:return dict(eligible=False,bodies=[],reason='Chromatic contour required')
    pixel_chroma=np.linalg.norm(il[:,:,1:],axis=2)
    cosine=(il[:,:,1:]*outline[1:]).sum(2)/np.maximum(1e-6,pixel_chroma*chroma)
    ring=(np.linalg.norm(il-outline,axis=2)<=POLICY['outlineDeltaE'])|((cosine>=.96)&(pixel_chroma>=max(15,chroma*.4))&(abs(il[:,:,0]-outline[0])<30))
    closed=cv2.morphologyEx(ring.astype(np.uint8),cv2.MORPH_CLOSE,np.ones((3,3),np.uint8))>0
    holes=ndimage.binary_fill_holes(closed)&~closed
    n,cc,stats,_=cv2.connectedComponentsWithStats(holes.astype(np.uint8),connectivity=8)
    seed=np.zeros(mask.shape,np.uint8)
    for polygon in geometry['polygons']:cv2.fillPoly(seed,[np.rint(polygon).astype(np.int32)],1)
    seeds=np.bincount(cc[(seed>0)&holes],minlength=n);bodies=[]
    for identity in range(1,n):
        if stats[identity,cv2.CC_STAT_AREA]<POLICY['minimumComponentPixels'] or seeds[identity]<3:continue
        body=cc==identity
        if float(mask[body].mean())<POLICY['minimumMaskFraction']:continue
        inner=ndimage.distance_transform_edt(body)>POLICY['interiorDistanceGreaterThan'];ys,xs=np.where(inner)
        if len(xs)<6:continue
        support=supported(arrays,ys,xs)
        bodies.append(dict(component=identity,pixels=rgb[ys,xs].copy(),lab=il[ys,xs].copy(),xy=np.column_stack([xs,ys]),support=support,
                           bodyPixels=int(body.sum()),interiorPixels=len(xs),sourceSupportFraction=float(support.mean())))
    return dict(eligible=len(bodies)>=3,bodies=bodies,reason='Finite source outline interiors',cropResized=False,bboxHardClip=False)

def choose(observation,prediction,support_fraction,maximum_additions):
    bodies=[b for b in observation['bodies'] if b['sourceSupportFraction']>=support_fraction]
    if len(bodies)<3:return [],dict(eligible=False,bodies=len(bodies),additions=[])
    pixels=np.concatenate([b['pixels'] for b in bodies]);ll=np.concatenate([b['lab'] for b in bodies]);xy=np.concatenate([b['xy'] for b in bodies]);support=np.concatenate([b['support'] for b in bodies]);ids=np.concatenate([np.full(len(b['pixels']),i) for i,b in enumerate(bodies)])
    palette=[prediction['fill']['rgb']]+[c['rgb'] for c in predicted_colours(prediction)];distance=np.linalg.norm(ll[:,None]-lab(palette)[None,:,:],axis=2).min(1)
    candidates=[]
    keys=np.floor(ll/POLICY['labBin']).astype(np.int32);_,groups=np.unique(keys,axis=0,return_inverse=True)
    for key in np.unique(groups):
        indices=np.flatnonzero(groups==key);center=np.median(ll[indices],axis=0);best=int(indices[np.argmin(np.linalg.norm(ll[indices]-center,axis=1))]);candidates.append(best)
    additions=[];reports=[]
    for _ in range(maximum_additions):
        uncovered=distance>10
        if uncovered.sum()<max(12,.02*len(ll)):break
        best=None;quality=None
        for pos in candidates:
            if np.linalg.norm(lab(palette+additions)-ll[pos],axis=1).min()<=6:continue
            d=np.linalg.norm(ll-ll[pos],axis=1);gain=uncovered&(d<=10);count=int(gain.sum())
            if count<max(12,.02*len(ll)):continue
            votes=[];witnesses=[]
            for i,b in enumerate(bodies):
                hits=np.flatnonzero(gain&support&(ids==i))
                if len(hits)<3:continue
                votes.append(i);p=int(hits[np.argmin(d[hits])]);witnesses.append(dict(body=i,xy=xy[p].tolist(),rgb=pixels[p].astype(int).tolist(),deltaE=float(d[p]),supportedNewPixels=len(hits)))
            if len(votes)<2:continue
            reduction=float(np.maximum(0,np.minimum(distance,10)-np.minimum(d,10)).sum());rgb=pixels[pos].astype(int).tolist();key=(count,reduction,tuple(-v for v in rgb))
            if quality is None or key>quality:quality=key;best=dict(rgb=rgb,gainPixels=count,components=votes,witnesses=witnesses,exactRGBWitnessXY=xy[pos].tolist(),exactRGBWitnessComponent=int(ids[pos]),distance=d)
        if best is None:break
        additions.append(best['rgb']);distance=np.minimum(distance,best.pop('distance'));reports.append(best)
    return additions,dict(eligible=True,bodies=len(bodies),nativeInteriorPixels=len(ll),supportedInteriorPixels=int(support.sum()),maximumAdditions=maximum_additions,minimumBodySourceSupport=support_fraction,additions=reports)


def infer(rgb,mask,arrays,geometry,prediction,diagnostic):
    import copy
    if diagnostic.get('mechanism')!='bounded-bright-interiors' or diagnostic.get('semantic',{}).get('accepted') is not True:
        return [],dict(eligible=False,reason='No freshly corroborated bright glyph bodies')
    native=copy.deepcopy(prediction)
    native['outline']['rgb']=list(diagnostic['sourceObservation']['rgb'])
    observation=propose(rgb,mask,arrays,geometry,native)
    additions,report=choose(observation,prediction,.95,3)
    selected=[ev for ev in report.get('additions',[]) if ev['gainPixels']/report['nativeInteriorPixels']>=.1]
    additions=[ev['rgb'] for ev in selected]
    evidence=dict(version=VERSION,eligible=bool(additions),mechanism='bounded-bright-interiors',
        diagnostic=copy.deepcopy(diagnostic),groups=[],nativeBodyReport=report,selectedAdditions=selected,GTAtInference=False)
    return additions,evidence


def validate(evidence,additions,rgb=None):
    def reject():raise ValueError('Invalid certified bright fill palette evidence')
    if evidence.get('version')!=VERSION or evidence.get('eligible') is not True:reject()
    diagnostic=evidence.get('diagnostic',{})
    if diagnostic.get('mechanism')!='bounded-bright-interiors' or diagnostic.get('semantic',{}).get('accepted') is not True:reject()
    holes=diagnostic.get('semantic',{}).get('holes',[])
    if sum(h.get('confirmed') is True for h in holes)<3:reject()
    report=evidence.get('nativeBodyReport',{});selected=evidence.get('selectedAdditions',[])
    if report.get('bodies',0)<3 or report.get('minimumBodySourceSupport')!=.95 or report.get('maximumAdditions')!=3:reject()
    if not 0<len(selected)<=3 or additions!=[ev.get('rgb') for ev in selected]:reject()
    n=report.get('nativeInteriorPixels',0)
    if n<=0:reject()
    def witness(xy,colour):
        if not isinstance(xy,list) or len(xy)!=2 or any(type(v) is not int or v<0 for v in xy):reject()
        if not isinstance(colour,list) or len(colour)!=3 or any(type(v) is not int or not 0<=v<=255 for v in colour):reject()
        if rgb is not None:
            x,y=xy
            if y>=rgb.shape[0] or x>=rgb.shape[1] or rgb[y,x].tolist()!=colour:reject()
    for ev in selected:
        if ev not in report.get('additions',[]) or ev.get('gainPixels',0)<max(12,.1*n):reject()
        components=ev.get('components',[]);witnesses=ev.get('witnesses',[])
        if len(set(components))<2 or len(components)!=len(set(components)) or set(components)!={v.get('body') for v in witnesses}:reject()
        if len(witnesses)!=len(components) or any(type(v) is not int or not 0<=v<report['bodies'] for v in components):reject()
        if ev.get('exactRGBWitnessComponent') not in range(report['bodies']):reject()
        witness(ev.get('exactRGBWitnessXY'),ev.get('rgb'))
        for evw in witnesses:
            if evw.get('supportedNewPixels',0)<3 or evw.get('deltaE',float('inf'))>10:reject()
            witness(evw.get('xy'),evw.get('rgb'))
