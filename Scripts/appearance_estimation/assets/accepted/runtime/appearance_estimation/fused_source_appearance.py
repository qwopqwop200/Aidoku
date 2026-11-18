"""Fuse original RGB, soft RF instance/semantic evidence, pixel posteriors and source bbox geometry."""
import cv2
import numpy as np
from source_appearance import extract as base_extract,lab

VERSION='source-palette-rf-seg-geometry-v2'
RF_NAMES=[f'rfClass{c}{s}' for c in range(5) for s in ['MaxMaskProbability','MeanMaskProbability','BoxConfidence']]
RF_NAMES += [f'rfOwnerClass{c}{s}' for c in range(5) for s in ['MaskProbability','Affinity']]
RF_NAMES += ['rfSemanticMargin','rfMaskUncertainty']


def extract(rgb,mask,rf,primary,boundary,polygons=None,font_pixels=None,base_packet=None,merged_polygon=None,ocr_maps=None):
    h,w=rgb.shape[:2]
    if mask.shape!=(h,w) or rf.shape!=(h,w,27) or primary.shape!=(h,w) or boundary.shape!=(h,w):
        raise ValueError('Source evidence must align exactly to the original RGB crop; resizing is forbidden')
    for name,array in [('RF',rf),('primary',primary),('boundary',boundary)]:
        if not np.isfinite(array).all() or float(array.min())<0 or float(array.max())>1.001:raise ValueError(name+' source probabilities invalid')
    if ocr_maps is None or ocr_maps.shape!=(h,w,8) or not np.isfinite(ocr_maps).all() or float(ocr_maps.min())<0 or float(ocr_maps.max())>1.001:
        raise ValueError('Aligned source OCR confidence/availability maps are required')
    # Colour candidates cover the entire predicted glyph mask; source boxes are soft ownership evidence.
    packet=base_extract(rgb,mask,None,font_pixels)
    f=max(1.,float(packet['fontPixels']));mask=mask.astype(bool)
    owner=np.ones((h,w),np.uint8)
    if polygons:
        owner[:]=0;cv2.fillPoly(owner,[np.rint(p).astype(np.int32) for p in polygons],1)
        points=np.concatenate([np.asarray(p,np.float32) for p in polygons])
    else:points=np.array([[0,0],[w-1,0],[w-1,h-1],[0,h-1]],np.float32)
    merged_points=np.asarray(merged_polygon,np.float32) if merged_polygon is not None else cv2.convexHull(points).reshape(-1,2)
    merged=np.zeros((h,w),np.uint8);cv2.fillPoly(merged,[np.rint(merged_points).astype(np.int32)],1)
    merged_inside=cv2.distanceTransform(merged,cv2.DIST_L2,3);merged_outside=cv2.distanceTransform(1-merged,cv2.DIST_L2,3)
    (cx,cy),(rw,rh),angle=cv2.minAreaRect(merged_points)
    angle=np.deg2rad(angle);cos,sin=np.cos(angle),np.sin(angle)
    yy,xx=np.indices((h,w),dtype=np.float32)
    u=((xx-cx)*cos+(yy-cy)*sin)/max(1,rw*.5);v=(-(xx-cx)*sin+(yy-cy)*cos)/max(1,rh*.5)
    inside=cv2.distanceTransform(owner,cv2.DIST_L2,3);outside=cv2.distanceTransform(1-owner,cv2.DIST_L2,3)
    geometry=np.stack([owner.astype(float),np.clip((inside-outside)/f,-2,2),np.clip(u,-2,2),np.clip(v,-2,2),
        np.minimum(abs(u),2),np.minimum(abs(v),2),merged.astype(float),np.clip((merged_inside-merged_outside)/f,-2,2)],axis=2)
    radius=max(2,min(24,round(f*.12)));near=cv2.dilate(mask.astype(np.uint8),cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(radius*2+1,radius*2+1)))>0
    # Ownership localises the source, but the three support regions never clip to bbox boundaries.
    regions=[mask,near&~mask,~near];region_names=['predictedText','unmaskedFringe','farContext']
    step=max(1,int(np.ceil(h*w/120000)));rf_sample=rf.reshape(-1,27)[::step]
    p=primary.ravel()[::step];q=boundary.ravel()[::step]
    soft=np.column_stack([p,q,np.maximum(p,q),np.minimum(p,q),abs(p-q)])
    text=rf_sample[:,0];sfx=rf_sample[:,3];balloon=rf_sample[:,6];frame=rf_sample[:,9]
    interactions=np.column_stack([text*p,sfx*p,text*q,sfx*q,balloon*(1-p),frame*(1-p)])
    matrix=np.column_stack([rf_sample,soft,interactions,geometry.reshape(-1,8)[::step],ocr_maps.reshape(-1,8)[::step]]).astype(np.float32)
    names=RF_NAMES+['segPrimary','segBoundary','segMax','segMin','segDisagreement']+[
        'rfTextTimesSegPrimary','rfSFXTimesSegPrimary','rfTextTimesSegBoundary','rfSFXTimesSegBoundary',
        'rfBalloonTimesNonTextPosterior','rfFrameTimesNonTextPosterior']+[
        'bboxOwnedSeed','bboxSignedDistanceInFonts','bboxAxisU','bboxAxisV','bboxAbsU','bboxAbsV','mergedBBoxOwnedSeed','mergedBBoxSignedDistanceInFonts']
    from source_confidence_evidence import NAMES as OCR_NAMES
    names+=OCR_NAMES
    colors=lab(packet['colors']);pixels=cv2.cvtColor(rgb.astype(np.float32)/255,cv2.COLOR_RGB2LAB).reshape(-1,3)[::step]
    regions=[r.ravel()[::step] for r in regions];added=[]
    global_geometry=[np.log1p(len(polygons) if polygons else 1),np.log(max(1,rw)/max(1,rh)),
        np.sin(2*angle),np.cos(2*angle),float(owner.mean()),f/max(1,min(h,w))]
    for color in colors:
        close=((pixels-color)**2).sum(1)<=100;vector=[]
        for selected in regions:
            positions=close&selected;n=int(positions.sum());denom=max(1,int(selected.sum()))
            vector.extend(matrix[positions].mean(0).tolist() if n else [0.]*matrix.shape[1])
            vector.extend([n/denom,float(n>0)])
        vector.extend(global_geometry);added.append(vector)
    base=np.asarray(packet['features'],np.float32)
    packet['features']=np.column_stack([base,np.asarray(added,np.float32)]).tolist()
    packet.update(version=VERSION,fusionFeatureNames=[f'{region}.{name}' for region in region_names for name in names+['colourFraction','supportObserved']]+[
        'bboxLogCount','bboxLogAspect','bboxSinDoubleAngle','bboxCosDoubleAngle','bboxOwnerFraction','bboxFontRelativeToCrop'],
        baseFeatureCount=int(base.shape[1]),fusionInputs=['original RGB','predicted binary removal mask',
        'RF all-query class masks and bbox confidences','RF owner-query masks and affinities',
        'pre-threshold primary/boundary segmentation probabilities','individual and exact merged source bbox polygons and relative orientation','source OCR detector/recognition/token confidences and availability'],
        RFBackgroundSlotSemantics='Slot 4 retained separately; only slots 0-3 have text/SFX/balloon/frame semantics',
        bboxActsAsHardClip=False,GTAtInference=False)
    return packet
