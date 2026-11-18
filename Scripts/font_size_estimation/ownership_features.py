"""Numerical source glyph-ownership features; predicted masks only."""
import hashlib
from functools import lru_cache
from pathlib import Path
import numpy as np
from PIL import Image
from estimator import features


@lru_cache(maxsize=3)
def page_mask(path,expected_sha,width,height):
    if hashlib.sha256(Path(path).read_bytes()).hexdigest()!=expected_sha:raise ValueError('Predicted mask identity differs')
    with Image.open(path) as image:
        if image.size!=(width,height):raise ValueError('Mask/source dimensions differ')
        value=np.asarray(image.convert('L')).copy()
    if not np.isin(value,[0,255]).all():raise ValueError('Predicted ownership mask must be binary')
    return value>0


def ownership_features(rgb,mask,bbox,prior):
    if mask.shape!=rgb.shape[:2]:raise ValueError('Mask/RGB crop geometry differs')
    native=features(rgb,bbox,prior,version=4)
    x,y,w,h=bbox;left=max(0,int(x));top=max(0,int(y));right=min(mask.shape[1],int(np.ceil(x+w)));bottom=min(mask.shape[0],int(np.ceil(y+h)))
    local=mask[top:bottom,left:right];fraction=float(local.mean()) if local.size else 0.
    if not local.any():return np.r_[native,0.,0.,np.zeros(150)]
    isolated=rgb.copy();isolated[~mask]=127
    measured=features(isolated,bbox,prior,version=4)
    return np.r_[native,1.,fraction,measured[6:]]


def measure(job):
    row,meta=job
    if row['sourceImageSHA256']!=meta['sourceSHA256'] or row['pageSize']!=[meta['width'],meta['height']]:raise ValueError('Mask/source binding differs')
    if row['contextFractionEachSide']>.15:raise ValueError('Crop exceeds authorized context')
    if hashlib.sha256(Path(row['crop']).read_bytes()).hexdigest()!=row['cropSHA256']:raise ValueError('RGB crop changed')
    mask=page_mask(meta['maskPath'],meta['maskSHA256'],meta['width'],meta['height']);x,y,right,bottom=row['cropBounds']
    with Image.open(row['crop']) as image:rgb=np.asarray(image.convert('RGB'))
    return ownership_features(rgb,mask[y:bottom,x:right],row['bboxInCrop'],row['priorReferenceFontPx'])
