"""Image/font-raster comparison, not a learned font-weight classifier.

The same OCR string is rendered at normal/heavy weights and matched in shared
geometry. Comparing stroke profiles cancels character complexity and cap height.
"""
import math
import unicodedata

import cv2
import numpy as np

from palette_word_pairs import prepare_palette
from masked_word_pairs import fit, locate
from word_pairs import word_masks, transform
from optimized_features.templates import rotate, pose_angle
from word_weight_summary import weight_intervals
from ink_weight_geometry import opposed_widths, clean_fill_style
from reference_grid import masks as grid_masks
from registered_stroke_evidence import profile as registered_profile


def reference_pairs(pairs):
    intervals = weight_intervals(pairs)
    families = {}
    for pair, interval in zip(pairs, intervals):
        family = families.setdefault(pair['name'], {})
        if interval[0] <= 400:
            family['regular'] = pair['regular']
            family['regularWeight'] = float(interval[0])
        if interval[1] > family.get('heavyWeight', 0):
            family['heavy'] = pair['heavy']
            family['heavyWeight'] = float(interval[1])
    return [dict(name=name, **values) for name, values in families.items()
            if 'regular' in values and 'heavy' in values]


def stroke_profile(alpha, known, unit):
    mask = ((np.asarray(alpha) > .5) & known).astype(np.uint8)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(mask, 8)
    keep = (np.maximum(stats[:, 2], stats[:, 3]) >= .2*unit) & (stats[:, 4] >= max(3, .003*unit**2))
    keep[0] = False
    widths, _ = opposed_widths(alpha, known, keep[labels], unit)
    if len(widths) < 16:
        return None
    return np.quantile(widths*unit, [.25, .5, .75, .9])


def fair_face_fits(prepared, pairs):
    """Optimize normal and heavy competitors independently, with equal budgets.

    Pairwise max fitting otherwise lets the heavy endpoint choose the regular
    endpoint's pose. Deduplicate identical faces before bounded refinement.
    """
    faces = {}
    frames = {p['name']: p for p in reference_pairs(pairs)}
    for pair, interval in zip(pairs, weight_intervals(pairs)):
        for key, weight in zip(('regular', 'heavy'), interval):
            face = pair[key]
            identity = (face['path'], face.get('SHA256'), float(weight))
            if identity not in faces:
                candidate = dict(name=pair['name'], regular=face, heavy=face, _frame=frames[pair['name']])
                faces[identity] = (fit(prepared, candidate, renderer=grid_masks), candidate, float(weight))
    candidates = list(faces.values())
    # Refine the same number from each class; comparisons never use a refined
    # bold fit against an unrefined normal fit.
    refined = []
    for normal in (True, False):
        group = [r for r in candidates if (r[2] <= 400) == normal and r[0][-1]]
        for _, candidate, weight in sorted(group, key=lambda r: -r[0][18])[:2]:
            refined.append((fit(prepared, candidate, True, renderer=grid_masks), candidate, weight))
    return refined


def measure(rgb, bbox, em, ownership, style, pairs, members, alpha, known):
    families = reference_pairs(pairs)
    by_name = {pair['name']: pair for pair in families}
    cleaned = clean_fill_style(style)
    results = []
    if cleaned is None:
        return dict(words=[], newModelCreated=False, modelTrainingPerformed=False)
    if len(members) > 6:
        members = [members[i] for i in np.linspace(0, len(members)-1, 6).astype(int)]
    for member in members:
        x, y, w, h = member['bbox']
        l, t = max(0, math.floor(x-.1*w)), max(0, math.floor(y-.1*h))
        r, b = min(rgb.shape[1], math.ceil(x+1.1*w)), min(rgb.shape[0], math.ceil(y+1.1*h))
        if min(w, h) <= 0 or x < 0 or y < 0 or x+w > rgb.shape[1]+1 or y+h > rgb.shape[0]+1:
            continue
        local = [x-l, y-t, w, h]
        angle = pose_angle(member['polygon']) if member.get('polygon') else 0.
        p = prepare_palette(rgb[t:b, l:r], local, em, member['text'], ownership[t:b, l:r], cleaned, angle)
        if p is None:
            continue
        source, valid = alpha[t:b, l:r], known[t:b, l:r]
        if abs(angle) > .1:
            source, _ = rotate(source, local, angle)
            valid, _ = rotate(valid.astype(np.uint8), local, angle, nearest=True)
        if source.shape != p['alpha'].shape:
            source = cv2.resize(source, (p['alpha'].shape[1], p['alpha'].shape[0]), interpolation=cv2.INTER_AREA)
            valid = cv2.resize(valid.astype(np.float32), (source.shape[1], source.shape[0]), interpolation=cv2.INTER_AREA) > .99
        ys, xs = np.nonzero((source > .5) & valid)
        if len(xs) < 5:
            continue
        spans = (ys.max()-ys.min()+1, xs.max()-xs.min()+1)
        p['long'], p['cross'] = spans if p['vertical'] else spans[::-1]
        # Match the reconstructed ink used by SWT, rather than a second palette
        # mask which can lose highlights despite the available glyph/RF maps.
        p['alpha'], p['observed'] = np.asarray(source, np.float32), np.asarray(valid, bool)
        candidates = fair_face_fits(p, pairs)
        if not candidates:
            continue
        pose, winner, nominal = max(candidates, key=lambda value: value[0][18])
        pair = by_name[winner['name']]
        if not pose[-1]:
            continue
        variant = p['text']
        if pose[26] < .999:
            while variant and unicodedata.category(variant[0])[0] in 'PS':
                variant = variant[1:]
            while variant and unicodedata.category(variant[-1])[0] in 'PS':
                variant = variant[:-1]
        base = grid_masks(pair, variant, p['vertical'], pose[24])
        if base is None:
            continue
        a, heavy = transform(*base, pose[22]*p['unit']/128, pose[23], pose[25]*4, p['vertical'])
        match = locate(p['alpha'], p['observed'], a, heavy)
        if match is None:
            continue
        _, _, _, mx, my = match
        src = stroke_profile(source[my:my+a.shape[0], mx:mx+a.shape[1]],
                             valid[my:my+a.shape[0], mx:mx+a.shape[1]], p['unit'])
        regular = stroke_profile(a, np.ones(a.shape, bool), p['unit'])
        bold = stroke_profile(heavy, np.ones(heavy.shape, bool), p['unit'])
        if src is None or regular is None or bold is None:
            continue
        correspondence = registered_profile(source[my:my+a.shape[0], mx:mx+a.shape[1]],
            a, heavy, valid[my:my+a.shape[0], mx:mx+a.shape[1]], p['unit'])
        gaps = bold-regular
        informative = gaps >= .75
        if informative.sum() < 2:
            continue
        coefficients = (src[informative]-regular[informative])/gaps[informative]
        fraction = float(np.median(coefficients))
        estimated = pair['regularWeight']+fraction*(pair['heavyWeight']-pair['regularWeight'])
        normal_fits = [float(value[18]) for value, candidate, weight in candidates if weight <= 400]
        results.append(dict(templateFit=float(pose[18]), estimatedVisualWeight=estimated,
             matchedReferenceWeight=nominal,
             bestRegularTemplateFit=max(normal_fits, default=0.),
             normalTemplateMargin=float(pose[18])-max(normal_fits, default=0.),
             weightFraction=fraction, fractionSpread=float(np.ptp(coefficients)),
             registeredStrokeProfile=correspondence,
             sourceWidthsPx=src.tolist(), regularWidthsPx=regular.tolist(), heavyWidthsPx=bold.tolist(),
             visibleSourceFraction=float(valid.mean()), referenceFamily=pair['name']))
    return dict(words=results, existingOCRUsedForReferenceRaster=True,
                newModelCreated=False, modelTrainingPerformed=False,
                method='equal-budget independently refined normal/heavy reconstructed-ink comparison')
