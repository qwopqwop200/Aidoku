#!/usr/bin/env python3
"""Frozen two-probe inline Korean repair and short strict punctuation acceptance."""
from __future__ import annotations
import argparse,copy,importlib.util,json,pathlib,shutil,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2];OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';FIXTURES=ROOT/'Scripts/tests/fixtures/native-korean-inline-repair';REFERENCE=ROOT/'Scripts/native-render-parity/reference-source'
spec=importlib.util.spec_from_file_location('comparison',ROOT/'Scripts/tests/native-outline-evidence-parity.py');comparison=importlib.util.module_from_spec(spec);spec.loader.exec_module(comparison)
def fixtures():
 out=[]
 for i in range(27):
  f=dict(name=f'inline-{i:02}',font=10,text='가나다라마바 사아자차카타',profiles={'10.00':dict(lines=3,breaks=[3,9],starts=[6],ends=[]),'9.25':dict(lines=3,breaks=[3],starts=[],ends=[]),'9.00':dict(lines=2,breaks=[],starts=[],ends=[])})
  p=f['profiles']
  if i==1:f['widest']=20
  elif i==2:f['budget']=2
  elif i==3:f['vertical']=True
  elif i==4:f['script']='word'
  elif i==5:p['9.25']['fits']=False
  elif i==6:p['9.25']['breaks']=[4];p['9.00']['breaks']=[5]
  elif i==7:p['9.25']['starts']=[6,7];p['9.00']['starts']=[6,7]
  elif i==8:p['9.25']['ends']=[5];p['9.00']['ends']=[5]
  elif i==9:p['9.25']['lines']=4;p['9.00']['lines']=4
  elif i==10:p['9.25']['ink']=[[-1,2,10,10]]
  elif i==11:f['minimum']=9.5
  elif i==12:p['10.00']['breaks']=[];p['10.00']['starts']=[]
  elif i==13:p['10.00']['null']=True
  elif i==14:f['text']='가'*181
  elif i==15:
   p['9.25']['starts']=[6];p['9.00']['starts']=[];p['9.00']['breaks']=[3]
  elif i>=16:
   f['text']='가나다!';p['10.00'].update(lines=2,breaks=[3],starts=[3]);p['strict']=dict(lines=1,breaks=[],starts=[],ends=[])
   if i==17:p['strict']['ink']=[[0,2,10,10]]
   elif i==18:p['strict']['ends']=[1]
   elif i==19:p['strict']['breaks']=[2]
   elif i==20:p['strict']['starts']=[3]
   elif i==21:p['strict']['lines']=3
   elif i==22:p['strict']['fits']=False
   elif i==23:f['exclusions']=[[2,2,10,10]]
   elif i==24:f['text']='가 나!'
   elif i==25:f['padding']=[2,.5,2,.5]
   elif i==26:p['9.25']['breaks']=[];p['9.25']['starts']=[]
  out.append(f)
 return out

def run(directory,reference):
 directory.mkdir(parents=True,exist_ok=True);inputs=directory/'input.json';inputs.write_text(json.dumps(fixtures()));source=directory/'main.swift';shutil.copyfile(FIXTURES/'main.swift',source);exe=directory/'native-inline'
 subprocess.run(['xcrun','swiftc',str(OVERLAY/'NativeKoreanInlineRepair.swift'),str(source),'-o',str(exe)],check=True)
 native,browser=directory/'native.json',directory/'browser.json';subprocess.run([str(exe),str(inputs),str(native)],check=True);subprocess.run(['node',str(FIXTURES/'oracle.cjs'),str(inputs),str(reference),str(browser)],check=True)
 actual,expected=json.loads(native.read_text()),json.loads(browser.read_text());diff=[]
 for a,b in zip(actual,expected,strict=True):
  fields=[k for k in a if not comparison.same(a[k],b[k])];print(f"{a['name']}: {'DIFFERENT '+', '.join(fields) if fields else 'EXACT'}")
  if fields:diff.append(dict(name=a['name'],fields=fields))
 report=dict(exact=not diff,fixtures=len(actual),wrapAccepted=sum(a['wrap'] for a in actual),punctuationAccepted=sum(a['punctuation'] for a in actual),scope='Actual frozen inline shrink ratios, shared character budget, break-identity/penalty/geometry veto, short strict-padding acceptance and rollback; shared shaped profiles, platform strict line breaking/raster excluded.',differences=diff)
 (directory/'report.json').write_text(json.dumps(report,indent=2)+'\n')
 if diff:raise SystemExit('Korean inline parity failed; inspect saved output.')
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--reference-overlay',type=pathlib.Path,default=REFERENCE);p.add_argument('--output-dir',type=pathlib.Path);a=p.parse_args()
 if a.output_dir:run(a.output_dir.resolve(),a.reference_overlay.resolve())
 else:
  with tempfile.TemporaryDirectory(prefix='aidoku-native-inline-') as d:run(pathlib.Path(d),a.reference_overlay.resolve())
if __name__=='__main__':main()
