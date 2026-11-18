#!/usr/bin/env python3
"""Focused ctypes parity against actual optimized_measurements._neighbors.

Accept an isolated host dylib built from NativeSourceCV.cpp; never build MAIN.
"""
import argparse
import ctypes as c
import json
from pathlib import Path
import sys
import numpy as np

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Scripts/font_size_estimation'))
from optimized_measurements import _neighbors

F=c.POINTER(c.c_float)
I=c.POINTER(c.c_int32)

def main(library):
    lib=c.CDLL(str(Path(library).resolve()));fn=lib.acv_cosine_neighbors
    fn.argtypes=[F,c.c_int,F,c.c_int,c.c_int,I,c.c_int,c.c_int,I,F];fn.restype=c.c_int
    lib.acv_last_error.restype=c.c_char_p
    results=[]
    def call(q,r,omit=(),neighbors=8):
        q=np.ascontiguousarray(q,dtype=np.float32);r=np.ascontiguousarray(r,dtype=np.float32)
        ex=np.asarray(omit,dtype=np.int32);ix=np.full((len(q),8),-1,np.int32);dist=np.full((len(q),8),np.nan,np.float32)
        status=fn(q.ctypes.data_as(F),len(q),r.ctypes.data_as(F),len(r),r.shape[1],
                  ex.ctypes.data_as(I) if len(ex) else None,len(ex),neighbors,ix.ctypes.data_as(I),dist.ctypes.data_as(F))
        return status,ix,dist
    def parity(name,q,r,omit=(),weighted=False):
        source_groups=['page']*len(q)
        bank={'features':r,'emPerComponentScale':np.arange(len(r),dtype=np.float64),
              'support':np.ones(len(r)), 'excludedBySourceGroup':{'page':list(omit)}}
        gold=_neighbors(q,np.ones(len(q)),np.arange(len(q)),bank,weighted=weighted,source_groups=source_groups)
        query=np.array(q,dtype=np.float32,copy=True)
        if weighted:
            query[:,-5]*=3;query[:,-4:-1]*=3;query/=np.linalg.norm(query,axis=1)[:,None]
        status,ix,dist=call(query,r,omit)
        assert status==0,(name,lib.acv_last_error())
        np.testing.assert_array_equal(ix,gold['ratios'].astype(np.int32),err_msg=name)
        np.testing.assert_allclose(dist,gold['distances'],atol=1e-6,rtol=0,err_msg=name)
        delta=float(np.max(np.abs(dist-gold['distances']))) if len(q) else 0
        results.append({'case':name,'queries':len(q),'references':len(r),'indices':'exact','maxDistanceAbs':delta})
    rng=np.random.default_rng(761984)
    q=rng.normal(size=(259,198)).astype(np.float32);r=rng.normal(size=(2053,198)).astype(np.float32)
    parity('multi-query-and-reference-tiles',q,r)
    parity('shared-page-exclusions',q,r,[0,2,8,128,1023,1024,2052])
    parity('weighted84-query',q[:7],r,[7,700])
    # Actual helper's missing source-group exclusions maps to an empty list.
    bank={'features':r,'emPerComponentScale':np.arange(len(r)),'support':np.ones(len(r)),'excludedBySourceGroup':{}}
    missing=_neighbors(q[:3],np.ones(3),np.arange(3),bank,source_groups=['missing']*3)
    status,ix,dist=call(q[:3],r);assert status==0
    np.testing.assert_array_equal(ix,missing['ratios']);np.testing.assert_allclose(dist,missing['distances'],atol=1e-6,rtol=0)
    results.append({'case':'missing-exclusions','indices':'exact'})
    tie=np.zeros((24,198),np.float32);tie[:10,0]=1;tie[10:20,0]=-1
    queries=np.zeros((3,198),np.float32);queries[0,0]=1;queries[1,0]=-1
    parity('duplicates-zero-rows-and-stable-ties',queries,tie)
    parity('ties-with-exclusions',queries,tie,[0,1,2,10,11,20,21])
    status,ix,_=call(queries,tie,[0,0,1,1]);assert status==0
    assert list(ix[0,:8])==list(range(2,10));results.append({'case':'duplicate-exclusions-set-semantics','indices':'exact'})
    parity('exactly-eight-eligible',q[:2],r[:16],list(range(8)))
    for name,query,refs,omit,neighbors in [
        ('too-few-reference-rows',q[:1],r[:7],[],8),
        ('too-few-after-exclusion',q[:1],r[:16],list(range(9)),8),
        ('negative-exclusion',q[:1],r[:16],[-1],8),
        ('outside-exclusion',q[:1],r[:16],[16],8),
        ('not-eight-neighbors',q[:1],r[:16],[],7),
        ('nonfinite-query',np.full((1,198),np.nan,np.float32),r[:16],[],8),
        ('nonfinite-reference',q[:1],np.full((16,198),np.inf,np.float32),[],8)]:
        status,_,_=call(query,refs,omit,neighbors);assert status==-1,name
        assert lib.acv_last_error(),name;results.append({'case':name,'rejected':True})
    status,_,_=call(q[:0],r);assert status==0;results.append({'case':'zero-query-noop','passed':True})
    # This size mirrors the mapped bank, but native scratch remains tiled.
    large=rng.normal(size=(41000,198)).astype(np.float32)
    parity('mapped-bank-scale-41000x198',q[:2],large,[5,73,40999])
    report={'allPassed':True,'distanceTolerance':1e-6,'cases':results}
    output=ROOT/'build/native-source-cosine-check/PARITY.json';output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('library');args=parser.parse_args();main(args.library)
