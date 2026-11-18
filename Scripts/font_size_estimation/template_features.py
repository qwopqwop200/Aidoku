"""OCR-bound physical glyph matching inside the target crop only."""
from functools import lru_cache
import math,unicodedata
import cv2
import numpy as np
from font_metric_features import font_resource,glyph_measurement,EM


FEATURE_COUNT=66
SCALES=(.4,.55,.7,.85,1.,1.15,1.3,1.5)


@lru_cache(maxsize=4096)
def glyph_bitmap(path,char):
    font,supported=font_resource(path)
    if ord(char) not in supported:return None
    mask=font.getmask(char,mode='L')
    if not min(mask.size):return None
    image=np.asarray(mask,np.uint8).reshape(mask.size[1],mask.size[0])
    yy,xx=np.nonzero(image>=64)
    if not len(xx):return None
    return image[yy.min():yy.max()+1,xx.min():xx.max()+1].copy()


def transformed_glyph(bitmap,unit,factor,aspect=1.,angle=0.):
    if not all(math.isfinite(v) for v in (unit,factor,aspect,angle)) or min(unit,factor,aspect)<=0:raise ValueError('Invalid glyph transform')
    size=(max(2,round(bitmap.shape[1]*unit*factor*aspect/EM)),max(2,round(bitmap.shape[0]*unit*factor/EM)))
    ink=cv2.resize(bitmap,size,interpolation=cv2.INTER_AREA).astype(np.float32)/255
    if angle:
        h,w=ink.shape;matrix=cv2.getRotationMatrix2D(((w-1)/2,(h-1)/2),angle,1.)
        cos,sin=abs(matrix[0,0]),abs(matrix[0,1]);nw=math.ceil(w*cos+h*sin);nh=math.ceil(h*cos+w*sin)
        matrix[0,2]+=(nw-w)/2;matrix[1,2]+=(nh-h)/2
        ink=cv2.warpAffine(ink,matrix,(nw,nh),flags=cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT,borderValue=0)
    return ink


def best_template_match(mask,bitmap,unit,factor,aspect=1.,angle=0.):
    ink=transformed_glyph(bitmap,unit,factor,aspect,angle);size=(ink.shape[1],ink.shape[0])
    pad=max(1,round(unit*factor*.04));pattern=np.pad(ink,pad)
    if np.std(pattern)<1e-5:return None
    padded=np.pad(mask,pad)
    if pattern.shape[0]>padded.shape[0] or pattern.shape[1]>padded.shape[1]:return None
    correlation=cv2.matchTemplate(padded,pattern,cv2.TM_CCOEFF_NORMED)
    if not np.isfinite(correlation).any():return None
    correlation=np.where(np.isfinite(correlation),correlation,-1.)
    _,score,_,location=cv2.minMaxLoc(correlation)
    return float(score),location,size


def refine_template_match(mask,bitmap,unit,coarse,affine=False,scale_bounds=None):
    minimum,maximum=(SCALES[0],SCALES[-1]) if scale_bounds is None else scale_bounds
    score,factor,location,size=coarse
    # Follow the same source glyph. Re-searching the complete target at every
    # fine scale can jump to an unrelated radical elsewhere in the bbox.
    radius=max(2,round(unit*.2));x,y=location;w,h=size
    left=max(0,x-radius);top=max(0,y-radius)
    local=mask[top:min(mask.shape[0],y+h+radius),left:min(mask.shape[1],x+w+radius)]
    lower=max(minimum,factor-.1);upper=min(maximum,factor+.1)
    candidates=sorted(set([factor]+np.linspace(lower,upper,9).tolist()))
    matches=[]
    for value in candidates:
        result=best_template_match(local,bitmap,unit,value)
        if result is not None and result[0]>=0:matches.append((result[0],value))
    if not matches:return score,factor,0.
    best=max(x[0] for x in matches)
    # Integer raster dimensions create exact plateaus; their geometric centre
    # avoids an upward size bias from choosing the largest tied candidate.
    tied=[f for s,f in matches if abs(s-best)<=1e-7]
    refined=float(np.exp(np.mean(np.log(tied))))
    lower_scores=[s for s,f in matches if abs(s-best)>1e-7]
    margin=best-max(lower_scores) if lower_scores else 0.
    if not affine:return best,refined,margin
    transformed=[]
    # Scale and width are coupled: fitting width at a wrong fixed scale traps
    # coordinate descent. Search both together before estimating rotation.
    affine_scales=sorted(set([refined]+np.linspace(max(minimum,refined-.15),min(maximum,refined+.15),9).tolist()))
    for aspect in (.8,.9,1.,1.1,1.2):
        for value in affine_scales:
            result=best_template_match(local,bitmap,unit,value,aspect,0.)
            if result is not None and result[0]>=0:transformed.append((result[0],value,aspect))
    if not transformed:return best,refined,margin
    # A deterministic identity preference resolves equal-score transforms.
    transformed.sort(key=lambda p:(-p[0],abs(math.log(p[2])),p[1],p[2]))
    transform_score,refined,aspect=transformed[0];rotated=[]
    for angle in (-10.,-5.,0.,5.,10.):
        result=best_template_match(local,bitmap,unit,refined,aspect,angle)
        if result is not None and result[0]>=0:rotated.append((result[0],angle))
    rotated.sort(key=lambda p:(-p[0],abs(p[1]),p[1]));transform_score,angle=rotated[0];fine=[]
    for value in sorted(set([refined]+np.linspace(max(minimum,refined-.04),min(maximum,refined+.04),9).tolist())):
        result=best_template_match(local,bitmap,unit,value,aspect,angle)
        if result is not None and result[0]>=0:fine.append((result[0],value))
    if not fine:return transform_score,refined,0.
    winner=max(s for s,_ in fine);tied=[f for s,f in fine if abs(s-winner)<=1e-7]
    final=float(np.exp(np.mean(np.log(tied))));lower_scores=[s for s,_ in fine if abs(s-winner)>1e-7]
    return winner,final,winner-max(lower_scores) if lower_scores else 0.


def template_features(rgb,bbox,prior,text,font_paths,refine=False,affine=False,ownership=None,
                      max_target_side=480,glyph_limit=2,coarse_scales=None):
    if affine and not refine:raise ValueError('Affine matching requires refinement')
    if not isinstance(max_target_side,(int,float)) or not math.isfinite(max_target_side) or max_target_side<1:
        raise ValueError('Invalid template target resolution')
    if type(glyph_limit) is not int or not 1<=glyph_limit<=8:
        raise ValueError('Invalid template glyph limit')
    scales=SCALES if coarse_scales is None else tuple(coarse_scales)
    if (not 2<=len(scales)<=32 or any(not math.isfinite(v) or v<=0 for v in scales)
            or any(a>=b for a,b in zip(scales,scales[1:]))):
        raise ValueError('Invalid template scale range')
    if not math.isfinite(prior) or prior<=0:raise ValueError('Invalid prior em')
    if len(font_paths)!=4:raise ValueError('Expected four fonts')
    x,y,w,h=bbox
    if min(w,h)<=0:raise ValueError('Empty bbox')
    target=rgb[max(0,int(y)):min(rgb.shape[0],math.ceil(y+h)),max(0,int(x)):min(rgb.shape[1],math.ceil(x+w))]
    if not target.size:raise ValueError('Target outside crop')
    own=None
    if ownership is not None:
        if np.asarray(ownership).shape!=rgb.shape[:2]:raise ValueError('Ownership/RGB geometry differs')
        own=np.asarray(ownership,bool)[max(0,int(y)):min(rgb.shape[0],math.ceil(y+h)),max(0,int(x)):min(rgb.shape[1],math.ceil(x+w))]
        if not own.any():return np.zeros(FEATURE_COUNT)
        # Keep area downsampling from mixing unrelated background into owned
        # edge pixels. This is a temporary numerical array, never a saved edit.
        target=target.copy();target[~own]=127
    scale=min(1.,max_target_side/max(target.shape[:2]))
    if scale<1:
        target=cv2.resize(target,None,fx=scale,fy=scale,interpolation=cv2.INTER_AREA)
        if own is not None:own=cv2.resize(own.astype(np.uint8),(target.shape[1],target.shape[0]),interpolation=cv2.INTER_NEAREST)>0
    if own is not None and not own.any():return np.zeros(FEATURE_COUNT)
    unit=prior*scale
    chars=[]
    for char in set(unicodedata.normalize('NFC',text or '')):
        if char.isspace() or unicodedata.category(char)[0] in 'MCPZS':continue
        dims=glyph_measurement(font_paths[0],char)
        if dims is not None and dims[4]>.05:chars.append((dims[4],char))
    # Stable source-only choice of visible main-body glyphs; no token
    # identity, string, absolute placement or winning font ID enters the model.
    chars=[c for _,c in sorted(chars,key=lambda p:(-p[0],p[1]))[:glyph_limit]]
    gray=cv2.cvtColor(target,cv2.COLOR_RGB2GRAY)
    if own is None:_,dark=cv2.threshold(gray,0,1,cv2.THRESH_BINARY_INV+cv2.THRESH_OTSU)
    else:
        cutoff,_=cv2.threshold(gray[own].reshape(-1,1),0,1,cv2.THRESH_BINARY_INV+cv2.THRESH_OTSU)
        dark=((gray<=cutoff)&own).astype(np.uint8)
    lo=target.min(axis=2);hi=target.max(axis=2);pale=((lo>180)&(hi.astype(float)-lo<45)).astype(np.uint8)
    if own is not None:pale*=own
    masks=[dark.astype(np.float32),pale.astype(np.float32)];per_font=[]
    for path in font_paths:
        observations=[]
        for char in chars:
            bitmap=glyph_bitmap(path,char)
            if bitmap is None:continue
            matches=[]
            for factor in scales:
                for mask_index,mask in enumerate(masks):
                    result=best_template_match(mask,bitmap,unit,factor)
                    if result is not None and result[0]>=0:matches.append((result[0],factor,mask_index,result[1],result[2]))
            if matches:
                matches.sort(reverse=True);score,factor,mask_index,location,size=matches[0]
                # Legacy confidence margin compares different scales, not two
                # polarities of the same scale.
                other=[s for s,f,*_ in matches if f!=factor];margin=score-max(other) if other else 0.
                if refine:score,factor,margin=refine_template_match(masks[mask_index],bitmap,unit,(score,factor,location,size),affine=affine,scale_bounds=(scales[0],scales[-1]))
                observations.append((factor,score,margin,float(factor in (scales[0],scales[-1]))))
        per_font.append(observations)
    values=[]
    for observations in per_font:
        if not observations:values.extend([0.]*16);continue
        array=np.asarray(observations)
        values.extend(np.quantile(array,[0,.5,1],axis=0).T.ravel().tolist())
        values.extend(array[np.argmax(array[:,1])].tolist())
    values.extend([float(bool(chars)),len(chars)/glyph_limit])
    return np.asarray(values,float)
