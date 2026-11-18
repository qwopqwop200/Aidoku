"""Second-pass source packets, exact pixel sampling and outline-width evidence."""
import argparse
import json
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[3] / 'labels/appearance-merged830-20261109-r64-review2'


def outline_evidence(rgb, ownership, fill_rgb, outline_rgb):
    if fill_rgb is None or outline_rgb is None:
        return dict(reliable=False, reason='missing source layer colors')
    raw = rgb.astype(np.int16)
    fill_color = np.asarray(fill_rgb)
    outline_color = np.asarray(outline_rgb)
    if np.max(np.abs(fill_color - outline_color)) < 60:
        return dict(reliable=False, reason='fill and outline colors insufficiently separated')
    fill_tolerance = 20 if max(fill_rgb) < 45 or min(fill_rgb) > 215 else 35
    outline_tolerance = 20 if max(outline_rgb) < 45 else 35
    all_fill = np.max(np.abs(raw - fill_color), axis=2) <= fill_tolerance
    fill = all_fill & ownership
    stroke = np.max(np.abs(raw - outline_color), axis=2) <= outline_tolerance
    height, width = fill.shape
    runs, gaps = [], []
    for dy, dx in [(0, 1), (0, -1), (1, 0), (-1, 0)]:
        y, x = np.where(fill)
        yy, xx = y + dy, x + dx
        valid = (yy >= 0) & (yy < height) & (xx >= 0) & (xx < width)
        valid &= ~fill[np.clip(yy, 0, height - 1), np.clip(xx, 0, width - 1)]
        yy, xx = yy[valid], xx[valid]
        gap = np.zeros(len(yy), np.int32)
        active = np.ones(len(yy), bool)
        for _ in range(3):
            inside = (yy >= 0) & (yy < height) & (xx >= 0) & (xx < width)
            ys, xs = np.clip(yy, 0, height - 1), np.clip(xx, 0, width - 1)
            advance = active & inside & ~stroke[ys, xs] & ~all_fill[ys, xs]
            yy[advance] += dy
            xx[advance] += dx
            gap[advance] += 1
            active &= inside & ~all_fill[ys, xs]
        ys, xs = np.clip(yy, 0, height - 1), np.clip(xx, 0, width - 1)
        start = active & (gap < 3) & (yy >= 0) & (yy < height) & (xx >= 0) & (xx < width) & stroke[ys, xs]
        yy, xx, gap = yy[start], xx[start], gap[start]
        length = np.zeros(len(yy), np.int32)
        active = np.ones(len(yy), bool)
        for _ in range(20):
            inside = (yy >= 0) & (yy < height) & (xx >= 0) & (xx < width)
            ys, xs = np.clip(yy, 0, height - 1), np.clip(xx, 0, width - 1)
            advance = active & inside & stroke[ys, xs]
            length[advance] += 1
            yy[advance] += dy
            xx[advance] += dx
            active = advance
        inside = (yy >= 0) & (yy < height) & (xx >= 0) & (xx < width)
        ys, xs = np.clip(yy, 0, height - 1), np.clip(xx, 0, width - 1)
        contrast = np.max(np.abs(raw[ys, xs] - outline_color), axis=1)
        accept = inside & (length >= 1) & (length < 15) & ~all_fill[ys, xs] & (contrast >= 45)
        runs.extend(length[accept].tolist())
        gaps.extend(gap[accept].tolist())
    if len(runs) < 40:
        return dict(reliable=False, usableRays=len(runs), reason='too few separable fill-outline-background rays; do not force a width')
    q = np.quantile(runs, [.1, .25, .5, .75])
    aa = float(np.median(gaps))
    estimate = float(q[1] + .5 * aa)
    return dict(reliable=True, usableRays=len(runs), coreRunPx=dict(p10=float(q[0]), p25=float(q[1]), median=float(q[2]), p75=float(q[3])),
        medianTransitionPx=aa, suggestedWidthPx=estimate, suggestedRangePx=[max(.5, float(q[0]) - .5), float(q[1]) + 2],
        limitations='Cardinal rays can overestimate slanted boundaries; merged white background, multiple rings or shadows can invalidate this evidence. Visually adjudicate, never bulk overwrite.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['list', 'labels', 'sample', 'measure'])
    parser.add_argument('--shard', type=int, required=True)
    parser.add_argument('--start', type=int, default=0)
    parser.add_argument('--count', type=int, default=4)
    parser.add_argument('--item')
    parser.add_argument('--points')
    parser.add_argument('--fill')
    parser.add_argument('--outline')
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    folder = args.root / 'shards' / f'{args.shard:02d}'
    packet = json.loads((folder / 'assignment.json').read_text())
    previous = None
    def prior(row):
        nonlocal previous
        if 'previousLabel' in row:
            return row
        if previous is None:
            previous = json.loads((folder / 'previous-labels.json').read_text())
        return previous[row['itemID']]
    if args.command in ['list', 'labels']:
        print(json.dumps(dict(worker=args.shard, total=packet['total'], start=args.start)))
        for row in packet['items'][args.start:args.start + args.count]:
            out = {k: row[k] for k in ['itemID', 'crop', 'cropSHA256', 'cropSize', 'fontPixels']}
            if args.command == 'labels':
                out['previousLabel'] = prior(row)['previousLabel']
                out['sourceAnchors'] = prior(row)['previousReview']['anchors']
            print(json.dumps(out, ensure_ascii=False))
        return
    row = next(r for r in packet['items'] if r['itemID'] == args.item)
    image = Image.open(row['crop']).convert('RGB')
    if args.command == 'sample':
        for x, y in json.loads(args.points):
            print(json.dumps(dict(xy=[x, y], rgb=list(image.getpixel((x, y))))))
    else:
        fill = json.loads(args.fill) if args.fill else prior(row)['previousLabel']['fill']['rgb']
        outline = json.loads(args.outline) if args.outline else prior(row)['previousLabel']['outline']['rgb']
        mask = np.asarray(Image.open(row['ownershipMask'])) > 0
        print(json.dumps(outline_evidence(np.asarray(image), mask, fill, outline)))


if __name__ == '__main__':
    main()
