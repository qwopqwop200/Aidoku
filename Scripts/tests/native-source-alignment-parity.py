#!/usr/bin/env python3
"""Bounded late source heading/alignment/edge policies against the frozen DOM pass."""
from __future__ import annotations
import argparse,copy,importlib.util,json,pathlib,shutil,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2];OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';FIXTURES=ROOT/'Scripts/tests/fixtures/native-source-alignment';REFERENCE=ROOT/'Scripts/native-render-parity/reference-source'
spec=importlib.util.spec_from_file_location('comparison',ROOT/'Scripts/tests/native-outline-evidence-parity.py');comparison=importlib.util.module_from_spec(spec);spec.loader.exec_module(comparison)
def base():
 return dict(name='base',frame=[0,0,200,200],records=[dict(id='a',text='가나다 라마바 사아자',source=[20,20,80,40],box=[20,20,80,40],font=10,sourceFont=10,lines=[[30,22,50,8],[38,34,34,8],[42,46,26,8]],flushLines=[[30,22,50,8],[30,34,34,8],[30,46,26,8]],fg=[0,0,0],bg=[255,255,255])],pixels=[[22,23,72,6],[22,35,51,6],[22,47,35,6]])
def fixtures():
 out=[]
 for i in range(26):
  f=base();r=f['records'][0];f['name']=f'align-{i:02}'
  if i==1:r['spans']=True
  elif i==2:r['visible']=False
  elif i==3:r['horizontal']=False
  elif i==4:r['rtl']=True
  elif i==5:r['transform']=False
  elif i==6:r['scale']=True
  elif i==7:r['sourceVertical']=True
  elif i==8:r['rotation']=.03
  elif i==9:r['sourceRotation']=True
  elif i==10:r['unsupported']=True
  elif i==11:f['pixels']=[[28,23,66,6],[36,35,50,6],[44,47,34,6]]
  elif i==12:f['pixels']+=[[0,20,25,4],[0,34,25,4],[0,46,25,4]]
  elif i==13:f['budget']=200
  elif i==14:r['flushLines']=[[10,22,70,8],[30,34,34,8],[30,46,26,8]]
  elif i==15:
   f['plates']=[dict(id='a',rect=[28,20,56,40],parent=True)];r['coverage']=[[38,20,46,40]]
  elif i==16:
   r.update(text='【가나다】 라마바 사아자',headingLines=[[30,22,36,8],[30,34,48,8],[30,46,40,8]])
  elif i==17:
   r.update(text='【가나다】 라마바 사아자',headingLines=[[30,22,36,8],[30,34,48,8],[30,46,40,8]],labelRows=2)
  elif i==18:
   r.update(text='【가나다】 라마바 사아자',headingLines=r['lines'])
  elif i==19:
   r.update(text='【가나다】 라마바 사아자',headingLines=[[30,22,36,8],[30,34,48,8],[30,46,40,8]],automatic=False)
  elif i==20:
   r.update(text='【가나다】 라마바 사아자',headingLines=[[30,22,36,8],[30,34,48,8],[30,46,40,8]],rendered='different words')
  elif i==21:
   r.update(text='이름이다! 라마바 사아자',headingLines=[[30,22,36,8],[30,34,48,8],[30,46,40,8]])
   f['pixels']=[[22,23,34,10],[22,37,60,6],[22,49,43,6]]
  elif i==22:
   r.update(text='【가나다】 라마바 사아자',headingLines=[[30,22,36,8],[30,34,48,8],[30,46,40,8]],overflow=2)
  elif i==23:
   r.update(text='【가나다】 라마바 사아자',headingLines=[[30,22,36,8],[30,34,48,8],[30,46,40,8]],extraHeight=5)
  elif i==24:f['pixelWidth']=100;f['pixelHeight']=100
  elif i==25:r.pop('fg');r.pop('bg')
  if 16<=i<=23 and i!=21:f['pixels']=[[22,23,34,6],[22,35,72,6],[22,47,51,6]]
  out.append(f)
 # Four moving edge candidates use actual old/new glyph footprints and source ownership.
 for k in range(8):
  f=dict(name=f'edge-{k:02}',frame=[0,0,250,250],records=[],pixels=[])
  for i in range(3):
   x=30 if i==0 else 45 if i==1 else 60;y=20+i*40
   f['records'].append(dict(id='safe-'+str(i) if k==4 else str(i),text='가나다',source=[20,y,90-i*15,16],box=[x,y,70,16],font=10,sourceFont=10,lines=[[x,y,50,10]],fg=[0,0,0],bg=[255,255,255]))
  if k==1:f['records'][0]['paint']=True
  elif k==2:f['records'][1]['sourceFont']=20
  elif k==3:f['plates']=[dict(id='1',rect=[44,59,52,12],parent=False)]
  elif k==5:f['records'][2]['lines'][0][0]=180
  elif k==6:f['records'][2]['rotation']=.05
  elif k==7:f['records'][1]['source'][0]=70
  out.append(f)
 # A two-line block inherits nearby source-aligned paragraph semantics.
 f=base();f['name']='left-column';r=copy.deepcopy(f['records'][0]);r.update(id='b',source=[20,72,80,25],box=[20,72,80,25],lines=[[32,74,40,8],[38,86,28,8]],flushLines=[[32,74,40,8],[32,86,28,8]]);f['records'].append(r);f['pixels'] += [[22,74,54,6],[22,86,30,6]];out.append(f)
 for k in range(12):
  f=base();r=f['records'][0];f['name']=f'heading-safety-{k:02}'
  r.update(text='○가나다○ 라마바 사아자',headingLines=[[30,22,36,8],[30,34,48,8],[30,46,40,8],[30,58,30,8]])
  f['pixels']=[[22,23,34,6],[22,35,72,6],[22,47,51,6]]
  if k==1:r['bg']=[200,200,200]
  elif k==2:r['root']=False
  elif k==3:f['plates']=[dict(id='a',rect=[28,20,55,50],parent=True)]
  elif k==4:f['plates']=[dict(id='a',rect=[28,20,55,50],parent=True,coverage=[[28,20,55,36]])]
  elif k==5:f['pixels'] += [[30,59,20,2]]
  elif k==6:r['headingLines'][3][1]=205
  elif k==7:r['headingLines'][3][0]=180
  elif k==8:r['overflow']=.5
  elif k==9:r['spans']=True
  elif k==10:r['text']='【'+('😀'*12)+'】 ラマ바 사아자'
  elif k==11:r['text']='【'+('😀'*17)+'】 라마바 사아자'
  out.append(f)
 return out

def run(directory,reference):
 directory.mkdir(parents=True,exist_ok=True);inputs=directory/'input.json';inputs.write_text(json.dumps(fixtures()));source=directory/'main.swift';shutil.copyfile(FIXTURES/'main.swift',source);exe=directory/'native-alignment'
 subprocess.run(['xcrun','swiftc',str(OVERLAY/'NativeTranslationSourceAlignment.swift'),str(source),'-o',str(exe)],check=True)
 native,browser=directory/'native.json',directory/'browser.json';subprocess.run([str(exe),str(inputs),str(native)],check=True);subprocess.run(['node',str(FIXTURES/'oracle.cjs'),str(inputs),str(reference),str(browser)],check=True)
 actual,expected=json.loads(native.read_text()),json.loads(browser.read_text());diff=[]
 for a,b in zip(actual,expected,strict=True):
  fields=[k for k in a if not comparison.same(a[k],b[k])];print(f"{a['name']}: {'DIFFERENT '+', '.join(fields) if fields else 'EXACT'}, headings={a['headings']} aligned={a['aligned']} edges={a['edgeMoves']}")
  if fields:diff.append(dict(name=a['name'],fields=fields))
 report=dict(exact=not diff,fixtures=len(actual),headings=sum(a['headings'] for a in actual),aligned=sum(a['aligned'] for a in actual),edgeMoves=sum(a['edgeMoves'] for a in actual),scope='Actual frozen bounded source pixel segmentation, heading safety/markers, committed flush-left and global edge target/undo policy; shared measured line rectangles, platform shaping/raster excluded.',differences=diff)
 (directory/'report.json').write_text(json.dumps(report,indent=2)+'\n')
 if diff:raise SystemExit('Source alignment parity failed; inspect saved output.')
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--reference-overlay',type=pathlib.Path,default=REFERENCE);p.add_argument('--output-dir',type=pathlib.Path);a=p.parse_args()
 if a.output_dir:run(a.output_dir.resolve(),a.reference_overlay.resolve())
 else:
  with tempfile.TemporaryDirectory(prefix='aidoku-native-align-') as d:run(pathlib.Path(d),a.reference_overlay.resolve())
if __name__=='__main__':main()
