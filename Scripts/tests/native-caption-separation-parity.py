#!/usr/bin/env python3
"""Exact final leading/column policies with shared deterministic line metrics."""
from __future__ import annotations
import argparse,json,math,pathlib,shutil,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
FIXTURES=ROOT/'Scripts/tests/fixtures/native-caption-separation'
REFERENCE=ROOT/'Scripts/native-render-parity/reference-source'
def fixtures():
    output=[]
    for i in range(60):
        entries=[];font=6+i%5*2;stroke=(i%4)*.8;pitch=font*.9
        for k in range(2+i%3):
            x,y=45+k*(20+i%7),40+(k%2)*(i%3)*3
            lines=[[x,y+j*pitch,35+(i%4)*4,font*1.05] for j in range(2+i%2)]
            entries.append(dict(id=str(k),frame=[0,0,300,300],source=[x+8,y,16,70],text='가나다'*len(lines),eligible=(i%11!=0),visible=(i%13!=0 or k==0),font=font,stroke=stroke,pitch=pitch,lines=lines,metrics=[[font*.8,font*.2]]*len(lines)))
        if i%8==0:entries[0]['lines']=[[45,275+j*pitch,35,font*1.05] for j in range(3)];entries[0]['text']='가나다'*3;entries[0]['metrics']=[[font*.8,font*.2]]*3
        output.append(dict(name=f'case-{i}',entries=entries,kept=[[10,40,27,100]] if i%7==0 else []))
    return output
def same(a,b):
    if isinstance(a,(float,int)) and isinstance(b,(float,int)):return math.isclose(a,b,abs_tol=1e-8,rel_tol=0)
    if isinstance(a,dict) and isinstance(b,dict):return a.keys()==b.keys() and all(same(a[k],b[k]) for k in a)
    if isinstance(a,list) and isinstance(b,list):return len(a)==len(b) and all(same(x,y) for x,y in zip(a,b))
    return a==b
def run(d,reference):
    d.mkdir(parents=True,exist_ok=True);inp=d/'input.json';inp.write_text(json.dumps(fixtures()));main=d/'main.swift';shutil.copyfile(FIXTURES/'main.swift',main);exe=d/'native-separation'
    subprocess.run(['xcrun','swiftc',str(OVERLAY/'NativeTranslationCaptionSeparation.swift'),str(main),'-o',str(exe)],check=True)
    native,browser=d/'native.json',d/'browser.json';subprocess.run([str(exe),str(inp),str(native)],check=True);subprocess.run(['node',str(FIXTURES/'oracle.cjs'),str(inp),str(reference),str(browser)],check=True)
    actual,expected=json.loads(native.read_text()),json.loads(browser.read_text());diff=[]
    for a,b in zip(actual,expected,strict=True):
        if not same(a,b):diff.append(a['name']);print(a['name']+': DIFFERENT')
    changed=sum(any(e['shift'][0]!=0 for e in a['entries']) for a in actual);leading=sum(any(e['pitch']!=r['pitch'] for e,r in zip(a['entries'],f['entries'])) for a,f in zip(actual,fixtures()))
    report=dict(exact=not diff and changed>0 and leading>0,fixtures=len(actual),columnPositive=changed,leadingPositive=leading,differences=diff);(d/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(report)
    if not report['exact']:raise SystemExit('Caption separation parity failed.')
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--reference-overlay',type=pathlib.Path,default=REFERENCE);p.add_argument('--output-dir',type=pathlib.Path);a=p.parse_args()
    if a.output_dir:run(a.output_dir.resolve(),a.reference_overlay.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='aidoku-native-caption-separation-') as d:run(pathlib.Path(d),a.reference_overlay.resolve())
if __name__=='__main__':main()
