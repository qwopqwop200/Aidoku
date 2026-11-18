#!/usr/bin/env python3
"""Isolated actual affine_pairs/weight_bands numeric oracle, caller alpha boundary."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unicodedata
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'Scripts/font_weight_estimation'))
import cv2
import numpy as np
import affine_pairs
import weight_bands
from native_pairs import glyph, SCALES
from font_metric_features import default_font_paths, glyph_measurement
from optimized_features.templates import anchor_chars, rotate


def matrix(a):
    a = np.ascontiguousarray(a)
    return dict(width=a.shape[1],height=a.shape[0],type={np.dtype('uint8'):0,np.dtype('float32'):5,np.dtype('float64'):6}[a.dtype],
                data=base64.b64encode(a.tobytes()).decode())


def run():
    pairs = json.loads((ROOT.parent/'font-weight-estimation-20261111/reference-bank/STRONG-NORMAL-BLACK-PAIRS.json').read_text())['pairs']
    assert len(pairs)==4 and SCALES==(.85,.95,1.,1.05,1.15)
    policy = dict(minimumAddedStem=.6, minimumCommonBody=.65,minimumGlyphFit=.55,maximumReconstructionError=.08)
    records, expected, names, kinds = [], [], [], []
    resources, anchors = {}, {}
    ref = default_font_paths()[0]
    def prepare(text):
        for cp in set(unicodedata.normalize('NFC',text)):
            dims = glyph_measurement(ref,cp)
            anchors[str(ord(cp))] = None if dims is None else dims[4]
        chars = anchor_chars(text,ref,256,exclude_small=True)
        witnesses = [c for c in chars if 0x3040<=ord(c)<=0x30ff][:2]+[c for c in chars if not 0x3040<=ord(c)<=0x30ff][:2]
        for face in range(8):
            for cp in witnesses:
                raster = glyph(pairs[face//2]['heavy' if face%2 else 'regular'],cp)
                resources[(face,ord(cp))] = None if raster is None else matrix(raster)
    def add_measure(name,alpha,em,text,angle=0,bbox=None,poses=None):
        prepare(text)
        # Replace only the input producer, not any downstream arithmetic,
        # rasterization, anchor selection, transformations, fit or band stats.
        affine_pairs.predicted_fill_alpha = lambda *args: alpha
        weight_bands.predicted_fill_alpha = lambda *args: alpha
        bbox = bbox or [0,0,alpha.shape[1],alpha.shape[0]]
        args=(None,bbox,em,text,None,None,pairs,angle)
        pose = affine_pairs.measure(*args) if poses is None else np.asarray(poses)
        bands = weight_bands.measure(*args,poses=poses)
        implicit = weight_bands.measure(*args,poses=pose)
        np.testing.assert_array_equal(bands,implicit)
        confirmed=bool(weight_bands.confirmation(bands[None],policy)[0])
        r=dict(op='measure',alpha=matrix(alpha),em=em,text=text,angle=angle,bbox=bbox,policy=policy)
        if poses is not None:r['poses']=pose.tolist()
        records.append(r);expected.append(dict(poses=pose,bands=bands,confirmed=confirmed));names.append(name);kinds.append('measure')
        return pose,bands
    def add_fit(name,alpha,r,h,em):
        records.append(dict(op='fit',alpha=matrix(alpha),regular=matrix(r),heavy=matrix(h),em=em))
        expected.append(affine_pairs.fit(alpha,r,h,em));names.append(name);kinds.append('fit')
    def add_stats(name,s,a,b,score=.6):
        records.append(dict(op='stats',source=matrix(s),regular=matrix(a),heavy=matrix(b),score=score))
        expected.append(weight_bands.band_stats(s,a,b,score));names.append(name);kinds.append('stats')
    rng=np.random.default_rng(991)
    text='あぬ漢語A2'
    # Use each real reference pair/weight and both groups in source-like alpha.
    for i,pair in enumerate(pairs):
        for face in ['regular','heavy']:
            for aspect,angle in [(1.,0.),(.9,-4.)]:
                a,b=affine_pairs.transformed_pair(glyph(pair['regular'],'あ'),glyph(pair['heavy'],'あ'),30,aspect,angle)
                canvas=np.zeros((90,130),np.float32)
                v=a if face=='regular' else b
                canvas[8:8+v.shape[0],9:9+v.shape[1]]=v
                a,b=affine_pairs.transformed_pair(glyph(pair['regular'],'漢'),glyph(pair['heavy'],'漢'),30)
                v=a if face=='regular' else b
                canvas[43:43+v.shape[0],65:65+v.shape[1]]=v
                add_measure(f'family{i}-{face}-{aspect}-{angle}',canvas,30,text)
    # First-winner constant ties, missing/non-fitting and one-sided groups.
    for value in [0.,.001,1.]:
        add_measure('constant-'+str(value),np.full((49,77),value,np.float32),27,'あぬ漢語')
    for t in ['', '!?ぁっゃァッ 🙂\u0301', 'あぬ', '漢語A2','か\u3099ガがé𝟙\u0378']:
        add_measure('text-'+repr(t),rng.random((53,89),dtype=np.float32),26,t)
    add_measure('no-fit',np.ones((2,3),np.float32),128,text)
    add_measure('global-limit256',rng.random((51,81),dtype=np.float32),25,'あぬ'+''.join(chr(0x4e00+i) for i in range(275)))
    for shape,angle,dtype in [((81,99),.1,np.float32),((81,99),.1001,np.float32),
                              ((101,157),-13,np.float64),((493,511),7,np.float32),((81,901),0,np.float64)]:
        add_measure(f'resize-angle-{shape}-{angle}',rng.random(shape).astype(dtype),31.5,'あ漢',angle,[2.25,1.5,shape[1]-4.5,shape[0]-3])
    # Alpha mass gate just below/at one (float32 pairwise summation).
    for total in [.9999999,1.,1.0000001]:
        alpha=np.zeros((39,51),np.float32);alpha.ravel()[:3]=np.float32(total/3)
        add_measure('mass-'+str(total),alpha,22,'あ漢')
    # Supplied poses: pose-equality recovery rather than always strongest glyph.
    alpha=rng.random((63,91),dtype=np.float32)
    poses,_=add_measure('provided-base',alpha,28,text)
    provided=poses.copy().reshape(4,2,24)
    for i in range(4):
        for g,cp in enumerate(['あ','漢']):
            p=provided[i,g]
            ab=affine_pairs.transformed_pair(glyph(pairs[i]['regular'],cp),glyph(pairs[i]['heavy'],cp),28*p[4],p[16],p[17]*4)
            found=affine_pairs.locate(alpha,*ab)
            if found is not None:p[0]=found[0]
    add_measure('provided-pose-witness',alpha,28,text,poses=provided.ravel())
    # Direct fit tests include exact coarse >.85 and uncertain refinement.
    r,h=glyph(pairs[0]['regular'],'あ'),glyph(pairs[0]['heavy'],'あ')
    for factor in SCALES:
        a,b=affine_pairs.transformed_pair(r,h,31*factor)
        for image,face in [(a,'regular'),(b,'heavy')]:
            add_fit(f'coarse-{factor}-{face}',np.pad(image,((4,7),(5,11))),r,h,31)
    for aspect,angle in [(.9,-4.),(.9,4.),(1.1,-4.),(1.1,4.)]:
        a,b=affine_pairs.transformed_pair(r,h,31,aspect,angle)
        add_fit(f'refine-{aspect}-{angle}',np.pad(b,7),r,h,31)
    add_fit('fit-first-tie',np.ones((71,81),np.float32),r,h,31)
    add_fit('fit-no-pose',np.zeros((1,1),np.float32),r,h,31)
    # Direct band stats isolate energy gate, quantiles and clipping.
    for shape in [(1,1),(3,7),(29,33)]:
        a=rng.random(shape).astype(np.float32);b=rng.random(shape).astype(np.float32)
        for c in [-3.,0.,.4,1.,4.]:add_stats(f'stats-{shape}-{c}',a+c*(b-a),a,b)
    for energy in [np.nextafter(1.,0.),1.,np.nextafter(1.,2.)]:
        a=np.zeros((1,1),np.float64);b=np.full((1,1),np.sqrt(energy))
        add_stats('energy-'+repr(energy),b,a,b)
    add_stats('identical',np.ones((4,4),np.float32),np.ones((4,4),np.float32),np.ones((4,4),np.float32))
    # Runtime confirmation's first argmax and inclusive boundary comparisons.
    confirm_cases=[]
    for field,threshold in [(0,.6),(5,.65),(12,.55),(4,.08)]:
        for v in [np.nextafter(threshold,-np.inf),threshold,np.nextafter(threshold,np.inf)]:
            bands=np.zeros((8,14));bands[0,[0,5,12,4]]=[.6,.65,.55,.08];bands[0,field]=v
            confirm_cases.append(bands.ravel())
    bands=np.zeros((8,14));bands[0,[0,5,12,4]]=[0,0,.8,1];bands[1,[0,5,12,4]]=[1,1,.8,0];confirm_cases.append(bands.ravel())
    confirm_cases.append(np.zeros(112))
    for i,bands in enumerate(confirm_cases):
        records.append(dict(op='confirm',bands=bands.tolist(),policy=policy))
        expected.append(bool(weight_bands.confirmation(bands[None],policy)[0]));names.append(f'confirm-{i}');kinds.append('confirm')
    good=len(records)
    invalid=[dict(records[0],em=0),dict(records[0],em=-1),dict(records[0],alpha=matrix(np.full((4,4),-.1,np.float32))),
             dict(records[0],alpha=matrix(np.full((4,4),np.nan,np.float32))),dict(records[0],bbox=[0,0,0,2])]
    records.extend(invalid)
    packet=dict(pairs=pairs,anchors=anchors,glyphs=[dict(face=f,cp=c,matrix=m) for (f,c),m in resources.items()],records=records)
    vendor=ROOT/'Vendor/NativeSourceCV';source=ROOT/'Vendor/SourceInference'
    start=time.monotonic()
    with tempfile.TemporaryDirectory(prefix='aidoku-weight-bands-') as temp:
        temp=Path(temp);binary=temp/'bands'
        command=['xcrun','clang++','-std=c++17','-O2','-fobjc-arc','-I'+str(vendor/'include'),'-I'+str(source),
                 str(Path(__file__).with_name('main.mm')),str(source/'FontWeightBands.mm'),
                 str(vendor/'opencv2.xcframework/macos-arm64/libopencv2.a'),'-lz']
        for fw in ['Foundation','Accelerate','CoreGraphics','CoreVideo','AVFoundation','CoreMedia','OpenCL']:
            command+=['-framework',fw]
        subprocess.run(command+['-o',str(binary)],check=True)
        build=time.monotonic()-start
        (temp/'input.json').write_text(json.dumps(packet))
        start=time.monotonic();subprocess.run([str(binary),str(temp/'input.json'),str(temp/'output.json')],check=True)
        duration=time.monotonic()-start
        actual=json.loads((temp/'output.json').read_text())
    maxima=dict(poses=0.,bands=0.,fit=0.,stats=0.)
    for name,kind,want,got in zip(names,kinds,expected,actual[:good]):
        assert not (isinstance(got,dict) and 'error' in got),(name,got)
        if kind=='measure':
            assert got['confirmed']==want['confirmed'],name
            for key in ['poses','bands']:
                error=float(np.max(np.abs(want[key]-got[key])));maxima[key]=max(maxima[key],error)
                np.testing.assert_allclose(got[key],want[key],atol=2e-6,rtol=2e-6,err_msg=name+' '+key)
            discrete=[4,14,15,16,17,20]
            np.testing.assert_array_equal(np.asarray(got['poses']).reshape(8,24)[:,discrete],want['poses'].reshape(8,24)[:,discrete],err_msg=name)
        elif kind=='confirm':assert got==want,name
        else:
            maxima[kind]=max(maxima[kind],float(np.max(np.abs(want-got))))
            np.testing.assert_allclose(got,want,atol=2e-6,rtol=2e-6,err_msg=name)
            if kind=='fit':np.testing.assert_array_equal(np.asarray(got)[[4,14,15,16,17]],want[[4,14,15,16,17]],err_msg=name)
    assert len(actual)==len(records)
    assert all(isinstance(r,dict) and r.get('error') for r in actual[good:])
    print(json.dumps(dict(cases={k:kinds.count(k) for k in set(kinds)},invalid=len(invalid),max_abs=maxima,
                         build_seconds=build,native_seconds=duration,python_cv=cv2.__version__,icu_linked=False),indent=2))

if __name__=='__main__':run()
