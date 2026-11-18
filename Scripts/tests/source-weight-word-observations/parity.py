#!/usr/bin/env python3
"""Actual source/RF reconstruction -> prepare -> fair fits -> reference/soft words."""
import base64
import copy
import hashlib
import json
import os
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
from color_consistent_ink import reconstruct
from reference_ink_weight import reference_pairs,measure as reference_measure
from soft_ink_source import observe as soft_observe
from reference_grid import masks
from word_pairs import transform
from palette_word_pairs import prepare_palette
from ink_weight_geometry import clean_fill_style


def matrix(a):
    a=np.ascontiguousarray(a);channels=a.shape[2] if a.ndim==3 else 1
    return dict(width=a.shape[1],height=a.shape[0],type={np.dtype('uint8'):0,np.dtype('float32'):5}[a.dtype]+8*(channels-1),
                data=base64.b64encode(a.tobytes()).decode())


def decoded(r):
    a=np.frombuffer(base64.b64decode(r['data']),np.float32 if r['type']==5 else np.uint8)
    return a.reshape(r['height'],r['width'])


def run():
    code=ROOT/'Scripts/font_weight_estimation'
    oracle_files=['soft_ink_source.py','reference_ink_weight.py','palette_word_pairs.py','masked_word_pairs.py',
                  'color_consistent_ink.py','ordered_glyph_ink.py']
    before={p:hashlib.sha256((code/p).read_bytes()).hexdigest() for p in oracle_files}
    pairs=json.loads((ROOT.parent/'font-weight-estimation-20261111/reference-bank/WORD-PAIRS.json').read_text())['pairs'][:8]
    families=reference_pairs(pairs)
    records=[];expected=[];names=[];kinds=[]
    def fixture(family=0,weight=1.,vertical=False,text='漢語',unit=48):
        a,b=transform(*masks(families[family],text,vertical),unit/128,1,0,vertical)
        alpha=np.pad((a+(b-a)*weight).astype(np.float32),((16,16),(16,16)))
        rgb=np.rint(255*(1-alpha[:,:,None])).astype(np.uint8).repeat(3,axis=2)
        h,w=alpha.shape
        evidence=dict(primary=(alpha>.05).astype(np.float32)*.95,boundary=np.full(alpha.shape,.8,np.float32),
                      native=np.ones(alpha.shape,np.float32),rf=np.zeros((*alpha.shape,27),np.float32),valid=np.ones(alpha.shape,bool))
        evidence['rf'][:,:,15]=.5;evidence['rf'][:,:,16]=.1
        packet=dict(rgb=rgb,bbox=[0,0,w,h],ownership=np.ones(alpha.shape,bool),
                    style=dict(fill=dict(rgb=[0,0,0]),background=dict(rgb=[255,255,255])),glyphEvidence=evidence,
                    wordMembers=[dict(bbox=[12,12,w-24,h-24],text=text)])
        return packet,unit
    def add(name,packet,em,ordered=False,paths=3):
        if os.environ.get("AIDOKU_WORD_OBSERVATIONS_CASE") and name!=os.environ["AIDOKU_WORD_OBSERVATIONS_CASE"]:return
        rgb=packet['rgb'];own=packet['ownership'];style=packet['style'];e=packet['glyphEvidence'];members=packet['wordMembers']
        alpha,known,_=reconstruct(rgb,own,style,e,em=em)
        reference=reference_measure(rgb,packet['bbox'],em,own,style,pairs,members,alpha,known)['words'] if paths&1 else []
        soft=soft_observe(packet,em,pairs,include_ordered=ordered) if paths&2 else dict(words=[],expectedWordCount=0)
        records.append(dict(rgb=matrix(rgb),ownership=matrix(own.astype(np.uint8)),style=style,em=em,members=members,
                            **{k:matrix(v.astype(np.uint8) if k=='valid' else v) for k,v in e.items()},paths=paths,includeOrdered=ordered))
        expected.append(dict(_inkAlpha=alpha,_inkKnown=known,reference=reference,soft=soft['words'],expectedReference=min(6,len(members)) if paths&1 else 0,
                             expectedSoft=soft['expectedWordCount'],orderedGlyphsImplemented=True))
        names.append(name);kinds.append('observation')
    def prepare(name,packet,em,angle=0,text=None,bbox=None):
        if os.environ.get("AIDOKU_WORD_OBSERVATIONS_CASE") and name!=os.environ["AIDOKU_WORD_OBSERVATIONS_CASE"]:return
        rgb=packet['rgb'];own=packet['ownership'];style=packet['style'];e=packet['glyphEvidence']
        bbox=bbox or [0,0,rgb.shape[1],rgb.shape[0]];text=text if text is not None else packet['wordMembers'][0]['text']
        clean=clean_fill_style(style)
        want=prepare_palette(rgb,bbox,em,text,own,clean,angle) if clean else None
        records.append(dict(op='prepare',rgb=matrix(rgb),ownership=matrix(own.astype(np.uint8)),style=style,em=em,text=text,bbox=bbox,angle=angle,
                            **{k:matrix(v.astype(np.uint8) if k=='valid' else v) for k,v in e.items()}))
        expected.append(want);names.append(name);kinds.append('prepare')
    for family in [0,1,3]:
        for weight in [0.,1.]:
            p,em=fixture(family,weight)
            add(f'family{family}-{weight}',p,em,ordered=family==0)
    p,em=fixture(0,.65,vertical=True,text='「漢語」')
    add('vertical-punctuation-ordered',p,em,ordered=True);prepare('prepare-vertical',p,em)
    p,em=fixture(0,1)
    # Existing RF/native/valid arrays must be used; unknown colored interior
    # cannot be replaced with a newly inferred background or a new glyph mask.
    q=copy.deepcopy(p);q['rgb'][25:35,31:40]=[160,40,190];q['glyphEvidence']['valid'][25:35,31:40]=False
    add('existing-unknown-seg-rf',q,em);prepare('prepare-unknown',q,em)
    q=copy.deepcopy(p);q['ownership'][18:27,20:30]=False
    add('ownership-gap',q,em)
    # Polygon-driven angle and exactly the original bbox, never line splitting.
    q=copy.deepcopy(p);h,w=q['rgb'].shape[:2]
    q['wordMembers'][0]['polygon']=cv2.boxPoints(((w/2,h/2),(w-24,h-24),8)).tolist()
    add('polygon-angle8',q,em);prepare('prepare-angle8',q,em,8)
    q=copy.deepcopy(p);q['wordMembers'][0]['bbox']=[12.25,11.75,w-24.5,h-23.5]
    add('fractional-bbox',q,em)
    # Alternate fill is needed for prepare's initial frozen-alpha geometry.
    q=copy.deepcopy(p);a=1-q['rgb'][:,:,0].astype(float)/255
    bg=np.array([255,255,255]);color=np.array([20,90,220]);q['rgb']=np.rint(bg+(color-bg)*a[:,:,None]).astype(np.uint8)
    q['style']['fill']=dict(rgb=[220,30,80],colors=[[20,90,220]])
    add('alternate-fill-prepare',q,em);prepare('prepare-alternate',q,em)
    for name,text in [('spaces-nfc',' 漢 \u8a9e\n'),('excluded','!?🙂'),('too-short','漢')]:
        q=copy.deepcopy(p);q['wordMembers'][0]['text']=text
        add(name,q,em);prepare('prepare-'+name,q,em,text=text)
    q=copy.deepcopy(p);q['style']['fill']['rgb']=[255,255,255]
    add('clean-none',q,em)
    q=copy.deepcopy(p);q['wordMembers']=[];add('no-words',q,em)
    # Eight ORIGINAL records preserve distinct first6 versus spread6 selection.
    tiles=[];members=[];evidence=[];offset=0
    for j,weight in enumerate([0.,.15,.3,.45,.6,.75,.9,1.]):
        tile,_=fixture(0,weight,unit=40);tw=tile['rgb'].shape[1]
        members.append(dict(bbox=[12+offset,12,tw-24,tile['rgb'].shape[0]-24],text='漢語'))
        tiles.append(tile['rgb']);evidence.append(tile['glyphEvidence']);offset+=tw
    q=copy.deepcopy(p);q['rgb']=np.concatenate(tiles,axis=1);q['ownership']=np.ones(q['rgb'].shape[:2],bool)
    q['glyphEvidence']={k:np.concatenate([e[k] for e in evidence],axis=1) for k in evidence[0]}
    q['wordMembers']=members;q['bbox']=[0,0,q['rgb'].shape[1],q['rgb'].shape[0]]
    add('first6-versus-spread6',q,40)
    # With 8 words, spread6 omits index3 but soft first6 includes it. A
    # nonfinite bbox there must be skipped only by soft, without failing the
    # reference path that never selected that word.
    malformed=copy.deepcopy(q);malformed['wordMembers'][3]['bbox'][0]=float('nan')
    if not os.environ.get('AIDOKU_WORD_OBSERVATIONS_CASE'):
        add('nonfinite-only-soft-selected',malformed,40)
        records[-1]['members']=copy.deepcopy(q['wordMembers']);records[-1]['injectNonfiniteWord']=3
    # >640 preparation exercises area-known footprint threshold and EM scaling.
    large,unit=fixture(0,1,text='漢語漢語漢語',unit=112)
    prepare('prepare-downsample640',large,unit,7)
    add('soft-only',p,em,paths=2);add('reference-only',p,em,paths=1)
    good=len(records)
    for key,value in [('em',0),('em',None),('cutoff',.4)]:
        r=copy.deepcopy(records[0]);r[key]=value;records.append(r)
    r=copy.deepcopy(records[0]);r['rf']=matrix(np.zeros((*p['rgb'].shape[:2],26),np.float32));records.append(r)
    r=copy.deepcopy(records[0]);r['injectNonfiniteWord']=0;records.append(r)
    vendor=ROOT/'Vendor/NativeSourceCV';source=ROOT/'Vendor/SourceInference'
    sources=['SourceWeightWordObservations.mm','SourceWeightInk.mm','SourceWeightRegisteredProfile.mm',
             'SourceWeightReferenceGrid.mm','SourceWeightWordFit.mm','SourceWeightOrderedGlyph.mm']
    start=time.monotonic()
    with tempfile.TemporaryDirectory(prefix='aidoku-word-observations-') as t:
        t=Path(t);binary=t/'observe'
        cmd=['xcrun','clang++','-std=c++17','-O2','-fobjc-arc','-I'+str(source),'-I'+str(vendor/'include'),'-I'+str(vendor/'freetype/include'),
             str(Path(__file__).with_name('main.mm')),*[str(source/p) for p in sources],str(vendor/'NativeSourceCV.cpp'),
             str(vendor/'opencv2.xcframework/macos-arm64/libopencv2.a'),str(vendor/'FreeType.xcframework/macos-arm64/libfreetype.a'),'-lz']
        for fw in ['Foundation','Accelerate','CoreGraphics','CoreVideo','AVFoundation','CoreMedia','OpenCL']:cmd+=['-framework',fw]
        subprocess.run(cmd+['-o',str(binary)],check=True);build=time.monotonic()-start
        (t/'in.json').write_text(json.dumps(dict(pairs=pairs,records=records)))
        start=time.monotonic();subprocess.run([str(binary),str(t/'in.json'),str(t/'out.json')],check=True)
        duration=time.monotonic()-start;actual=json.loads((t/'out.json').read_text())
    assert len(actual)==len(records)
    assert all(isinstance(v,dict) and 'error' in v for v in actual[good:]),actual[good:]
    maxima={};counts=dict(reference=0,soft=0,ordered=0,orderedGlyphs=0)
    def compare(want,got,path):
        if isinstance(want,dict):
            assert set(want)==set(got),(path,set(want)^set(got))
            for key in want:compare(want[key],got[key],path+'/'+key)
        elif isinstance(want,(list,tuple)):
            assert len(want)==len(got),(path,len(want),len(got))
            for i,(a,b) in enumerate(zip(want,got)):compare(a,b,path+f'/{i}')
        elif isinstance(want,(bool,str,int,np.integer)):
            assert want==got,(path,want,got)
        else:
            err=abs(float(want)-float(got));key=path.split('/')[-1];maxima[key]=max(maxima.get(key,0),err)
            np.testing.assert_allclose(got,want,atol=2e-6,rtol=2e-6,err_msg=path)
    for name,kind,want,got in zip(names,kinds,expected,actual[:good]):
        assert not (isinstance(got,dict) and 'error' in got),(name,got)
        if kind=='observation':
            np.testing.assert_array_equal(decoded(got.pop('_inkKnown')),want.pop('_inkKnown'),err_msg=name+' reconstruction known')
            np.testing.assert_allclose(decoded(got.pop('_inkAlpha')),want.pop('_inkAlpha'),atol=1e-7,rtol=1e-7,err_msg=name+' reconstruction alpha')
            compare(want,got,name)
            counts['reference']+=len(got['reference']);counts['soft']+=len(got['soft'])
            for row in got['soft']:
                if 'orderedGlyphs' in row:counts['ordered']+=1;counts['orderedGlyphs']+=len(row['orderedGlyphs']['glyphs'])
        elif want is None:assert got is None,name
        else:
            for k in ['text','vertical','long','cross','boxLong','boxCross','unit']:compare(want[k],got[k],name+'/'+k)
            np.testing.assert_array_equal(decoded(got['observed']),want['observed'],err_msg=name)
            np.testing.assert_allclose(decoded(got['alpha']),want['alpha'],atol=1e-7,rtol=1e-7,err_msg=name)
    if not os.environ.get('AIDOKU_WORD_OBSERVATIONS_CASE'):assert counts['reference']>0 and counts['soft']>0 and counts['orderedGlyphs']>0,counts
    after={p:hashlib.sha256((code/p).read_bytes()).hexdigest() for p in oracle_files}
    assert before==after,'Python oracle changed during verification; rerun against a fixed snapshot'
    print(json.dumps(dict(cases={k:kinds.count(k) for k in set(kinds)},invalid=len(records)-good,words=counts,
                         max_abs=max(maxima.values(),default=0),max_by_field=maxima,build_seconds=build,native_seconds=duration,
                         python_cv=cv2.__version__,oracle_sha256=before),indent=2))

if __name__=='__main__':run()
