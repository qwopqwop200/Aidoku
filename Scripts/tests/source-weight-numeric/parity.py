#!/usr/bin/env python3
"""Synthetic/crop-only oracle comparison; builds solely in TemporaryDirectory.
Run with .venv-source-inference/bin/python; no app, models or shared build cache.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
sys.dont_write_bytecode = True
import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[3]
SIZE = ROOT / 'Scripts/font_size_estimation'
WEIGHT = ROOT / 'Scripts/font_weight_estimation'
sys.path[:0] = [str(WEIGHT), str(SIZE)]

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

weight = load('features', WEIGHT / 'features.py')
fill = load('weight_fill_oracle', WEIGHT / 'fill_body.py')
from estimator import features as estimator
from morphology_features import grouped_body_features
from glyph_body_features import glyph_body_features
from font_metric_features import font_metric_features, default_font_paths
from pixel_rules import observe
KEYS = ('quality', 'glyphCount', 'bodyThickness', 'thinStroke', 'broadStroke', 'hollowFraction', 'occupancy')
STYLE = {'fill': {'rgb': [24,80,210]}, 'background': {'rgb': [240,230,220]},
         'outline': {'present': True, 'widthPx': 1.7}}


def cases():
    # Repeated synthetic fragmented strokes, rings, slanted polygons, clipped
    # components, dark/light/colored bodies and antialiased source pixels.
    for seed in range(16):
        rng = np.random.default_rng(seed)
        h,w = [(83,137),(141,71),(17,23),(97,109)][seed%4]
        rgb = np.full((h,w,3), [245,245,245] if seed%2 else [14,22,18], np.uint8)
        for i in range(12):
            x,y = int(rng.integers(-4,w)),int(rng.integers(-4,h))
            color = [(0,0,0),(255,255,255),(220,25,70),(25,130,230)][i%4]
            if i%3==0:
                cv2.rectangle(rgb,(x,y),(x+9+i%5,y+14+i%7),color,1+i%4)
            elif i%3==1:
                cv2.line(rgb,(x,y),(x+13,y+18),color,2+i%3,cv2.LINE_AA)
            else:
                cv2.fillPoly(rgb,[np.array([[x,y],[x+7,y-3],[x+14,y+16],[x+3,y+18]])],color)
        bbox = (-2.4,1.7,w+1.1,h-3.2) if seed%3 else (3.1,4.4,w-5.8,h-6.6)
        prior = [18.,25.,5.,30.,.75,50.][seed%6]
        alpha = rng.random((h,w)).astype(np.float32 if seed%2 else np.float64)
        alpha[alpha<.6]=0
        if seed%4==0: alpha[:]=0
        if seed%5==0: alpha[:]=1
        own=(rng.random((h,w))>.3).astype(np.uint8)
        yield f'synthetic-{seed}',rgb,bbox,prior,alpha,own
    # Explicit resizing at both 640 and 800; banker-rounding morphology radius.
    for seed,(h,w,prior) in enumerate([(89,1001,50.),(903,67,125.),(57,641,25.),(801,73,75.)]):
        rgb=np.full((h,w,3),237,np.uint8)
        for y in range(3,h,21):
            for x in range(2,w,23):cv2.rectangle(rgb,(x,y),(x+11,y+16),(10,10,10),2)
        alpha=(rgb[:,:,0]<100).astype(np.float32)
        yield f'resize-{seed}',rgb,(0.,0.,float(w),float(h)),prior,alpha,np.ones((h,w),np.uint8)
    for value in [0,255]:
        rgb=np.full((5,7,3),value,np.uint8)
        yield f'blank-{value}',rgb,(0.,0.,7.,5.),.1,np.zeros((5,7),np.float64),np.zeros((5,7),np.uint8)
    # More than six equally frequent palette modes exercise unstable selection.
    for seed in range(8):
        rgb=np.full((127,173,3),128,np.uint8)
        rng=np.random.default_rng(8090+seed)
        codes=rng.choice(512,32,replace=False)
        for i,code in enumerate(codes):
            color=(int(code//64)*32+8,int(code//8%8)*32+8,int(code%8)*32+8)
            x=3+(i%8)*21;y=3+(i//8)*30
            width,height=[(3,12),(4,9),(6,6),(9,4)][i%4]
            rgb[y:y+height,x:x+width]=color
        alpha=(rgb[:,:,0]/255).astype(np.float32)
        yield f'palette-ties-{seed}',rgb,(0.,0.,173.,127.),18.,alpha,np.ones((127,173),np.uint8)
    # Alpha mass near the discrete >1 gate must retain float32 sum semantics.
    for seed,n in enumerate([9,17,127,8193]):
        h,w=(19,503) if n>800 else (1,n)
        rgb=np.full((h+2,w+2,3),128,np.uint8)
        alpha=np.zeros((h+2,w+2),np.float32)
        alpha[1:h+1,1:w+1]=np.float32(1/(h*w))
        yield f'alpha-mass-gate-{seed}',rgb,(1.,1.,float(w),float(h)),12.,alpha,np.ones((h+2,w+2),np.uint8)
    # Singleton target exercises empty np.array_split cells and no contours.
    yield 'singleton',np.full((1,1,3),120,np.uint8),(0.,0.,1.,1.),1.,np.ones((1,1),np.float32),np.ones((1,1),np.uint8)


def main():
    vendor=ROOT/'Vendor/NativeSourceCV'
    source=ROOT/'Vendor/SourceInference/Sources'
    start=time.monotonic()
    with tempfile.TemporaryDirectory(prefix='aidoku-weight-numeric-') as tmp:
        tmp=Path(tmp); binary=tmp/'parity'
        subprocess.run(['xcrun','clang++','-std=c++17','-O2','-I'+str(vendor/'include'),'-I'+str(source),
                        str(Path(__file__).with_name('main.cpp')),
                        str(vendor/'opencv2.xcframework/macos-arm64/libopencv2.a'),
                        '-framework','Accelerate','-framework','CoreGraphics','-framework','Foundation',
                        '-framework','CoreVideo','-framework','AVFoundation','-framework','CoreMedia',
                        '-framework','OpenCL','-lz','-o',str(binary)],check=True)
        build_seconds=time.monotonic()-start;start=time.monotonic()
        # Quantized palette ties can alter the top-six set and hence direct7.
        rng=np.random.default_rng(7101)
        distributions=[np.ones(n,dtype=np.int64) for n in [1,6,7,16,17,20,32,512]]
        distributions += [rng.integers(1,12,size=int(rng.integers(1,513)),dtype=np.int64) for _ in range(200)]
        distributions += [np.arange(512,dtype=np.int64),np.arange(512,dtype=np.int64)[::-1]]
        request=''.join(str(len(v))+' '+' '.join(map(str,v))+'\n' for v in distributions)
        lines=subprocess.check_output([str(binary),'--palette'],input=request,text=True).splitlines()
        for values,line in zip(distributions,lines,strict=True):
            np.testing.assert_array_equal(np.fromstring(line,sep=' ',dtype=int),np.argsort(values))
        maximum={};count=0
        for name,rgb,bbox,prior,alpha,own in cases():
            base=estimator(rgb,bbox,prior,version=5);base[:6]=0
            glyph=glyph_body_features(rgb,bbox,prior,np.ones(rgb.shape[:2],bool))
            metrics=font_metric_features('日あA',base[:156],default_font_paths())
            raw=weight.measure(rgb,bbox,prior,'日あA')
            x,y,w,h=bbox
            target=rgb[max(0,int(y)):min(len(rgb),int(np.ceil(y+h))),max(0,int(x)):min(rgb.shape[1],int(np.ceil(x+w)))]
            scale=min(1.,640/max(target.shape[:2]))
            if scale<1:target=cv2.resize(target,None,fx=scale,fy=scale,interpolation=cv2.INTER_AREA)
            lo=target.min(2);hi=target.max(2);chroma=hi.astype(float)-lo
            gray=cv2.cvtColor(target,cv2.COLOR_RGB2GRAY)
            _,dark=cv2.threshold(gray,0,1,cv2.THRESH_BINARY_INV+cv2.THRESH_OTSU)
            stroke=np.r_[tuple(weight.stroke_summary(m,max(1.,prior*scale)) for m in [dark,1-dark,hi<70,(lo>200)&(chroma<45),chroma>75])]
            direct=observe(rgb,bbox,prior)
            # Supply caller's alpha; actual fill_body.measure still performs all
            # v1 cropping/resizing, strokes, moments and style diagnostics.
            fill.predicted_fill_alpha=lambda *args:alpha
            expected={'extra40':base[156:], 'stroke55':stroke,
                      'grouped144':grouped_body_features(rgb,bbox,prior),
                      'direct7':np.array([direct[k] for k in KEYS]),
                      'fill71v1':fill.measure(rgb,bbox,prior,own,STYLE,version=1), 'raw597':raw}
            inp=tmp/'input';out=tmp/'output'
            with inp.open('wb') as f:
                f.write(np.array([len(rgb),rgb.shape[1],alpha.dtype==np.float64],'<i4').tobytes())
                f.write(np.array([*bbox,prior],'<f8').tobytes());f.write(rgb.tobytes());f.write(alpha.tobytes());f.write(own.tobytes())
                f.write(np.r_[base[:156],glyph,metrics].astype('<f8').tobytes())
            mask=subprocess.check_output([str(binary),str(inp),str(out)],text=True).strip()
            actual=np.fromfile(out,dtype='<f8');offset=0
            for key,reference in expected.items():
                got=actual[offset:offset+len(reference)];offset+=len(reference)
                error=float(np.max(np.abs(got-reference)));maximum[key]=max(maximum.get(key,0),error)
                np.testing.assert_allclose(got,reference,atol=1e-7,rtol=1e-7,err_msg=f'{name}/{key}')
            assert offset==len(actual) and np.all(actual[-597:-591]==0)
            assert mask==direct['mask'],(name,mask,direct['mask'])
            count+=1
        print(json.dumps({'cases':count,'paletteArgsortCases':len(distributions),'absoluteMaximumErrors':maximum,'atol':1e-7,'rtol':1e-7,
                          'buildSeconds':build_seconds,'testSeconds':time.monotonic()-start,
                          'numpy':np.__version__,'opencv':cv2.__version__},indent=2))

if __name__=='__main__':main()
