"""Geometry-preserving line observations for mixed-weight source text."""
import math
import cv2
import numpy as np
from pixel_rules import observe
from features import render_policy

def source_palette_qualifies(style):
    """Admit a clean source contrast regime; unknown source style is unresolved."""
    if not isinstance(style,dict) or style.get('outline',{}).get('present') is not False:return False
    fill=np.asarray(style.get('fill',{}).get('rgb'),float);background=np.asarray(style.get('background',{}).get('rgb'),float)
    if fill.shape!=(3,) or background.shape!=(3,) or not np.isfinite(np.r_[fill,background]).all():return False
    if np.any(np.r_[fill,background]<0) or np.any(np.r_[fill,background]>255):return False
    return bool(fill.min()>230 and background.max()<45)

def qualified_analyze(rgb,bbox,source_em,style):
    if not source_palette_qualifies(style):
        return {'sourceWeight':'unresolved','styleRuns':[],'sourcePaletteQualified':False}
    result=analyze(rgb,bbox,source_em)
    result['sourcePaletteQualified']=True
    return result


def source_lines(rgb,bbox,source_em):
    x,y,w,h=bbox;left=max(0,int(x));top=max(0,int(y));right=min(rgb.shape[1],math.ceil(x+w));bottom=min(len(rgb),math.ceil(y+h))
    target=rgb[top:bottom,left:right]
    if not target.size:raise ValueError('Empty target')
    if max(w,h)/min(w,h)<1.3:return [{'boxInCrop':list(bbox),'orientation':'unknown'}]
    vertical=h>=w
    gray=cv2.cvtColor(target,cv2.COLOR_RGB2GRAY);_,ink=cv2.threshold(gray,0,1,cv2.THRESH_BINARY_INV+cv2.THRESH_OTSU)
    if ink.mean()>.5:ink=1-ink
    profile=ink.sum(axis=0 if vertical else 1)
    active=np.flatnonzero(profile>max(1,profile.max()*.06));groups=[]
    for value in active:
        if not groups or value-groups[-1][-1]>max(1,round(source_em*.08)):groups.append([value])
        else:groups[-1].append(value)
    lines=[]
    for group in groups:
        if group[-1]-group[0]+1<source_em*.15:continue
        lo=max(0,group[0]-1);hi=min(target.shape[1 if vertical else 0],group[-1]+2)
        frame=[left+lo,top,hi-lo,bottom-top] if vertical else [left,top+lo,right-left,hi-lo]
        lines.append({'boxInCrop':[int(n) for n in frame],'orientation':'vertical' if vertical else 'horizontal'})
    if len(lines)<2:return [{'boxInCrop':list(bbox),'orientation':'vertical' if vertical else 'horizontal'}]
    # Vertical Japanese line order is right to left, horizontal top to bottom.
    return list(reversed(lines)) if vertical else lines


def analyze(rgb,bbox,source_em,minimum_bold=.12,relative_ratio=1.5):
    lines=source_lines(rgb,bbox,source_em)
    for index,line in enumerate(lines):
        line['lineID']=f'column-{index+1}-from-right' if line['orientation']=='vertical' else f'line-{index+1}-from-top'
        line['observation']=observe(rgb,line['boxInCrop'],source_em)
    supported=[l['observation']['bodyThickness'] for l in lines if l['observation']['glyphCount']>=2]
    center=float(np.median(supported)) if supported else 0.
    for line in lines:
        o=line['observation'];line['weight']='bold' if center>0 and o['glyphCount']>=2 and o['bodyThickness']>=max(minimum_bold,center*relative_ratio) else 'regular'
    mixed=len({line['weight'] for line in lines})>1
    return {'sourceWeight':'mixed' if mixed else 'unresolved','styleRuns':lines,
            'renderPolicy':render_policy('mixed' if mixed else 'regular'),
            'method':'source projection line split plus normalized body stroke contrast; no IDs or GT',
            'productionActivated':False}
