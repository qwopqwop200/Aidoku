#!/usr/bin/env python3
"""Actual raw restoration CGImage transport versus WebKit Canvas putImageData."""
import argparse,hashlib,json,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent

def method(text,start):
 begin=text.index('{',start);depth=0
 for end in range(begin,len(text)):
  if text[end]=='{':depth+=1
  if text[end]=='}':
   depth-=1
   if depth==0:return text[start:end+1]
 raise ValueError('unclosed method')

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,default=ROOT/'build/native-render-parity/restoration-image-transport');args=parser.parse_args();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
 production=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeRestorationPixels.swift';text=production.read_text();image=method(text,text.index('    func image() -> CGImage?'))
 shell='import Foundation\nimport CoreGraphics\nstruct NAME { let width:Int;let height:Int;let rgba:[UInt8]\nMETHOD\n}\n'
 extracted=out/'Transport.swift';extracted.write_text(shell.replace('NAME','NativeImageTransportProbe').replace('METHOD',image)+shell.replace('NAME','StraightImageTransportProbe').replace('METHOD',image.replace('CGImageAlphaInfo.premultipliedLast','CGImageAlphaInfo.last'))+shell.replace('NAME','CanonicalImageTransportProbe').replace('METHOD',image.replace('CGImageAlphaInfo.last','CGImageAlphaInfo.premultipliedLast')))
 started=time.monotonic();executable=out/'transport-probe'
 subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete',str(extracted),str(HERE/'Probe.swift'),'-o',str(executable)],check=True,cwd=ROOT)
 completed=subprocess.run([str(executable),str(out/'raster-pairs.json')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,cwd=ROOT);(out/'oracle.log').write_text(completed.stdout)
 if completed.returncode:print(completed.stdout);return completed.returncode
 pairs=json.loads((out/'raster-pairs.json').read_text());oracle={row['name']:row['rgba'] for row in pairs['oracle']};assert len(oracle)==40 and len(pairs['native'])==120
 rows=[];coverage={}
 for native in pairs['native']:
  expected=oracle[native['name']];actual=native['rgba'];assert len(expected)==len(actual)
  delta=[abs(a-b) for a,b in zip(expected,actual)];changed=[i for i,d in enumerate(delta) if d];first=changed[0]//4 if changed else None
  row={'name':native['name'],'variant':native['variant'],'exact':not changed,'differingBytes':len(changed),'differingPixels':len({i//4 for i in changed}),'maxChannelDelta':max(delta),'firstDifferingPixel':first,'oraclePixel':expected[first*4:first*4+4] if first is not None else None,'nativePixel':actual[first*4:first*4+4] if first is not None else None,'channelMaximumDeltas':[max(delta[c::4]) for c in range(4)],'oracleSHA256':hashlib.sha256(bytes(expected)).hexdigest(),'nativeSHA256':hashlib.sha256(bytes(actual)).hexdigest()};rows.append(row)
  c=coverage.setdefault(row['variant'],{'cases':0,'exact':0,'maxChannelDelta':0});c['cases']+=1;c['exact']+=row['exact'];c['maxChannelDelta']=max(c['maxChannelDelta'],row['maxChannelDelta'])
 report={'productionMatchesCanvas':coverage['production']['exact']==40,'oracleAvailable':True,'coverage':coverage,'scope':'Actual unchanged production image() method extracted verbatim, ImageIO PNG encode/decode and BGRA sRGB CoreGraphics draw versus actual WKWebView putImageData/toDataURL/drawImage/getImageData. Candidate alpha-last and canonical premultiplication remain host-only diagnostic variants; no production edits. AllRGBA bytes compared without tolerance.','sourceSHA256':hashlib.sha256(production.read_bytes()).hexdigest(),'methodSHA256':hashlib.sha256(image.encode()).hexdigest(),'webKitUserAgent':pairs['userAgent'],'devicePixelRatio':pairs['devicePixelRatio'],'seconds':time.monotonic()-started,'rows':rows}
 (out/'report.json').write_text(json.dumps(report,indent=2));(out/'report.md').write_text('| Pattern/route/query | Variant | Exact | Changed bytes | Max RGBA delta |\n|---|---|---|---:|---:|\n'+'\n'.join(f"| {r['name']} | {r['variant']} | {'PASS' if r['exact'] else 'MISMATCH'} | {r['differingBytes']} | {r['maxChannelDelta']} |" for r in rows)+'\n');print(json.dumps(coverage,indent=2));print(out/'report.json');return 0
if __name__=='__main__':raise SystemExit(main())
