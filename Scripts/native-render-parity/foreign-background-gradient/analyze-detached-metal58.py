#!/usr/bin/env python3
"""Independent immutable capture audit. Flips are diagnostic comparisons, never acceptance substitutions."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--capture', type=Path, required=True)
parser.add_argument('--reference', type=Path, default=ROOT/'build/native-render-parity/verify-gradient-backend-build56-snapshot')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
sha = lambda value: hashlib.sha256(value).hexdigest()

def png(path):
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    offset, compressed, chunks = 8, b'', []
    while offset < len(data):
        count = struct.unpack('>I', data[offset:offset+4])[0]
        kind = data[offset+4:offset+8]; value = data[offset+8:offset+8+count]
        assert zlib.crc32(kind+value) & 0xffffffff == struct.unpack('>I',data[offset+8+count:offset+12+count])[0]
        chunks.append(kind.decode())
        if kind == b'IHDR': width,height,depth,color,_,_,interlace = struct.unpack('>IIBBBBB',value)
        if kind == b'IDAT': compressed += value
        offset += count+12
    assert depth == 8 and color in (2,6) and interlace == 0
    channels = 3 if color == 2 else 4; row_size = width*channels
    filtered = zlib.decompress(compressed); assert len(filtered) == height*(row_size+1)
    previous = bytearray(row_size); result = bytearray()
    for y in range(height):
        method = filtered[y*(row_size+1)]; row = bytearray(filtered[y*(row_size+1)+1:(y+1)*(row_size+1)])
        for x in range(row_size):
            left = row[x-channels] if x >= channels else 0
            upper = previous[x]; corner = previous[x-channels] if x >= channels else 0
            predicted = left+upper-corner
            distances = [abs(predicted-left),abs(predicted-upper),abs(predicted-corner)]
            paeth = [left,upper,corner][distances.index(min(distances))]
            row[x] = (row[x]+[0,left,upper,(left+upper)//2,paeth][method]) & 255
        for x in range(width): result.extend(row[x*channels:(x+1)*channels] if channels == 4 else row[x*3:(x+1)*3]+b'\xff')
        previous = row
    return width,height,bytes(result),chunks

def difference(a,b):
    if len(a) != len(b): return {'dimensionMismatch':True,'exactRGBA':False}
    return {'exactRGBA':a==b,'changedPixels':sum(a[i:i+4]!=b[i:i+4] for i in range(0,len(a),4)),
            'changedBytes':sum(x!=y for x,y in zip(a,b)), 'maxChannelDelta':max(abs(x-y) for x,y in zip(a,b))}

def flip_vertical(data,width,height):
    row = width*4
    return b''.join(data[y*row:(y+1)*row] for y in reversed(range(height)))

def crop(data,width,left,top,w,h):
    return b''.join(data[(y*width+left)*4:(y*width+left+w)*4] for y in range(top,top+h))

def box(points):
    if not points: return None
    xs,ys = zip(*points)
    return [min(xs),min(ys),max(xs)-min(xs)+1,max(ys)-min(ys)+1]

def observation(data,width,height,source_rgb):
    alpha = Counter(data[3::4]); colors = Counter(tuple(data[i:i+4]) for i in range(0,len(data),4))
    background = [41,65,87]; foreground = []; nonopaque = []
    for y in range(height):
        for x in range(width):
            p = data[(y*width+x)*4:(y*width+x+1)*4]
            if p[3] != 255: nonopaque.append((x,y))
            # Classification only: nearest of literal foreground/background RGB, no acceptance tolerance.
            if p[3] and sum((p[c]-source_rgb[c])**2 for c in range(3)) < sum((p[c]-background[c])**2 for c in range(3)):
                foreground.append((x,y))
    return {'alphaHistogram':dict(sorted(alpha.items())), 'opaque':alpha=={255:width*height},
            'nonopaqueBounds':box(nonopaque), 'literalColorNearestForegroundBounds':box(foreground),
            'paletteCardinality':len(colors),'mostFrequentRGBA':[{'RGBA':list(k),'count':n} for k,n in colors.most_common(12)],
            'corners':[list(data[(y*width+x)*4:(y*width+x+1)*4]) for x,y in [(0,0),(width-1,0),(0,height-1),(width-1,height-1)]]}

manifest = json.loads((ROOT/'Scripts/native-render-parity/foreign-background-gradient/staged/Fixtures/manifest.json').read_text())
records = []
for name,rgb in [('red',[220,30,40]),('blue',[30,40,220])]:
    reference_png = args.reference/name/'web.png'; reference_raw = (args.reference/name/'web.rgba').read_bytes()
    rw,rh,reference_decoded,_ = png(reference_png)
    pinned = next(r for r in manifest['references'] if r['scene'] == name)
    assert (rw,rh)==(960,480) and reference_raw==reference_decoded
    assert sha(reference_png.read_bytes())==pinned['PNGHash'] and sha(reference_raw)==pinned['RGBAHash']
    directory = args.capture/name
    metadata_file = directory/'capture.json'
    metadata = json.loads(metadata_file.read_text()) if metadata_file.exists() else None
    raw_file = directory/'native-detached-metal.rgba'
    if not raw_file.exists():
        records.append({'scene':name,'rawCapturePresent':False,'metadata':metadata}); continue
    raw = raw_file.read_bytes(); width = metadata['width']; height = metadata['height']
    assert len(raw)==width*height*4
    png_file = directory/'native-detached-metal.png'
    encoding = None
    if png_file.exists():
        pw,ph,decoded,chunks = png(png_file)
        encoding = {'size':[pw,ph], 'PNGHash':sha(png_file.read_bytes()),'chunks':chunks,
                    'decodedStraightRGBAEqualsSavedCanonicalPMA':decoded==raw,
                    'qualification':'Straight PNG versus PMA readback equality is required only when all pixels are opaque.'}
    result = {'scene':name,'rawCapturePresent':True,'size':[width,height],'rawRGBAHash':sha(raw),
              'metadata':metadata,'PNGTransport':encoding,'observation':observation(raw,width,height,rgb),
              'unalteredWholeImage':difference(reference_raw,raw),
              'orientationDiagnosticOnly':{'verticalFlip':difference(reference_raw,flip_vertical(raw,width,height)),
                  'noFlippedImageUsedForAcceptance':True},'expectedForegroundRasterRect':[60,60,288,288],
              'expectedVerticallyReversedForegroundRect':[60,132,288,288]}
    if (width,height)==(rw,rh):
        inner = crop(raw,width,66,66,276,276)
        result['borderFreeInterior'] = difference(crop(reference_raw,rw,66,66,276,276),inner)
        result['interiorPalette'] = [{'RGBA':list(k),'count':v} for k,v in sorted(Counter(tuple(inner[i:i+4]) for i in range(0,len(inner),4)).items())]
    records.append(result)
original = json.loads((args.capture/'report.json').read_text())
report = {'scope':'Independent raw/PNG/source audit of detached public CARenderer; flips and geometry classifications diagnostic only',
          'capturePath':str(args.capture),'referencePath':str(args.reference),'actualReportHash':sha((args.capture/'report.json').read_bytes()),
          'actualDiagnosticPassed':original.get('passed'), 'actualFailures':original.get('failures'),
          'rawCaptureCount':sum(r['rawCapturePresent'] for r in records),'records':records,
          'productionOrOracleEdited':False,'pixelAcceptanceSubstitution':False}
(args.output/'report.json').write_text(json.dumps(report,indent=2))
print(json.dumps({'rawCaptureCount':report['rawCaptureCount'],'output':str(args.output/'report.json')},indent=2))
