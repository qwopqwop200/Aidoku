"""Prepare 64 disjoint source-crop appearance annotation assignments."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import hashlib
import json
from pathlib import Path
import cv2
import numpy as np
from PIL import Image


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def palette(rgb, selection, maximum):
    positions = np.flatnonzero(selection.ravel())
    if not len(positions):
        return []
    pixels = rgb.reshape(-1, 3)[positions]
    quantized = pixels.astype(np.int32) // 16
    codes = quantized[:, 0] * 256 + quantized[:, 1] * 16 + quantized[:, 2]
    counts = np.bincount(codes, minlength=4096)
    output = []
    for code in np.argsort(counts)[::-1][:maximum]:
        if not counts[code]:
            break
        members = np.flatnonzero(codes == code)
        color = np.rint(np.median(pixels[members], axis=0)).astype(int)
        sample = members[np.argmin(np.sum((pixels[members].astype(np.int32) - color) ** 2, axis=1))]
        position = int(positions[sample])
        output.append(dict(rgb=color.tolist(), hex='#' + ''.join(f'{c:02X}' for c in color),
            fraction=float(counts[code] / len(positions)), count=int(counts[code]),
            sampleXY=[position % rgb.shape[1], position // rgb.shape[1]],
            sampleRGB=pixels[sample].tolist()))
    return output


def prepare(payload):
    item, root = payload
    crop, mask_path = root / item['crop'], root / item['mask']
    if digest(crop) != item['cropSHA256'] or digest(mask_path) != item['maskSHA256']:
        raise ValueError('Source/ownership mask hash mismatch: ' + item['itemID'])
    rgb = np.asarray(Image.open(crop).convert('RGB'))
    mask = np.asarray(Image.open(mask_path)) > 0
    ring = (cv2.dilate(mask.astype(np.uint8), np.ones((11, 11), np.uint8)) > 0) & ~mask
    if not ring.any():
        ring = ~mask
    source = {key: item.get(key) for key in ['itemID', 'page', 'regionID', 'sourceRegionIDs', 'sourceImageSHA256',
        'cropBounds', 'pageSize', 'mergedPolygonCrop', 'individualPolygonsCrop', 'maxContextFraction']}
    polygons = item['individualPolygonsCrop'] or [item['mergedPolygonCrop']]
    font = float(np.median([max(1., min(np.ptp(np.asarray(p), axis=0))) for p in polygons]))
    source.update(crop=str(crop.resolve()), cropSHA256=item['cropSHA256'], ownershipMask=str(mask_path.resolve()),
        ownershipMaskSHA256=item['maskSHA256'], cropSize=[rgb.shape[1], rgb.shape[0]], fontPixels=font)
    hints = item.get('baselineParameters', {}).get('authorSettings', {})
    source['suggestions'] = dict(status='unreviewed-non-GT-proposals', insideMaskPalette=palette(rgb, mask, 12),
        localBackgroundPalette=palette(rgb, ring, 8), segmentationAuthorHint=hints)
    return source


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--gt', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    gt = json.loads(args.gt.read_text())
    root = args.gt.parent.resolve()
    with ProcessPoolExecutor(max_workers=4) as pool:
        items = list(pool.map(prepare, [(item, root) for item in gt['items']], chunksize=8))
    for index in range(64):
        start, stop = len(items) * index // 64, len(items) * (index + 1) // 64
        folder = args.out / 'shards' / f'{index:02d}'
        (folder / 'review-items').mkdir(parents=True, exist_ok=True)
        assignment = dict(worker=index, total=len(items[start:stop]), items=items[start:stop])
        (folder / 'assignment.json').write_text(json.dumps(assignment, ensure_ascii=False, indent=2) + '\n')
    manifest = dict(schema='aidoku-original-text-appearance-annotation-input-v1', items=items,
        itemCount=len(items), agentAssignments=64, inputGTSHA256=digest(args.gt), inputGT=str(args.gt.resolve()),
        cropContextMaximumEachSide=.15, wholePagesMayBeVisuallyOpened=False, originalSourceImagesModified=False,
        allAutomaticSuggestionsAreUnreviewed=True)
    (args.out / 'input-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print(dict(items=len(items), shards=64, sourceGT=str(args.gt), output=str(args.out)), flush=True)


if __name__ == '__main__':
    main()
