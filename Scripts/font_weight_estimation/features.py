"""Pooled source-body stroke evidence; no glyph identity or page coordinates."""
from pathlib import Path
import sys

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'font_size_estimation'))
from estimator import features as size_features

VERSION = 2

def stroke_summary(mask, unit, allow_boundary=False):
    mask = np.asarray(mask, np.uint8)
    n, cc, stats, _ = cv2.connectedComponentsWithStats(mask, 8)
    keep = np.zeros(n, bool)
    if n > 1:
        s = stats[1:]
        keep[1:] = ((s[:,4]>=max(3, unit*unit*.003)) & (s[:,4]<mask.size*(.95 if allow_boundary else .65)))
        if not allow_boundary:
            keep[1:] &= ((s[:,0]>0) & (s[:,1]>0)
                         & (s[:,0]+s[:,2]<mask.shape[1]) & (s[:,1]+s[:,3]<mask.shape[0]))
    body = keep[cc].astype(np.uint8)
    depth = cv2.distanceTransform(body, cv2.DIST_L2, cv2.DIST_MASK_PRECISE)
    ridge = (depth>0) & (depth>=cv2.dilate(depth, np.ones((3,3),np.uint8))-.001)
    thickness = 2*depth[ridge]/unit
    values = np.quantile(thickness,[.1,.25,.5,.75,.9]) if thickness.size else np.zeros(5)
    contour,_ = cv2.findContours(body,cv2.RETR_LIST,cv2.CHAIN_APPROX_SIMPLE)
    perimeter = sum(cv2.arcLength(c,True) for c in contour)
    area = float(body.sum())
    extents = [float(stats[i,4]/(stats[i,2]*stats[i,3])) for i in np.flatnonzero(keep)]
    return np.r_[values, area/max(1,body.size), area/max(1,perimeter)/unit,
                 np.quantile(extents,[.25,.5,.75]) if extents else np.zeros(3),
                 min(1.,len(extents)/max(1,body.size/unit**2))]

def measure(rgb, bbox, source_em, source_text=''):
    """source_em is an OCR/source-estimated em, never an annotation field."""
    if not np.isfinite(source_em) or source_em<=0: raise ValueError('Invalid source em')
    base = size_features(rgb,bbox,source_em,version=5)
    # Remove absolute size and bbox/position cues; keep physical relative metrics.
    base[:6] = 0
    x,y,w,h = bbox
    t = rgb[max(0,int(y)):min(len(rgb),int(np.ceil(y+h))),
            max(0,int(x)):min(rgb.shape[1],int(np.ceil(x+w)))]
    if not t.size: raise ValueError('Empty target')
    scale = min(1.,640/max(t.shape[:2]))
    if scale<1: t=cv2.resize(t,None,fx=scale,fy=scale,interpolation=cv2.INTER_AREA)
    unit=max(1.,source_em*scale)
    gray=cv2.cvtColor(t,cv2.COLOR_RGB2GRAY)
    _,dark=cv2.threshold(gray,0,1,cv2.THRESH_BINARY_INV+cv2.THRESH_OTSU)
    lo=t.min(2);hi=t.max(2);chroma=hi.astype(float)-lo
    masks=[dark,1-dark,hi<70,(lo>200)&(chroma<45),chroma>75]
    from morphology_features import grouped_body_features
    from glyph_body_features import glyph_body_features
    from font_metric_features import font_metric_features, default_font_paths
    # Reference glyph dimensions are pooled, not token identity features. They
    # separate a naturally dense kanji from an unusually heavy simple kana.
    reference=font_metric_features(source_text,base[:156],default_font_paths())
    return np.r_[base,*(stroke_summary(m,unit) for m in masks),
                 grouped_body_features(rgb,bbox,source_em),
                 glyph_body_features(rgb,bbox,source_em,np.ones(rgb.shape[:2],bool)),reference]

def page_context(matrix):
    """Unlabelled same-page summaries are available on unseen pages too."""
    x=np.asarray(matrix,float)
    if x.ndim!=2 or not len(x) or not np.isfinite(x).all():raise ValueError('Invalid source features')
    center=np.median(x,axis=0)
    spread=np.maximum(np.quantile(x,.75,axis=0)-np.quantile(x,.25,axis=0),.02)
    return np.c_[x,np.clip((x-center)/spread,-8,8),np.tile(center,(len(x),1))]

def render_policy(label, confidence=None, aligned_translation_runs=None):
    """Mixed source weight cannot be mapped onto a translation without alignment.

    Geometry/region IDs are deliberately not accepted. Any mixed region uses
    regular rendering unless actual aligned translation run ranges are supplied.
    """
    if label not in {'regular','bold','mixed'}:raise ValueError('Invalid weight label')
    if label=='mixed':
        return {'sourceWeight':'mixed','renderBold':False,'renderWeight':'regular',
                'requiresTranslationSpanAlignment':True,'translatedStyleRuns':aligned_translation_runs or []}
    return {'sourceWeight':label,'renderBold':label=='bold','renderWeight':label,
            'requiresTranslationSpanAlignment':False,'translatedStyleRuns':[]}
