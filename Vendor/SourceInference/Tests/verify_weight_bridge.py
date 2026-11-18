#!/usr/bin/env python3
"""Original Python numeric oracle; synthetic bounded RGB only, private temp build.
Run: PYTHONDONTWRITEBYTECODE=1 .venv-source-inference/bin/python Vendor/SourceInference/Tests/verify_weight_bridge.py
No models, GT, source IDs, whole pages, production/shared build or oracle patches.
"""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT/'Scripts/tests/source-weight-numeric')]
from parity import cases, weight, fill, observe, KEYS, default_font_paths
from physical_templates import measure as physical_measure, font_pairs
from active_weight_model import load_accepted_model
from source_runtime import _legacy_residual, _source_angle
from weight_bands import measure as band_measure
from line_weights import qualified_analyze
import numpy as np


def main():
    vendor = ROOT/'Vendor/NativeSourceCV'
    source = ROOT/'Vendor/SourceInference'
    fonts = default_font_paths()
    spec = dict(fonts=fonts, extendedFonts=fonts+fonts, nativeFonts=fonts)
    physical_pairs=[[dict(path=a,faceIndex=ai),dict(path=b,faceIndex=bi)] for a,ai,b,bi in font_pairs()]
    bundle, _ = load_accepted_model(ROOT/'Scripts/font_weight_estimation/assets/accepted-complete/model.pkl.gz')
    packets, expected = [], []
    for index, (name, rgb, _, prior, _, own) in enumerate(cases()):
        h, w = rgb.shape[:2]
        # At most 15% context on every side; both fractional and full bboxes.
        bbox = [2.1, 2.3, w-4.2, h-4.6] if min(h,w)>40 and index%2 else [0,0,w,h]
        style = {'fill': {'rgb': [24,80,210]}, 'background': {'rgb': [240,230,220]},
                 'outline': {'present': True, 'widthPx': 1.7, 'rgb': [0,0,0]}}
        if index % 3 == 0:
            style={'fill':{'rgb':[255,255,255]},'background':{'rgb':[0,0,0]},
                   'outline':{'present':False,'widthPx':0.,'rgb':[0,0,0]}}
        text = ['日あA', 'か\u3099 Ａ\n日', '', 'A\u0301\tあ\u200d'][index%4]
        # Final em deliberately differs from prior; test true predicted alpha.
        em = prior*1.37
        for variant in range(2):
            ownership = own if variant == 0 else np.ones((h,w), np.uint8)
            direct = observe(rgb,bbox,prior)
            reference = dict(raw597=weight.measure(rgb,bbox,prior,text),
                             direct7=np.array([direct[k] for k in KEYS]),
                             fill71=fill.measure(rgb,bbox,em,ownership,style,version=1),
                             paired48=physical_measure(rgb,bbox,em,text,scales=(.85,.95,1.,1.05,1.15)))
            reference['qualifiedMixed']=np.array(qualified_analyze(rgb,bbox,em,style)['sourceWeight']=='mixed',float)
            expected.append((name, reference))
            packets.append(dict(width=w,height=h,rgb=base64.b64encode(rgb.tobytes()).decode(),
                                ownership=base64.b64encode((ownership*(255 if index%2 else 1)).tobytes()).decode(),
                                bbox=bbox,prior=prior,text=text,sourceEm=em,style=style,measurementSpec=spec,physicalFontPairs=physical_pairs,
                                # Deliberately stale caller vectors must be ignored.
                                native156=[999.]*156))
            if index < 2:
                x,y,bw,bh=bbox
                polygons=[[[x,y],[x+bw,y],[x+bw,y+bh],[x,y+bh]]]
                original=dict(rgb=rgb,bbox=bbox,prior=prior,ownership=ownership,
                              text=text,style=style,memberPolygons=polygons)
                angle=_source_angle(original)
                reference['weightStyle187']=_legacy_residual(original,rgb,bbox,prior,ownership,fonts,fonts)
                reference['weightAngle131']=np.array(angle)
                reference['bands112']=band_measure(rgb,bbox,em,text,ownership,style,bundle['referencePairs'],angle)
                packets[-1].update(weightMemberPolygons=polygons,referencePairs=bundle['referencePairs'])
            if index == 1 and variant == 1:
                packets[-1]['physicalFontPairs']=[physical_pairs[0],dict(available=False),physical_pairs[2]]
                reference['paired48'][16:32]=0
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='aidoku-weight-bridge-') as directory:
        directory = Path(directory)
        binary = directory/'check'
        sources = [source/'Tests/FontWeightFeaturesMain.mm', source/'FontWeightFeatures.mm',
                   source/'FontTemplateFeatures.mm', source/'FontWeightPhysical.mm',
                   source/'FontWeightBands.mm',source/'FontWeightBandSource.mm',source/'Sources/SourceCoreFeatures.cpp',
                   source/'Sources/SourceWeightFeatures.cpp', vendor/'NativeSourceCV.cpp']
        cmd = ['xcrun','clang++','-std=c++17','-O2','-fobjc-arc',
               '-I'+str(vendor/'include'),'-I'+str(vendor/'freetype/include'), *map(str,sources),
               str(vendor/'opencv2.xcframework/macos-arm64/libopencv2.a'),
               str(vendor/'FreeType.xcframework/macos-arm64/libfreetype.a'),'-lz']
        for framework in ['Foundation','CoreText','CoreGraphics','Accelerate','CoreVideo','AVFoundation','CoreMedia','OpenCL']:
            cmd += ['-framework',framework]
        subprocess.run(cmd+['-o',str(binary)],check=True)
        build_seconds = time.monotonic()-start
        inp, out = directory/'input.json', directory/'output.json'
        inp.write_text(json.dumps(packets))
        start = time.monotonic()
        subprocess.run([str(binary),str(inp),str(out)],check=True)
        native_seconds = time.monotonic()-start
        actual = json.loads(out.read_text())
        assert len(actual) == len(expected)
        errors = {}
        failures = []
        for i, ((name, reference), result) in enumerate(zip(expected,actual)):
            for key, value in reference.items():
                got = np.asarray(result[key],dtype=float)
                assert got.shape == value.shape
                errors[key] = max(errors.get(key,0),float(np.max(abs(got-value))))
                bad = np.flatnonzero(~np.isclose(got,value,atol=1e-7,rtol=1e-7))
                if len(bad): failures.append(dict(case=i,name=name,key=key,indices=bad.tolist(),actual=got[bad].tolist(),expected=value[bad].tolist()))
            assert result['raw597'][:6] == [0]*6
            if i%2:
                assert result['raw597'] == actual[i-1]['raw597']
                assert result['direct7'] == actual[i-1]['direct7']
        print(json.dumps(dict(failures=failures,cases=len(actual), maxAbsoluteErrors=errors, atol=1e-7,rtol=1e-7,
                              isolatedBuildSeconds=build_seconds,nativeSeconds=native_seconds,
                              numpy=np.__version__, hostOnly=True),indent=2))
        assert not failures, 'Native/Python parity gaps listed above'


if __name__ == '__main__': main()
