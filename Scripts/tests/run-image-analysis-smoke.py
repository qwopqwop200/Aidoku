#!/usr/bin/env python3
"""Saved-run analysis, coordinate geometry and actual native repair diagnostics.
No model, server, or iOS app compilation is needed; the report viewer remains HTML.
"""
import json
import math
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[2]


def png(width, height):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    rows = b''.join(b'\0' + b''.join(bytes((255, 100, 80) if y < 30 else (90, 210, 255)) for x in range(width)) for y in range(height))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>2I5B', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


def polygon(angle, width, height, cx=140, cy=120):
    a = math.radians(angle)
    return [{'x': cx + x * math.cos(a) - y * math.sin(a), 'y': cy + x * math.sin(a) + y * math.cos(a)}
            for x, y in [(-width/2, -height/2), (width/2, -height/2), (width/2, height/2), (-width/2, height/2)]]


with tempfile.TemporaryDirectory(prefix='aidoku-analysis-') as temporary:
    run = Path(temporary)
    image = run / '0001'
    image.mkdir()
    (image / 'input.png').write_bytes(png(320, 240))
    (image / 'final.png').write_bytes(png(320, 240))
    dangerous = '</script><script>bad()</script>'
    stages = [
        ('detector-output', {'boxes': [{'polygon': polygon(13, 100, 20), 'score': .85}]}),
        ('native-ocr', {'lines': [
            {'polygon': polygon(13, 100, 20), 'text': dangerous, 'score': .91, 'orientation': 'horizontal'},
            {'polygon': polygon(11, 20, 90), 'text': '縦書き', 'score': .82, 'orientation': 'vertical', 'orientationIsEstimated': True},
            # A horizontal single glyph with a tall box still has a horizontal reading axis.
            {'polygon': polygon(7, 15, 30), 'text': '!', 'score': .95, 'orientation': 'horizontal'}],
            'recoveryCandidates': [{'polygon': polygon(-9, 20, 90), 'text': '候補', 'score': .6, 'orientation': 'vertical'}]}),
        ('grouped-regions', [{'id': 'group', 'rect': {'x': .25, 'y': .125, 'width': .5, 'height': .25}, 'source': 'merged',
             'sourceOrientation': 'horizontal', 'unitMemberRects': [{'x': .25, 'y': .125, 'width': .2, 'height': .25}],
             'balloonInterior': {'rect': {'x': .1, 'y': .05, 'width': .8, 'height': .8}, 'spans': [.1, .9, .2, .8]}}]),
        ('rejected-reads', [{'polygon': polygon(0, 10, 10), 'text': '', 'confidence': .2}]),
        ('native-render-diagnostics', {'cards': [{}, {}, {}], 'initialPatches': [{}], 'finalPatches': [{}, {}],
             'initialPatchCaptureFailures': ['initial-capture-failure'],
             'finalPatchCaptureFailures': ['final-capture-failure']})]
    for i, (name, value) in enumerate(stages):
        if name == 'grouped-regions':
            # Identical raw evidence must take the packed HTML path; exercise
            # selection after reconstruction rather than only the fallback.
            value = value + value
        (image / f'{i+1:03d}-{name}.json').write_text(json.dumps({'stage': name, 'value': value}, ensure_ascii=False))
    for sequence in [999, 1000]:
        (image / f'{sequence}-grouped-regions.json').write_text(json.dumps({'stage': 'grouped-regions', 'value': []}))
    result = subprocess.run(['swift', str(ROOT / 'Scripts/image-translation.swift'), '--visualize-run', str(run)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    data = json.loads((image / 'analysis.json').read_text())
    assert len(data['stages']) == 6
    assert [stage['source'] for stage in data['stages'][-2:]] == ['999-grouped-regions.json', '1000-grouped-regions.json']
    detected = data['stages'][0]['records'][0]
    assert detected['direction'] == 'unknown' and detected['tiltDegrees'] is None
    assert abs(detected['longAxisDegrees'] - 13) < 1e-6
    native = data['stages'][1]['records']
    for row, angle in zip(native, [13, 11, 7, -9]):
        assert abs(row['tiltDegrees'] - angle) < 1e-6, row
    assert native[1]['directionEstimated']
    grouped = data['stages'][2]['records'][0]
    assert grouped['rect'] == [80, 30, 160, 60]
    assert grouped['memberRects'] == [[80, 30, 64, 60]]
    assert grouped['balloon']['rect'] == [32, 12, 256, 192]
    assert data['stages'][3]['records'][0]['category'] == 'rejected'
    diagnostics = [row['value'] for row in data['metrics'] if row['stage'] == 'native-render-diagnostics']
    assert diagnostics == [{'cards': 3, 'initialPatches': 1, 'finalPatches': 2,
        'captureFailures': ['initial-capture-failure'],
        'initialPatchCaptureFailures': ['initial-capture-failure'],
        'finalPatchCaptureFailures': ['final-capture-failure']}], diagnostics
    assert all((image / stage['preview']).stat().st_size > 100 for stage in data['stages'])
    html = (image / 'analysis.html').read_text()
    assert 'const PACKED=' in html, 'duplicate raw fixture bypassed pooled HTML'
    assert dangerous not in html and '\\u003c' in html
    assert (run / 'analysis-index.html').exists()
    # Parse and execute the report in a deterministic DOM/Canvas fixture. Exercise selection and filtering.
    script = re.search(r'<script>\s*([\s\S]*?)</script>', html).group(1)
    harness = r'''
const vm=require('node:vm'),assert=require('node:assert/strict');
const elements=new Map();
function element(){const ctx=new Proxy({measureText:()=>({width:30}),createImageData:(w,h)=>({data:new Uint8ClampedArray(w*h*4)})},{get:(t,k)=>t[k]||(()=>{})});
 return {value:'',checked:true,width:1,height:1,clientWidth:650,style:{},dataset:{},children:[],getContext:()=>ctx,getBoundingClientRect:()=>({left:0,top:0,width:320,height:240}),append(...a){this.children.push(...a)},replaceChildren(){this.children=[]},click(){this.onclick?.()},toDataURL:()=> 'data:image/png;base64,eA=='};}
const document={getElementById:id=>{if(!elements.has(id))elements.set(id,element());return elements.get(id)},createElement:()=>element()};
class Image{constructor(){this.complete=true;this.naturalWidth=320}set src(v){this.value=v;this.onload?.()}}
const sandbox={document,Image,Uint8ClampedArray,console,window:{}};vm.createContext(sandbox);
vm.runInContext(SCRIPT,sandbox);assert(sandbox.window.analysisReady());
assert.equal(document.getElementById('finalPanel').hidden,false);
assert.equal(document.getElementById('finalPreview').src,'final.png');
vm.runInContext("changeStage(1);select(1);",sandbox);
assert.match(document.getElementById('selection').textContent,/縦書き/);
assert.equal(document.getElementById('crop').width>1,true);
vm.runInContext("document.getElementById('search').value='縦書き';fillTable();",sandbox);
assert.equal(document.getElementById('rows').children.length,1);
vm.runInContext("document.getElementById('heat').checked=true;draw();changeStage(2);select(0);",sandbox);
'''
    subprocess.run(['node', '-e', 'const SCRIPT=' + json.dumps(script) + ';' + harness], check=True)

print('PASS: saved-run export, coordinates, reading axes, safe HTML, interactive report and historical diagnostics')
