"""Candidate page inference from source measurements, without label/file lookup.

Measurement producers own source-pixel/mask/style bindings. This array adapter
does not certify model quality or activate a model in the operational pipeline.
"""
import numpy as np
from features import page_context,render_policy
from physical_correction import white_body_bold
from weight_bands import confirmation as confirm_bands

def predict_page(bundle,raw_source_features,source_styles,paired_glyph_features,source_mixed=None):
    raw=np.asarray(raw_source_features,float);paired=np.asarray(paired_glyph_features,float)
    if raw.ndim!=2 or raw.shape[1]!=bundle['rawFeatureCount'] or not np.isfinite(raw).all():raise ValueError('Invalid source feature matrix')
    if paired.shape!=(len(raw),48) or not np.isfinite(paired).all() or len(source_styles)!=len(raw):raise ValueError('Invalid source correction batch')
    mixed=np.zeros(len(raw),bool) if source_mixed is None else np.asarray(source_mixed,bool)
    if mixed.shape!=(len(raw),):raise ValueError('Invalid mixed-source batch')
    if not len(raw):return []
    x=page_context(raw)
    if x.shape[1]!=bundle['featureCount']:raise ValueError('Feature contract mismatch')
    scores=bundle['model'].predict_proba(x)[:,1];out=[]
    for i,(style,signal,score) in enumerate(zip(source_styles,paired,scores)):
        correction=white_body_bold(style,signal,bundle['physicalCorrection'])
        label='mixed' if mixed[i] else 'bold' if score>=bundle['threshold'] or correction else 'regular'
        out.append(dict(render_policy(label),boldScore=float(score),physicalCorrection=bool(correction),GTAtInference=False))
    return out


def predict_complementary_page(bundle,raw_source_features,legacy_fill_features,
                               source_styles,paired_glyph_features,source_mixed=None):
    """Conservative union of distinct source/polarity heads; mixed stays regular.

    The polarity head uses legacy fill-v1, not complete fill-v2. They have equal
    widths but different distributions; the caller must measure the right one.
    """
    raw=np.asarray(raw_source_features,float)
    fill=np.asarray(legacy_fill_features,float)
    if raw.ndim!=2 or raw.shape[1]!=866 or fill.shape!=(len(raw),71) or not np.isfinite(fill).all():
        raise ValueError('Complementary source/fill-v1 contract differs')
    result=predict_page(bundle['primary'],raw,source_styles,paired_glyph_features,source_mixed)
    if not len(raw):return result
    polarity=bundle['polarity']
    alternate=page_context(np.c_[raw[:,:597],fill,raw[:,604:]])
    if alternate.shape[1]!=polarity['featureCount'] or bundle.get('fillVersion')!=1:
        raise ValueError('Polarity head feature version differs')
    scores=polarity['model'].predict_proba(alternate)[:,1]
    for row,score in zip(result,scores):
        rescue=row['sourceWeight']=='regular' and score>=polarity['threshold']
        if rescue:row.update(render_policy('bold'))
        row.update(polarityRescueScore=float(score),polarityRescueApplied=bool(rescue))
    return result


def predict_band_page(bundle,raw_source_features,legacy_fill_features,source_styles,
                      paired_glyph_features,band_features,source_mixed=None):
    """Source measurements only: complementary heads + differential stem proof."""
    raw=np.asarray(raw_source_features,float);bands=np.asarray(band_features,float)
    if raw.ndim!=2 or raw.shape[1]!=866 or bands.shape!=(len(raw),bundle['bandFeatureCount']) or not np.isfinite(bands).all():
        raise ValueError('Source/differential-band contract differs')
    result=predict_complementary_page(bundle['primary'],raw,legacy_fill_features,
                                      source_styles,paired_glyph_features,source_mixed)
    if not len(raw):return result
    def probability(head,values):
        x=page_context(values)
        if x.shape[1]!=head['featureCount']:raise ValueError('Source head layout differs')
        return head['model'].predict_proba(x)[:,1]
    body=probability(bundle['body'],raw[:,:597])
    paired=np.asarray(paired_glyph_features,float)
    physical=probability(bundle['physical'],np.c_[raw[:,:604],paired,raw[:,604:]])
    stem=bundle['stem']
    stem_raw=bands if stem['rawFeatureCount']==bands.shape[1] else np.c_[raw,bands]
    if stem_raw.shape[1]!=stem['rawFeatureCount']:raise ValueError('Stem head layout differs')
    stem_score=probability(stem,stem_raw)
    confirmed=confirm_bands(bands,bundle['bandPolicy'])
    for i,row in enumerate(result):
        agreed=body[i]>=bundle['body']['threshold'] and physical[i]>=bundle['physical']['threshold']
        learned=stem_score[i]>=stem['threshold']
        added=row['sourceWeight']=='regular' and (learned or (agreed and confirmed[i]))
        if added:row.update(render_policy('bold'))
        row.update(stemRescueScore=float(stem_score[i]),stemRescueApplied=bool(added and learned),
                   physicalHeadAgreement=bool(agreed),addedStemConfirmed=bool(confirmed[i]),
                   confirmedStemRescueApplied=bool(added and agreed and confirmed[i]))
    return result
