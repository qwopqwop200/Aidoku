"""Image reconstruction guided by existing glyph probabilities and RF evidence."""
import cv2
import numpy as np

from ink_weight_geometry import clean_fill_style, observe
from palette_word_pairs import observe_palette


def reconstruct(rgb, ownership, style, evidence, cutoff=.5, em=None, maximum_component_em=1.7):
    p, q, rf, valid = (evidence[k] for k in ('primary', 'boundary', 'rf', 'valid'))
    if p.shape != rgb.shape[:2] or q.shape != p.shape or rf.shape != (*p.shape, 27):
        raise ValueError('Glyph/RF evidence geometry differs')
    if not np.isfinite(p).all() or not np.isfinite(q).all() or not np.isfinite(rf).all():
        raise ValueError('Nonfinite existing glyph/RF evidence')
    source = clean_fill_style(style)
    if source is None:
        color, known = np.zeros(p.shape, np.float32), np.zeros(p.shape, bool)
    else:
        color, known = observe_palette(rgb, ownership, source)
    # Native glyph and owner-query support corroborate weak primary pixels.
    text = np.maximum(rf[:, :, 0], rf[:, :, 15]*rf[:, :, 16])
    sfx = np.maximum(rf[:, :, 3], rf[:, :, 17]*rf[:, :, 18])
    semantic = np.maximum(text, sfx)
    backed = (p >= .25) & (evidence['native'] > 0) & (semantic >= .05)
    probability = np.maximum(p, np.where(backed, q, 0))
    full = (probability >= cutoff) & valid & ownership
    depth = cv2.distanceTransform(full.astype(np.uint8), cv2.DIST_L2, cv2.DIST_MASK_PRECISE)
    outline = style.get('outline', {})
    radius = max(0., float(outline.get('widthPx') or 0)) if outline.get('present') else 0.
    interior = np.clip(depth-radius+.5, 0, 1) if radius else full.astype(np.float32)
    visible_color = color*known*ownership
    seeds = (visible_color > .5)
    count, labels, stats, _ = cv2.connectedComponentsWithStats((interior > .25).astype(np.uint8), 8)
    hits = np.bincount(labels[seeds].ravel(), minlength=count)
    allowed = (hits >= 2) & (hits/np.maximum(1, stats[:, cv2.CC_STAT_AREA]) >= .03)
    if em is not None and maximum_component_em is not None:
        allowed &= np.maximum(stats[:, cv2.CC_STAT_WIDTH], stats[:, cv2.CC_STAT_HEIGHT]) <= maximum_component_em*em
    allowed[0] = False
    recovered = interior*allowed[labels]
    # Existing outline/shadow colour estimates distinguish their remaining
    # pixels even when the probabilistic glyph mask includes several rings.
    excluded_paint = np.zeros(p.shape, bool)
    fill_colors = np.asarray([source['fill']['rgb'], *source['fill'].get('colors', [])], float) if source is not None else None
    for role in ('outline', 'shadow'):
        paint = style.get(role, {})
        if not paint.get('present') or paint.get('rgb') is None or fill_colors is None:
            continue
        paint_rgb = np.asarray(paint['rgb'], float)
        if np.linalg.norm(fill_colors-paint_rgb, axis=1).min() <= 35:
            continue
        excluded_paint |= np.linalg.norm(rgb.astype(float)-paint_rgb, axis=2) < 22
    recovered[excluded_paint] = 0
    backgrounds = [style['background']['rgb']]
    for bg_color, mass in zip(style['background'].get('colors', []), style['background'].get('observedContextWeights', [])):
        if mass >= .1:
            backgrounds.append(bg_color)
    background_like = np.zeros(p.shape, bool)
    for bg_color in backgrounds:
        background_like |= np.linalg.norm(rgb.astype(float)-bg_color, axis=2) < 22
    n, components = cv2.connectedComponents(background_like.astype(np.uint8), 8)
    exterior = np.zeros(n, bool)
    border = np.r_[components[0], components[-1], components[:, 0], components[:, -1]]
    exterior[np.unique(border)] = True
    exterior[0] = False
    exterior_pixels = exterior[components]
    recovered[exterior_pixels] = 0
    # Close only small segmentation-supported gaps, never dilate every stroke.
    # Preserve existing enclosed counters so they cannot become bold blobs.
    radius_close = max(1, min(2, round(.025*em))) if em is not None else 1
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2*radius_close+1,)*2)
    closed = cv2.morphologyEx(seeds.astype(np.uint8), cv2.MORPH_CLOSE, kernel).astype(bool)
    contours, hierarchy = cv2.findContours(seeds.astype(np.uint8), cv2.RETR_CCOMP, cv2.CHAIN_APPROX_SIMPLE)
    counters = np.zeros(p.shape, np.uint8)
    if hierarchy is not None:
        for i, contour in enumerate(contours):
            if hierarchy[0, i, 3] >= 0:
                cv2.drawContours(counters, [contour], -1, 1, -1)
    counters = counters.astype(bool) & ~seeds
    bridges = closed & ~seeds & ~counters & full & (q >= .65) & ~exterior_pixels & ~excluded_paint
    recovered[bridges] = 1
    recovered[counters] = 0
    # Restore whole seeded interiors, including gradient/highlight gaps; retain
    # observed colour ink if outline-radius uncertainty erodes it too far.
    alpha = np.maximum(recovered, visible_color)
    observed = valid | known
    return alpha.astype(np.float32), observed, dict(rawGlyphCutoff=cutoff, outlineRadiusPx=radius,
         glyphPixels=int(full.sum()), seedPixels=int(seeds.sum()), recoveredPixels=int((recovered > .5).sum()),
         colorInkPreservedOutsideSegmentation=int((seeds & ~full).sum()),
         acceptedReconstructionComponents=int(allowed.sum()), bridgedGapPixels=int(bridges.sum()),
         excludedOutlineShadowPixels=int(excluded_paint.sum()),
         protectedCounterPixels=int(counters.sum()), exteriorBackgroundPixels=int(exterior_pixels.sum()),
         rfTextMean=float(text[full].mean()) if full.any() else 0.,
         rfSFXMean=float(sfx[full].mean()) if full.any() else 0.,
         primaryMean=float(p[full].mean()) if full.any() else 0.,
         boundaryMean=float(q[full].mean()) if full.any() else 0.)


def measure(rgb, bbox, em, ownership, style, evidence):
    # Encode recovered foreground as a numerical black/white observation so the
    # same opposed-edge and component geometry algorithm measures actual ink.
    # This is a temporary in-memory signal, never a replacement source image.
    alpha, valid, audit = reconstruct(rgb, ownership, style, evidence, em=em)
    signal = np.repeat(np.rint(255*(1-alpha))[:, :, None].astype(np.uint8), 3, axis=2)
    neutral = dict(fill=dict(rgb=[0, 0, 0]), background=dict(rgb=[255, 255, 255]))
    result = observe(signal, bbox, em, ownership & valid, neutral)
    result.pop('learnedModelUsed', None)
    result.update(existingGlyphModelsUsed=True, RFTextAndSFXUsed=True, evidenceAudit=audit,
                  existingLearnedPredictionsUsed=True, newLearnedClassifierUsed=False,
                  newModelCreated=False, modelTrainingPerformed=False,
                  donor=evidence['donor'], rfModelWeightsSHA256=evidence['rfModelWeightsSHA256'])
    return result
