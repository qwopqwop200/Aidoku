#!/usr/bin/env python3
"""Compare final source-ring admission ordering, crop geometry and page budgets."""
from __future__ import annotations
import argparse
import copy
import json
import pathlib
import shutil
import subprocess
import tempfile
import importlib.util
ROOT=pathlib.Path(__file__).resolve().parents[2]
OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
FIXTURES=ROOT/'Scripts/tests/fixtures/native-outline-scan'
REFERENCE=ROOT/'Scripts/native-render-parity/reference-source'
spec=importlib.util.spec_from_file_location('evidence',ROOT/'Scripts/tests/native-outline-evidence-parity.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

def fixtures():
    sample=dict(foreground=[12,12,12],stroke=[255,255,255],background=[255,255,255],confidence=dict(foreground=.8,stroke=.8))
    def record(id,**kwargs):return dict(id=str(id),bounds=[.2,.2,.35,.3],frame=[11.5,18.25,420,630],glyph=20,mode='readability-panel',plate=[255,255,255],ink=[12,12,12],sample=copy.deepcopy(sample),**kwargs)
    output=[]
    for index in range(18):
        records=[record(j) for j in range(4)]
        if index==0:pass
        elif index==1:
            for r in records:r['mode']='inpainted';r.pop('plate');r['stroke']=1
        elif index==2:
            for r in records:r['mode']='slanted-glyph-restored';r.pop('plate');r['sample']['confidence']['stroke']=.2;r['ink']=[150,150,150]
        elif index==3:
            for r in records:r['mode']='inpainted';r['vertical']=True;r['sample'].pop('stroke')
        elif index==4:
            for r in records:r['visible']=False
        elif index==5:
            for r in records:r['eligible']=False
        elif index==6:
            for r in records:r['mode']='manual'
        elif index==7:
            for r in records:r.pop('plate')
        elif index==8:
            for r in records:r.pop('glyph');r['bounds']=[.20213,.19852,.32145,.29849]
        elif index==9:
            for r in records:r['bounds']=[.0012,.98754,.35,.0121]
        elif index==10:
            for r in records:r['bounds']=[.2,.2,0,.3]
        elif index==11:
            for r in records:r['bounds']=[.9,.9,.3,.3];r['frame']=[0,0,640,900]
        elif index==12:
            for r in records:r['mode']='rotated-panel'
        elif index==13:
            for r in records:r['mode']='inpainted';r['sample']['confidence']['stroke']=.549;r['vertical']=True;r['sample']['confidence']['foreground']=.55
        elif index==14:
            for r in records:r['mode']='inpainted';r['sample']['confidence']['stroke']=.1;r['sample']['confidence']['foreground']=.1;r['vertical']=True;r['proof']='outlined-source-position'
        elif index==15:
            for r in records:r['mode']='slanted-glyph-restored';r['sample']['confidence']['stroke']=.54;r['ink']=[36,36,36]
        elif index==16:
            for r in records:r['mode']='slanted-glyph-restored';r['sample']['confidence']['stroke']=.54;r['ink']=[36.0001,36,36]
        elif index==17:
            for r in records:r['glyph']=-1;r['frame']=[0,0,0,50]
        output.append(dict(name=f'admission-{index:02}',image=[1024,1536],records=records))
    # A restored sampled caption and an unsampled slanted caption begin before
    # plates in input, then must move after them under stable rank ordering.
    for count in [9,10,11,12,16]:
        records=[record(j) for j in range(count)]
        for j,r in enumerate(records):
            r['bounds']=[.02+(j%5)*.18,.08+(j//5)*.2,.16,.18]
            if j%3==0:r['mode']='inpainted'
            if j%3==1:r['mode']='slanted-glyph-restored';r['sample']['confidence']['stroke']=.1;r['ink']=[170,170,170]
        output.append(dict(name=f'stable-budget-{count}',image=[4096,6144],records=records))
        reserve=copy.deepcopy(records);reserve[0]['stroke']=1;reserve[0]['reserve']=True
        output.append(dict(name=f'reserved-budget-{count}',image=[4096,6144],records=reserve,display=[0,0,420,630]))
    return output

def run(directory,reference):
    directory.mkdir(parents=True,exist_ok=True);inputs=directory/'input.json';inputs.write_text(json.dumps(fixtures()))
    source=directory/'main.swift';shutil.copyfile(FIXTURES/'main.swift',source);executable=directory/'native-outline-scan'
    subprocess.run(['xcrun','swiftc',str(OVERLAY/'NativeSourceOutlineEvidence.swift'),str(OVERLAY/'NativeSourceOutlineScan.swift'),str(source),'-o',str(executable)],check=True)
    native,browser=directory/'native.json',directory/'browser.json'
    subprocess.run([str(executable),str(inputs),str(native)],check=True)
    subprocess.run(['node',str(FIXTURES/'oracle.cjs'),str(inputs),str(reference),str(browser)],check=True)
    actual,expected=json.loads(native.read_text()),json.loads(browser.read_text());differences=[]
    for a,b in zip(actual,expected,strict=True):
        fields=[k for k in a if not module.same(a[k],b[k])]
        print(f"{a['name']}: {'DIFFERENT '+', '.join(fields) if fields else 'EXACT'} reads={len(a['reads'])}")
        if fields:differences.append(dict(name=a['name'],fields=fields))
    report=dict(exact=not differences,fixtures=len(actual),positiveReads=sum(bool(a['reads']) for a in actual),budgetRejected=sum(s['reject']=='budget' for a in actual for s in a['states']),scope='Frozen source-ring admission/rank/crops/page-budget and lower evidence; final paint decision and final raster excluded.',differences=differences)
    (directory/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    if differences:raise SystemExit('Source outline scan parity failed; inspect saved output.')

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--reference-overlay',type=pathlib.Path,default=REFERENCE);p.add_argument('--output-dir',type=pathlib.Path);a=p.parse_args()
    if a.output_dir:run(a.output_dir.resolve(),a.reference_overlay.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='aidoku-native-outline-scan-') as d:run(pathlib.Path(d),a.reference_overlay.resolve())
if __name__=='__main__':main()
