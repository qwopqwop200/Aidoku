#!/usr/bin/env python3
"""Exact sampled balloon fallback topology, contour raster and query comparison."""
from __future__ import annotations
import argparse,importlib.util,json,math,pathlib,shutil,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2];OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';FIXTURES=ROOT/'Scripts/tests/fixtures/native-balloon-interior';REFERENCE=ROOT/'Scripts/native-render-parity/reference-source'
spec=importlib.util.spec_from_file_location('comparison',ROOT/'Scripts/tests/native-outline-evidence-parity.py');comparison=importlib.util.module_from_spec(spec);spec.loader.exec_module(comparison)
def fixtures():
    out=[]
    for i in range(16):
        f=dict(name=f'interior-{i:02}',frame=[0,0,120,120],own=[[50,40,20,40]],glyph=20,queries=[[50,40,20,40],[10,10,30,30],[40.25,55.8,30.4,14.7],[0,0,120,120]])
        if i==8:f.update(members=2,own=[[42,40,16,40],[63,40,15,40]],union=[42,40,36,40])
        if i==9:f['own']=[[50,40,1,40]]
        if i==10:f['frame']=[5.25,3.125,120,120]
        if i==11:f.update(budget=70000,repeat=3)
        if i==12:f['glyph']=-1
        if i==13:f['frame']=[0,0,450,450];f['own']=[[210,170,40,100]];f['glyph']=32
        own=f['own'][0];u=f.get('union',own);ext=max(3*max(u[2],u[3]),27);frame=f['frame'];left=max(frame[0],u[0]-ext);top=max(frame[1],u[1]-ext);right=min(frame[0]+frame[2],u[0]+u[2]+ext);bottom=min(frame[1]+frame[3],u[1]+u[3]+ext);k=min(2,math.sqrt(250000/max(1,(right-left)*(bottom-top))));w=math.ceil((right-left)*k);h=math.ceil((bottom-top)*k)
        rgba=[]
        for y in range(h):
            py=top+(y+.5)*(bottom-top)/h
            for x in range(w):
                px=left+(x+.5)*(right-left)/w;cx,cy=(225,225) if i==13 else (60,60);rx,ry=(145,160) if i==13 else ((17,25) if i==1 else (40,45));inside=((px-cx)/rx)**2+((py-cy)/ry)**2<=1
                if i==2:inside=True
                if i==3:inside=inside or 58<py<62 and px<cx
                if i==4:inside=inside and not(px>55 and py<45)
                if i==14:inside=inside and not(px>72 and 35<py<85)
                rgb=[250,248,240] if i==5 else [250,250,250]
                if i==6:rgb=[250,180,170]
                if i==7:rgb=[90,90,90]
                if not inside:rgb=[25,25,25]
                if i==15 and 52<px<58 and 18<py<98:rgb=[15,15,15]
                if any(r[0]+4<px<r[0]+6 and r[1]+6<py<r[1]+r[3]-6 for r in f['own']):rgb=[15,15,15]
                rgba.extend(rgb+[255])
        f['rgba']=rgba;out.append(f)
    return out

def run(directory,reference):
    directory.mkdir(parents=True,exist_ok=True);inputs=directory/'input.json';inputs.write_text(json.dumps(fixtures()));source=directory/'main.swift';shutil.copyfile(FIXTURES/'main.swift',source);exe=directory/'native-balloon-interior'
    subprocess.run(['xcrun','swiftc','-O',str(OVERLAY/'NativeBalloonRelayout.swift'),str(OVERLAY/'NativeBalloonInteriorEstimator.swift'),str(source),'-o',str(exe)],check=True)
    native,browser=directory/'native.json',directory/'browser.json';subprocess.run([str(exe),str(inputs),str(native)],check=True);subprocess.run(['node',str(FIXTURES/'oracle.cjs'),str(inputs),str(reference),str(browser)],check=True)
    actual,expected=json.loads(native.read_text()),json.loads(browser.read_text());differences=[]
    for a,b in zip(actual,expected,strict=True):
        fields=[k for k in a if not comparison.same(a[k],b[k])];print(f"{a['name']}: {'DIFFERENT '+', '.join(fields) if fields else 'EXACT'}, accepted={sum(bool(r) for r in a['results'])}")
        if fields:differences.append(dict(name=a['name'],fields=fields))
    report=dict(exact=not differences,fixtures=len(actual),accepted=sum(bool(r) for a in actual for r in a['results']),tight=sum(bool(r and r['tight']) for a in actual for r in a['results']),scope='Frozen fallback source topology/full fill/integral queries/crop/page budget; shared source raster supplied and final renderer excluded.',differences=differences)
    (directory/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    if differences:raise SystemExit('Balloon interior parity failed; inspect saved output.')
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--reference-overlay',type=pathlib.Path,default=REFERENCE);p.add_argument('--output-dir',type=pathlib.Path);a=p.parse_args()
    if a.output_dir:run(a.output_dir.resolve(),a.reference_overlay.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='aidoku-native-balloon-interior-') as d:run(pathlib.Path(d),a.reference_overlay.resolve())
if __name__=='__main__':main()
