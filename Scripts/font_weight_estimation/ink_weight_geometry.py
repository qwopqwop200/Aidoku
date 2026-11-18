"""Image processing only: opposed glyph edges and reliable component strokes."""
import math

import cv2
import numpy as np

from palette_word_pairs import observe_palette


def clean_fill_style(style):
    """Contrasting source fill candidates; background/outline are not pen ink."""
    primary = np.asarray(style['fill']['rgb'], float)
    background = np.asarray(style['background']['rgb'], float)
    colors = [primary, *[np.asarray(c, float) for c in style['fill'].get('colors', [])]]
    accepted = []
    for color in colors:
        if np.linalg.norm(color-background) <= 35:
            continue
        if np.linalg.norm(color-primary) > 1:
            paint = style.get('outline', {})
            if paint.get('present') and paint.get('rgb') is not None and np.linalg.norm(color-paint['rgb']) < 22:
                continue
            paint = style.get('shadow', {})
            if paint.get('present') and paint.get('rgb') is not None and np.linalg.norm(color-paint['rgb']) < 22:
                continue
        if not any(np.linalg.norm(color-other) < 1 for other in accepted):
            accepted.append(color)
    if not accepted:
        return None
    return dict(style, fill=dict(style['fill'], rgb=accepted[0].tolist(),
                                 colors=[c.tolist() for c in accepted]))


def opposed_widths(alpha, observed, mask, unit, maximum_edges=6000):
    """Stroke-width transform: inward rays must hit an opposing visible edge.

    Junction disks and outline thickness cannot silently replace pen width.
    Unknown-colour boundaries are not accepted as actual glyph edges.
    """
    mask = np.asarray(mask, bool)
    alpha = np.asarray(alpha, np.float32)
    valid = np.asarray(observed, bool)
    if mask.shape != alpha.shape or valid.shape != mask.shape or not math.isfinite(unit) or unit <= 0:
        raise ValueError('Invalid stroke-width geometry')
    smooth = cv2.GaussianBlur(alpha, (3, 3), .65)
    dx = cv2.Sobel(smooth, cv2.CV_32F, 1, 0, ksize=3)
    dy = cv2.Sobel(smooth, cv2.CV_32F, 0, 1, ksize=3)
    length = np.hypot(dx, dy)
    edge = mask & ~cv2.erode(mask.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    trustworthy = cv2.erode(valid.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    ys, xs = np.nonzero(edge & trustworthy & (length > .08))
    if len(xs) > maximum_edges:
        selected = np.linspace(0, len(xs)-1, maximum_edges).astype(int)
        xs, ys = xs[selected], ys[selected]
    if not len(xs):
        return np.zeros(0), 0.
    nx, ny = dx[ys, xs]/length[ys, xs], dy[ys, xs]/length[ys, xs]
    alive = np.ones(len(xs), bool)
    result = []
    for distance in np.arange(.5, max(2.1, .5*unit)+.1, .5):
        active = np.flatnonzero(alive)
        if not len(active):
            break
        xx = np.rint(xs[active]+distance*nx[active]).astype(int)
        yy = np.rint(ys[active]+distance*ny[active]).astype(int)
        inside = (xx >= 0) & (yy >= 0) & (xx < mask.shape[1]) & (yy < mask.shape[0])
        alive[active[~inside]] = False
        active, xx, yy = active[inside], xx[inside], yy[inside]
        known = trustworthy[yy, xx]
        alive[active[~known]] = False
        active, xx, yy = active[known], xx[known], yy[known]
        hits = ~mask[yy, xx]
        if not hits.any():
            continue
        index, xx, yy = active[hits], xx[hits], yy[hits]
        alignment = (nx[index]*dx[yy, xx]+ny[index]*dy[yy, xx])/np.maximum(1e-6, length[yy, xx])
        accepted = (alignment < -.5) & (length[yy, xx] > .08) & (distance >= 1.)
        result.extend([float(distance/unit)]*int(accepted.sum()))
        alive[index] = False
    widths = np.asarray(result, float)
    return widths, len(widths)/len(xs)


def observe(rgb, bbox, em, ownership, style):
    if not math.isfinite(em) or em <= 0:
        raise ValueError('Invalid stroke measurement scale')
    cleaned = clean_fill_style(style)
    if cleaned is None:
        alpha, known = np.zeros(rgb.shape[:2], np.float32), np.ones(rgb.shape[:2], bool)
    else:
        alpha, known = observe_palette(rgb, ownership, cleaned)
    scale = min(1., 800/max(alpha.shape))
    if scale < 1:
        alpha = cv2.resize(alpha, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
        known = cv2.resize(known.astype(np.float32), (alpha.shape[1], alpha.shape[0]),
                           interpolation=cv2.INTER_AREA) > .99
        ownership = cv2.resize(ownership.astype(np.uint8), (alpha.shape[1], alpha.shape[0]),
                               interpolation=cv2.INTER_NEAREST).astype(bool)
    unit = em*scale
    x, y, w, h = np.asarray(bbox)*scale
    target = np.zeros(alpha.shape, bool)
    target[max(0, math.floor(y)):min(len(alpha), math.ceil(y+h)),
           max(0, math.floor(x)):min(alpha.shape[1], math.ceil(x+w))] = True
    out = []
    for cutoff in (.25, .5, .75):
        binary = ((alpha > cutoff) & known & ownership).astype(np.uint8)
        count, labels, stats, _ = cv2.connectedComponentsWithStats(binary, 8)
        overlaps = np.bincount(labels[target].ravel(), minlength=count)
        chosen, bodies = np.zeros(count, bool), []
        for i in range(1, count):
            sx, sy, sw, sh, area = stats[i]
            if not (.22*unit <= max(sw, sh) <= 1.7*unit and min(sw, sh) >= max(2, .06*unit)
                    and area >= max(4, .006*unit**2) and overlaps[i]/area >= .3):
                continue
            body = np.pad((labels[sy:sy+sh, sx:sx+sw] == i).astype(np.uint8), 1)
            depth = cv2.distanceTransform(body, cv2.DIST_L2, cv2.DIST_MASK_PRECISE)
            ridge = (depth > 0) & (depth >= cv2.dilate(depth, np.ones((3, 3), np.uint8))-.001)
            if ridge.sum() < max(3, .1*unit):
                continue
            widths = 2*depth[ridge]/unit
            contour, hierarchy = cv2.findContours(body, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_SIMPLE)
            perimeter = sum(cv2.arcLength(c, True) for c in contour)
            holes = sum(cv2.contourArea(c) for j, c in enumerate(contour) if hierarchy[0, j, 3] >= 0) if hierarchy is not None else 0.
            bodies.append([*np.quantile(widths, [.25, .5, .75, .9]),
                           2*area/max(1, perimeter)/unit, area/(sw*sh), max(sw, sh)/unit,
                           holes/max(1, holes+area)])
            chosen[i] = True
        selected = chosen[labels]
        paired, pair_support = opposed_widths(alpha, known, selected, unit)
        bodies = np.asarray(bodies)
        out.append(dict(cutoff=cutoff, components=len(bodies), pairedRays=len(paired), pairSupport=pair_support,
                        pairedQuantiles=np.quantile(paired, [.25, .5, .75, .9]).tolist() if len(paired) else [0.]*4,
                        componentMedian=np.median(bodies, axis=0).tolist() if len(bodies) else [0.]*8,
                        componentUpper=np.quantile(bodies, .75, axis=0).tolist() if len(bodies) else [0.]*8,
                        observedFraction=float(known.mean())))
    return dict(stages=out, method='source fill palette + opposed-edge SWT + component-balanced medial widths',
                sourcePaletteQualified=cleaned is not None, learnedModelUsed=False)
