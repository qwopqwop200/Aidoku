"""Source-evidence correction; no source identifiers or GT arguments."""
import numpy as np

POLICY={'minimumWhiteFill':230.,'maximumBlackBackground':45.,'serifFit':.5,
        'serifHeavyMargin':.08,'blackSansMinimumMargin':-.05,
        'blackSansFit':.55,'blackSansHeavyMargin':.12}

def white_body_bold(style,paired_features,policy=POLICY):
    fill=np.asarray(style['fill']['rgb'],float);background=np.asarray(style['background']['rgb'],float)
    if fill.shape!=(3,) or background.shape!=(3,) or not np.isfinite(np.r_[fill,background]).all():raise ValueError('Invalid source palette')
    if (fill.min()<=policy['minimumWhiteFill'] or background.max()>=policy['maximumBlackBackground']
            or style.get('outline',{}).get('present',False)):return False
    channels=np.asarray(paired_features,float)
    if channels.shape!=(48,) or not np.isfinite(channels).all():raise ValueError('Invalid paired glyph evidence')
    channels=channels.reshape(3,2,8)
    # Matching a high-contrast serif alone can mistake slender handwriting for
    # bold. The paired black-sans fit must independently reject that mismatch.
    sans=channels[1,0] if channels[1,0,5]>0 else channels[1,1]
    serif=channels[2,0] if channels[2,0,5]>0 else channels[2,1]
    serif_body=(serif[0]>=policy['serifFit'] and serif[3]>=policy['serifHeavyMargin']
                and sans[3]>=policy['blackSansMinimumMargin'])
    sans_body=sans[0]>=policy['blackSansFit'] and sans[3]>=policy['blackSansHeavyMargin']
    return bool(serif_body or sans_body)
