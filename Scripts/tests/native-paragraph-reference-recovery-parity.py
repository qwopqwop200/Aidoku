#!/usr/bin/env python3
"""Whole frozen paragraph-reference proposal with shared font/profile callbacks."""
import json,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
FIX=ROOT/'Scripts/tests/fixtures/native-paragraph-reference-recovery'
def main():
 base={'text':'그대의 작은 글씨를 읽기 좋은 곳에 다시 가지런히 놓을 것이랍니다','font':10,'lineHeightRatio':1.2,'usableWidth':180,'usableHeight':120,'automaticRecovery':True,'hasReference':False,'vertical':False,'sourceVertical':False,'script':'korean','fittedFont':10,'lines':2,'refinement':16384,'readable':2048,'probe':512}
 base['text']='그대의 작은 글씨는 이 넓은 상자 안에서 가지런히 읽힐 것이랍니다 공녀의 명령이랍니다'
 cases=[base]
 cases += [{**base,'text':base['text'].replace(' ', separator)} for separator in ['\ufeff','\u0085','\u00a0']]
 for key,values in {'font':[8.99,9,11.5,11.99,12],'fittedFont':[8.99,9,9.5,11.5],'lines':[None,1,2,3,5],
 'usableWidth':[119.99,120,120.01,240],'usableHeight':[47.99,48,50,60,96,120],
 'lineHeightRatio':[1,1.2,1.5],'automaticRecovery':[False],'hasReference':[True],'vertical':[True],
 'sourceVertical':[True],'script':['word','japanese'],'refinement':[0,32,50],'readable':[0,32,50],'probe':[0,32,50]}.items():
  cases += [{**base,key:value} for value in values]
 for font in [9,10,11.5,11.51]:
  for text in ['짧은 두 단어','짧은 단어','하나','아주 짧은 작은 두 글씨를','그대의 작은 글씨\n위험한 문단','그대의 작은 글씨\r위험한 문단']:
   cases.append({**base,'font':font,'text':text,'sourceVertical':True,'usableWidth':30})
 for used in [23.99,24,24.01,47.99,48,48.01]: cases.append({**base,'usableHeight':used*2})
 with tempfile.TemporaryDirectory(prefix='aidoku-paragraph-reference-') as folder:
  folder=pathlib.Path(folder);(folder/'input.json').write_text(json.dumps(cases,ensure_ascii=False))
  subprocess.run(['swiftc','-O',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeParagraphReferenceRecovery.swift'),str(FIX/'main.swift'),'-o',str(folder/'probe')],check=True)
  subprocess.run([str(folder/'probe'),str(folder/'input.json'),str(folder/'native.json')],check=True)
  subprocess.run(['node',str(FIX/'oracle.cjs'),str(folder/'input.json'),str(folder/'frozen.json'),str(ROOT/'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift')],check=True)
  a=json.loads((folder/'native.json').read_text());b=json.loads((folder/'frozen.json').read_text());diff=[{'case':i,'native':x,'frozen':y} for i,(x,y) in enumerate(zip(a,b)) if x!=y]
  report={'cases':len(cases),'exact':len(cases)-len(diff),'positives':sum(x['proposal'] is not None for x in b),'differences':diff,'scope':'Whole original3693–3734 paragraph proposal, guard/probe-debit/font-profile callback order/additionalLines/12pt cap. Shared supplied font/profile; native actual shaping and pixel raster excluded.'}
  path=ROOT/'build/native-render-parity/paragraph-reference-recovery-policy.json';path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(report,indent=2));print(json.dumps(report));assert not diff
if __name__=='__main__':main()
