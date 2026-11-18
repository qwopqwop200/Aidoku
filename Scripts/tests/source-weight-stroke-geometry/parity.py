#!/usr/bin/env python3
"""Actual unmodified Python directional_ink/ink_weight_geometry numeric oracle."""
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
ROOT=Path(__file__).resolve().parents[3]
ORACLE=ROOT/'Scripts/font_weight_estimation'
sys.path.insert(0,str(ORACLE))
import cv2
import numpy as np
from directional_ink import measure as directional
from ink_weight_geometry import observe, opposed_widths, clean_fill_style
from palette_word_pairs import observe_palette
from segmented_ink_geometry import reconstruct


def matrix(a):
    a=np.ascontiguousarray(a)
    if a.dtype==bool:a=a.astype(np.uint8)
    channels=a.shape[2] if a.ndim==3 else 1
    return dict(height=a.shape[0],width=a.shape[1],type={np.dtype('uint8'):0,np.dtype('float32'):5}[a.dtype]+8*(channels-1),
                data=base64.b64encode(a.tobytes()).decode())


def encoded_number(n):
    return 'nan' if np.isnan(n) else 'inf' if n==np.inf else '-inf' if n==-np.inf else float(n)


def run():
    files=['directional_ink.py','ink_weight_geometry.py','palette_word_pairs.py','segmented_ink_geometry.py','color_consistent_ink.py']
    untouched=[ROOT/'Vendor/SourceInference/SourceWeightInk.h',ROOT/'Vendor/SourceInference/SourceWeightInk.mm']
    def digests():return {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [ORACLE/f for f in files]+untouched}
    before=digests();records=[];expected=[];names=[];coverage={}
    def add(name,record,want):
        records.append(record);expected.append(want);names.append(name)
        coverage[record['op']]=coverage.get(record['op'],0)+1
    def rays(name,a,known,unit,mask=None,limits=(6000,)):
        if mask is None:mask=(a>.5)&known
        for limit in limits:
            widths,support=opposed_widths(a,known,mask,unit,maximum_edges=limit)
            add(name+'/opposed-'+str(limit),dict(op='opposed',alpha=matrix(a),known=matrix(known),mask=matrix(mask),em=encoded_number(unit),maximumEdges=limit),
                dict(widths=widths.tolist(),pairSupport=support))
        for cap in [1.7,None]:
            add(name+'/directional-'+str(cap),dict(op='directional',alpha=matrix(a),known=matrix(known),em=encoded_number(unit),maximumComponentEm=cap),
                directional(a,known,unit,maximum_component_em=cap))
    def rgb(name,image,own,style,em,bbox=None):
        bbox=bbox or [0,0,image.shape[1],image.shape[0]]
        packet=dict(rgb=matrix(image),ownership=matrix(own),style=style,em=encoded_number(em),bbox=bbox)
        geometry=observe(image,bbox,em,own,style)
        add(name+'/observe',dict(packet,op='observe'),geometry)
        cleaned=clean_fill_style(style)
        ga,gk=observe_palette(image,own,cleaned) if cleaned else (np.zeros(own.shape,np.float32),np.ones(own.shape,bool))
        add(name+'/alpha',dict(op='alpha',alpha=matrix(ga),known=matrix(gk),ownership=matrix(own),em=em,bbox=bbox,qualified=cleaned is not None),geometry)
        color,known=observe_palette(image,own,cleaned) if cleaned else (np.zeros(own.shape,np.float32),own)
        add(name+'/colorDirectional',dict(packet,op='colorDirectional'),directional(color*own,known,em))
    def reconstructed(name,alpha,known,own,em,bbox=None):
        bbox=bbox or [0,0,alpha.shape[1],alpha.shape[0]]
        signal=np.repeat(np.rint(255*(1-alpha))[:,:,None].astype(np.uint8),3,axis=2)
        neutral=dict(fill=dict(rgb=[0,0,0]),background=dict(rgb=[255,255,255]))
        want=observe(signal,bbox,em,own&known,neutral)
        add(name+'/reconstructed',dict(op='reconstructed',alpha=matrix(alpha),known=matrix(known),ownership=matrix(own),em=em,bbox=bbox),want)
    s=dict(fill=dict(rgb=[0,0,0]),background=dict(rgb=[255,255,255]))
    known=np.ones((100,100),bool)
    a=np.zeros(known.shape,np.float32);a[20:80,20:32]=1;a[20:24,20:70]=1
    result=directional(a,known,60);assert result['directionContrast']>2
    rays('anisotropic-L',a,known,60,limits=(6000,37,1,0))
    rgb('anisotropic-L',np.repeat(np.rint(255*(1-a))[:,:,None].astype(np.uint8),3,axis=2),known,s,60)
    rays('all-unknown',a,np.zeros_like(known),60)
    rays('empty',np.zeros_like(a),known,60)
    rays('solid',np.ones_like(a),known,60)
    b=a.copy();cv2.circle(b,(65,64),14,1,3);rays('ring-diagonal',b,known,60)
    b=np.zeros((100,240),np.float32)
    for x in [20,80,140,200]:b[20:80,x:x+8]=1
    b[48:52,20:208]=1;k=np.ones(b.shape,bool)
    assert directional(b,k,60)['components']==0
    assert directional(b,k,60,maximum_component_em=None)['components']==1
    rays('long-connected',b,k,60)
    # A ray cannot use a boundary hidden by the known map.
    b=np.zeros((80,80),np.float32);b[10:70,30:38]=1;k=np.ones(b.shape,bool);k[:,35:]=False
    assert len(opposed_widths(b,k,(b>.5)&k,40)[0])==0
    rays('unknown-opposite-edge',b,k,40)
    k[:]=True;k[15:25,28:40]=False;rays('known-holes',b,k,40)
    for width in [1,2,3,4,8,14,28]:
        b=np.zeros((80,96),np.float32);b[10:67,20:20+width]=1
        rays('stem-'+str(width),b,np.ones(b.shape,bool),40)
    # Squared-EM area gates must retain the Python multiplication grouping.
    gate=float(np.sqrt(40/.003));b=np.zeros((70,90),np.float32);b[20,15:55]=1
    for unit in [np.nextafter(gate,0).item(),gate,np.nextafter(gate,np.inf).item()]:
        rays('squared-em-area-gate-'+repr(unit),b,np.ones(b.shape,bool),unit)
    # Original .5 strict alpha threshold, component/area bounds and negative cap.
    for value in [np.nextafter(np.float32(.5),np.float32(0)),.5,np.nextafter(np.float32(.5),np.float32(1)),.75]:
        b=np.zeros((50,70),np.float32);b[10:36,20:26]=value;rays('alpha-'+str(value),b,np.ones(b.shape,bool),30)
    b=np.zeros((80,90),np.float32);b[8:68,10:14]=1;b[8:13,10:60]=1
    for cap in [0,-1,float('nan'),float('inf')]:
        add('explicit-cap-'+str(cap),dict(op='directional',alpha=matrix(b),known=matrix(np.ones(b.shape,bool)),em=40,maximumComponentEm=encoded_number(cap)),
            directional(b,np.ones(b.shape,bool),40,maximum_component_em=cap))
    # Explicit directional NaN-unit quirk: zero structure, not a finite-scale error.
    add('directional-nan-unit',dict(op='directional',alpha=matrix(b),known=matrix(np.ones(b.shape,bool)),em='nan',maximumComponentEm=1.7),
        directional(b,np.ones(b.shape,bool),float('nan')))
    for em in [.2,1.,3.9,4.2,7.8,40,60]:rays('ray-distance-limit-'+str(em),b,np.ones(b.shape,bool),em)
    # Dense bounded calibration patterns force the 6000-edge truncation.
    b=np.zeros((260,320),np.float32)
    for y in range(5,250,12):
        for x in range(5,310,12):b[y:y+8,x:x+8]=1
    edge=(b>.5)&~cv2.erode(b.astype(np.uint8),np.ones((3,3),np.uint8)).astype(bool)
    assert edge.sum()>6000
    rays('edge-truncation',b,np.ones(b.shape,bool),32,limits=(6000,5999,73,2,1,0))
    # Heterogeneous edge population makes linspace/truncation selection visible
    # in widths/directional group distributions, not just in total edge count.
    b=np.zeros((290,350),np.float32)
    for j,y in enumerate(range(4,275,14)):
        for i,x in enumerate(range(4,335,14)):
            height=[7,9,11,12][(i+2*j)%4];width=[3,5,8,11][(2*i+j)%4]
            b[y:y+height,x:x+width]=1
    k=np.ones(b.shape,bool);k[36:40,20:55]=False
    edge=(b>.5)&~cv2.erode(b.astype(np.uint8),np.ones((3,3),np.uint8)).astype(bool)
    assert edge.sum()>6000
    rays('heterogeneous-edge-truncation',b,k,32,limits=(6000,5999,71,3,1,0))
    # Counters, repeated components, contours including all hierarchy holes.
    b=np.zeros((120,170),np.float32)
    for x in [12,62,112]:
        cv2.rectangle(b,(x,15),(x+30,80),1,4);cv2.circle(b,(x+15,100),9,1,3)
    image=np.repeat(np.rint(255*(1-b))[:,:,None].astype(np.uint8),3,axis=2)
    own=np.ones(b.shape,bool);rgb('repeated-counters',image,own,s,60)
    for bbox in [[10.2,14.3,78.1,75.8],[20,20,10,10],[500,500,10,10],[-10,-10,50,60],[0,0,-3,-5]]:
        rgb('bbox-'+str(bbox),image,own,s,60,bbox)
    # Gradient, antialias cutoffs, palette alternatives, outline/shadow rejection.
    color=copy.deepcopy(s);color['fill']=dict(rgb=[230,30,90],colors=[[20,120,230],[0,0,0],[255,255,255]])
    color['outline']=dict(present=True,rgb=[0,0,0],widthPx=2)
    color['shadow']=dict(present=True,rgb=[100,100,100])
    im=np.full((96,150,3),255,np.uint8)
    for x in [12,55,98]:
        cv2.rectangle(im,(x,12),(x+27,73),(0,0,0),-1);im[16:70,x+4:x+24]=[230,30,90]
        im[30:36,x+4:x+24]=[20,120,230]
        im[50:56,x+4:x+24]=[120,180,210]
    own=np.ones(im.shape[:2],bool);rgb('palette-outline-gradient',im,own,color,52)
    own[32:40,16:32]=False;rgb('unowned-holes',im,own,color,52)
    nofill=dict(fill=dict(rgb=[255,255,255]),background=dict(rgb=[255,255,255]))
    rgb('no-clean-fill',im,own,nofill,52)
    # Resize paths exceed 800 only along a bounded narrow crop axis.
    for shape in [(71,801),(83,1201),(805,91),(91,800)]:
        b=np.zeros(shape,np.float32)
        for x in range(8,shape[1]-15,40):b[8:min(shape[0]-8,65),x:x+8]=1
        for y in range(8,shape[0]-15,45):b[y:y+6,12:min(shape[1]-8,70)]=1
        im=np.repeat(np.rint(255*(1-b))[:,:,None].astype(np.uint8),3,axis=2);o=np.ones(shape,bool);o[20:24,20:30]=False
        rgb('resize-'+str(shape),im,o,s,52,[3.1,2.7,shape[1]-7.4,shape[0]-6.2])
        reconstructed('resize-'+str(shape),b,o,np.ones(shape,bool),52)
    # Reference eligibility bridge uses original baseline reconstruction, not
    # color_consistent alpha and not direct alpha geometry.
    im=np.full((96,150,3),255,np.uint8);own=np.ones(im.shape[:2],bool)
    for x in [14,58,102]:
        im[15:70,x:x+20]=0;im[16:55,x+3:x+14]=[160,30,210]
    evidence={k:np.ones(own.shape,np.float32) for k in ['primary','boundary','native']}
    evidence['valid']=np.ones(own.shape,bool);evidence['valid'][20:25,17:23]=False
    evidence['rf']=np.ones((*own.shape,27),np.float32)
    alpha,observed,_=reconstruct(im,own,s,evidence,em=48)
    reconstructed('baseline-reference-eligibility',alpha,observed,own,48)
    for delta in [0,.001,.5/255,1/255]:
        aa=np.clip(alpha+delta,0,1).astype(np.float32)
        reconstructed('neutral-quantization-'+str(delta),aa,observed,own,48)
    # Direct-alpha API compared to unmodified observe through exact representable
    # grayscale levels; neutral palette yields alpha (255-gray)/255 float32.
    im=np.full((90,120,3),255,np.uint8)
    for x,gray in [(12,0),(45,64),(78,128)]:im[12:72,x:x+12]=gray
    own=np.ones(im.shape[:2],bool);alpha,known=observe_palette(im,own,s)
    add('direct-alpha-neutral',dict(op='alpha',alpha=matrix(alpha),known=matrix(known),ownership=matrix(own),em=50,bbox=[0,0,120,90],qualified=True),observe(im,[0,0,120,90],50,own,s))
    rng=np.random.default_rng(9104)
    for i in range(18):
        shape=(90+i,120+i);a=np.zeros(shape,np.float32)
        for j in range(9):
            x=int(rng.integers(2,shape[1]-25));y=int(rng.integers(2,shape[0]-35))
            a[y:y+int(rng.integers(9,30)),x:x+int(rng.integers(2,18))]=rng.choice([.25,.5,.75,1.])
        if i%2:a=cv2.GaussianBlur(a,(3,3),.65)
        k=np.ones(shape,bool)
        if i%3==0:k[20:24,20:30]=False
        rays('random-'+str(i),a,k,35+i,limits=(6000,31))
        im=np.repeat(np.rint(255*(1-a))[:,:,None].astype(np.uint8),3,axis=2)
        rgb('random-'+str(i),im,k,s,35+i)
        reconstructed('random-'+str(i),a,k,np.ones(shape,bool),35+i)
    # Nonfinite alpha is not an opposed_widths validation error; directional
    # explicitly rejects it. Keep the two error contracts separate.
    a=np.zeros((20,30),np.float32);a[3:15,8:12]=1;a[5,9]=np.nan;k=np.ones(a.shape,bool)
    widths,support=opposed_widths(a,k,np.nan_to_num(a)>.5,20)
    add('opposed-nonfinite-alpha',dict(op='opposed',alpha=matrix(a),known=matrix(k),mask=matrix(np.nan_to_num(a)>.5),em=20,maximumEdges=6000),dict(widths=widths.tolist(),pairSupport=support))
    good=len(records);invalid=[]
    def reject(name,record,fn):
        try:fn()
        except Exception as error:invalid.append((name,record,str(error)))
        else:raise AssertionError('Oracle unexpectedly accepted '+name)
    base=records[0]
    for em in [0,-1,np.nan,np.inf]:
        reject('opposed-bad-em-'+str(em),dict(base,em=encoded_number(em)),lambda em=em:opposed_widths(b,np.ones(b.shape,bool),b>.5,em))
    direct=next(r for r in records if r['op']=='directional')
    for em in [0,-1,np.inf]:reject('directional-bad-em-'+str(em),dict(direct,em=encoded_number(em)),lambda em=em:directional(b,np.ones(b.shape,bool),em))
    reject('directional-nonfinite-alpha',dict(direct,alpha=matrix(a),known=matrix(k)),lambda:directional(a,k,20))
    reject('opposed-negative-samples',dict(base,maximumEdges=-1),lambda:opposed_widths(b,np.ones(b.shape,bool),b>.5,40,-1))
    reject('directional-shape',dict(direct,known=matrix(np.ones((2,3),bool))),lambda:directional(b,np.ones((2,3),bool),40))
    observe_record=next(r for r in records if r['op']=='observe')
    for em in [0,-1,np.nan,np.inf]:reject('observe-bad-em-'+str(em),dict(observe_record,em=encoded_number(em)),lambda em=em:observe(im,[0,0,10,10],em,np.ones(im.shape[:2],bool),s))
    records.extend(record for _,record,_ in invalid)
    source=ROOT/'Vendor/SourceInference';vendor=ROOT/'Vendor/NativeSourceCV'
    with tempfile.TemporaryDirectory(prefix='aidoku-stroke-geometry-') as temp:
        temp=Path(temp);binary=temp/'geometry';start=time.monotonic()
        command=['xcrun','clang++','-std=c++17','-O2','-fobjc-arc','-I'+str(vendor/'include'),'-I'+str(source),
                 str(Path(__file__).with_name('main.mm')),str(source/'SourceWeightStrokeGeometry.mm'),str(source/'SourceWeightInk.mm'),
                 str(vendor/'opencv2.xcframework/macos-arm64/libopencv2.a'),'-lz']
        for fw in ['Foundation','Accelerate','CoreGraphics','CoreVideo','AVFoundation','CoreMedia','OpenCL']:command+=['-framework',fw]
        subprocess.run(command+['-o',str(binary)],check=True);build=time.monotonic()-start
        (temp/'input.json').write_text(json.dumps(records,allow_nan=False));start=time.monotonic()
        subprocess.run([str(binary),str(temp/'input.json'),str(temp/'output.json')],check=True)
        duration=time.monotonic()-start;actual=json.loads((temp/'output.json').read_text())
    assert len(actual)==len(records),(len(actual),len(records))
    max_error=0.;numeric=0
    def compare(want,got,path):
        nonlocal max_error,numeric
        if isinstance(want,dict):
            assert isinstance(got,dict) and want.keys()==got.keys(),(path,want,got)
            for key,value in want.items():compare(value,got[key],path+'/'+key)
        elif isinstance(want,list):
            assert len(want)==len(got),(path,len(want),len(got))
            for i,(w,g) in enumerate(zip(want,got)):compare(w,g,path+'/'+str(i))
        elif want is None or isinstance(want,(str,bool,int)):
            assert want==got,(path,want,got)
        else:
            error=abs(want-got);max_error=max(max_error,error);numeric+=1
            assert error<2e-6,(path,want,got,error)
    for name,want,got in zip(names,expected,actual[:good]):compare(want,got,name)
    for (name,_,message),got in zip(invalid,actual[good:]):
        assert got.get('error'),(name,message,got)
        if name!='opposed-negative-samples':assert got['error']==message,(name,message,got)
    assert before==digests(),'Existing oracle/helper files changed'
    print(json.dumps(dict(cases=good,by_operation=coverage,invalid=len(invalid),numeric_fields=numeric,max_abs=max_error,
                         build_seconds=build,native_seconds=duration,python_cv=cv2.__version__,oracle_sha256={Path(p).name:h for p,h in before.items()}),indent=2))

if __name__=='__main__':run()
