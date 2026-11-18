"""Corresponding stroke radii integrated over antialiased alpha level sets."""
import cv2
import numpy as np

from registered_stroke_evidence import signed_distance

LEVELS = tuple(float(v) for v in np.linspace(.1, .9, 9))


def depth(alpha):
    alpha = np.asarray(alpha, np.float32)
    result = np.zeros(alpha.shape, np.float32)
    for level in LEVELS:
        binary = alpha >= level
        # Distance-to-pixel-centre has a one-pixel jump across a boundary.
        # Correct it to an edge distance before integrating alpha level sets.
        result += signed_distance(binary)-np.where(binary, .5, -.5)
    return result/len(LEVELS)


def profile(source, regular, heavy, known, unit):
    src, normal, bold, valid = [np.asarray(a) for a in (source, regular, heavy, known)]
    if (src.ndim != 2 or any(a.shape != src.shape for a in (normal, bold, valid))
            or not np.isfinite(unit) or unit <= 0 or not all(np.isfinite(a).all() for a in (src, normal, bold, valid))):
        raise ValueError('Invalid soft stroke geometry')
    nd, bd, sd = depth(normal), depth(bold), depth(src)
    ridge = (nd > 0) & (nd >= cv2.dilate(nd, np.ones((3, 3), np.uint8))-.001)
    trusted = cv2.erode(valid.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    shared = ridge & trusted & (bd > 0)
    informative = shared & (bd-nd >= .5)
    count = int(informative.sum())
    result = dict(informativeCentres=count, correspondingCentres=int(shared.sum()),
                  alphaLevels=list(LEVELS), newModelCreated=False, modelTrainingPerformed=False)
    if count < 8:
        return dict(result, usable=False)
    fraction = (sd[informative]-nd[informative])/(bd[informative]-nd[informative])
    return dict(result, usable=True, medianWeightFraction=float(np.median(fraction)),
        lowerWeightFraction=float(np.quantile(fraction, .25)), upperWeightFraction=float(np.quantile(fraction, .75)),
        correspondingSourceSupport=float((src[informative] > .5).mean()),
        medianNormalRadiusEm=float(np.median(nd[informative])/unit),
        medianSourceRadiusEm=float(np.median(sd[informative])/unit))
