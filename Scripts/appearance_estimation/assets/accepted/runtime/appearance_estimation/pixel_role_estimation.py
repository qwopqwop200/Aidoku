"""Source-only pixel paint-role estimation using RGB, RF, soft pixels, OCR and bbox geometry."""
import cv2
import numpy as np
from source_appearance import lab

VERSION='source-pixel-paint-role-v1'
ROLE_NAMES=['fill','outline','background','shadowComposite']


def features(rgb,mask,rf,primary,boundary,ocr,geometry,prediction,positions):
    h,w=mask.shape;positions=np.asarray(positions,np.int64)
    if rgb.shape!=(h,w,3) or rf.shape!=(h,w,27) or primary.shape!=(h,w) or boundary.shape!=(h,w) or ocr.shape!=(h,w,8):raise ValueError('Pixel-role evidence/source geometry mismatch')
    if positions.ndim!=1 or (positions<0).any() or (positions>=h*w).any():raise ValueError('Pixel queries must be actual crop positions')
    raw=rgb.astype(np.float32)/255;image_lab=cv2.cvtColor(raw,cv2.COLOR_RGB2LAB)
    f=max(1.,float(geometry.get('fontPixels') or min(h,w)));owned=np.ones((h,w),np.uint8)
    polygons=geometry.get('polygons')
    if polygons:
        owned[:]=0;cv2.fillPoly(owned,[np.rint(p).astype(np.int32) for p in polygons],1)
    points=np.asarray(geometry.get('mergedPolygon') or [[0,0],[w-1,0],[w-1,h-1],[0,h-1]],np.float32)
    merged=np.zeros((h,w),np.uint8);cv2.fillPoly(merged,[np.rint(points).astype(np.int32)],1)
    (cx,cy),(rw,rh),angle=cv2.minAreaRect(points);angle=np.deg2rad(angle)
    y=(positions//w).astype(np.float32);x=(positions%w).astype(np.float32)
    u=((x-cx)*np.cos(angle)+(y-cy)*np.sin(angle))/max(1,rw*.5)
    v=(-(x-cx)*np.sin(angle)+(y-cy)*np.cos(angle))/max(1,rh*.5)
    def sample(a):return a.reshape(h*w,-1)[positions]
    matrix=[sample(raw),sample(image_lab)/np.array([100,128,128],np.float32)]
    names=['red','green','blue','LabL','LabA','LabB']
    for size in [3,9]:
        matrix.append(sample(raw-cv2.boxFilter(raw,-1,(size,size),borderType=cv2.BORDER_REFLECT)))
        names += [f'RGBContrast{size}.{c}' for c in ['r','g','b']]
    grey=cv2.cvtColor(raw,cv2.COLOR_RGB2GRAY);gx=cv2.Sobel(grey,-1,1,0);gy=cv2.Sobel(grey,-1,0,1)
    matrix += [sample(np.hypot(gx,gy)),sample(rf),sample(primary),sample(boundary),sample(abs(primary-boundary)),sample(ocr)]
    names += ['gradientMagnitude']+[f'RF{i}' for i in range(27)]+['segPrimary','segBoundary','segDisagreement']+[f'OCR{i}' for i in range(8)]
    for label,area in [('bbox',owned),('mergedBBox',merged),('predictedMask',mask.astype(np.uint8))]:
        inside=cv2.distanceTransform(area.astype(np.uint8),cv2.DIST_L2,3)
        outside=cv2.distanceTransform(1-area.astype(np.uint8),cv2.DIST_L2,3)
        matrix += [sample(area),sample(np.clip((inside-outside)/f,-2,2))];names += [label+'.support',label+'.signedDistanceInFonts']
    matrix.append(np.column_stack([np.clip(u,-2,2),np.clip(v,-2,2)]));names += ['relativeBBoxU','relativeBBoxV']
    colour=sample(image_lab)
    for role in ['fill','outline','background']:
        distance=np.linalg.norm(colour-lab([prediction[role]['rgb']])[0],axis=1)
        matrix += [distance[:,None]/100,np.exp(-.5*(distance/10)**2)[:,None]];names += [role+'.colourDistance',role+'.colourAffinity']
    p=primary.ravel()[positions];text=rf.reshape(-1,27)[positions,0];sfx=rf.reshape(-1,27)[positions,3]
    matrix.append(np.column_stack([text*p,sfx*p,rf.reshape(-1,27)[positions,6]*(1-p),rf.reshape(-1,27)[positions,9]*(1-p)]))
    names += ['RFTextTimesPixel','RFSFXTimesPixel','RFBalloonTimesBackgroundPixel','RFFrameTimesBackgroundPixel']
    matrix.append(np.tile([float(prediction['outline']['present']),prediction['outline']['probability']],(len(positions),1)))
    names += ['sourceOutlinePresent','sourceOutlineClassifierProbability']
    result=np.column_stack(matrix).astype(np.float32)
    if not np.isfinite(result).all():raise ValueError('Nonfinite source pixel-role features')
    return result,names


def describe(rgb,mask,rf,primary,boundary,ocr,geometry,prediction,model,max_samples=4096,feature_prediction=None):
    if model['version']!=VERSION:raise ValueError('Pixel-role/source feature contract mismatch')
    step=max(1,int(np.ceil(mask.size/max_samples)));positions=np.arange(0,mask.size,step,dtype=np.int64)
    x,names=features(rgb,mask,rf,primary,boundary,ocr,geometry,feature_prediction if feature_prediction is not None else prediction,positions)
    if names!=model['featureNames']:raise ValueError('Pixel-role feature schema changed')
    scores=model['classifier'].predict_proba(x);colours=rgb.reshape(-1,3)[positions]
    result=dict(version=VERSION,samples=len(positions),GTAtInference=False,roles={})
    for j,name in enumerate(ROLE_NAMES):
        column=np.flatnonzero(model['classifier'].classes_==j)
        if not len(column):continue
        probability=scores[:,column[0]];threshold=model.get('roleProbabilityThresholds',{}).get(name,model['probabilityThreshold']);selected=probability>=threshold
        if name=='shadowComposite' and not prediction['shadow']['present']:selected[:]=False
        paint=[]
        if selected.sum()>=8:
            pixels=colours[selected];weights=probability[selected];codes=(pixels.astype(np.int32)//16)@np.array([256,16,1])
            mass=np.bincount(codes,weights=weights,minlength=4096);total=mass.sum()
            for code in np.argsort(-mass)[:3]:
                if mass[code]<max(.05*total,1):continue
                member=pixels[codes==code];paint.append(dict(rgb=np.rint(np.median(member,axis=0)).astype(int).tolist(),observedMass=float(mass[code]/total)))
        result['roles'][name]=dict(meanProbability=float(probability.mean()),confidentSamples=int(selected.sum()),observedColours=paint)
    if feature_prediction is not None:result['featureContextPolicy']=model['featureContext']['version']
    result['shadowColourSemantics']='Observed composite colours only; intrinsic shadow colour/opacity/blur are not identified'
    return result
