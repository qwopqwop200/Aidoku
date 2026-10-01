#!/usr/bin/env python3
"""Saved-run analysis/angle/coordinate and host-only JS instrumentation tests.
No model, server, or production app compilation is needed.
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
        ('rejected-reads', [{'polygon': polygon(0, 10, 10), 'text': '', 'confidence': .2}])]
    for i, (name, value) in enumerate(stages):
        (image / f'{i+1:03d}-{name}.json').write_text(json.dumps({'stage': name, 'value': value}, ensure_ascii=False))
    result = subprocess.run(['swift', str(ROOT / 'Scripts/image-translation.swift'), '--visualize-run', str(run)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    data = json.loads((image / 'analysis.json').read_text())
    assert len(data['stages']) == 4
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
    assert all((image / stage['preview']).stat().st_size > 100 for stage in data['stages'])
    html = (image / 'analysis.html').read_text()
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

# Validate trace output and that instrumentation preserves original returns/exceptions.
source = (ROOT / 'Scripts/image-translation/HostSegmentationTrace.swift').read_text()
trace_script = source.split('static let script = #"""', 1)[1].split('"""#', 1)[0]
trace_harness = r'''
const assert=require('node:assert/strict');
let original=new Uint8Array([0,1,1,0]),throws=false;
function aidokuReadablePolygonMask(){if(throws)throw Error('original failure');return original}
function aidokuForcedTextMask(){return original}
function aidokuSourcePolygonMask(){return original}
const ctx={createImageData:(w,h)=>({data:new Uint8ClampedArray(w*h*4)}),putImageData(){},drawImage(){}};
const document={createElement:()=>({getContext:()=>ctx,toDataURL:()=> 'data:image/png;base64,eA=='})};
class ImageData{constructor(data,w,h){this.data=data}}
eval(SCRIPT);
const rgba=new Uint8ClampedArray(16);
assert.equal(aidokuReadablePolygonMask(rgba,2,2,{x:1}),original);
assert.equal(globalThis.__aidokuHostSegmentationTrace.captures[0].selectedPixels,2);
assert(globalThis.__aidokuHostSegmentationTrace.captures[0].source);
assert.equal(aidokuSourcePolygonMask(2,2,{}),original);
assert.equal(globalThis.__aidokuHostSegmentationTrace.captures[1].kind,'polygon-ownership');
throws=true;assert.throws(()=>aidokuReadablePolygonMask(rgba,2,2,{}),/original failure/);throws=false;
for(let i=0;i<70;i++)aidokuForcedTextMask(rgba,2,2,{});
assert.equal(globalThis.__aidokuHostSegmentationTrace.captures.length,64);
assert.equal(globalThis.__aidokuHostSegmentationTrace.dropped,8);
'''
subprocess.run(['node', '-e', 'const SCRIPT=' + json.dumps(trace_script) + ';' + trace_harness], check=True)
# Replay real stored crop pixels through the current production segmenter, with/without tracing.
production_harness = r''' 
const fs=require('node:fs'),zlib=require('node:zlib'),assert=require('node:assert/strict');
const source=fs.readFileSync(ROOT+'/AidokuTests/Translation/LegacyBrowserOverlay/BrowserSourceGlyphSegmentation.swift','utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const fixtures=JSON.parse(fs.readFileSync(ROOT+'/Scripts/tests/fixtures/source-inpainting-art-guard.json')).fixtures;
const context={createImageData:(w,h)=>({data:new Uint8ClampedArray(w*h*4)}),putImageData(){},drawImage(){}};
globalThis.document={createElement:()=>({getContext:()=>context,toDataURL:()=> 'data:image/png;base64,eA=='})};
globalThis.ImageData=class{constructor(data){this.data=data}};
const original=new Function(source+';return aidokuForcedTextMask')();
const traced=new Function(source+'\n'+SCRIPT+';return aidokuForcedTextMask')();
for(const item of fixtures){const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(item.rgba,'base64')));
 const options={vertical:item.vertical,sampleScale:item.scale};
 const baseline=original(rgba,item.w,item.h,item.b,item.palette,options),observed=traced(rgba,item.w,item.h,item.b,item.palette,options);
 assert.deepEqual(observed,baseline,'tracing preserves actual production mask and metadata');}
assert(globalThis.__aidokuHostSegmentationTrace.captures.length>0);
assert(globalThis.__aidokuHostSegmentationTrace.captures.some(c=>c.selectedPixels>0));
'''
subprocess.run(['node', '-e', 'const ROOT=' + json.dumps(str(ROOT)) + ';const SCRIPT=' + json.dumps(trace_script) + ';' + production_harness], check=True)
print('PASS: saved-run export, coordinates, reading axes, safe HTML, interactive report and segmentation trace/budgets')
