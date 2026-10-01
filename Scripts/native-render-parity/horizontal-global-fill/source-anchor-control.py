"""Exact RGBA counterproof of global glyph transport and Float inline centering.

Reads immutable captured CoreText row geometry, not inverse-rounded PDF origins.
It generates a separate diagnostic PDF; input artifacts and image oracle stay intact.
"""
from pathlib import Path
import argparse
import json
import math
import shutil
import struct
from pypdf import PdfReader, PdfWriter
from pypdf.generic import ArrayObject, ContentStream, FloatObject

parser = argparse.ArgumentParser()
parser.add_argument('capture', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--device-scale', type=float, required=True)
parser.add_argument('--mode', choices=['global-only', 'float-only', 'both'], default='both')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
def f32(value):
    return struct.unpack('f', struct.pack('f', value))[0]
def quartz(value):
    return float(format(value, '.7g'))
source_frame = json.loads((args.capture / 'web-layout.json').read_text())[0]['sourceFrame']
crop_x, crop_y = (int(f32(value)) for value in source_frame[:2])
native = PdfReader(args.capture / 'native-typography.pdf')
page = native.pages[0]
scale = f32(args.device_scale) * f32(1 / args.device_scale)
height = float(page.mediabox.height) + crop_y * scale
cards = json.loads((args.capture / 'native-final-layout.json').read_text())['cards']
rows = []
for card in cards:
    for row in card['typographyFinal']['coreTextRows']:
        x = card['contentRect'][0] + row['layoutOffset'][0] + row['origin'][0] + row['lineOffset'][0]
        y = card['contentRect'][1] + row['layoutOffset'][1] + row['frameSize'][1] - row['origin'][1] + row['lineOffset'][1]
        y = math.floor(y * args.device_scale + 0.5) / args.device_scale
        # Captured rows in this control have centered paragraph alignment;
        # production must check its own alignment provenance before applying this.
        width = row['frameSize'][0] - 2 * row['origin'][0]
        centered = x + (width - f32(width)) / 2
        rows.append(dict(owner=card['id'], index=row['index'], x=f32(x), y=f32(y),
                         centeredX=f32(centered), rawWidth=width, floatWidth=f32(width)))
stream = ContentStream(page['/Contents'], native)
operations = stream.operations
mode, stack, last_cm, changes = 0, [], None, []
for index, (values, operator) in enumerate(operations):
    if operator == b'q':
        stack.append(mode)
    elif operator == b'Q':
        mode = stack.pop()
    elif operator == b'Tr':
        mode = int(values[0])
    elif operator == b'cm':
        last_cm = index
    elif operator == b'Tm' and last_cm is not None and list(values[4:]) == [0, 0]:
        cm = operations[last_cm][0]
        if list(cm[:4]) not in [[1, 0, 0, 1], [1, 0, 0, -1]]:
            continue
        # Locate each actual captured source point in serialized operators.
        # This recognition bound is not an image comparison tolerance.
        row = min(rows, key=lambda r: abs(float(cm[4]) - (r['x'] - crop_x) * scale)
                  + abs(float(cm[5]) - (height - r['y'] * scale)))
        if abs(float(cm[4]) - (row['x'] - crop_x) * scale) > 0.0001 or abs(float(cm[5]) - (height - row['y'] * scale)) > 0.0001:
            continue
        x = row['x'] if args.mode == 'global-only' else row['centeredX']
        if mode == 1 or args.mode == 'float-only':
            updated = list(cm)
            updated[4] = FloatObject(quartz((x - crop_x) * scale))
            operations[last_cm] = (ArrayObject(updated), b'cm')
        else:
            operations[last_cm] = (ArrayObject(map(FloatObject,
                [quartz(scale), 0, 0, -quartz(scale), quartz(-crop_x * scale), quartz(height)])), b'cm')
            operations[index] = (ArrayObject(map(FloatObject,
                [float(values[0]), 0, 0, -abs(float(values[3])), quartz(x), quartz(row['y'])])), b'Tm')
        changes.append(dict(owner=row['owner'], row=row['index'], passType=mode, sourceX=x, sourceY=row['y']))
writer = PdfWriter(clone_from=native)
stream = ContentStream(writer.pages[0]['/Contents'], writer)
stream.operations = operations
writer.pages[0].replace_contents(stream)
writer.write(args.output / 'native-typography.pdf')
shutil.copyfile(args.capture / 'web-typography.pdf', args.output / 'web-typography.pdf')
(args.output / 'source-points.json').write_text(json.dumps(dict(mode=args.mode, sourceFrame=source_frame,
    sourceDeviceScale=args.device_scale, rows=rows, changes=changes), indent=2))
print('Source-point matched changes:', len(changes), args.mode)
