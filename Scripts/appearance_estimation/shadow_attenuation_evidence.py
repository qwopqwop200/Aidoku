"""Local source attenuation displacement with independent component validation.

No palette mode, paragraph background plane, continuous optimizer or GT inputs.
Sigma and attenuation scale are search nuisances, never intrinsic outputs.
"""
import cv2
import numpy as np
from scipy.ndimage import distance_transform_edt
from source_appearance import lab
from shadow_template_fit import source_core

VERSION='source-component-local-attenuation-v1'
POLICIES=[
    dict(name='local-median',referenceQuantile=.5,neutralSpread=.1,minimumExplained=.2,minimumGain=.05),
    dict(name='local-upper-quartile',referenceQuantile=.75,neutralSpread=.1,minimumExplained=.2,minimumGain=.05),
    dict(name='local-upper-quartile-strict',referenceQuantile=.75,neutralSpread=.1,minimumExplained=.35,minimumGain=.1),
    dict(name='local-upper-quartile-neutral',referenceQuantile=.75,neutralSpread=.05,minimumExplained=.2,minimumGain=.05),
]


def _score_grid(body,valid,data,radius,sigma):
    template=body.astype(np.float32)
    if sigma:
        size=2*int(np.ceil(3*sigma))+1
        template=cv2.GaussianBlur(template,(size,size),sigma,borderType=cv2.BORDER_CONSTANT)
    # Zero padding is confined to the component's MODEL, never the RGB observations.
    padded=np.pad(template,radius)
    weights=valid.astype(np.float32)
    dot=cv2.matchTemplate(padded,weights*data,cv2.TM_CCORR)
    norm=cv2.matchTemplate(padded*padded,weights,cv2.TM_CCORR)
    energy=float(np.sum(weights*data*data))
    score=dot*dot/np.maximum(1e-8,np.maximum(norm,0)*energy)
    score[(dot<=0)|(norm<1e-6)]=0
    # Array position[dy+radius,dx+radius] describes positive source displacement.
    return np.clip(score[::-1,::-1],0,1)


def estimate(rgb,mask,prediction,font_pixels,polygons=None,policy=None):
    policy=POLICIES[0]if policy is None else policy
    if policy not in POLICIES:raise ValueError('Unknown frozen attenuation policy')
    if rgb.shape!=(*mask.shape,3)or rgb.dtype!=np.uint8:raise ValueError('Native RGB/mask shape or dtype mismatch')
    if not np.isfinite(float(font_pixels))or font_pixels<=0:raise ValueError('Invalid source font scale')
    result=dict(version=VERSION,policy=policy['name'],identified=False,offsetPx=None,intrinsicRGB=None,
        blurRadiusPx=None,opacity=None,GTAtInference=False,contextExpanded=False)
    core=source_core(rgb,mask,prediction,polygons)
    if core is None or isinstance(core,dict):return dict(result,reason='No separated source primary-fill core')
    width=float(prediction['outline'].get('widthPx')or 0)if prediction['outline']['present']else 0
    if not np.isfinite(width)or width<0:return dict(result,reason='Invalid source outline width')
    radius=max(3,min(12,round(font_pixels*.15)));sigmas=[0.,1.,2.]
    distance,nearest=distance_transform_edt(~core,return_indices=True)
    count,labels,stats,_=cv2.connectedComponentsWithStats(core.astype(np.uint8),connectivity=8)
    owners=labels[nearest[0],nearest[1]];body=distance<=width
    ids=[i for i in range(1,count)if stats[i,cv2.CC_STAT_AREA]>=max(12,font_pixels**2*.005)]
    ids=sorted(ids,key=lambda i:(-stats[i,cv2.CC_STAT_AREA],i))[:12]
    il=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB)
    paint=np.zeros(mask.shape,bool)
    colors=[prediction['fill']['rgb']]+prediction['fill'].get('colors',[])
    if prediction['outline']['present']:colors.append(prediction['outline']['rgb'])
    for color in colors:paint|=((il-lab([color])[0])**2).sum(2)<=8**2
    paint&=mask.astype(bool)
    componentScores=[];logs=[];censored=0
    pad=int(np.ceil(width))+2*radius+int(np.ceil(3*max(sigmas)))+4
    for identity in ids:
        x,y,w,h,_=map(int,stats[identity])
        if x-pad<0 or y-pad<0 or x+w+pad>mask.shape[1]or y+h+pad>mask.shape[0]:
            censored+=1;logs.append(dict(sourceComponent=identity,reason='Reference/search/sigma footprint outside actual crop'));continue
        x0,y0,x1,y1=x-pad,y-pad,x+w+pad,y+h+pad
        local=labels[y0:y1,x0:x1]==identity
        d=distance_transform_edt(~local);localBody=d<=width
        owner=owners[y0:y1,x0:x1]==identity
        occlusion=body[y0:y1,x0:x1]|paint[y0:y1,x0:x1]
        # Reference pixels are actual local exterior samples, excluding all owned paint.
        refs=(d>width+radius+2)&(d<=width+2*radius+4)&owner&~occlusion
        if refs.sum()<32:
            logs.append(dict(sourceComponent=identity,reason='Fewer than32 native local exterior references'));continue
        source=rgb[y0:y1,x0:x1];light=il[y0:y1,x0:x1,0]
        threshold=np.quantile(light[refs],policy['referenceQuantile'])
        refs&=light>=threshold
        reference=np.median(source[refs],axis=0).astype(np.float32)
        ratios=(reference-source.astype(np.float32))/np.maximum(reference,32)
        neutral=np.ptp(ratios,axis=2)<=policy['neutralSpread']
        data=np.clip(np.median(ratios,axis=2),0,.95).astype(np.float32)
        valid=owner&~occlusion&neutral&(d>width)&(d<=width+radius+3)
        positive=valid&(data>=.03)
        if positive.sum()<8:
            logs.append(dict(sourceComponent=identity,reason='Fewer than8 observed neutral attenuation pixels',referenceRGB=reference.tolist(),validPixels=int(valid.sum())));continue
        scores=np.stack([_score_grid(localBody,valid,data,radius,s)for s in sigmas])
        componentScores.append(scores)
        logs.append(dict(sourceComponent=identity,reason='source-component-score-grid',referenceRGB=reference.tolist(),
            referencePixels=int(refs.sum()),validPixels=int(valid.sum()),attenuationPixels=int(positive.sum()),
            medianObservedAttenuation=float(np.median(data[positive])),sourceArea=int(stats[identity,cv2.CC_STAT_AREA])))
    result.update(components=len(componentScores),censoredComponents=censored,sourceComponentLogs=logs,searchRadiusPx=radius,
        sigmaNuisanceChoices=sigmas,zeroShiftBaseline='Best symmetric0shift over all sigma choices, independently per component')
    if len(componentScores)<3:return dict(result,reason='Fewer than three uncensored independently measured components')
    scores=np.stack(componentScores);train=np.arange(len(scores))%2==0;validation=~train
    mean=scores[train].mean(0);mean[:,radius,radius]=-1
    sigmaIndex,iy,ix=np.unravel_index(np.argmax(mean),mean.shape);dx,dy=int(ix-radius),int(iy-radius)
    selected=scores[:,sigmaIndex,iy,ix]
    baseline=scores[:,:,radius,radius].max(1)
    opposite=scores[:,sigmaIndex,2*radius-iy,2*radius-ix]
    trainingScore=float(selected[train].mean());validationScore=float(selected[validation].mean())
    trainingGain=float((selected-baseline)[train].mean());validationGain=float((selected-baseline)[validation].mean())
    oppositeGain=float((selected-opposite)[validation].mean())
    agreement=float(np.mean((selected>=policy['minimumExplained'])&((selected-baseline)>=policy['minimumGain'])))
    accepted=trainingScore>=policy['minimumExplained']and validationScore>=policy['minimumExplained']and trainingGain>=policy['minimumGain']and validationGain>=policy['minimumGain']and oppositeGain>=policy['minimumGain']and agreement>=.6
    result.update(identified=bool(accepted),reason='Local attenuation displacement repeats on held-out components'if accepted else'Displacement fails held-out symmetric/opposite controls',
        candidateOffsetPx=[dx,dy],offsetPx=[dx,dy]if accepted else None,trainingComponents=int(train.sum()),validationComponents=int(validation.sum()),
        trainingExplainedEnergy=trainingScore,validationExplainedEnergy=validationScore,trainingGainOverZero=trainingGain,
        validationGainOverZero=validationGain,validationGainOverOpposite=oppositeGain,componentAgreement=agreement,
        selectedSigmaNuisancePx=sigmas[sigmaIndex],componentScores=[dict(selected=float(s),symmetricZero=float(z),opposite=float(o),fit=bool(t))for s,z,o,t in zip(selected,baseline,opposite,train)],
        note='Visible geometry only; local reference RGB and sigma are nuisance estimates, not intrinsic shadow colour/opacity/blur')
    return result
