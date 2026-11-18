"""Stroke measurements of predicted source FILL, excluding outline and art."""
import math
import sys
from pathlib import Path
import cv2
import numpy as np

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'font_size_estimation'))
from optimized_features.fill_alpha import predicted_fill_alpha
from optimized_features.glyph_residuals import moments
from features import stroke_summary

FEATURE_COUNT=71
VERSION=2

def measure(rgb,bbox,source_em,ownership,source_style,*,version=VERSION):
    if version not in (1,2):raise ValueError('Unknown fill-body measurement version')
    if not math.isfinite(source_em) or source_em<=0:raise ValueError('Invalid source em')
    if ownership.shape!=rgb.shape[:2]:raise ValueError('Invalid ownership geometry')
    alpha=predicted_fill_alpha(rgb,bbox,ownership,source_style)
    # predicted_fill_alpha already admits components by their overlap with the
    # source target. Keep their complete bodies within the existing <=15% crop;
    # clipping again at an approximate bbox discards bold boundary strokes.
    if version==1:
        x,y,w,h=bbox
        target=alpha[max(0,int(y)):min(len(alpha),math.ceil(y+h)),max(0,int(x)):min(alpha.shape[1],math.ceil(x+w))]
    else:
        target=alpha
    if not target.size:raise ValueError('Empty target')
    scale=min(1.,800/max(target.shape));unit=source_em*scale
    if scale<1:target=cv2.resize(target,None,fx=scale,fy=scale,interpolation=cv2.INTER_AREA)
    stroke=np.r_[*(stroke_summary(target>cutoff,unit,allow_boundary=version==2) for cutoff in [.25,.5,.75])]
    body=moments(target,unit)
    support=float((target>.5).mean());mean_alpha=float(target.mean())
    # Source palette contrast is diagnostic, never itself a bold decision.
    fill=np.array(source_style['fill']['rgb'],float);bg=np.array(source_style['background']['rgb'],float)
    contrast=float(np.linalg.norm(fill-bg)/math.sqrt(3*255**2))
    outline=source_style.get('outline',{});outline_width=float(outline.get('widthPx',0) or 0)/source_em if outline.get('present') else 0.
    result=np.r_[stroke,body,support,mean_alpha,contrast,outline_width,float(target.sum()>1),float(ownership.mean())]
    if result.shape!=(FEATURE_COUNT,) or not np.isfinite(result).all():raise ValueError('Invalid fill body evidence')
    return result
