#!/usr/bin/env python3
import base64,copy,json,subprocess,sys,tempfile,time
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'Scripts/font_weight_estimation'))
import numpy as np
import cv2
from word_pairs import word_masks,transform,font
from reference_grid import masks as grid_masks
from reference_ink_weight import reference_pairs,fair_face_fits
import masked_word_pairs as masked

def matrix(a):
    a=np.ascontiguousarray(a)
    return dict(width=a.shape[1],height=a.shape[0],type=5 if a.dtype==np.float32 else 0,data=base64.b64encode(a.tobytes()).decode())
def decoded(r):return np.frombuffer(base64.b64decode(r['data']),np.float32).reshape(r['height'],r['width'])
def run():
    bank=ROOT.parent/'font-weight-estimation-20261111/reference-bank'
    intervals=json.loads((bank/'WORD-PAIRS.json').read_text())['pairs']
    frames=reference_pairs(json.loads((bank/'PAIRS.json').read_text())['pairs']+intervals)
    byname={p['name']:p for p in frames}
    records=[];expected=[];names=[];kinds=[]
    for p in intervals[:4]:
        frame=byname[p['name']]
        for selected in [p,dict(name=p['name'],regular=p['regular'],heavy=p['regular'],_frame=frame)]:
            for vertical in [False,True]:
                for tracking in [.9,1.,1.1]:
                    for text in ['あ漢が','Afjg é','「はぁ?」','ー…（）','A\u0301Z','𝟙あ','あ\u0378']:
                        for op,fn in [('word',word_masks),('grid',grid_masks)]:
                            r=dict(op=op,pair=selected,text=text,vertical=vertical,tracking=tracking)
                            want=fn(selected,text,vertical,tracking)
                            records.append(r);expected.append(want);names.append((p['name'],bool(selected.get('_frame')),vertical,tracking,text,op));kinds.append('render')
    # Probe Pillow's float32-start -> 26.6 -> PIXEL double quantization,
    # including values just below the half-pixel threshold and negative bearings.
    for pair in intervals[:4]:
        for op,fn in [('word',word_masks),('grid',grid_masks)]:
            adv=max(font(pair['regular']).getlength('g'),font(pair['heavy']).getlength('g'))
            for phase in [.49,.49218749,.4921875,.5]:
                tracking=(adv+phase)/adv
                records.append(dict(op=op,pair=pair,text='gAfj',vertical=False,tracking=tracking))
                expected.append(fn(pair,'gAfj',False,tracking));names.append(('phase',pair['name'],op,phase));kinds.append('render')
    # Transform oracle with cross-axis scaling and rotation.
    for vertical in [False,True]:
        for angle in [-4.,0.,4.]:
            for cross in [.9,1.,1.1]:
                p=intervals[0];base=grid_masks(p,'「漢A」',vertical,.9)
                records.append(dict(op='grid',pair=p,text='「漢A」',vertical=vertical,tracking=.9,scale=.23125,cross=cross,angle=angle))
                expected.append(transform(*base,.23125,cross,angle,vertical));names.append(('transform',vertical,cross,angle));kinds.append('render')
    rng=np.random.default_rng(732)
    def put(r,want,name,kind):records.append(r);expected.append(want);names.append(name);kinds.append(kind)
    def pack(p):
        return dict(text=p['text'],alpha=matrix(p['alpha']),known=matrix(p['observed'].astype(np.uint8)),vertical=p['vertical'],
                                                        long=int(p['long']),crossExtent=int(p['cross']),boxLong=float(p['boxLong']),boxCross=float(p['boxCross']),unit=float(p['unit']))
    # Unmodified masked correlation and its shared-location stronger-OR locator.
    for shape,pshape in [((33,51),(11,17)),((11,17),(11,17)),((8,9),(11,17))]:
        source=rng.random(shape,dtype=np.float32);a=rng.random(pshape,dtype=np.float32);b=rng.random(pshape,dtype=np.float32)
        for ratio in [0.,.25,1.]:
            known=rng.random(shape)<ratio
            put(dict(op='correlation',source=matrix(source),known=matrix(known.astype(np.uint8)),pattern=matrix(a)),
                            masked.correlation(source,known,a),('corr',shape,ratio),'correlation')
            put(dict(op='locate',source=matrix(source),known=matrix(known.astype(np.uint8)),a=matrix(a),b=matrix(b)),
                            masked.locate(source,known,a,b),('locate',shape,ratio),'locate')
    # Complete prepared-word fits: no crop/profile producer or split/token rules.
    prepared_cases=[]
    for family in [0,3]:
        p=intervals[family]
        for vertical in [False,True]:
            text='「漢A」'
            base=grid_masks(p,text,vertical,.9)
            a,b=transform(*base,28/128,.9,0,vertical)
            for heavy in [False,True]:
                value=b if heavy else a
                alpha=np.pad(value,((7,9),(9,11))).astype(np.float32)
                known=np.ones(alpha.shape,bool);known[9:14,12:19]=False
                alpha[~known]=.8 # unknown must not become background evidence
                ys,xs=np.nonzero((alpha>.4)&known);spans=(int(np.ptp(ys)+1),int(np.ptp(xs)+1))
                long,cross=spans if vertical else spans[::-1]
                prep=dict(text=text,alpha=alpha,observed=known,vertical=vertical,long=long,cross=cross,boxLong=long*1.08,boxCross=cross*1.15,unit=28.)
                prepared_cases.append(prep)
                for grid in [False,True]:
                    for refine in [False,True]:
                        want=masked.fit(prep,p,refine,renderer=grid_masks if grid else word_masks)
                        put(dict(op='fit',pair=p,prepared=pack(prep),refine=refine,grid=grid),want,('fit',family,vertical,heavy,grid,refine),'fit')
    # Fair independent budgets and stable dedup across normal/strong intervals.
    for i in [0,1,2,3]:
        prep=prepared_cases[i]
        for refs in [intervals[:8],intervals[:8]+intervals[:2]]:
            want=[dict(fit=v,family=p['name'],weight=w) for v,p,w in fair_face_fits(prep,refs)]
            put(dict(op='fair',pairs=refs,prepared=pack(prep)),want,('fair',i,len(refs)),'fair')
    # No known support -> zero/no matches, independent of unknown ink.
    prep=copy.deepcopy(prepared_cases[0]);prep['observed'][:]=False
    put(dict(op='fit',pair=intervals[0],prepared=pack(prep),refine=True,grid=True),masked.fit(prep,intervals[0],True,renderer=grid_masks),'unknown-fit','fit')
    put(dict(op='fair',pairs=intervals[:8],prepared=pack(prep)),fair_face_fits(prep,intervals[:8]),'unknown-fair','fair')
    good=len(records)
    # Invalid SHA/axis are detected, with no fallback font and no copying.
    for field,value in [('SHA256','0'*64),('path','/missing/font.ttf'),('weight',10000)]:
        p=copy.deepcopy(intervals[0]);p['regular'][field]=value
        records.append(dict(op='grid',pair=p,text='漢A',vertical=False,tracking=1.))
    source=ROOT/'Vendor/SourceInference';vendor=ROOT/'Vendor/NativeSourceCV'
    with tempfile.TemporaryDirectory(prefix='aidoku-word-') as t:
        t=Path(t);binary=t/'words';start=time.monotonic()
        cmd=['xcrun','clang++','-std=c++17','-O2','-fobjc-arc','-I'+str(source),'-I'+str(vendor/'include'),'-I'+str(vendor/'freetype/include'),str(Path(__file__).with_name('main.mm')),str(source/'SourceWeightReferenceGrid.mm'),str(source/'SourceWeightWordFit.mm'),str(vendor/'NativeSourceCV.cpp'),str(vendor/'opencv2.xcframework/macos-arm64/libopencv2.a'),str(vendor/'FreeType.xcframework/macos-arm64/libfreetype.a'),'-lz']
        for fw in ['Foundation','Accelerate','CoreGraphics','CoreVideo','AVFoundation','CoreMedia','OpenCL']:cmd+=['-framework',fw]
        subprocess.run(cmd+['-o',str(binary)],check=True);build=time.monotonic()-start
        (t/'in.json').write_text(json.dumps(records));start=time.monotonic()
        subprocess.run([str(binary),str(t/'in.json'),str(t/'out.json')],check=True);duration=time.monotonic()-start
        actual=json.loads((t/'out.json').read_text())
    errors=[];maxerr=0;maxfit=0;maxcorr=0
    assert len(actual)==len(records)
    assert all(isinstance(v,dict) and 'error' in v for v in actual[good:])
    for name,kind,want,got in zip(names,kinds,expected,actual[:good]):
        if want is None:
            assert got is None,(name,got);continue
        assert not (isinstance(got,dict) and 'error' in got),(name,got)
        if kind=='render':
            for a,b in zip(want,got):
                b=decoded(b)
                if a.shape!=b.shape:errors.append((name,'shape',a.shape,b.shape));continue
                e=float(np.max(np.abs(a-b)));maxerr=max(maxerr,e)
                if e:errors.append((name,'pixels',e,int(np.count_nonzero(a!=b))))
        elif kind=='correlation':
            got=decoded(got);maxcorr=max(maxcorr,float(np.max(np.abs(want-got))))
            np.testing.assert_allclose(got,want,atol=2e-6,rtol=2e-6,err_msg=str(name))
        elif kind=='locate':
            np.testing.assert_allclose(got,want,atol=2e-6,rtol=2e-6,err_msg=str(name));assert got[3:]==list(want[3:]),name
        elif kind=='fit':
            maxfit=max(maxfit,float(np.max(np.abs(want-got))))
            np.testing.assert_allclose(got,want,atol=2e-6,rtol=2e-6,err_msg=str(name))
            np.testing.assert_array_equal(np.asarray(got)[[22,23,24,25,26,28,30,31]],want[[22,23,24,25,26,28,30,31]],err_msg=str(name))
        elif kind=='fair':
            assert len(want)==len(got),(name,len(want),len(got))
            for a,b in zip(want,got):
                assert (a['family'],a['weight'])==(b['family'],b['weight']),(name,a['family'],a['weight'],b['family'],b['weight'])
                maxfit=max(maxfit,float(np.max(np.abs(a['fit']-b['fit']))))
                np.testing.assert_allclose(b['fit'],a['fit'],atol=2e-6,rtol=2e-6,err_msg=str(name))
                np.testing.assert_array_equal(np.asarray(b['fit'])[[22,23,24,25,26,28,30,31]],a['fit'][[22,23,24,25,26,28,30,31]],err_msg=str(name))
    print(json.dumps(dict(build_seconds=build,native_seconds=duration,cases={k:kinds.count(k) for k in set(kinds)},invalid=len(records)-good,
                                                                                        max_raster=maxerr,max_correlation=maxcorr,max_fit=maxfit,mismatches=len(errors)),indent=2))
    print(*errors[:20],sep='\n')
    assert not errors
if __name__=='__main__':run()
