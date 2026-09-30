#!/usr/bin/env python3
"""Large-page raster regression: original background survives final compositing.
Uses a saved render payload, with no OCR, models or translation server.
"""
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

ROOT=Path(__file__).resolve().parents[2]

def chunk(kind,data):
    return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))

def png(w,h):
    rows=b''.join(b'\0'+bytes((35,105,165) if y<h//2 else (220,75,45))*w for y in range(h))
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>2I5B',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b'')

def pixels(file):
    data=file.read_bytes();offset=8;compressed=b''
    while offset<len(data):
        size=struct.unpack('>I',data[offset:offset+4])[0];kind=data[offset+4:offset+8];body=data[offset+8:offset+8+size];offset+=size+12
        if kind==b'IHDR':w,h,depth,color,_,_,interlace=struct.unpack('>2I5B',body)
        if kind==b'IDAT':compressed+=body
    assert depth==8 and color in (2,6) and interlace==0
    channels=3 if color==2 else 4;stride=w*channels;raw=zlib.decompress(compressed);rows=[];previous=bytearray(stride)
    for y in range(h):
        start=y*(stride+1);filter_kind=raw[start];row=bytearray(raw[start+1:start+1+stride])
        for x in range(stride):
            a=row[x-channels] if x>=channels else 0;b=previous[x];c=previous[x-channels] if x>=channels else 0
            if filter_kind==1:value=a
            elif filter_kind==2:value=b
            elif filter_kind==3:value=(a+b)//2
            elif filter_kind==4:
                p=a+b-c;dist=[abs(p-a),abs(p-b),abs(p-c)];value=[a,b,c][dist.index(min(dist))]
            else:assert filter_kind==0;value=0
            row[x]=(row[x]+value)&255
        rows.append(row);previous=row
    return w,h,lambda x,y:tuple(rows[y][x*channels:x*channels+3])

with tempfile.TemporaryDirectory(prefix='aidoku-composite-') as temporary:
    run=Path(temporary);directory=run/'0001';directory.mkdir();(directory/'input.png').write_bytes(png(2600,1800))
    (directory/'final.json').write_text(json.dumps({'input':'synthetic-large-page','mode':'translation','regions':[]}))
    payload={'items':[{'id':'text','text':'합성 확인','x':900,'y':650,'width':300,'height':140,'fontSize':35,'lineHeight':45,
        'paddingTop':1,'paddingRight':1,'paddingBottom':1,'paddingLeft':1,'vertical':False,'rotation':0,'sourceTextOnly':False,'sourceColorEligible':False,'sourcePanelRestorationEligible':False,
        'sourceCleanup':False,'keptLettering':False,'fontScript':'korean','wrappingScript':'korean'}],
        'revision':1,'session':'raster-test','appearance':{'opacity':1,'minimumReadableFontSize':5,
        'preserveSourceTextColor':False,'preserveSourceBackgroundColor':False,'inpaintingEnabled':False,'sourceLetterFonts':False}}
    (directory/'001-render-payload.json').write_text(json.dumps({'stage':'render-payload','value':payload},ensure_ascii=False))
    subprocess.run(['swift',str(ROOT/'Scripts/image-translation.swift'),'--render-run',str(run)],cwd=ROOT,check=True)
    w,h,pixel=pixels(directory/'final.png');assert (w,h)==(2600,1800)
    for x,y in [(5,5),(2500,5),(5,1700),(2500,1700),(1800,700),(1800,1400)]:
        expected=(35,105,165) if y<900 else (220,75,45)
        assert all(abs(a-b)<=2 for a,b in zip(pixel(x,y),expected)),(x,y,pixel(x,y),expected)
    assert any(pixel(x,y)!=(35,105,165) for x in range(910,1180,20) for y in range(660,780,20)), 'Translation layer must also be present'
    assert (run/'analysis-index.html').exists()
print('PASS: large-page source pixels, translated layer, final dimensions and saved-payload replay')
