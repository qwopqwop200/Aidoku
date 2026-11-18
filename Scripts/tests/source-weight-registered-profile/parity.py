#!/usr/bin/env python3
"""Bounded original unmodified hard/soft registered stroke profile oracle."""
import base64
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import warnings
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[3]
ORACLE=ROOT/'Scripts/font_weight_estimation'
sys.path.insert(0,str(ORACLE))
import cv2
import numpy as np
from registered_stroke_evidence import profile as hard, signed_distance
from soft_stroke_profile import profile as soft, depth, LEVELS


def matrix(a):
    a=np.ascontiguousarray(a)
    if a.dtype==bool:a=a.astype(np.uint8)
    return dict(width=a.shape[1],height=a.shape[0],type={np.dtype('uint8'):0,np.dtype('float32'):5,np.dtype('float64'):6}[a.dtype],
                data=base64.b64encode(a.tobytes()).decode())


def number(n):
    return 'nan' if np.isnan(n) else 'inf' if n==np.inf else '-inf' if n==-np.inf else float(n)


def run():
    paths=[ORACLE/f for f in ['registered_stroke_evidence.py','soft_stroke_profile.py']]
    paths.extend(ROOT/'Vendor/SourceInference'/f for f in ['SourceWeightInk.h','SourceWeightInk.mm','SourceWeightStrokeGeometry.h','SourceWeightStrokeGeometry.mm'])
    def digests():return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    before=digests();records=[];expected=[];names=[];coverage={};usable={'hard':0,'soft':0}
    def add(name,record,want):
        records.append(record);expected.append(want);names.append(name)
        op=record['op'];coverage[op]=coverage.get(op,0)+1
        if op in usable:usable[op]+=int(want['usable'])
    def profiles(name,src,r,h,k,unit=48):
        packet=dict(source=matrix(src),regular=matrix(r),heavy=matrix(h),known=matrix(k),unit=number(unit))
        for op,fn in [('hard',hard),('soft',soft)]:
            with warnings.catch_warnings():
                warnings.simplefilter('ignore',RuntimeWarning)
                result=fn(src,r,h,k,unit)
            add(name+'/'+op,dict(packet,op=op),result)
        return expected[-2:]
    def depths(name,a):
        add(name+'/depth',dict(op='depth',alpha=matrix(a)),depth(a))
        binary=(a>.5).astype(np.uint8)
        add(name+'/signed',dict(op='signed',binary=matrix(binary)),signed_distance(binary))
    def stems(shape=(96,108)):
        r=np.zeros(shape,np.float32);h=r.copy()
        r[12:84,48:52]=1;h[12:84,44:56]=1
        return r,h,np.ones(shape,bool)
    r,h,k=stems()
    for name,src in [('regular',r),('heavy',h),('half-blend',(r+h)/2),('blank',np.zeros_like(r)),('full',np.ones_like(r))]:
        got=profiles(name,src,r,h,k)
        if name=='regular':assert all(p['usable'] and p['medianWeightFraction']==0 for p in got)
        if name=='heavy':assert all(p['usable'] and p['medianWeightFraction']==1 for p in got)
    depths('regular',r);depths('heavy',h)
    # Corresponding centres measure this stroke only, not unrelated thick paint.
    src=np.zeros_like(r);src[12:84,12:24]=1
    got=profiles('unrelated-stroke',src,r,h,k)
    assert all(p['correspondingSourceSupport']==0 and p['medianWeightFraction']<0 for p in got)
    for dx,dy in [(1,0),(-3,0),(5,0),(0,2),(9,8),(-9,-8)]:
        shifted=cv2.warpAffine(h,np.array([[1,0,dx],[0,1,dy]],np.float64),(h.shape[1],h.shape[0]),flags=cv2.INTER_LINEAR)
        profiles('shift-'+str((dx,dy)),shifted,r,h,k)
    for amount in [0,.1,.5,.9,1]:
        occluded=h.copy();occluded[12:12+round(72*amount)]=0
        profiles('occluded-source-'+str(amount),occluded,r,h,k)
        known=k.copy();known[12:12+round(72*amount)]=False
        profiles('occluded-known-'+str(amount),h,r,h,known)
    profiles('all-unknown',h,r,h,np.zeros_like(k))
    profiles('no-added-radius',h,r,r,k)
    profiles('heavy-missing',r,r,np.zeros_like(h),k)
    profiles('normal-missing',h,np.zeros_like(r),h,k)
    # Exact informative count gate. Eroding disjoint 3x3 known islands leaves
    # one corresponding centre each; 7 must omit numeric fields, 8 must expose.
    r=np.zeros((90,90),np.float32);h=r.copy();r[8:82,44:47]=1;h[8:82,41:50]=1
    for count in [0,1,7,8,9]:
        known=np.zeros_like(r,bool)
        for i in range(count):known[13+6*i:16+6*i,44:47]=True
        got=profiles('centre-count-'+str(count),h,r,h,known)
        assert all(p['informativeCentres']==count and p['usable']==(count>=8) for p in got)
        assert all(('medianWeightFraction' in p)==(count>=8) for p in got)
    # Antialias difference with identical >.5 masks must be visible only to soft.
    r,h,k=stems();r[:,48]=np.where(r[:,48]>0,.6,0);r[:,51]=np.where(r[:,51]>0,.6,0)
    src=r.copy();src[:,48]=np.where(src[:,48]>0,.9,0);src[:,51]=np.where(src[:,51]>0,.9,0)
    got=profiles('same-binary-antialias',src,r,h,k)
    assert got[0]['medianWeightFraction']==0 and got[1]['medianWeightFraction']>.01
    depths('antialias-source',src)
    # Test every exact alpha-level and its adjacent representable float32s.
    levels=np.array(LEVELS,np.float32)
    for i,v in enumerate(levels):
        for side,n in [('below',np.nextafter(v,np.float32(0))),('at',v),('above',np.nextafter(v,np.float32(1)))]:
            a=np.zeros((23,31),np.float32);a[3:20,9:22]=n
            depths('level-'+str(i)+'-'+side,a)
    # A reference with a soft .5px difference is informative even though its
    # binary mask is unchanged. Sweep alpha to exercise the >=.5 soft gate.
    r=np.zeros((80,88),np.float32);r[9:71,32:38]=1
    for edge in [.2,.3,.4,.5,.6,.7,.8,.9,1.]:
        h=r.copy();h[9:71,30:32]=edge;h[9:71,38:40]=edge
        profiles('soft-radius-gate-'+str(edge),h,r,h,np.ones(r.shape,bool))
    # Counters, intersecting strokes, separated islands and diagonal boundaries.
    for thickness in [1,2,3,4]:
        r=np.zeros((112,128),np.float32);h=r.copy()
        cv2.rectangle(r,(12,12),(45,84),1,thickness);cv2.rectangle(h,(12,12),(45,84),1,thickness+4)
        cv2.circle(r,(87,56),22,1,thickness);cv2.circle(h,(87,56),22,1,thickness+4)
        cv2.line(r,(9,100),(113,15),1,thickness);cv2.line(h,(9,100),(113,15),1,thickness+4)
        src=(r*.4+h*.6).astype(np.float32);known=np.ones(r.shape,bool);known[40:44,15:35]=False
        profiles('counter-junction-'+str(thickness),src,r,h,known);depths('counter-junction-'+str(thickness),src)
    # Border strokes retain forced-zero inside padding, forced-one complement.
    for side in ['left','right','top','bottom']:
        r=np.zeros((64,74),np.float32);h=r.copy()
        if side=='left':r[:,0:3]=1;h[:,0:8]=1
        if side=='right':r[:,-3:]=1;h[:,-8:]=1
        if side=='top':r[0:3,:]=1;h[0:8,:]=1
        if side=='bottom':r[-3:,:]=1;h[-8:,:]=1
        profiles('border-'+side,h,r,h,np.ones(r.shape,bool));depths('border-'+side,r)
    for shape in [(1,1),(1,39),(43,1),(2,2),(3,7),(30,44)]:
        for value in [0.,.5,1.]:
            a=np.full(shape,value,np.float32);depths('constant-'+str(shape)+'-'+str(value),a)
            profiles('degenerate-'+str(shape)+'-'+str(value),a,a,a,np.ones(shape,bool))
    # Float64 input is thresholded at original precision for hard profile;
    # soft depth casts to float32, but support still uses original src > .5.
    r,h,k=stems()
    for n in [np.nextafter(.5,0),.5,np.nextafter(.5,1)]:
        src=np.where(h>0,n,0).astype(np.float64)
        profiles('float64-source-support-'+repr(n),src,r.astype(np.float64),h.astype(np.float64),k)
        depths('float64-depth-'+repr(n),src)
    # Known floating maps use NumPy uint8 truncation/wrapping before erosion.
    for value in [.5,1.5,2.,255.,256.,257.,-1.]:
        profiles('known-cast-'+str(value),h,r,h,np.full(r.shape,value,np.float64))
    for unit in [.125,1.,31.25,48.,103.7,1e-50,1e100]:profiles('unit-'+str(unit),h,r,h,k,unit)
    for unit in [np.nan,np.inf]:
        with np.errstate(all='ignore'):
            want=hard(h,r,h,k,unit)
        add('hard-unit-'+str(unit),dict(op='hard',source=matrix(h),regular=matrix(r),heavy=matrix(h),known=matrix(k),unit=number(unit)),want)
    rng=np.random.default_rng(24791)
    for i in range(24):
        shape=(67+i,79+i);r=np.zeros(shape,np.float32)
        for j in range(6):
            x=int(rng.integers(4,shape[1]-18));y=int(rng.integers(4,shape[0]-22))
            r[y:y+int(rng.integers(8,21)),x:x+int(rng.integers(2,8))]=1
        h=cv2.dilate(r,cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(5,5)))
        if i%2:r=cv2.GaussianBlur(r,(3,3),.65);h=cv2.GaussianBlur(h,(3,3),.65)
        src=(r*(1-i/23)+h*(i/23)).astype(np.float32)
        if i%3==0:src=cv2.warpAffine(src,np.array([[1,0,.5],[0,1,-.5]],np.float64),(shape[1],shape[0]),flags=cv2.INTER_LINEAR)
        known=np.ones(shape,bool)
        if i%4==0:known[15:25,20:28]=False
        profiles('random-'+str(i),src,r,h,known,20+i/3);depths('random-'+str(i),src)
    good=len(records);invalid=[]
    r,h,k=stems()
    def reject(name,op,src=r,normal=r,bold=h,known=k,unit=48):
        fn=soft if op=='soft' else hard
        try:fn(src,normal,bold,known,unit)
        except Exception as e:
            invalid.append((name,dict(op=op,source=matrix(src),regular=matrix(normal),heavy=matrix(bold),known=matrix(known),unit=number(unit)),str(e)))
        else:raise AssertionError('Original unexpectedly accepted '+name)
    for op in ['hard','soft']:
        for unit in [0,-1,-np.inf]:reject(op+'-unit-'+str(unit),op,unit=unit)
        reject(op+'-shape',op,normal=np.zeros((3,5),np.float32))
        for key in ['src','normal','bold','known']:
            for value in [np.nan,np.inf]:
                args={key:np.full(r.shape,value,np.float32)};reject(op+'-'+key+'-'+str(value),op,**args)
    for unit in [np.nan,np.inf]:reject('soft-unit-'+str(unit),'soft',unit=unit)
    records.extend(record for _,record,_ in invalid)
    vendor=ROOT/'Vendor/NativeSourceCV';source=ROOT/'Vendor/SourceInference'
    with tempfile.TemporaryDirectory(prefix='aidoku-registered-profile-') as temp:
        temp=Path(temp);binary=temp/'profile';start=time.monotonic()
        command=['xcrun','clang++','-std=c++17','-O2','-fobjc-arc','-I'+str(vendor/'include'),'-I'+str(source),
                 str(Path(__file__).with_name('main.mm')),str(source/'SourceWeightRegisteredProfile.mm'),
                 str(vendor/'opencv2.xcframework/macos-arm64/libopencv2.a'),'-lz']
        for fw in ['Foundation','Accelerate','CoreGraphics','CoreVideo','AVFoundation','CoreMedia','OpenCL']:command+=['-framework',fw]
        subprocess.run(command+['-o',str(binary)],check=True);build=time.monotonic()-start
        (temp/'input.json').write_text(json.dumps(records,allow_nan=False));start=time.monotonic()
        subprocess.run([str(binary),str(temp/'input.json'),str(temp/'output.json')],check=True)
        duration=time.monotonic()-start;actual=json.loads((temp/'output.json').read_text())
    assert len(actual)==len(records),(len(actual),len(records))
    errors={'signed':0.,'depth':0.,'profiles':0.};fields=0
    for name,record,want,got in zip(names,records[:good],expected,actual[:good]):
        op=record['op'];assert 'error' not in got,(name,got)
        if op in ['signed','depth']:
            value=np.frombuffer(base64.b64decode(got['data']),dtype=np.float32).reshape((got['height'],got['width']))
            assert value.shape==want.shape and got['type']==5,name
            error=float(np.max(np.abs(value-want)));errors[op]=max(errors[op],error)
            np.testing.assert_allclose(value,want,atol=2e-6,rtol=0,err_msg=name)
        else:
            assert want.keys()==got.keys(),(name,want,got)
            for key,v in want.items():
                if key=='alphaLevels':assert got[key]==v==list(LEVELS),(name,key,got[key],v)
                elif isinstance(v,(bool,int)):assert got[key]==v,(name,key,got[key],v)
                elif not np.isfinite(v):assert got[key]==number(v),(name,key,got[key],v)
                else:
                    error=abs(got[key]-v);errors['profiles']=max(errors['profiles'],error);fields+=1
                    assert error<2e-6,(name,key,got[key],v,error)
    for (name,_,message),got in zip(invalid,actual[good:]):assert got.get('error')==message,(name,message,got)
    assert before==digests(),'Existing files changed'
    print(json.dumps(dict(cases=good,by_operation=coverage,usable=usable,invalid=len(invalid),profile_numeric_fields=fields,
                         max_abs=errors,build_seconds=build,native_seconds=duration,python_cv=cv2.__version__,oracle_sha256=before),indent=2))

if __name__=='__main__':run()
