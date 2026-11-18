"""Compact source-crop annotation packets and original-pixel sampling."""
import argparse
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[3] / 'labels/appearance-merged830-20261109-r64'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['list', 'sample'])
    parser.add_argument('--shard', type=int, required=True)
    parser.add_argument('--start', type=int, default=0)
    parser.add_argument('--count', type=int, default=4)
    parser.add_argument('--item')
    parser.add_argument('--points', help='JSON [[x,y],...]')
    args = parser.parse_args()
    packet = json.loads((ROOT / 'shards' / f'{args.shard:02d}' / 'assignment.json').read_text())
    if args.command == 'list':
        print(json.dumps(dict(worker=args.shard, total=packet['total'], start=args.start), ensure_ascii=False))
        for item in packet['items'][args.start:args.start + args.count]:
            hint = item['suggestions']['segmentationAuthorHint']
            print(json.dumps(dict(itemID=item['itemID'], crop=item['crop'], cropSHA256=item['cropSHA256'],
                ownershipMask=item['ownershipMask'], cropSize=item['cropSize'], fontPixels=item['fontPixels'],
                nonbindingHint={k: hint[k] for k in ['kind', 'color', 'whiteDistanceLimit'] if k in hint},
                insidePalette=item['suggestions']['insideMaskPalette'][:8],
                backgroundPalette=item['suggestions']['localBackgroundPalette'][:4]), ensure_ascii=False))
    else:
        item = next(i for i in packet['items'] if i['itemID'] == args.item)
        rgb = Image.open(item['crop']).convert('RGB')
        for x, y in json.loads(args.points):
            print(json.dumps(dict(xy=[x, y], rgb=list(rgb.getpixel((x, y)))), ensure_ascii=False))


if __name__ == '__main__':
    main()
