"""Original OCR confidence/box evidence only: no text, target IoU, labels or keep decisions."""
from functools import lru_cache
from pathlib import Path
import gzip
import json
import cv2
import numpy as np

NAMES=['ocrBoxSupport','ocrDetAvailable','ocrDetectorConfidence','ocrRecAvailable','ocrRecognitionConfidence',
       'ocrTokensAvailable','ocrMinimumTokenConfidence','ocrMeanTokenConfidence']
SOURCE_FIELDS=['detectorAvailable','detectorConfidence','recAvailable','recConfidence','recTokensAvailable',
               'recMinTokenConfidence','recMeanTokenConfidence']


@lru_cache(maxsize=2)
def load(path):
    with gzip.open(path,'rt') as f:raw=json.load(f)
    data=raw['value'];names=data['featureNames'];indices={key:names.index(key) for key in SOURCE_FIELDS}
    boxes=[]
    for row in data['rows']:
        polygon=np.asarray(row['polygon'],np.float32)
        if polygon.ndim!=2 or polygon.shape[1]!=2 or len(polygon)<3 or not np.isfinite(polygon).all():continue
        values=np.array([row['features'][indices[k]] for k in SOURCE_FIELDS],np.float32)
        values=np.where(np.isfinite(values),np.clip(values,0,1),0)
        boxes.append((polygon,values))
    return dict(sourceSHA256=raw['sourceSHA256'],pageSize=[data['width'],data['height']],boxes=boxes)


def raster(path,source_sha,page_size,bounds):
    data=load(str(path))
    if data['sourceSHA256']!=source_sha or data['pageSize']!=page_size:raise ValueError('OCR confidence evidence source/geometry mismatch')
    x,y,right,bottom=bounds;h,w=bottom-y,right-x;planes=np.zeros((h,w,len(NAMES)),np.float32)
    for polygon,values in data['boxes']:
        lo=polygon.min(0);hi=polygon.max(0)
        if hi[0]<x or hi[1]<y or lo[0]>=right or lo[1]>=bottom:continue
        local=polygon-[x,y];support=np.zeros((h,w),np.uint8);cv2.fillPoly(support,[np.rint(local).astype(np.int32)],1)
        np.maximum(planes,support[:,:,None]*np.r_[1.,values],out=planes)
    return planes
