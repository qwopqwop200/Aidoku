#!/usr/bin/env python3
"""Native source adapter + real FT/Pillow glyphs + unmodified Python bands oracle."""
import base64
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'Scripts/font_weight_estimation'))
import cv2
import numpy as np
from PIL import ImageFont
from fontTools.ttLib import TTFont
import affine_pairs
import weight_bands
from native_pairs import glyph, reference_font
from font_metric_features import default_font_paths, glyph_measurement
from optimized_features.fill_alpha import predicted_fill_alpha


def matrix(a):
    a=np.ascontiguousarray(a)
    return dict(width=a.shape[1],height=a.shape[0],type={np.dtype('uint8'):0,np.dtype('float32'):5,np.dtype('float64'):6}[a.dtype]+(16 if a.ndim==3 else 0),
                data=base64.b64encode(a.tobytes()).decode())


def decoded(r):
    if r is None:return None
    return np.frombuffer(base64.b64decode(r['data']),np.uint8).reshape(r['height'],r['width'])


def anchor_metric(path,face,weight,cp):
    with TTFont(path,fontNumber=face,lazy=True) as f:
        if cp not in f.getBestCmap():return None
    font=ImageFont.truetype(path,256,index=face)
    if weight is not None:
        axes=font.get_variation_axes();values=[float(a['default']) for a in axes]
        values[next(i for i,a in enumerate(axes) if a['name']==b'Weight')]=weight
        font.set_variation_by_axes(values)
    mask=font.getmask(chr(cp),mode='L')
    area=np.count_nonzero(np.asarray(mask,np.uint8)>=64)
    return float(np.sqrt(area/256**2)) if area else None


def run():
    pairs=json.loads((ROOT.parent/'font-weight-estimation-20261111/reference-bank/STRONG-NORMAL-BLACK-PAIRS.json').read_text())['pairs']
    assert len(pairs)==4
    w3=default_font_paths()[0]
    anchor=dict(key='baseline:original-W3#face=0',path=w3,face=0)
    records=[];expected=[];names=[];kinds=[]
    def base(rgb,alpha,text='あぬ漢語A2',em=31,angle=0,bbox=None):
        h,w=alpha.shape
        return dict(rgb=matrix(rgb),alpha=matrix(alpha),bbox=bbox or [0,0,w,h],prior=17.25,
                    em=em,angle=angle,text=text,anchor=anchor)
    def add(name,r,want,kind):
        records.append(r);expected.append(want);names.append(name);kinds.append(kind)
    # Full unmodified measure, including the actual predicted alpha producer.
    # C++ receives that already-computed alpha, as required by this adapter API.
    for i,pair in enumerate(pairs):
        for heavy in [False,True]:
            a=np.zeros((91,143),np.float32)
            for cp,y,x in [('あ',7,8),('漢',48,83)]:
                r,h=affine_pairs.transformed_pair(glyph(pair['regular'],cp),glyph(pair['heavy'],cp),31,.9 if i%2 else 1.,-4 if i%2 else 0)
                v=h if heavy else r;a[y:y+v.shape[0],x:x+v.shape[1]]=v
            for mode,fill,bg,angle in [('dark',[0,0,0],[255,255,255],0),('pale',[255,255,255],[0,0,0],9),('color',[230,35,55],[90,130,150],-.1001)]:
                fill=np.array(fill);bg=np.array(bg)
                rgb=np.rint(bg+(fill-bg)*a[:,:,None]).astype(np.uint8)
                own=np.ones(a.shape,bool)
                style=dict(fill=dict(rgb=fill.tolist()),background=dict(rgb=bg.tolist()),outline=dict(present=False))
                bbox=[2.5,1.25,138,88.5]
                alpha=predicted_fill_alpha(rgb,bbox,own,style)
                args=(rgb,bbox,31,'あぬ漢語A2',own,style,pairs,angle)
                pose=affine_pairs.measure(*args);bands=weight_bands.measure(*args)
                add(f'full-{i}-{heavy}-{mode}',base(rgb,alpha,angle=angle,bbox=bbox),dict(poses=pose,bands=bands),'measure')
    for text,shape,angle in [('',(37,53),0),('!?ぁっ🙂\u0301',(41,79),0),('か\u3099ガがé𝟙\u0378',(51,89),4),('あ漢',(491,509),7)]:
        rng=np.random.default_rng(731);rgb=rng.integers(0,256,(*shape,3),dtype=np.uint8)
        style=dict(fill=dict(rgb=[0,0,0]),background=dict(rgb=[255,255,255]))
        own=np.ones(shape,bool);bbox=[0,0,shape[1],shape[0]]
        alpha=predicted_fill_alpha(rgb,bbox,own,style)
        args=(rgb,bbox,29.75,text,own,style,pairs,angle)
        add('misc-'+repr(text)+repr(shape),base(rgb,alpha,text,29.75,angle),
            dict(poses=affine_pairs.measure(*args),bands=weight_bands.measure(*args)),'measure')
    # Exercise alias absence (path itself is the original key), with fresh
    # same-call resources, not a global digest/glyph cache.
    plain=copy.deepcopy(records[0]);plain['anchor']=dict(key=w3)
    add('plain-anchor-path',plain,expected[0],'measure')
    # Direct byte oracles for the exact provider used inside the public API.
    cps=[0,ord(' '),ord('あ'),ord('ぬ'),ord('漢'),ord('語'),ord('A'),ord('é'),ord('が'),0x378,0x1f600,0x1d7d9]
    for desc in [anchor,dict(key='prefix:Mincho#face=2',path=default_font_paths()[3],face=2),
                 dict(key='prefix:weighted#bits700',path=pairs[0]['regular']['path'],face=0,weight=700),
                 dict(key='prefix:weighted#bits700.5',path=pairs[0]['regular']['path'],face=0,weight=700.5)]:
        r=copy.deepcopy(records[0]);r.update(op='resources',anchor=desc,codepoints=cps)
        want=dict(anchors=[anchor_metric(desc['path'],desc['face'],desc.get('weight'),cp) for cp in cps],
                  rasters=[[glyph(p['regular' if face==0 else 'heavy'],chr(cp)) for p in pairs for face in range(2)] for cp in cps])
        add('resources-'+desc['key'],r,want,'resources')
    # Fractional reference weights exercise the discovered Pillow13 integer
    # coordinate conversion in both actual glyph bytes and full downstream fit.
    fractional=copy.deepcopy(pairs);fractional[0]['regular']['weight']=700.5
    r=copy.deepcopy(records[0]);r.update(op='resources',pairs=fractional,codepoints=cps)
    add('fractional-reference-resources',r,
        dict(anchors=[anchor_metric(w3,0,None,cp) for cp in cps],
             rasters=[[glyph(p['regular' if face==0 else 'heavy'],chr(cp)) for p in fractional for face in range(2)] for cp in cps]),'resources')
    rgb=np.full((63,101,3),255,np.uint8);rgb[12:47,21:78]=0
    own=np.ones(rgb.shape[:2],bool);bbox=[0,0,101,63]
    style=dict(fill=dict(rgb=[0,0,0]),background=dict(rgb=[255,255,255]))
    alpha=predicted_fill_alpha(rgb,bbox,own,style)
    args=(rgb,bbox,31,'あ漢',own,style,fractional,0)
    r=base(rgb,alpha,text='あ漢');r['pairs']=fractional
    add('fractional-reference-full',r,dict(poses=affine_pairs.measure(*args),bands=weight_bands.measure(*args)),'measure')
    # These calls prove unsupported references use their own .notdef while the
    # old default and strict APIs retain their distinct existing behavior.
    r=copy.deepcopy(records[0]);r.update(op='legacy',cp=0x378)
    def raw_pillow(font,cp):
        mask=font.getmask(chr(cp),mode='L')
        return np.asarray(mask,np.uint8).reshape(mask.size[1],mask.size[0])
    add('legacy-notdef',r,dict(default=raw_pillow(ImageFont.truetype(pairs[0]['regular']['path'],128),0x378),
        reference=raw_pillow(reference_font(pairs[0]['regular']['path'],pairs[0]['regular']['SHA256'],pairs[0]['regular']['weight']),0x378)),'legacy')
    good=len(records)
    # Invalid resources must fail even when no alpha/text witness is available.
    empty=base(np.zeros((9,13,3),np.uint8),np.zeros((9,13),np.float32),text='')
    invalid=[]
    def bad_pair(field,value,face='regular',pair_index=0):
        r=copy.deepcopy(empty);r['pairs']=copy.deepcopy(pairs);r['pairs'][pair_index][face][field]=value;invalid.append(r)
    bad_pair('SHA256','0'*64)
    bad_pair('SHA256','INVALID')
    bad_pair('path','/missing/reference.ttf')
    bad_pair('weight',-1)
    bad_pair('weight',10000)
    bad_pair('weight',400,pair_index=1) # static TTF has no axis
    bad_pair('path',pairs[1]['regular']['path']) # actual bytes with another identity
    for desc in [dict(key='bad',path='/missing/anchor.ttc',face=0),dict(key='bad',path=w3,face=999),
                 dict(key='bad',path=w3,face=0,weight=400),dict(key='bad',path=pairs[0]['regular']['path'],face=0,weight=-1)]:
        r=copy.deepcopy(empty);r['anchor']=desc;invalid.append(r)
    r=copy.deepcopy(records[0]);r['alpha']=matrix(np.zeros((2,2),np.float32));invalid.append(r)
    records.extend(invalid)
    # Revalidate after wrong digest/weight calls to detect accidental cache reuse.
    records.append(copy.deepcopy(records[0]));expected.append(expected[0]);names.append('after-invalids');kinds.append('measure')
    vendor=ROOT/'Vendor/NativeSourceCV';source=ROOT/'Vendor/SourceInference'
    start=time.monotonic()
    with tempfile.TemporaryDirectory(prefix='aidoku-band-source-') as temp:
        temp=Path(temp);binary=temp/'source'
        cmd=['xcrun','clang++','-std=c++17','-O2','-fobjc-arc','-I'+str(vendor/'include'),'-I'+str(vendor/'freetype/include'),'-I'+str(source),
             str(Path(__file__).with_name('main.mm')),str(source/'FontWeightBands.mm'),str(vendor/'NativeSourceCV.cpp'),
             str(vendor/'opencv2.xcframework/macos-arm64/libopencv2.a'),str(vendor/'FreeType.xcframework/macos-arm64/libfreetype.a'),'-lz']
        for fw in ['Foundation','Accelerate','CoreGraphics','CoreVideo','AVFoundation','CoreMedia','OpenCL']:cmd+=['-framework',fw]
        subprocess.run(cmd+['-o',str(binary)],check=True);build=time.monotonic()-start
        (temp/'input.json').write_text(json.dumps(dict(pairs=pairs,records=records)))
        start=time.monotonic();subprocess.run([str(binary),str(temp/'input.json'),str(temp/'output.json')],check=True)
        duration=time.monotonic()-start;actual=json.loads((temp/'output.json').read_text())
    assert len(actual)==len(records)
    assert all(isinstance(r,dict) and r.get('error') for r in actual[good:good+len(invalid)]),actual[good:good+len(invalid)]
    # Successful final repeat is placed after invalids in the actual packet.
    outputs=actual[:good]+actual[-1:]
    maxima=dict(poses=0.,bands=0.,anchors=0.);pixel_checks=0
    for name,kind,want,got in zip(names,kinds,expected,outputs):
        assert 'error' not in got,(name,got)
        if kind=='measure':
            for field in ['poses','bands']:
                maxima[field]=max(maxima[field],float(np.max(np.abs(want[field]-got[field]))))
                np.testing.assert_allclose(got[field],want[field],atol=2e-6,rtol=2e-6,err_msg=name+' '+field)
            np.testing.assert_array_equal(np.asarray(got['poses']).reshape(8,24)[:,[4,14,15,16,17,20]],
                                          want['poses'].reshape(8,24)[:,[4,14,15,16,17,20]],err_msg=name)
        elif kind=='resources':
            for a,b in zip(want['anchors'],got['anchors']):
                if a is None:assert b is None,(name,a,b)
                else:maxima['anchors']=max(maxima['anchors'],abs(a-b));assert a==b,(name,a,b)
            for aa,bb in zip(want['rasters'],got['rasters']):
                for a,b in zip(aa,bb):
                    if a is None:assert b is None,name
                    else:np.testing.assert_array_equal(decoded(b),a,err_msg=name)
                    pixel_checks+=1
        elif kind=='legacy':
            assert got['defaultCode']==0 and got['strictCode']!=0 and got['referenceCode']==0
            np.testing.assert_array_equal(decoded(got['default']),want['default'])
            np.testing.assert_array_equal(decoded(got['reference']),want['reference'])
    print(json.dumps(dict(measure_cases=kinds.count('measure'),resource_cases=kinds.count('resources'),
                         glyph_pixel_checks=pixel_checks,anchor_checks=len(cps)*kinds.count('resources'),legacy_api_cases=1,invalid=len(invalid),
                         max_abs=maxima,build_seconds=build,native_seconds=duration,
                         python_cv=cv2.__version__,native_freetype='2.14.3',icu_linked=False),indent=2))

if __name__=='__main__':run()
