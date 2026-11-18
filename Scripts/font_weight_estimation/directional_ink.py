"""Source stroke contrast by edge-normal direction, without a learned model."""
import cv2
import numpy as np


def measure(alpha, known, unit, maximum_component_em=1.7):
    alpha = np.asarray(alpha, np.float32)
    known = np.asarray(known, bool)
    if alpha.shape != known.shape or unit <= 0 or not np.isfinite(alpha).all():
        raise ValueError('Invalid directional stroke input')
    binary = (alpha > .5) & known
    n, labels, stats, _ = cv2.connectedComponentsWithStats(binary.astype(np.uint8), 8)
    accepted = ((np.maximum(stats[:, 2], stats[:, 3]) >= .2*unit)
                & (stats[:, 4] >= max(4, .003*unit**2)))
    if maximum_component_em is not None:
        accepted &= np.maximum(stats[:, 2], stats[:, 3]) <= maximum_component_em*unit
    # Long connected text is an explicit measurement variant. Removing this
    # bound unconditionally admitted new background/paint components in the
    # full corpus, so it must not silently replace the validated default.
    accepted[0] = False
    mask = accepted[labels]
    smooth = cv2.GaussianBlur(alpha, (3, 3), .65)
    dx = cv2.Sobel(smooth, cv2.CV_32F, 1, 0, ksize=3)
    dy = cv2.Sobel(smooth, cv2.CV_32F, 0, 1, ksize=3)
    magnitude = np.hypot(dx, dy)
    edge = mask & ~cv2.erode(mask.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    trusted = cv2.erode(known.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    ys, xs = np.nonzero(edge & trusted & (magnitude > .08))
    if len(xs) > 6000:
        select = np.linspace(0, len(xs)-1, 6000).astype(int)
        xs, ys = xs[select], ys[select]
    nx, ny = dx[ys, xs]/magnitude[ys, xs], dy[ys, xs]/magnitude[ys, xs]
    direction = np.where(np.abs(nx) >= .9, 0, np.where(np.abs(ny) >= .9, 1, 2))
    alive = np.ones(len(xs), bool)
    widths = [[], [], []]
    for distance in np.arange(.5, max(2.1, .5*unit)+.1, .5):
        active = np.flatnonzero(alive)
        if not len(active):
            break
        xx = np.rint(xs[active]+distance*nx[active]).astype(int)
        yy = np.rint(ys[active]+distance*ny[active]).astype(int)
        inside = (xx >= 0) & (yy >= 0) & (xx < mask.shape[1]) & (yy < mask.shape[0])
        alive[active[~inside]] = False
        active, xx, yy = active[inside], xx[inside], yy[inside]
        visible = trusted[yy, xx]
        alive[active[~visible]] = False
        active, xx, yy = active[visible], xx[visible], yy[visible]
        hits = ~mask[yy, xx]
        index, xx, yy = active[hits], xx[hits], yy[hits]
        alignment = (nx[index]*dx[yy, xx]+ny[index]*dy[yy, xx])/np.maximum(1e-6, magnitude[yy, xx])
        good = (alignment < -.5) & (magnitude[yy, xx] > .08) & (distance >= 1.)
        for group in range(3):
            widths[group].extend([float(distance/unit)]*int((good & (direction[index] == group)).sum()))
        alive[index] = False
    groups = {}
    for name, values in zip(('verticalStems', 'horizontalStems', 'diagonalStems'), widths):
        groups[name] = dict(count=len(values), quantiles=np.quantile(values, [.1, .25, .5, .75]).tolist()
                            if values else [0.]*4)
    medians = [group['quantiles'][2] for group in groups.values() if group['count'] >= 12]
    return dict(groups=groups, components=int(accepted.sum()),
                directionContrast=max(medians)/max(1e-6, min(medians)) if len(medians) >= 2 else None,
                minimumDirectionalMedian=min(medians) if medians else 0.,
                newModelCreated=False, modelTrainingPerformed=False)
