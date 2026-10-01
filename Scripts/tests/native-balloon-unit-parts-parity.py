#!/usr/bin/env python3
"""Frozen joined two-member part search, shared whole-word geometry callbacks."""
import argparse,copy,importlib.util,json,pathlib,shutil,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2];OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';FIX=ROOT/'Scripts/tests/fixtures/native-balloon-unit-parts'
spec=importlib.util.spec_from_file_location('compare',ROOT/'Scripts/tests/native-outline-evidence-parity.py');compare=importlib.util.module_from_spec(spec);spec.loader.exec_module(compare)
def fixtures():
 result=[]
 for i in range(28):
  f=dict(name=f'parts-{i:02}',text='가나다 라마바 사아자 차카타 파하가 나다라',members=[[170,100,100,70],[170,270,100,70]],font=12,root=True,interior=[0,0,500,500],span=400,panel=[50,40,370,390])
  if i==1:f['root']=False
  elif i==2:f['text']='가나다 라마바. 사아자 차카타 파하가 나다라'
  elif i==3:f['text']='가 나다라마바사'
  elif i==4:f['members'][1][1]=130
  elif i==5:f['members'].reverse()
  elif i==6:f['font']=24
  elif i==7:f['font']=22
  elif i==8:f['text']='가나다라마바사'
  elif i==9:f['text']='가나다\n 라마바'
  elif i==10:f['others']=[[0,0,500,500]]
  elif i==11:f['interior']=[130,80,180,310]
  elif i==12:f['interior']=[160,80,130,310]
  elif i==13:f['span']=80
  elif i==14:f['span']=40
  elif i==15:f['members'][0][2]=30
  elif i==16:f['members'][1][2]=30
  elif i==17:f['text']='  가나다  라마바   사아자 차카타 파하가  나다라   '
  elif i==18:f['text']='first words second part next text last phrase'
  elif i==19:f['text']='가나 😀라마 사아 차카 파하'
  elif i==20:f['root']=False;f['coverage']=[[60,50,200,100],[60,230,200,100]]
  elif i==21:f['root']=False;f['panel']=[200,170,50,30]
  elif i==22:f['text']='가나다? 라마바사아자차카타파하가나다라'
  elif i==23:f['members'][1][1]=160
  elif i==24:f['members'][1][1]=156
  elif i==25:f['font']=8
  elif i==26:f['others']=[[170,140,100,100]]
  elif i==27:f['text']='가나, 다라. 마바사 아자차 카타파 하가나 다라마'
  result.append(f)
 return result

def run(folder):
 folder.mkdir(parents=True,exist_ok=True);source=folder/'main.swift';shutil.copyfile(FIX/'main.swift',source);inputs=folder/'input.json';inputs.write_text(json.dumps(fixtures()));exe=folder/'parts'
 subprocess.run(['xcrun','swiftc',str(OVERLAY/'NativeBalloonUnitParts.swift'),str(source),'-o',str(exe)],check=True)
 a,b=folder/'native.json',folder/'frozen.json';subprocess.run([str(exe),str(inputs),str(a)],check=True);subprocess.run(['node',str(FIX/'oracle.cjs'),str(inputs),str(ROOT/'Scripts/native-render-parity/reference-source'),str(b)],check=True)
 native,frozen=json.loads(a.read_text()),json.loads(b.read_text());diff=[]
 for x,y in zip(native,frozen,strict=True):
  fields=[k for k in x if not compare.same(x[k],y.get(k))];print(x['name'], 'EXACT' if not fields else 'DIFFERENT '+str(fields))
  if fields:diff.append(dict(name=x['name'],fields=fields))
 report=dict(exact=not diff,fixtures=len(native),accepted=sum(x['accepted'] for x in native),scope='Whole frozen joined-two-member split parts search: source reading order, overlap veto, UTF16 area-share and punctuation break rank, font and width search, own surface/foreign ink checks, retained plate union and coverage. Shared whole-word measured geometry; platform CoreText shaping/raster and native runtime adapter excluded.',differences=diff)
 (folder/'report.json').write_text(json.dumps(report,indent=2)+'\n')
 if diff:raise SystemExit('Split parts parity differs')
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--output-dir',type=pathlib.Path);a=p.parse_args()
 if a.output_dir:run(a.output_dir.resolve())
 else:
  with tempfile.TemporaryDirectory(prefix='aidoku-unit-parts-') as d:run(pathlib.Path(d))
