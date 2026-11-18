"""Physical glyph metrics from source OCR, without token identity features.

Reference fonts supply ink dimensions in em units. Only pooled dimensions and
source-body/expected-body ratios enter regression, never strings or glyph IDs.
"""
from functools import lru_cache
from pathlib import Path
import unicodedata
import numpy as np
from PIL import ImageFont
from fontTools.ttLib import TTFont


EM=256
FEATURE_COUNT=146


def default_font_paths():
    needles=('角ゴシック W3','角ゴシック W6','丸ゴ ProN W4','明朝 ProN')
    paths=list(Path('/System/Library/Fonts').glob('*.ttc'))
    result=[]
    for needle in needles:
        matches=[p for p in paths if needle in unicodedata.normalize('NFC',p.name)]
        if len(matches)!=1:raise ValueError('Reference font unavailable: '+needle)
        result.append(str(matches[0]))
    return result


@lru_cache(maxsize=8)
def font_resource(path):
    with TTFont(path,fontNumber=0,lazy=True) as face:supported=frozenset(face.getBestCmap())
    return ImageFont.truetype(path,EM,index=0),supported


@lru_cache(maxsize=16384)
def glyph_measurement(path,char):
    font,supported=font_resource(path)
    if ord(char) not in supported:return None
    mask=font.getmask(char,mode='L')
    if not min(mask.size):return None
    ink=np.asarray(mask,dtype=np.uint8).reshape(mask.size[1],mask.size[0])>=64
    yy,xx=np.nonzero(ink)
    if not len(xx):return None
    w=float(xx.max()-xx.min()+1)/EM;h=float(yy.max()-yy.min()+1)/EM
    area=float(ink.sum())/EM**2
    return (w,h,max(w,h),min(w,h),area**.5,area/(w*h))


def font_metric_features(text,native,font_paths):
    if len(font_paths)!=4:raise ValueError('Expected four reference fonts')
    native=np.asarray(native)
    if native.shape!=(156,) or not np.isfinite(native).all():raise ValueError('Expected156 native measurements')
    chars=[c for c in unicodedata.normalize('NFC',text or '') if not c.isspace() and not unicodedata.category(c).startswith(('M','C'))]
    result=[];coverages=[]
    for path in font_paths:
        values=[value for c in chars if (value:=glyph_measurement(path,c)) is not None]
        coverages.append(len(values)/max(1,len(chars)))
        if not values:result.extend([0.]*36);continue
        quantiles=np.quantile(values,[.25,.5,.75],axis=0).T
        result.extend(quantiles.ravel().tolist())
        expected=quantiles[[2,3,4]].ravel()
        for offset in (96,120):
            ratio=np.divide(native[offset:offset+9],expected,out=np.zeros(9),where=expected>=.03)
            result.extend(np.clip(ratio,0,8).tolist())
    result.extend([float(bool(chars)),float(np.mean(coverages))])
    return np.asarray(result,dtype=np.float64)
