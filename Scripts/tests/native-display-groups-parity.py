#!/usr/bin/env python3
"""Whole frozen display-column group search with retained plate tilts and shared metrics."""
from __future__ import annotations
import argparse,copy,importlib.util,json,math,pathlib,shutil,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2];OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';FIXTURES=ROOT/'Scripts/tests/fixtures/native-display-groups';REFERENCE=ROOT/'Scripts/native-render-parity/reference-source'
spec=importlib.util.spec_from_file_location('comparison',ROOT/'Scripts/tests/native-outline-evidence-parity.py');comparison=importlib.util.module_from_spec(spec);spec.loader.exec_module(comparison)
def turn(x,y,t):return [x*math.cos(t)-y*math.sin(t),x*math.sin(t)+y*math.cos(t)]
def cell(i,angle=.2):return dict(id=str(i),text='가나다라',glyph=60,font=20,color=[250,245,240],width=90,height=190,angle=angle,center=turn(80+i*85,180,angle))
def fixtures():
 out=[]
 for i in range(26):
  f=dict(name=f'display-{i:02}',cells=[cell(0),cell(1)]);a,b=f['cells']
  if i==1:b['angle']=.41
  elif i==2:b['glyph']=82
  elif i==3:b['color']=[190,245,240]
  elif i==4:b['center']=turn(200,180,.2)
  elif i==5:b['center']=turn(110,180,.2)
  elif i==6:b['center']=turn(165,290,.2)
  elif i==7:a['font']=50;b['font']=50
  elif i==8:a['font']=10;b['font']=50
  elif i==9:a['text']='가나다라마바사아자차카타파하'
  elif i==10:f['foreign']=[dict(id='foreign',rect=[0,0,500,500])]
  elif i==11:f['cells']=[cell(0)]
  elif i==12:f['cells']=[cell(j) for j in range(3)]
  elif i==13:f['cells']=[cell(j) for j in range(4)]
  elif i==14:f['cells']=[cell(j) for j in range(5)]
  elif i==15:b['center']=turn(165,260,.2)
  elif i==16:a['text']='가나다라 마바사아';b['text']='자차카타 파하'
  elif i==17:a['glyph']=300;b['glyph']=300
  elif i==18:a['height']=70;b['height']=70
  elif i==19:a['angle']=.16;b['angle']=.23
  elif i==20:a['text']='가나 다';b['text']='라마 바'
  elif i==21:a['text']='A😀BC';b['text']='D😀EF'
  elif i==22:
   a['color']=[0,0,0];b['color']=[48,48,48]
  elif i==23:b['glyph']=81
  elif i==24:
   a['font']=35;b['font']=35
  elif i==25:
   for c in f['cells']:c['width']=85
  out.append(f)
 # Two independent groups see the current final ink of already-set groups.
 f=dict(name='multiple-groups',cells=[cell(0),cell(1),cell(2),cell(3)])
 for c in f['cells'][2:]:c['color']=[0,0,0];c['center'][1]+=270
 out.append(f)
 return out

def run(directory,reference):
 directory.mkdir(parents=True,exist_ok=True);inputs=directory/'input.json';inputs.write_text(json.dumps(fixtures()));source=directory/'main.swift';shutil.copyfile(FIXTURES/'main.swift',source);exe=directory/'native-display'
 subprocess.run(['xcrun','swiftc',str(OVERLAY/'NativeTranslationDisplayGroups.swift'),str(source),'-o',str(exe)],check=True)
 native,browser=directory/'native.json',directory/'browser.json';subprocess.run([str(exe),str(inputs),str(native)],check=True);subprocess.run(['node',str(FIXTURES/'oracle.cjs'),str(inputs),str(reference),str(browser)],check=True)
 actual,expected=json.loads(native.read_text()),json.loads(browser.read_text());diff=[]
 for a,b in zip(actual,expected,strict=True):
  fields=[k for k in a if not comparison.same(a[k],b[k])];print(f"{a['name']}: {'DIFFERENT '+', '.join(fields) if fields else 'EXACT'} groups={a['groups']}")
  if fields:diff.append(dict(name=a['name'],fields=fields))
 report=dict(exact=not diff,fixtures=len(actual),groups=sum(a['groups'] for a in actual),scope='Whole actual frozen admitted display-column grouping/component order/fonts/search/own-tilt inset/foreign ink rejection and final transformed glyph boxes; shared text metrics, native plate eligibility adapter/raster excluded.',differences=diff)
 (directory/'report.json').write_text(json.dumps(report,indent=2)+'\n')
 if diff:raise SystemExit('Display group parity failed; inspect saved output.')
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--reference-overlay',type=pathlib.Path,default=REFERENCE);p.add_argument('--output-dir',type=pathlib.Path);a=p.parse_args()
 if a.output_dir:run(a.output_dir.resolve(),a.reference_overlay.resolve())
 else:
  with tempfile.TemporaryDirectory(prefix='aidoku-native-display-') as d:run(pathlib.Path(d),a.reference_overlay.resolve())
if __name__=='__main__':main()
