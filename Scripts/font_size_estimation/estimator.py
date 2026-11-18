"""Source-crop measurements and portable tabular font-size inference.

Native crop measurements, geometry and prior OCR em drive point inference.
Optional pooled original-OCR glyph metrics and verified predicted masks refine
scale communities. Word identity, page IDs and GT labels are never features.
"""
import math
import pickle
from functools import lru_cache
from pathlib import Path

import cv2
import numpy as np


VERSION = 5


def signed_log_features(matrix):
    value=np.asarray(matrix,float)
    return np.sign(value)*np.log1p(np.abs(value))


def relative_log_features(matrix):
    value=signed_log_features(matrix)
    # The first scalar is absolute log-prior px; the other measurements are
    # relative units. Exclude this absolute-scale cue in the invariant head.
    value[:,0]=0.
    return value


def features(rgb, bbox, prior, version=VERSION):
    if version not in (1,2,3,4,5):raise ValueError('Unknown feature version')
    if not math.isfinite(prior) or prior <= 0:
        raise ValueError('Prior em must be positive and finite')
    x, y, w, h = bbox
    if min(w, h) <= 0:
        raise ValueError('Empty bbox')
    # Measure target only; context may contain adjacent unrelated letters.
    target = rgb[max(0, int(y)):min(rgb.shape[0], math.ceil(y+h)),
                 max(0, int(x)):min(rgb.shape[1], math.ceil(x+w))]
    if target.size == 0:
        raise ValueError('Target outside crop')
    scale = min(1., 640 / max(target.shape[:2]))
    if scale < 1:
        target = cv2.resize(target, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(target, cv2.COLOR_RGB2GRAY)
    f = [math.log(prior), w/prior, h/prior, min(w,h)/prior, max(w,h)/prior,
         math.log(max(w/h, 1e-6))]
    _, dark = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV+cv2.THRESH_OTSU)
    local = cv2.GaussianBlur(gray, (0, 0), max(1., prior*scale*.18))
    contrast = cv2.absdiff(gray, local)
    _, edge = cv2.threshold(contrast, 0, 255, cv2.THRESH_BINARY+cv2.THRESH_OTSU)
    masks=(dark,255-dark,edge)
    for mask in masks:
        n, labels, stats, centers = cv2.connectedComponentsWithStats(mask, 8)
        s = stats[1:]; s = s[(s[:,4] >= max(3, (prior*scale)**2*.004)) &
                            (s[:,4] < mask.size*.75)]
        if len(s):
            lengths = np.maximum(s[:,2],s[:,3])/(scale*prior)
            widths = np.minimum(s[:,2],s[:,3])/(scale*prior)
            f.extend(np.quantile(lengths,[.2,.5,.8,.95]).tolist())
            f.extend(np.quantile(widths,[.2,.5,.8]).tolist())
            f.extend([len(s)/max(1,w*h/prior**2),float(mask.mean()/255)])
        else:
            f.extend([0.]*9)
        for axis in (0,1):
            signal = (mask>0).mean(axis=axis).astype(float)
            signal -= signal.mean()
            corr = np.correlate(signal,signal,'full')[len(signal)-1:]
            low=max(2,int(prior*scale*.55)); high=min(len(corr)-1,int(prior*scale*1.7))
            if high>low and corr[0]>1e-8:
                lag=low+int(np.argmax(corr[low:high+1]));f.extend([lag/(scale*prior),corr[lag]/corr[0]])
            else:f.extend([0.,0.])
    if version==1:return np.asarray(f,dtype=np.float64)
    # Additional body/outline and cell-spacing evidence. These summaries do not
    # encode a glyph bitmap, its position on a page or its transcription.
    unit=scale*prior
    for mask in masks:
        _,_,stats,centers=cv2.connectedComponentsWithStats(mask,8)
        s=stats[1:];c=centers[1:]
        valid=(s[:,4]>=max(3,unit**2*.006))&(s[:,4]<mask.size*.6)
        s=s[valid];c=c[valid]
        if len(s):
            area=s[:,4]/unit**2;extent=s[:,4]/(s[:,2]*s[:,3])
            f.extend(np.quantile(area,[.25,.5,.75]).tolist())
            f.extend(np.quantile(extent,[.25,.5,.75]).tolist())
            f.append(float(((s[:,0]==0)|(s[:,1]==0)|(s[:,0]+s[:,2]>=mask.shape[1])|(s[:,1]+s[:,3]>=mask.shape[0])).mean()))
        else:f.extend([0.]*7)
        # Nearest longitudinal center distance among components in the same
        # column/row. Full glyphs, rather than detached dots, witness cell pitch.
        for axis in (0,1):
            gaps=[]
            if len(s):
                full=(s[:,2+1-axis]>=unit*.22)&(np.maximum(s[:,2],s[:,3])<=unit*1.8)
                cc=c[full]
                for center in cc:
                    aligned=cc[np.abs(cc[:,1-axis]-center[1-axis])<=unit*.35]
                    d=aligned[:,axis]-center[axis];d=d[(d>=unit*.35)&(d<=unit*1.8)]
                    if len(d):gaps.append(float(d.min()/unit))
            f.extend(np.quantile(gaps,[.25,.5,.75]).tolist() if gaps else [0.]*3)
            f.append(min(1.,len(gaps)/max(1.,w*h/prior**2)))
        depth=cv2.distanceTransform(mask,cv2.DIST_L2,3);nonzero=depth[depth>0]
        f.extend((np.quantile(nonzero,[.5,.9])/unit).tolist() if len(nonzero) else [0.,0.])
    if version==2:return np.asarray(f,dtype=np.float64)
    if version in (4,5):
        # Separate pale glyph interiors from saturated outlines, and dark ink
        # from pastel texture. Edge-connected background is measured separately
        # instead of dominating equal-weight glyph-size quantiles.
        lo=target.min(axis=2);hi=target.max(axis=2);chroma=hi.astype(float)-lo
        cores=[hi<40,hi<100,(lo>220)&(chroma<45),(lo>180)&(chroma<45),chroma>80]
        for core in cores:
            _,_,stats,_=cv2.connectedComponentsWithStats(core.astype(np.uint8),8)
            s=stats[1:];s=s[(s[:,4]>=max(3,unit**2*.003))&(s[:,4]<core.size*.65)]
            if not len(s):f.extend([0.]*12);continue
            interior=(s[:,0]>0)&(s[:,1]>0)&(s[:,0]+s[:,2]<core.shape[1])&(s[:,1]+s[:,3]<core.shape[0]);own=s[interior]
            if not len(own):f.extend([0.]*9)
            else:
                for values in [np.maximum(own[:,2],own[:,3])/unit,np.minimum(own[:,2],own[:,3])/unit,np.sqrt(own[:,4])/unit]:f.extend(np.quantile(values,[.25,.5,.75]).tolist())
            f.extend([float(interior.mean()),float(s[:,4].sum()/core.size),float(np.median(s[:,2]/s[:,3]))])
        if version==4:return np.asarray(f,dtype=np.float64)
        # Axis-aligned bbox spans inflate slanted letters. Measure actual
        # contour rectangles and scale-independent nearest-body distances.
        for core in [cores[0],cores[2]]:
            contours,_=cv2.findContours(core.astype(np.uint8),cv2.RETR_EXTERNAL,cv2.CHAIN_APPROX_SIMPLE)
            lengths=[];centers=[];edge=0
            for contour in contours:
                x0,y0,cw,ch=cv2.boundingRect(contour);area=cv2.contourArea(contour)
                if area<max(3,unit**2*.003) or area>=core.size*.65:continue
                if x0<=0 or y0<=0 or x0+cw>=core.shape[1] or y0+ch>=core.shape[0]:edge+=1;continue
                center,sides,_=cv2.minAreaRect(contour);small,big=sorted(sides)
                if small<=1:continue
                lengths.append([big/unit,small/unit,math.sqrt(area)/unit,big/small,area/max(1,big*small)])
                if small>=unit*.06 and big>=unit*.15:centers.append(center)
            if lengths:
                f.extend(np.quantile(np.asarray(lengths),[.25,.5,.75],axis=0).T.ravel().tolist())
            else:f.extend([0.]*15)
            gaps=[];cc=np.asarray(centers)
            for center in cc:
                distances=np.linalg.norm(cc-center,axis=1);distances=distances[(distances>unit*.08)&(distances<unit*2.)]
                if len(distances):gaps.append(float(distances.min()/unit))
            f.extend(np.quantile(gaps,[.25,.5,.75]).tolist() if gaps else [0.]*3)
            f.extend([len(lengths)/max(1,w*h/prior**2),edge/max(1,edge+len(lengths))])
        return np.asarray(f,dtype=np.float64)
    # Broad local maxima retain valid glyph periods far below an erroneous OCR
    # prior. Unlike the old restricted argmax, this does not assume em is within
    # a factor of two of that prior; strength and repetition remain evidence.
    for mask in masks:
        for axis in (0,1):
            signal=(mask>0).mean(axis=axis).astype(float);signal-=signal.mean()
            corr=np.correlate(signal,signal,'full')[len(signal)-1:]
            low=max(2,int(unit*.18));high=min(len(corr)-2,int(unit*2.4))
            peaks=[]
            if corr[0]>1e-8:
                peaks=[i for i in range(low,high+1) if corr[i]>0 and corr[i]>=corr[i-1] and corr[i]>corr[i+1]]
                peaks=sorted(peaks,key=lambda i:-corr[i])[:3]
            for k in range(3):
                f.extend([peaks[k]/unit,corr[peaks[k]]/corr[0]] if k<len(peaks) else [0.,0.])
    return np.asarray(f,dtype=np.float64)


def harmonize(predictions, groups, ratio, method='median'):
    """Complete-link similar predicted scales; never use GT page cohorts."""
    if method not in ('median','mean','log_mean','trimmed_log_mean'):raise ValueError('Unknown font consensus method')
    out=np.asarray(predictions,dtype=float).copy()
    if ratio<=1:return out
    for group in set(groups):
        ids=sorted([i for i,g in enumerate(groups) if g==group],key=lambda i:out[i])
        clusters=[]
        for i in ids:
            if not clusters or out[i]/out[clusters[-1][0]]>ratio:clusters.append([i])
            else:clusters[-1].append(i)
        for cluster in clusters:
            if len(cluster)>1:
                values=out[cluster]
                if method=='median':canonical=np.median(values)
                elif method=='mean':canonical=np.mean(values)
                else:
                    if method=='trimmed_log_mean' and len(values)>=5:
                        trim=len(values)//5;values=np.sort(values)[trim:-trim]
                    canonical=np.exp(np.mean(np.log(values)))
                out[cluster]=canonical
    return out


def harmonize_with_witness(predictions,witnesses,groups,ratio,method='median',witness_ratio=None):
    """Require both proposals and their pre-consensus source witnesses to fit.

    A first median must not alone make previously separated observations form
    a transitive chain at the next consensus. Context corrections are applied
    to the raw source witnesses as well, so real new evidence may still join
    previously separated estimates.
    """
    out=np.asarray(predictions,float).copy();witnesses=np.asarray(witnesses,float)
    if out.shape!=witnesses.shape or not np.isfinite(witnesses).all() or (witnesses<=0).any():raise ValueError('Invalid font consensus witnesses')
    if not np.isfinite(out).all() or (out<=0).any():raise ValueError('Invalid font consensus proposals')
    witness_ratio=ratio if witness_ratio is None else witness_ratio
    if not math.isfinite(witness_ratio) or witness_ratio<1:raise ValueError('Invalid witness ratio')
    if ratio<=1:return out
    for group in set(groups):
        ids=sorted([i for i,g in enumerate(groups) if g==group],key=lambda i:(out[i],witnesses[i]));clusters=[]
        for i in ids:
            if not clusters:clusters.append([i]);continue
            prior=clusters[-1];observed=witnesses[prior+[i]]
            if out[i]/out[prior[0]]<=ratio and observed.max()/observed.min()<=witness_ratio:prior.append(i)
            else:clusters.append([i])
        for ids in clusters:
            if len(ids)>1:out[ids]=harmonize(out[ids],['cohort']*len(ids),ratio,method)
    return out


def prediction_groups(rows):
    """Transport identity defines the page batch, never a numeric feature."""
    return [r['sourceImageSHA256']+':'+str(r.get('page','')) for r in rows]


def context_features(matrix, predictions, priors, groups,raw_predictions=None):
    """Source-only peer-scale evidence; no GT cohort or page number is encoded."""
    predictions=np.asarray(predictions);priors=np.asarray(priors);extra=np.zeros((len(priors),15))
    for group in set(groups):
        ids=np.flatnonzero(np.asarray(groups)==group)
        for i in ids:
            peers=ids[ids!=i];ratios=np.log(predictions[peers]/predictions[i])
            extra[i,0]=math.log(predictions[i]/priors[i])
            if not len(peers):continue
            closest=ratios[np.lexsort((ratios,np.abs(ratios)))][:3]
            extra[i,1:1+len(closest)]=closest
            extra[i,4:9]=np.quantile(ratios,[0,.25,.5,.75,1])
            extra[i,9]=min(1.,len(peers)/12)
            extra[i,10]=float((np.abs(ratios)<=math.log(1.12)).mean())
            extra[i,11]=float((np.abs(ratios)<=math.log(1.3)).mean())
            extra[i,12]=float(np.std(ratios))
            extra[i,13]=float((ratios<0).mean())
            extra[i,14]=float((ratios>0).mean())
    result=np.concatenate([matrix,extra],axis=1)
    if raw_predictions is not None:
        raw=np.asarray(raw_predictions,float)
        if raw.shape!=predictions.shape or not np.isfinite(raw).all() or (raw<=0).any():raise ValueError('Invalid raw font context')
        # Physical source displacement, not floating-point tie information.
        own=np.round(np.column_stack([np.log(raw/predictions),np.log(raw/priors)]),12)
        result=np.concatenate([result,own],axis=1)
    return result


def finish_prediction(bundle,baseline,priors,groups,source_evidence,finalize,native=None,cluster_evidence=None):
    from physical_consensus import apply_source_evidence
    proposed=apply_source_evidence(bundle,baseline,priors,groups,source_evidence)
    if finalize:
        from font_clusters import apply_final_clustering
        return apply_final_clustering(bundle,baseline,proposed,groups,native,cluster_evidence)
    return proposed


def predict_matrix(bundle, matrix, priors, groups,source_evidence=None,finalize=True,cluster_evidence=None):
    if bundle.get('optimizedGraph'):
        raise ValueError('Optimized font bundle requires source signals through predict_optimized or the source runtime adapter')
    if bundle['featureVersion'] not in (1,2,3,4,VERSION):raise ValueError('Feature version mismatch')
    if bundle['featureVersion']==1:matrix=matrix[:,:45]
    if bundle['featureVersion']==2:matrix=matrix[:,:96]
    if bundle['featureVersion']==3:matrix=matrix[:,:132]
    if bundle['featureVersion']==4:matrix=matrix[:,:156]
    model=bundle['model']
    model_matrix=matrix[:,:bundle.get('modelFeatureCount',matrix.shape[1])]
    correction=np.full(len(priors),bundle['logScale']) if model is None else model.predict(model_matrix)
    if bundle.get('auxiliaryModel') is not None:
        columns=bundle.get('auxiliaryFeatureIndices',list(range(matrix.shape[1])))
        auxiliary=bundle['auxiliaryModel'].predict(matrix[:,columns]);weight=bundle['auxiliaryWeight']
        if not math.isfinite(weight) or not 0<=weight<=1:raise ValueError('Invalid auxiliary mixture weight')
        correction=(1-weight)*correction+weight*auxiliary
    bounds=bundle.get('correctionBounds',[-.85,.85])
    pred=np.asarray(priors)*np.exp(np.clip(correction,*bounds))
    raw_weight=bundle.get('contextRawWeight',0.)
    if not math.isfinite(raw_weight) or not 0<=raw_weight<=1:raise ValueError('Invalid context raw weight')
    source_witness=pred.copy() if bundle.get('contextWitness','none')!='none' or raw_weight>0 or bundle.get('contextRawFeatures') else None
    pred=harmonize(pred,groups,bundle['harmonizationRatio'])
    if bundle.get('contextEnsemble'):
        variants=[];weights=[]
        for variant in bundle['contextEnsemble']:
            context=context_features(matrix[:,:variant['featureCount']],pred,priors,groups)
            delta=variant['model'].predict(context)*variant['strength']
            value=pred*np.exp(np.clip(delta,-variant['clip'],variant['clip']))
            variants.append(harmonize(value,groups,variant['finalRatio']));weights.append(variant['weight'])
        if not all(math.isfinite(w) and w>=0 for w in weights) or not math.isclose(sum(weights),1.):raise ValueError('Invalid context mixture weights')
        pred=np.exp(np.sum(np.log(np.asarray(variants))*np.asarray(weights)[:,None],axis=0))
        return finish_prediction(bundle,harmonize(pred,groups,bundle['ensembleFinalRatio']),priors,groups,source_evidence,finalize,matrix,cluster_evidence)
    if bundle.get('contextModel') is not None:
        context=context_features(matrix[:,:bundle.get('contextBaseFeatureCount',matrix.shape[1])],pred,priors,groups,source_witness if bundle.get('contextRawFeatures') else None)
        correction=bundle['contextModel'].predict(context)*bundle['contextStrength']
        multiplier=np.exp(np.clip(correction,-bundle['contextClip'],bundle['contextClip']))
        if raw_weight==1:pred=source_witness*multiplier
        elif raw_weight>0:pred=np.exp((1-raw_weight)*np.log(pred)+raw_weight*np.log(source_witness))*multiplier
        else:pred*=multiplier
        witness_mode=bundle.get('contextWitness','none')
        if witness_mode=='none':pred=harmonize(pred,groups,bundle['contextFinalRatio'],bundle.get('contextConsensus','median'))
        elif witness_mode in ('raw','corrected-raw'):
            witness=source_witness*multiplier if witness_mode=='corrected-raw' else source_witness
            pred=harmonize_with_witness(pred,witness,groups,bundle['contextFinalRatio'],bundle.get('contextConsensus','median'),bundle.get('contextWitnessRatio'))
        else:raise ValueError('Unknown context witness mode')
    return finish_prediction(bundle,pred,priors,groups,source_evidence,finalize,matrix,cluster_evidence)


@lru_cache(maxsize=4)
def load_model(path):
    # Trusted local estimator artifacts only, never untrusted uploaded pickle files.
    from split_artifact import read_bytes
    data=read_bytes(path)
    if str(path).endswith('.gz'):
        import gzip
        data=gzip.decompress(data)
    bundle=pickle.loads(data)
    if bundle.get('optimizedGraph'):
        specification=bundle['optimizedGraph'].get('measurementSpec',{})
        for key in ('fonts','extendedFonts','nativeFonts'):
            for record in specification.get(key,[]):
                if not Path(record['path']).is_absolute():
                    record['path']=str((Path(path).resolve().parent/record['path']).resolve())
    return bundle
