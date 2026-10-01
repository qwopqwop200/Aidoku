#!/usr/bin/env python3
"""Compare final plated balloon reflow against its frozen candidate search."""
from __future__ import annotations
import argparse,copy,importlib.util,json,pathlib,shutil,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2];OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';FIXTURES=ROOT/'Scripts/tests/fixtures/native-balloon-relayout';REFERENCE=ROOT/'Scripts/native-render-parity/reference-source'
spec=importlib.util.spec_from_file_location('comparison',ROOT/'Scripts/tests/native-outline-evidence-parity.py');comparison=importlib.util.module_from_spec(spec);spec.loader.exec_module(comparison)
def fixtures():
    out=[]
    for i in range(26):
        f=dict(name=f'relayout-{i:02}',text='가나다 라마바 사아자',font=12,pitch=14.4,ink=[8,75,86,20],box=[8,75,86,20],source=[75,75,50,50],frame=[0,0,200,200],contour=[55,45,90,110])
        if i==1:f['vertical']=True
        elif i==2:f['rotation']=.01
        elif i==3:f['balanced']=True
        elif i==4:f['script']='japanese'
        elif i==5:f['visible']=False
        elif i==6:f['text']='';
        elif i==7:f['text']='가'*181
        elif i==8:f['text']='가나\n다라'
        elif i==9:f['rendered']='다른 글자'
        elif i==10:f['tight']=True
        elif i==11:f['interior']=False
        elif i==12:f.pop('source')
        elif i==13:f['font']=0
        elif i==14:f['ink']=[80,80,40,25];f['box']=f['ink']
        elif i==15:f['unit']=True;f['tight']=True
        elif i==16:f['foreign']=[[50,40,100,120]]
        elif i==17:f['foreign']=[[70,95,20,30]]
        elif i==18:f['text']='긴단어가너무길어요'
        elif i==19:f['text']='가나다 라마바 사아자 차카타 파하';f['unit']=True
        elif i==20:f['text']='가 나 다 라 마 바 사 아';f['box']=[0,0,5,20]
        elif i==21:f['frame']=[0,0,70,200]
        elif i==22:f['source']=[-10,-10,20,20]
        elif i==23:f['text']='가나다라마바사아';f['unit']=True;f['contour']=[75,70,50,60]
        elif i==24:f['unit']=True;f['font']=8;f['pitch']=9.6
        elif i==25:f['script']='word';f['text']='hello native world'
        out.append(f)
    for size in [9,12,15,18,24]:
        for unit in [False,True]:
            out.append(dict(name=f'font-search-{size}-{unit}',text='가나다 라마바 사아자',font=size,pitch=size*1.2,ink=[8,75,86,20],box=[8,75,86,20],source=[75,75,50,50],frame=[0,0,200,200],contour=[65,55,70,90],unit=unit))
    for i in range(8):
        f=copy.deepcopy(out[0]);f.update(name=f'native-contour-{i}',nativeRect=[.25,.25,.5,.5],spans=[.35,.65,.3,.7,.25,.75,.25,.75,.3,.7,.35,.65],unit=True,queries=[[50,50,100,100],[70,70,50,40],[10,10,30,30],[48.3,61.7,34.4,28.8]])
        if i==1:f['spans']=[.25,.75]*6
        elif i==2:f['spans']=[-.1,-.1,.4,.5,.3,.7,.3,.7,.4,.5,-.1,-.1]
        elif i==3:f['paper']=[220,215,195]
        elif i==4:f['frame']=[11.25,7.125,420.5,630.25]
        elif i==5:f['nativeRect']=[.3,.3,.01,.01];f['spans']=[.3,.31]*6
        elif i==6:f['nativeRect']=[.2,.2,.7,.7];f['spans']=[.2,.9]*6
        elif i==7:f['frame']=[0,0,1300,1600];f['nativeRect']=[.1,.1,.5,.5];f['spans']=[.1,.6]*6
        out.append(f)
    return out

def run(directory,reference):
    directory.mkdir(parents=True,exist_ok=True);inputs=directory/'input.json';inputs.write_text(json.dumps(fixtures()));source=directory/'main.swift';shutil.copyfile(FIXTURES/'main.swift',source);executable=directory/'native-balloon-relayout'
    subprocess.run(['xcrun','swiftc',str(OVERLAY/'NativeBalloonRelayout.swift'),str(source),'-o',str(executable)],check=True)
    native,browser=directory/'native.json',directory/'browser.json';subprocess.run([str(executable),str(inputs),str(native)],check=True);subprocess.run(['node',str(FIXTURES/'oracle.cjs'),str(inputs),str(reference),str(browser)],check=True)
    actual,expected=json.loads(native.read_text()),json.loads(browser.read_text());differences=[]
    for a,b in zip(actual,expected,strict=True):
        exact=comparison.same(a['result'],b['result']) and comparison.same(a['interior'],b['interior']);print(f"{a['name']}: {'EXACT' if exact else 'DIFFERENT'}, accepted={bool(a['result'])}")
        if not exact:differences.append(dict(name=a['name'],fields=['result']))
    report=dict(exact=not differences,fixtures=len(actual),accepted=sum(bool(a['result']) for a in actual),fontReduced=sum(bool(a['result'] and len(a['result']['diagnostics'])==6) for a in actual),scope='Frozen balloon relayout search/final verification and native-unit sampled contour raster/integral with shared wordwrap metrics; CoreText/DOM adapter and final raster excluded.',differences=differences)
    (directory/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    if differences:raise SystemExit('Balloon reflow policy parity failed; inspect saved output.')
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--reference-overlay',type=pathlib.Path,default=REFERENCE);p.add_argument('--output-dir',type=pathlib.Path);a=p.parse_args()
    if a.output_dir:run(a.output_dir.resolve(),a.reference_overlay.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='aidoku-native-balloon-relayout-') as d:run(pathlib.Path(d),a.reference_overlay.resolve())
if __name__=='__main__':main()
