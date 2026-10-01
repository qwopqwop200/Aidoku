#!/usr/bin/env python3
"""Whole frozen deferred fixed-box callback with shared measured profiles."""
import argparse,copy,importlib.util,json,pathlib,shutil,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2];FIX=ROOT/'Scripts/tests/fixtures/native-caption-fixed-box-reflow';OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
spec=importlib.util.spec_from_file_location('compare',ROOT/'Scripts/tests/native-outline-evidence-parity.py');compare=importlib.util.module_from_spec(spec);spec.loader.exec_module(compare)
def fixtures():
 base=dict(lines=5,breaks=[3,8],starts=[5],ends=[7],isolated=2,punctuation=1,ink=[[110,110,40,60]])
 good=dict(lines=4,breaks=[3],starts=[],ends=[],isolated=1,punctuation=0,ink=[[110,110,90,60]])
 out=[]
 for i in range(34):
  f=dict(name=f'reflow-{i:02}',baseline=copy.deepcopy(base),probes=[dict(profile=copy.deepcopy(good)) for _ in range(3)])
  if i==1:f['preserve']=False
  elif i==2:f['opacity']=0
  elif i==3:f['automatic']=False
  elif i==4:f['vertical']=True
  elif i==5:f['script']='word'
  elif i==6:f['text']='가'*181
  elif i==7:f['text']='가\n나'
  elif i==8:f['text']='가\r나'
  elif i==9:f['budget']=27
  elif i==10:f['budget']=28
  elif i==11:f['baseline']=None
  elif i==12:f['baseline']['lines']=1
  elif i==13:f['panel']=[100,100,50,100]
  elif i==14:f['panel']=[100,100,50.5,100]
  elif i==15:
   for p in f['probes']:p['profile']=None
  elif i==16:
   for p in f['probes']:p['fits']=False
  elif i==17:
   for p in f['probes']:p['profile']['lines']=6
  elif i==18:
   for p in f['probes']:p['profile']['breaks']=[4]
  elif i==19:
   for p in f['probes']:p['profile']['starts']=[3,4]
  elif i==20:
   for p in f['probes']:p['profile']['ends']=[3,4]
  elif i==21:
   for p in f['probes']:p['profile']['isolated']=3
  elif i==22:
   for p in f['probes']:p['profile']['punctuation']=2
  elif i==23:
   for p in f['probes']:p['profile']['ink']=[[104.49,110,60,60]]
  elif i==24:
   for p in f['probes']:p['profile']['ink']=[[110,99.49,60,60]]
  elif i==25:f['others']=[[110,110,10,10]]
  elif i==26:
   for p in f['probes']:p['profile']=copy.deepcopy(base)
  elif i==27:f['probes'][0]['fits']=False
  elif i==28:f['probes'][0]['fits']=False;f['probes'][1]['fits']=False
  elif i==29:
   for p in f['probes']:p['profile']['ink']=[[104.5,99.5,111,101]]
  elif i==30:f['others']=[[199.5,169.5,10,10]]
  elif i==31:f['text']='가😀나다 라마바';f['width']=43.44679511278194
  elif i==32:
   for p in f['probes']:p['profile']['lines']=5
  elif i==33:
   for p in f['probes']:p['profile']['lines']=5;p['profile']['breaks']=[3,8]
  out.append(f)
 return out

def run(folder):
 folder.mkdir(parents=True,exist_ok=True);shutil.copyfile(FIX/'main.swift',folder/'main.swift');(folder/'input.json').write_text(json.dumps(fixtures()));exe=folder/'reflow'
 subprocess.run(['xcrun','swiftc',str(OVERLAY/'NativeCaptionFixedBoxReflow.swift'),str(folder/'main.swift'),'-o',str(exe)],check=True)
 a,b=folder/'native.json',folder/'frozen.json';subprocess.run([str(exe),str(folder/'input.json'),str(a)],check=True);subprocess.run(['node',str(FIX/'oracle.cjs'),str(folder/'input.json'),str(ROOT/'Scripts/native-render-parity/reference-source'),str(b)],check=True)
 native,frozen=json.loads(a.read_text()),json.loads(b.read_text());diff=[]
 for x,y in zip(native,frozen,strict=True):
  fields=[k for k in x if not compare.same(x[k],y.get(k))];print(x['name'],'EXACT' if not fields else 'DIFFERENT '+str(fields))
  if fields:diff.append(dict(name=x['name'],fields=fields))
 report=dict(exact=not diff,fixtures=len(native),accepted=sum(x['accepted'] for x in native),scope='Whole frozen deferred captionTextReflow fixed-box policy, eligibility/sharedcharacterbudget/scales/wordflow/contains/foreign-node overlap/atomic rollback/diagnostics. Shared measured profiles; native glyph profile adapter/platform shape/raster excluded.',differences=diff)
 (folder/'report.json').write_text(json.dumps(report,indent=2)+'\n')
 if diff:raise SystemExit('Fixed box callback parity differs')
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--output-dir',type=pathlib.Path);a=p.parse_args()
 if a.output_dir:run(a.output_dir.resolve())
 else:
  with tempfile.TemporaryDirectory(prefix='aidoku-caption-reflow-') as d:run(pathlib.Path(d))
