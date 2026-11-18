#!/usr/bin/env python3
"""Bounded synthetic crops against unmodified reconstruction/colour Python."""
import base64
import copy
import hashlib
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
from segmented_ink_geometry import reconstruct as segmented
from color_consistent_ink import reconstruct as consistent
from ink_weight_geometry import clean_fill_style
from palette_word_pairs import observe_palette


def matrix(a):
    a = np.ascontiguousarray(a)
    channels = a.shape[2] if a.ndim == 3 else 1
    return dict(width=a.shape[1], height=a.shape[0],
                type={np.dtype('uint8'): 0, np.dtype('float32'): 5}[a.dtype]+8*(channels-1),
                data=base64.b64encode(a.tobytes()).decode())


def base():
    shape=(48,76)
    rgb=np.full((*shape,3),255,np.uint8)
    own=np.ones(shape,bool)
    e={k:np.zeros(shape,np.float32) for k in ['primary','boundary','native']}
    e['rf']=np.zeros((*shape,27),np.float32)
    e['valid']=np.ones(shape,bool)
    s=dict(fill=dict(rgb=[0,0,0]),background=dict(rgb=[255,255,255]))
    return rgb,own,s,e


def run():
    oracle_files=['segmented_ink_geometry.py','color_consistent_ink.py','palette_word_pairs.py','ink_weight_geometry.py']
    def digests():
        return {p:hashlib.sha256((ROOT/'Scripts/font_weight_estimation'/p).read_bytes()).hexdigest() for p in oracle_files}
    before=digests()
    records=[];expected=[];names=[];audits={}
    def add(name,args,em=20,cutoff=.5):
        rgb,own,style,e=args
        cleaned=clean_fill_style(style)
        if cleaned is None:color,known=np.zeros(own.shape,np.float32),np.zeros(own.shape,bool)
        else:color,known=observe_palette(rgb,own,cleaned)
        for mode in ['segmented','uncapped','consistent']:
            if mode=='consistent':a,v,audit=consistent(rgb,own,style,e,cutoff,em)
            else:a,v,audit=segmented(rgb,own,style,e,cutoff,em,maximum_component_em=1.7 if mode=='segmented' else None)
            expected.append((a,v,audit,color,known,cleaned is not None));names.append(name+'/'+mode)
            records.append(dict(rgb=matrix(rgb),ownership=matrix(own.astype(np.uint8)),style=style,
                                **{k:matrix(v.astype(np.uint8) if k=='valid' else v) for k,v in e.items()},
                                mode=mode,cutoff=cutoff,em=em))
            audits[name,mode]=audit
    add('empty',base(),None)
    a=base();rgb,own,s,e=a
    rgb[10:30,10:24]=0;e['primary'][8:32,8:26]=.9;e['boundary'][:]=.8
    add('solid',a)
    # Gradient and highlight not fitting a paint line: unknown seeded interior.
    rgb[12:28,11:23]=[170,80,210];rgb[10:12,10:24]=0
    add('unknown-gradient',a)
    # A known light interior suppresses segmentation in consistent mode.
    rgb[12:28,11:23]=230
    add('known-gradient',a)
    b=base();b[0][10:30,10:26]=0;b[0][10:22,16:20]=230
    b[3]['primary'][10:30,10:26]=.9;add('known-background-veto',b)
    assert audits['known-background-veto','consistent']['suppressedKnownBackgroundPixels']>0
    # Long seeded connected body: only the segmented rule imposes 1.7em.
    a=base();rgb,own,s,e=a;rgb[18:24,8:12]=0;rgb[18:24,64:68]=0
    rgb[18:24,12:64]=[130,40,180];e['primary'][18:24,8:68]=.9
    add('long-component',a)
    assert audits['long-component','segmented']['acceptedReconstructionComponents']==0
    assert audits['long-component','uncapped']['acceptedReconstructionComponents']==1
    # Enclosed counter, nested island and a single-pixel counter.
    a=base();rgb,own,s,e=a
    cv2.rectangle(rgb,(10,9),(34,35),(0,0,0),3);rgb[20:23,20:23]=0
    rgb[8:13,44:49]=0;rgb[10,46]=255;e['primary'][6:38,6:54]=.95;e['boundary'][:]=.9
    add('counters',a,40)
    assert audits['counters','segmented']['protectedCounterPixels']>0
    # Small supported gap, neither paint nor exterior nor counter.
    a=base();rgb,own,s,e=a
    rgb[14:27,14:28]=0;rgb[14:16,20]=[170,70,190]
    e['primary'][14:27,14:28]=.3;e['boundary'][14:27,14:28]=.8
    e['native'][:]=1;e['rf'][:,:,15]=.5;e['rf'][:,:,16]=.1
    add('supported-bridge',a)
    assert audits['supported-bridge','segmented']['bridgedGapPixels']>0
    for channel in [0,3,15,17]:
        b=copy.deepcopy(a);b[3]['rf'][:]=0
        if channel in [15,17]:b[3]['rf'][:,:,channel]=.5;b[3]['rf'][:,:,channel+1]=.1
        else:b[3]['rf'][:,:,channel]=.05
        add('rf-support-'+str(channel),b)
    b=copy.deepcopy(a);b[3]['native'][:]=0;add('unsupported-gap',b)
    b=copy.deepcopy(a);b[3]['boundary'][:]=.649999;add('low-boundary',b)
    # Outlines/shadows are negatives; alternate fill close to either is cleaned.
    a=base();rgb,own,s,e=a
    s.update(outline=dict(present=True,rgb=[0,0,0],widthPx=1.5),shadow=dict(present=True,rgb=[90,90,90]))
    s['fill']=dict(rgb=[230,40,100],colors=[[230,40,100],[0,0,0],[90,90,90],[255,255,255],[40,110,220]])
    cv2.rectangle(rgb,(9,8),(29,32),(90,90,90),-1)
    cv2.rectangle(rgb,(8,7),(27,30),(0,0,0),-1);rgb[11:27,12:24]=[230,40,100]
    rgb[17:23,14:22]=[40,110,220];e['primary'][7:33,8:30]=.9
    add('palette-outline-shadow',a)
    assert audits['palette-outline-shadow','segmented']['excludedOutlineShadowPixels']>0
    for radius in [0,.5,2,9]:
        b=copy.deepcopy(a);b[2]['outline']['widthPx']=radius;add('outline-radius-'+str(radius),b)
    # Observed fill is preserved even outside validity/segmentation, ownership is hard.
    b=copy.deepcopy(a);b[3]['valid'][12:25,12:23]=False;b[1][17:21,15:20]=False
    add('valid-holes-unowned',b)
    b=base();b[3]['valid'][:]=False;b[0][8:13,8:13]=[160,20,180];b[1][0:5]=False
    add('explicit-unknown',b)
    # Fill almost background, no clean fill; missing palettes and tied lines.
    for fill in [[255,255,255],[235,235,235],[0,0,0]]:
        b=base();b[2]['fill']['rgb']=fill;b[2]['background']['colors']=[[0,0,0],[255,255,255]]
        b[0][9:18,9:18]=0;b[3]['primary'][7:20,7:20]=1;add('near-background-'+str(fill),b)
    b=base();b[2]['background'].update(colors=[[170,80,210],[70,180,90]],observedContextWeights=[.1,.099999])
    b[0][:15]=[170,80,210];b[0][20:26,20:26]=0;b[3]['primary'][:]=.8
    add('exterior-context-weights',b,80)
    # Lexicographic np.unique order and first residual winner are observable.
    b=base();b[2]['fill']['colors']=[[255,0,0],[0,0,0],[0,0,255],[0,0,0]]
    b[2]['background']['colors']=[[0,255,0],[255,255,255]];b[0][8:28,8:28]=[120,100,120]
    b[3]['primary'][:]=.8;add('palette-ties',b)
    # Seed area/hit gates, rounding of close radius, noncontiguous arrays.
    for em in [19,60,100,None]:add('em-'+str(em),a,em)
    for count in [1,2,3,5]:
        b=base();b[0][20,10:10+count]=0;b[3]['primary'][15:25,7:27]=.9;add('seed-count-'+str(count),b)
    rng=np.random.default_rng(741)
    for i in range(32):
        b=base();rgb,own,s,e=b
        rgb[:]=rng.integers(0,256,rgb.shape,dtype=np.uint8)
        rgb[12:16,10:20]=0;own[:]=rng.random(own.shape)>.2
        for k in ['primary','boundary','native']:e[k][:]=rng.random(own.shape,dtype=np.float32)
        e['rf'][:]=rng.random(e['rf'].shape,dtype=np.float32);e['valid'][:]=rng.random(own.shape)>.15
        if i%2:s['fill']['colors']=[[240,20,80],[40,160,200]]
        if i%3:s['outline']=dict(present=True,rgb=[30,40,50],widthPx=i%5+.5)
        # strided matrices exercise row access rather than flat assumptions.
        if i%4==0:
            b=(rgb[:,::-1],own[:,::-1],s,{k:v[:,::-1] for k,v in e.items()})
        add('random-'+str(i),b,20+i,cutoff=[.25,.5,.75][i%3])
    # Float32 comparisons must match NumPy scalar casting at exact gates.
    for q in [np.nextafter(np.float32(.65),np.float32(0)),np.float32(.65),np.nextafter(np.float32(.65),np.float32(1))]:
        b=base();b[0][14:27,14:28]=0;b[0][14:16,20]=[170,70,190]
        b[3]['primary'][14:27,14:28]=.5;b[3]['boundary'][:]=q
        add('boundary-gate-'+repr(q),b)
    for semantic in [np.nextafter(np.float32(.05),np.float32(0)),np.float32(.05),np.nextafter(np.float32(.05),np.float32(1))]:
        b=base();b[0][14:27,14:28]=0;b[3]['primary'][14:27,14:28]=.25
        b[3]['boundary'][:]=.5;b[3]['native'][:]=1;b[3]['rf'][:,:,0]=semantic
        add('semantic-gate-'+repr(semantic),b)
    for length in [33,34,35]:
        b=base();b[0][18:23,8:10]=0;b[0][18:23,10:8+length]=[170,70,190]
        b[3]['primary'][18:23,8:8+length]=.9;add('component-1.7em-'+str(length),b)
    for count in [2,3,4]:
        b=base();b[0][10,10:10+count]=0;b[3]['primary'][10:20,10:20]=.9
        add('seed-area-fraction-'+str(count),b)
    b=base();b[0][:]=0;b[3]['primary'][:]=1;b[3]['boundary'][:]=1
    add('all-foreground',b,None)
    b=base();b[0][0:12,0:12]=0;b[0][0:3,5]=[170,70,190];b[3]['primary'][:]=1;b[3]['boundary'][:]=1
    add('border-touching-gap',b,100)
    for delta in [34,35,36]:
        b=base();b[2]['fill']['rgb']=[255-delta,255,255]
        b[0][9:25,9:25]=b[2]['fill']['rgb'];b[3]['primary'][9:25,9:25]=1
        add('clean-fill-distance-'+str(delta),b)
    # True multidimensional gradient through both known and unknown colours.
    b=base();yy,xx=np.indices((20,24));b[0][8:28,8:32]=np.stack([xx*10,yy*12,(xx+yy)*5],axis=2).astype(np.uint8)
    b[0][8,8:32]=0;b[3]['primary'][8:28,8:32]=.9;add('spatial-gradient',b,40)
    good=len(records)
    invalid=[]
    for key,value in [('em',0),('em',-1)]:
        r=copy.deepcopy(records[0]);r[key]=value;invalid.append(r)
    for key in ['primary','boundary','native','rf']:
        r=copy.deepcopy(records[0]);shape=(48,76,27) if key=='rf' else (48,76)
        r[key]=matrix(np.full(shape,np.nan,np.float32));invalid.append(r)
    r=copy.deepcopy(records[0]);r['valid']=matrix(np.ones((2,2),np.uint8));invalid.append(r)
    records.extend(invalid)
    vendor=ROOT/'Vendor/NativeSourceCV';source=ROOT/'Vendor/SourceInference'
    with tempfile.TemporaryDirectory(prefix='aidoku-source-weight-ink-') as temp:
        temp=Path(temp);binary=temp/'ink';start=time.monotonic()
        command=['xcrun','clang++','-std=c++17','-O2','-fobjc-arc','-I'+str(vendor/'include'),'-I'+str(source),
                 str(Path(__file__).with_name('main.mm')),str(source/'SourceWeightInk.mm'),
                 str(vendor/'opencv2.xcframework/macos-arm64/libopencv2.a'),'-lz']
        for fw in ['Foundation','Accelerate','CoreGraphics','CoreVideo','AVFoundation','CoreMedia','OpenCL']:command+=['-framework',fw]
        subprocess.run(command+['-o',str(binary)],check=True);build=time.monotonic()-start
        (temp/'input.json').write_text(json.dumps(records));start=time.monotonic()
        subprocess.run([str(binary),str(temp/'input.json'),str(temp/'output.json')],check=True)
        duration=time.monotonic()-start;actual=json.loads((temp/'output.json').read_text())
    assert len(actual)==len(records), (len(actual),len(records))
    maxima=dict(alpha=0.,palette=0.,means=0.)
    for name,want,got in zip(names,expected,actual[:good]):
        assert 'error' not in got,(name,got)
        alpha,observed,audit,color,known,clean=want
        for key,target,dtype in [('alpha',alpha,np.float32),('observed',observed,np.uint8),('color',color,np.float32),('known',known,np.uint8)]:
            value=np.frombuffer(base64.b64decode(got[key]),dtype=dtype).reshape(target.shape)
            if dtype==np.uint8:np.testing.assert_array_equal(value,target,err_msg=name+' '+key)
            else:
                err=float(np.max(np.abs(value-target)));maxima['alpha' if key=='alpha' else 'palette']=max(maxima['alpha' if key=='alpha' else 'palette'],err)
                np.testing.assert_allclose(value,target,rtol=0,atol=2e-6,err_msg=name+' '+key)
        assert got['clean']==clean,name
        assert got['audit'].keys()==audit.keys(),(name,got['audit'],audit)
        for key,v in audit.items():
            if key.endswith('Mean'):
                err=abs(got['audit'][key]-v);maxima['means']=max(maxima['means'],err)
                assert err<2e-6,(name,key,got['audit'][key],v)
            else:assert got['audit'][key]==v,(name,key,got['audit'][key],v)
    assert len(actual)==len(records)
    assert all(r.get('error') for r in actual[good:])
    assert before==digests(),'Original oracle files changed'
    print(json.dumps(dict(crops=good//3,reconstructions=good,invalid=len(invalid),max_abs=maxima,
                         build_seconds=build,native_seconds=duration,python_cv=cv2.__version__,oracle_sha256=before),indent=2))

if __name__=='__main__':run()
