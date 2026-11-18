#!/usr/bin/env python3
"""Actual physical_templates.measure oracle; isolated host compilation only."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT/'Scripts/font_weight_estimation'))
import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import physical_templates as oracle
from source_runtime import PAIRED_SCALES


def run():
    pairs = oracle.font_pairs()
    assert len(pairs) == 3 and PAIRED_SCALES == (.85, .95, 1., 1.05, 1.15)
    records, expected, names = [], [], []

    def add(name, rgb, em, text, bbox=None):
        h, w = rgb.shape[:2]
        bbox = bbox or [0, 0, w, h]
        records.append(dict(rgb=base64.b64encode(rgb.tobytes()).decode(), width=w,
                            height=h, bbox=bbox, em=em, text=text, pairs=pairs))
        expected.append(oracle.measure(rgb, bbox, em, text, scales=PAIRED_SCALES))
        names.append(name)

    # Real font raster crops with both witness groups; distinct masks/scales/faces.
    for face, (path, index) in enumerate([(pairs[0][0],0), (pairs[0][2],0),
                                         (pairs[1][2],0), (pairs[2][0],0), (pairs[2][0],2)]):
        for size in [16, 32, 65]:
            for mode, bg, ink in [('dark','white','black'), ('pale','black','white'),
                                  ('color',(120,120,120),(230,20,40))]:
                image = Image.new('RGB',(size*7,size*3),bg)
                ImageDraw.Draw(image).text((size//2,size//2),'あ漢A2',font=ImageFont.truetype(path,size,index=index),fill=ink)
                add(f'font-{face}-{size}-{mode}',np.asarray(image),size,'あ漢A2')
    for text in ['', '!? \n\u0301🙂', 'あいうえお', '漢ABC123', 'か\u3099ガがé𝟙', 'AABBああ', '\u0378']:
        rgb = np.full((64,160,3),255,np.uint8)
        cv2.rectangle(rgb,(10,10),(40,45),(0,0,0),-1)
        add('text-'+repr(text),rgb,24,text)
    # Constant masks exercise first ties; tiny/oversize patterns yield zero groups.
    for shape in [(1,1),(9,17),(64,90),(361,401),(79,800)]:
        for value in [0,190,255]:
            add(f'constant-{shape}-{value}',np.full((*shape,3),value,np.uint8),19,'あ漢')
    rng = np.random.default_rng(713)
    for size in [(53,91),(397,451),(101,721)]:
        rgb = rng.integers(0,256,(*size,3),dtype=np.uint8)
        add(f'noise-{size}',rgb,29.5,'ぬ語９Z')
    rgb = rng.integers(0,256,(111,207,3),dtype=np.uint8)
    add('fractional',rgb,31.25,'あ漢',[10.25,5.75,187.5,99.5])
    add('negative-clip',rgb,31.25,'あ漢',[-.75,-.5,207.5,111.5])
    add('very-large-em',np.zeros((80,80,3),np.uint8),400,'あ漢')
    good_count = len(records)
    for em in [0,-1]:
        r = dict(records[0]); r['em'] = em; records.append(r)
    r = dict(records[0]); r['bbox'] = [50,0,10,10]; records.append(r)
    r = dict(records[0]); r['pairs'] = [list(p) for p in pairs]; r['pairs'][2][3] = 1; records.append(r)
    r = dict(records[0]); r['pairs'] = [list(p) for p in pairs]; r['pairs'][0][0] = '/missing/font.ttc'; records.append(r)
    vendor = ROOT/'Vendor/NativeSourceCV'
    source = ROOT/'Vendor/SourceInference'
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='aidoku-physical-') as temp:
        temp = Path(temp)
        binary = temp/'physical'
        cmd = ['xcrun','clang++','-std=c++17','-O2','-fobjc-arc',
               '-I'+str(vendor/'include'),'-I'+str(vendor/'freetype/include'),'-I'+str(source),
               str(Path(__file__).with_name('main.mm')),str(source/'FontWeightPhysical.mm'),
               str(vendor/'NativeSourceCV.cpp'),
               str(vendor/'opencv2.xcframework/macos-arm64/libopencv2.a'),
               str(vendor/'FreeType.xcframework/macos-arm64/libfreetype.a'),
               '-lz']
        for framework in ['Foundation','Accelerate','CoreGraphics','CoreVideo','AVFoundation','CoreMedia','OpenCL']:
            cmd += ['-framework',framework]
        subprocess.run(cmd+['-o',str(binary)],check=True)
        build_seconds = time.monotonic()-start
        (temp/'in.json').write_text(json.dumps(records))
        start = time.monotonic()
        subprocess.run([str(binary),str(temp/'in.json'),str(temp/'out.json')],check=True)
        actual = json.loads((temp/'out.json').read_text())
        seconds = time.monotonic()-start
    maximum = 0.
    for name, want, got in zip(names,expected,actual[:good_count]):
        assert isinstance(got,list), (name,got)
        error = float(np.max(np.abs(want-got))); maximum = max(maximum,error)
        np.testing.assert_allclose(got,want,atol=2e-6,rtol=2e-6,err_msg=name)
        # Selected scale, count and gates must match exactly.
        np.testing.assert_array_equal(np.asarray(got).reshape(6,8)[:,4:],want.reshape(6,8)[:,4:],err_msg=name)
    assert len(actual) == len(records)
    assert all(isinstance(row,dict) and row.get('error') for row in actual[good_count:])
    print(json.dumps(dict(cases=good_count,rejections=len(records)-good_count,
                         max_abs=maximum,build_seconds=build_seconds,native_seconds=seconds,
                         python_cv=cv2.__version__),indent=2))

if __name__ == '__main__':
    run()
