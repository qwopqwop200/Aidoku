"""Measure source pen radius at corresponding reference stroke centres.

Global width quantiles can compare unrelated strokes. This routine instead
tests the same registered points and counts unsupported/misaligned centres.
It consumes predicted source ink only; no training or annotation masks.
"""
import cv2
import numpy as np


def signed_distance(binary):
    binary = np.asarray(binary, np.uint8)
    inside = cv2.distanceTransform(np.pad(binary, 1), cv2.DIST_L2, cv2.DIST_MASK_PRECISE)[1:-1, 1:-1]
    outside = cv2.distanceTransform(np.pad(1-binary, 1, constant_values=1),
                                    cv2.DIST_L2, cv2.DIST_MASK_PRECISE)[1:-1, 1:-1]
    return inside - outside


def profile(source, regular, heavy, known, unit):
    arrays = [np.asarray(a) for a in (source, regular, heavy, known)]
    if any(a.shape != arrays[0].shape for a in arrays) or unit <= 0:
        raise ValueError('Registered stroke geometry differs')
    src, normal, bold, valid = arrays
    if not all(np.isfinite(a).all() for a in arrays):
        raise ValueError('Nonfinite registered stroke evidence')
    normal_depth = signed_distance(normal > .5)
    bold_depth = signed_distance(bold > .5)
    source_depth = signed_distance(src > .5)
    ridge = (normal_depth > 0) & (normal_depth >= cv2.dilate(normal_depth, np.ones((3, 3), np.uint8))-.001)
    trusted = cv2.erode(valid.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    shared = ridge & trusted & (bold_depth > 0)
    informative = shared & (bold_depth-normal_depth >= .75)
    count = int(informative.sum())
    result = dict(correspondingCentres=int(shared.sum()), informativeCentres=count,
                  newModelCreated=False, modelTrainingPerformed=False)
    if count < 8:
        return dict(result, usable=False)
    delta = (source_depth[informative]-normal_depth[informative]) / (bold_depth[informative]-normal_depth[informative])
    support = source_depth[informative] > 0
    result.update(usable=True, medianWeightFraction=float(np.median(delta)),
                  lowerWeightFraction=float(np.quantile(delta, .25)),
                  upperWeightFraction=float(np.quantile(delta, .75)),
                  correspondingSourceSupport=float(support.mean()),
                  medianNormalRadiusEm=float(np.median(normal_depth[informative])/unit),
                  medianSourceRadiusEm=float(np.median(source_depth[informative])/unit))
    return result
