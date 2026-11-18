"""Pure exact-local final-background source features, with no inference I/O.

Callers authenticate aligned native source arrays, restore any previous final
background correction, and enforce the existing <=15%-per-side crop contract.
Ownership/balloon/frame values remain soft evidence, never geometry clips.
"""
import cv2
import numpy as np

MODEL_VERSION = 'local-exterior-rf27-seg-ocr-primary-ranker-v2'
FEATURE_VERSION = 'exact-local-background-rf27-seg2-ocr8-interactions6-v1'
BASE_FEATURE_COUNT = 15
EXTRA_FEATURE_COUNT = 87
FEATURE_COUNT = 102
RF_NAMES = tuple(f'rfClass{c}{s}' for c in range(5)
                 for s in ('MaxMaskProbability', 'MeanMaskProbability', 'BoxConfidence')) + tuple(
    f'rfOwnerClass{c}{s}' for c in range(5) for s in ('MaskProbability', 'Affinity')) + (
    'rfSemanticMargin', 'rfMaskUncertainty')
OCR_NAMES = ('ocrBoxSupport', 'ocrDetAvailable', 'ocrDetectorConfidence',
             'ocrRecAvailable', 'ocrRecognitionConfidence', 'ocrTokensAvailable',
             'ocrMinimumTokenConfidence', 'ocrMeanTokenConfidence')
SIGNAL_NAMES = RF_NAMES + ('segPrimary', 'segBoundary') + OCR_NAMES + (
    'balloonNonText', 'frameNonText', 'ownerBalloonNonText',
    'ownerFrameNonText', 'textSeg', 'sfxSeg')
BASE_FEATURE_NAMES = (
    'candidateLabLDiv100', 'candidateLabADiv100', 'candidateLabBDiv100',
    'observedContextWeight', 'visibleColourFraction', 'borderColourFraction',
    'localNearestMass', 'localColourFraction', 'localRelativeColourFraction',
    'backgroundRoleColourDistanceDiv100', 'backgroundRoleObservedMass',
    'fillColourDistanceDiv100', 'outlineColourDistanceDiv100',
    'localMatchedFraction', 'localLog1pPixelCountDiv10')
EXTRA_FEATURE_NAMES = tuple('localConditionalMean.' + n for n in SIGNAL_NAMES) + tuple(
    'localJointMass.' + n for n in SIGNAL_NAMES) + ('localSupportObserved',)
FEATURE_NAMES = BASE_FEATURE_NAMES + EXTRA_FEATURE_NAMES
SOURCE_ARRAY_NAMES = ('rf', 'segPrimary', 'segBoundary', 'ocr')


def _lab(colours):
    values = np.asarray(colours, np.float32).reshape(1, -1, 3) / 255
    return cv2.cvtColor(values, cv2.COLOR_RGB2LAB).reshape(-1, 3)


def extra_features(rgb, own, context, colours, font_pixels, source_arrays):
    """Return native candidate-close conditional/joint means, float32 [N,87].

    Candidate order MUST be the original background palette followed by the
    restored pre-correction incumbent (including duplicates). Colour support is
    squared native Lab distance <=100. Signals/interactions are computed in the
    input floating dtype BEFORE float64 accumulation, preserving frozen rounding.
    The caller supplies float32 RF/seg/OCR arrays from the authenticated loader.
    No palette invention, pixel sampling, bbox clipping, or area cap is applied.
    RF slot 4 is retained without assigning it text/SFX/balloon/frame semantics.
    """
    rgb = np.asarray(rgb)
    own = np.asarray(own, dtype=bool)
    context = own if context is None else np.asarray(context, dtype=bool)
    if (rgb.dtype != np.uint8 or own.ndim != 2 or rgb.shape != own.shape + (3,)
            or context.shape != own.shape or np.any(own & ~context)):
        raise ValueError('Expected aligned native uint8 RGB and own/union masks')
    if not np.isfinite(font_pixels) or font_pixels <= 0:
        raise ValueError('Invalid source font scale')
    colours_array = np.asarray(colours)
    if (colours_array.ndim != 2 or colours_array.shape[1] != 3 or len(colours_array) == 0
            or not np.isfinite(colours_array).all() or np.any(colours_array < 0)
            or np.any(colours_array > 255)):
        raise ValueError('Invalid candidate RGB palette')
    shapes = dict(rf=own.shape + (27,), segPrimary=own.shape,
                  segBoundary=own.shape, ocr=own.shape + (8,))
    for name in SOURCE_ARRAY_NAMES:
        if name not in source_arrays:
            raise ValueError('Missing source array: ' + name)
        a = np.asarray(source_arrays[name])
        if (a.shape != shapes[name] or a.dtype != np.float32
                or not np.isfinite(a).all() or np.any(a < 0) or np.any(a > 1.001)):
            raise ValueError('Expected aligned native float32 source probabilities: ' + name)
    distance = cv2.distanceTransform((~own).astype(np.uint8), cv2.DIST_L2, 3)
    eligible = (distance > 0) & (distance <= float(np.clip(font_pixels * .12, 2, 12))) & ~context
    rf = source_arrays['rf'][eligible]
    primary = source_arrays['segPrimary'][eligible]
    boundary = source_arrays['segBoundary'][eligible]
    interactions = np.column_stack([
        rf[:, 6] * (1 - primary), rf[:, 9] * (1 - primary),
        rf[:, 19] * (1 - primary), rf[:, 21] * (1 - primary),
        rf[:, 0] * primary, rf[:, 3] * primary])
    signals = np.column_stack([rf, primary, boundary,
                               source_arrays['ocr'][eligible], interactions]).astype(np.float64)
    pixels = cv2.cvtColor(rgb.astype(np.float32) / 255, cv2.COLOR_RGB2LAB)[eligible]
    means, joint, observed = [], [], []
    for colour in _lab(colours):
        close = ((pixels - colour) ** 2).sum(1) <= 100
        count = int(close.sum())
        mean = signals[close].mean(0) if count else np.zeros(len(SIGNAL_NAMES))
        means.append(mean)
        joint.append(mean * (count / max(1, len(pixels))))
        observed.append(float(count > 0))
    # The study rounded conditional and joint matrices separately to float32.
    result = np.column_stack([np.asarray(means, np.float32), np.asarray(joint, np.float32),
                              np.asarray(observed, dtype=float)[:, None]]).astype(np.float32)
    if result.shape != (len(colours), EXTRA_FEATURE_COUNT) or not np.isfinite(result).all():
        raise ValueError('Invalid local background fusion features')
    return result


def feature_matrix(rgb, own, context, packet, prediction, font_pixels,
                   source_arrays, *, base_features=None):
    """Return (palette + restored incumbent, float32 [N,102]).

    prediction must already be restored by the final posthead caller. Optionally
    pass its existing N x 15 base_features to avoid recomputing the frozen base.
    Otherwise this convenience wrapper uses the existing pure 15-feature API.
    """
    colours = list(prediction['background']['colors']) + [prediction['background']['rgb']]
    if base_features is None:
        from final_background_refinement import source_summaries, feature_matrix as base_matrix
        local, exterior = source_summaries(rgb, own, context, packet, prediction, font_pixels)
        base_colours, base_features = base_matrix(prediction, local, exterior)
        if base_colours != colours:
            raise ValueError('Base background candidate order differs')
    base = np.asarray(base_features, np.float32)
    if base.shape != (len(colours), BASE_FEATURE_COUNT) or not np.isfinite(base).all():
        raise ValueError('Expected frozen N x 15 background base features')
    extra = extra_features(rgb, own, context, colours, font_pixels, source_arrays)
    return colours, np.column_stack([base, extra]).astype(np.float32)
