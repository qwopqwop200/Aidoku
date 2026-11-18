"""Finite native normal-profile evidence of diffuse dark glow, not shadow fitting."""
import cv2
import numpy as np
from scipy.ndimage import distance_transform_edt
from local_source_core import extract
from source_appearance import lab

VERSION='source-native-dip-recovery-glow-v2'
POLICIES=[
    dict(name='three-pixel-dip',minimumDarkPixels=3,minimumDropL=8,maximumControlRangeL=8),
    dict(name='four-pixel-dip',minimumDarkPixels=4,minimumDropL=8,maximumControlRangeL=8),
    dict(name='stronger-dip',minimumDarkPixels=3,minimumDropL=12,maximumControlRangeL=8),
    dict(name='stable-background',minimumDarkPixels=3,minimumDropL=8,maximumControlRangeL=4),
]


def _sector(dx,dy):
    # float32 modulo can round to2*pi;4 is the same circular bin as0.
    return int(((np.arctan2(dy,dx)+np.pi/4)%(2*np.pi))/(np.pi/2))%4


def _native_profile(rgb,xx,yy):
    x=np.rint(xx).astype(int);y=np.rint(yy).astype(int)
    if (x<0).any()or(x>=rgb.shape[1]).any()or(y<0).any()or(y>=rgb.shape[0]).any():return None
    keep=np.r_[True,(x[1:]!=x[:-1])|(y[1:]!=y[:-1])]
    return x[keep],y[keep],np.flatnonzero(keep),rgb[y[keep],x[keep]]


def _dip_profile(pixels,steps,start,depth,paints,policy):
    """One real source ray + its further background-only control, no padding."""
    il=lab(pixels);referenceMask=(steps>=depth-3)&(steps<=depth)
    control=steps>=depth+2
    if referenceMask.sum()<3 or control.sum()<4:return None,'insufficient-finite-reference-or-control'
    reference=np.median(pixels[referenceMask],axis=0)
    referenceLab=lab([reference])[0]
    if np.ptp(il[referenceMask,0])>6:return None,'nonplateau-exterior'
    if np.ptp(il[control,0])>policy['maximumControlRangeL']or abs(np.median(il[control,0])-referenceLab[0])>6:
        return None,'shared-background-control-varies'
    ratios=(reference-pixels.astype(float))/np.maximum(reference,32)
    neutral=(np.ptp(ratios,axis=1)<=.1)&(ratios.min(1)>=-.03)
    close=np.linalg.norm(il[:,None,:]-lab(paints)[None,:,:],axis=2).min(1)<=8
    near=(steps>=start)&(steps<=min(depth-6,start+max(4,depth//2)))&~close&neutral
    if not near.any():return None,'no-unoccluded-neutral-dip'
    indices=np.flatnonzero(near);peak=int(indices[np.argmin(il[indices,0])])
    darkness=referenceLab[0]-il[:,0]
    if darkness[peak]<policy['minimumDropL']:return None,'insufficient-dark-dip'
    after=(steps>=steps[peak])&(steps<=depth-3)&neutral&~close
    sequence=np.flatnonzero(after)
    if len(sequence)<5:return None,'short-recovery-native-support'
    if (darkness[sequence]>=policy['minimumDropL']).sum()<policy['minimumDarkPixels']:return None,'thin-AA-or-crisp-edge'
    if np.any(np.diff(sequence)>1):return None,'recovery-interrupted-by-paint-or-chroma'
    light=il[sequence,0];rises=np.diff(light)
    # A crisp plateau followed by one AA edge cannot supply three recovery increments.
    if (rises>=1).sum()<3 or (rises>=-1).mean()<.75:return None,'not-smooth-multistep-recovery'
    if light[-1]-light[0]<policy['minimumDropL']*.75:return None,'no-finite-recovery'
    return dict(rgb=pixels[peak].astype(int).tolist(),sourceBackgroundRGB=reference.tolist(),
        conditionalBlackAttenuation=float(np.median(ratios[peak])),
        dropL=float(darkness[peak]),darkNativePixels=int((darkness[sequence]>=policy['minimumDropL']).sum()),
        recoverySpanPx=int(steps[sequence[-1]]-steps[peak]),recoveryRises=int((rises>=1).sum()),controlRangeL=float(np.ptp(il[control,0]))),'observed-dip-smooth-recovery'


def estimate(rgb,mask,prediction,font_pixels,polygons=None,policy=None):
    policy=POLICIES[0]if policy is None else policy
    if policy not in POLICIES:raise ValueError('Unknown frozen glow profile policy')
    if rgb.dtype!=np.uint8 or rgb.shape!=(*mask.shape,3):raise ValueError('Native RGB/mask geometry mismatch')
    if not np.isfinite(float(font_pixels))or font_pixels<=0:raise ValueError('Invalid source font scale')
    result=dict(version=VERSION,policy=policy['name'],identified=False,observedRGB=None,intrinsicRGB=None,offsetPx=None,
        blurRadiusPx=None,opacity=None,GTAtInference=False,contextExpanded=False)
    core,coreEvidence=extract(rgb,mask,prediction,polygons,font_pixels)
    result['coreEvidence']=coreEvidence
    if core is None or isinstance(core,dict):return dict(result,reason='No locally separated source core')
    n,labels,stats,_=cv2.connectedComponentsWithStats(core.astype(np.uint8),connectivity=8)
    ids=sorted([i for i in range(1,n)if stats[i,cv2.CC_STAT_AREA]>=max(12,font_pixels**2*.005)],key=lambda i:(-stats[i,cv2.CC_STAT_AREA],i))[:12]
    if len(ids)<3:return dict(result,reason='Fewer than three source components',components=len(ids))
    inside=cv2.distanceTransform(core.astype(np.uint8),cv2.DIST_L2,5)
    outside=cv2.distanceTransform((~core).astype(np.uint8),cv2.DIST_L2,5)
    _,nearest=distance_transform_edt(~core,return_indices=True);owner=labels[nearest[0],nearest[1]]
    gy,gx=np.gradient(cv2.GaussianBlur(inside-outside,(0,0),1))
    edge=core&~cv2.erode(core.astype(np.uint8),np.ones((3,3),np.uint8)).astype(bool)
    y,x=np.where(edge&np.isin(labels,ids))
    if len(y)>1600:
        take=np.linspace(0,len(y)-1,1600).astype(int);y,x=y[take],x[take]
    norm=np.hypot(gx[y,x],gy[y,x]);valid=norm>.2;y,x,norm=y[valid],x[valid],norm[valid]
    dx,dy=-gx[y,x]/norm,-gy[y,x]/norm
    width=float(prediction['outline'].get('widthPx')or 0)if prediction['outline']['present']else 0
    if not np.isfinite(width)or width<0:return dict(result,reason='Invalid source nominal outline width')
    start=max(1,int(np.ceil(width)));depth=max(start+10,min(32,max(10,round(font_pixels*.25))))
    steps=np.arange(0,depth+9)
    paints=[prediction['fill']['rgb']]+prediction['fill'].get('colors',[])
    if prediction['outline']['present']:paints.append(prediction['outline']['rgb'])
    counts={i:dict(eligible=0,censored=0,positive=0,sectors=[0]*4)for i in ids};reasons={};positive=[]
    for j,(xx,yy)in enumerate(zip(x,y)):
        identity=int(labels[yy,xx]);p=_native_profile(rgb,xx+dx[j]*steps,yy+dy[j]*steps)
        if p is None:counts[identity]['censored']+=1;reasons['outside-real-crop']=reasons.get('outside-real-crop',0)+1;continue
        px,py,sourceSteps,pixels=p
        if np.any(owner[py,px]!=identity):counts[identity]['censored']+=1;reasons['other-component-context']=reasons.get('other-component-context',0)+1;continue
        counts[identity]['eligible']+=1
        e,reason=_dip_profile(pixels,sourceSteps,start,depth,paints,policy)
        reasons[reason]=reasons.get(reason,0)+1
        if e is None:continue
        # Centre bins on cardinal directions; tiny signs around a horizontal normal
        # must not manufacture both "up" and "down" support at a clipped edge.
        sector=_sector(dx[j],dy[j])
        counts[identity]['positive']+=1;counts[identity]['sectors'][sector]+=1
        positive.append(dict(sourceComponent=identity,sector=sector,seedXY=[int(xx),int(yy)],**e))
    measured=[i for i in ids if counts[i]['eligible']>=10]
    for i in ids:counts[i]['support']=counts[i]['positive']/max(1,counts[i]['eligible'])
    result.update(components=len(ids),measuredComponents=len(measured),rayReasons=reasons,componentEvidence=[dict(sourceComponent=i,**counts[i])for i in ids],
        eligibleProfiles=sum(c['eligible']for c in counts.values()),censoredProfiles=sum(c['censored']for c in counts.values()),
        positiveProfiles=len(positive),positiveProfileLogs=positive,sourceProfileDepthPx=depth)
    if len(measured)<3:return dict(result,reason='Fewer than three independently observed profile components')
    fit=measured[::2];validation=measured[1::2]
    fitPositive=[p for p in positive if p['sourceComponent']in fit];valPositive=[p for p in positive if p['sourceComponent']in validation]
    if not fitPositive or not valPositive:return dict(result,reason='Dip/recovery absent on component fit or validation side')
    observed=np.array([p['rgb']for p in fitPositive]);center=np.median(lab(observed),axis=0);color=observed[np.argmin(np.linalg.norm(lab(observed)-center,axis=1))].astype(int).tolist()
    valColorAgreement=float(np.mean(np.linalg.norm(lab([p['rgb']for p in valPositive])-lab([color])[0],axis=1)<=10))
    sectors=[sum(p['sector']==s for p in positive)for s in range(4)]
    def componentSupport(i):return counts[i]['positive']>=3 and counts[i]['support']>=.1
    fitAgreement=float(np.mean([componentSupport(i)for i in fit]));validationAgreement=float(np.mean([componentSupport(i)for i in validation]))
    support=len(positive)/max(1,result['eligibleProfiles'])
    accepted=len(positive)>=30 and support>=.1 and sum(s>=5 for s in sectors)>=3 and fitAgreement>=.5 and validationAgreement>=.5 and sum(componentSupport(i)for i in measured)>=3 and valColorAgreement>=.5
    result.update(identified=bool(accepted),reason='Repeated native dark dip and smooth exterior recovery'if accepted else'Dip/recovery fails repeated component/background controls',
        observedRGB=color if accepted else None,candidateObservedRGB=color,profileSupport=support,sectors=sectors,
        fitComponents=len(fit),validationComponents=len(validation),fitComponentAgreement=fitAgreement,validationComponentAgreement=validationAgreement,
        validationObservedColourAgreement=valColorAgreement,
        semantics='Observed source composite at repeated dip samples only; no intrinsic pigment, displacement, blur or opacity identified')
    return result
