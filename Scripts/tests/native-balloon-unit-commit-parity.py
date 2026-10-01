#!/usr/bin/env python3
"""Late current-card balloon-unit blockers, readable floor and atomic commit parity."""
from __future__ import annotations
import argparse,copy,importlib.util,json,pathlib,shutil,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2];OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';FIXTURES=ROOT/'Scripts/tests/fixtures/native-balloon-unit-commit';REFERENCE=ROOT/'Scripts/native-render-parity/reference-source'
spec=importlib.util.spec_from_file_location('comparison',ROOT/'Scripts/tests/native-outline-evidence-parity.py');comparison=importlib.util.module_from_spec(spec);spec.loader.exec_module(comparison)
def records(prefix=''):
    unit=dict(members=[prefix+'a',prefix+'b'],rect=[.15,.15,.7,.7],center=[.5,.5],spans=[.15,.85]*6)
    return [dict(id=prefix+'a',text='가나다 라마바',font=12,pitch=14.4,glyph=12,bounds=[.3,.3,.2,.1],sources=[[60,60,40,20]],ink=[60,60,40,14],unit=copy.deepcopy(unit)),dict(id=prefix+'b',text='사아자 차카타',font=11,pitch=13.2,glyph=12,bounds=[.3,.5,.2,.1],sources=[[60,100,40,20]],ink=[60,100,40,14],unit=copy.deepcopy(unit))]
def fixtures():
    out=[]
    for i in range(32):
        rs=records();f=dict(name=f'unit-{i:02}',frame=[0,0,200,200],records=rs)
        if i==1:rs[0]['rotation']=.01
        elif i==2:rs[0]['vertical']=True
        elif i==3:rs[0]['balanced']=True
        elif i==4:rs[0]['root']=False
        elif i==5:rs[0]['transform']=False
        elif i==6:rs[0]['gloss']=True
        elif i==7:rs[0]['scale']=True
        elif i==8:rs[0]['background']='readability-panel'
        elif i==9:rs[0]['restored']=False
        elif i==10:rs[0]['restored']=False;rs[0]['surfaceFit']=True
        elif i==11:rs[0]['hasRestoration']=False
        elif i==12:rs[0]['complete']=False
        elif i==13:rs[0]['provisional']=True
        elif i==14:rs[0]['hidden']=True
        elif i==15:f['layers']=[dict(id='a',rect=[0,0,10,10])]
        elif i==16:f['layers']=[dict(id='a',rect=[0,0,10,10],participates=False)]
        elif i==17:rs[0]['alignment']='left-source'
        elif i==18:rs[0]['heading']=True
        elif i==19:rs[0]['font']=16;rs[0]['pitch']=19.2;rs[0]['glyph']=20;rs[1]['glyph']=12
        elif i==20:rs[0]['hasNode']=False
        elif i==21:
            for r in rs:r['font']=8.6;r['pitch']=10.32;r['unit']['rect']=[.3,.3,.4,.25];r['unit']['spans']=[.3,.7]*6
        elif i==22:
            rs[0]['font']=35;rs[0]['pitch']=42
        elif i==23:f['kept']=[dict(id='keep',rects=[[0,0,200,200]])]
        elif i==24:rs[0]['verifyDx']=1.1
        elif i==25:rs[0]['verifyDx']=.9
        elif i==26:rs[0]['commitFail']=True
        elif i==27:
            for r in rs:r['sourceVertical']=False
            rs[1]['bounds']=[.3,.5,.05,.1];rs[1]['sources']=[[60,100,10,20]]
        elif i==28:
            for r in rs:r['unit']['spans']=[-.1,-.1]*6
        elif i==29:
            for r in rs:r['unit']['members']=['a'];rs[0]['unit']['members']=['a']
        elif i==30:
            for r in rs:r['unit']['members']=['a','missing']
        elif i==31:
            rs[0]['text']='가';rs[1]['text']='사아자 차카타 파하';rs[1]['font']=13;rs[1]['pitch']=15.6
        out.append(f)
    rs=records();rs[0].update(text='가',font=8.6,pitch=10.32);rs[1].update(text='가나 '*14+'가나',font=7,pitch=8.4)
    for r in rs:r['unit']['rect']=[.15,.42,.7,.1525];r['unit']['spans']=[.15,.85]*6
    out.append(dict(name='readable-floor-keeps-current-member',frame=[0,0,200,200],records=rs))
    # The budget is one shared 480-probe page allowance; each unit is blocked
    # by already painted neighboring text, not by descriptor-only geometry.
    rs=[]
    for i in range(22):rs+=records(str(i)+'-')
    out.append(dict(name='shared-page-budget',frame=[0,0,200,200],records=rs))
    # An earlier successful unit updates the current physical glyph/font state
    # seen by a later overlapping group instead of replaying the old plan.
    rs=records();c=copy.deepcopy(rs[1]);c['id']='c';c['unit']=dict(members=['b','c'],rect=[.15,.15,.7,.7],center=[.5,.5],spans=[.15,.85]*6);rs.append(c)
    out.append(dict(name='overlapping-late-units',frame=[0,0,200,200],records=rs))
    return out

def run(directory,reference,policy):
    directory.mkdir(parents=True,exist_ok=True);inputs=directory/'input.json';inputs.write_text(json.dumps(fixtures()));source=directory/'main.swift';shutil.copyfile(FIXTURES/'main.swift',source);exe=directory/'native-balloon-unit'
    subprocess.run(['xcrun','swiftc',str(policy),str(source),'-o',str(exe)],check=True)
    native,browser=directory/'native.json',directory/'browser.json';subprocess.run([str(exe),str(inputs),str(native)],check=True);subprocess.run(['node',str(FIXTURES/'oracle.cjs'),str(inputs),str(reference),str(browser)],check=True)
    actual,expected=json.loads(native.read_text()),json.loads(browser.read_text());diff=[]
    for a,b in zip(actual,expected,strict=True):
        fields=[k for k in a if not comparison.same(a[k],b[k])];print(f"{a['name']}: {'DIFFERENT '+', '.join(fields) if fields else 'EXACT'}, layouts={a['layouts']}, probes={a['probes']}")
        if fields:diff.append(dict(name=a['name'],fields=fields))
    report=dict(exact=not diff,fixtures=len(actual),layouts=sum(a['layouts'] for a in actual),scope='Actual frozen late current-card unit chronology/blockers/weighted readable floor/search/atomic measured commit; shared deterministic text metrics, final raster excluded.',differences=diff)
    (directory/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    if diff:raise SystemExit('Late balloon unit parity failed; inspect saved output.')
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--reference-overlay',type=pathlib.Path,default=REFERENCE);p.add_argument('--policy-source',type=pathlib.Path,default=OVERLAY/'NativeTranslationBalloonUnitCommit.swift');p.add_argument('--output-dir',type=pathlib.Path);a=p.parse_args()
    if a.output_dir:run(a.output_dir.resolve(),a.reference_overlay.resolve(),a.policy_source.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='aidoku-native-balloon-unit-') as d:run(pathlib.Path(d),a.reference_overlay.resolve(),a.policy_source.resolve())
if __name__=='__main__':main()
