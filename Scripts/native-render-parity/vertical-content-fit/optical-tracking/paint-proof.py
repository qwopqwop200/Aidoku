from pathlib import Path
import json,re,subprocess,hashlib
ROOT=Path(__file__).resolve().parents[4];HERE=Path(__file__).resolve().parent;O=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';OUT=ROOT/'build/native-render-parity/vertical-ideograph-paint';OUT.mkdir(parents=True,exist_ok=True)
BASE=ROOT/'build/native-render-parity/vertical-content-fit';OPT=ROOT/'build/native-render-parity/vertical-optical-tracking'
sources=[OPT/'TypographyCandidate.swift',O/'NativeTextPaintGeometry.swift',*[O/(n+'.swift') for n in ('NativePreformattedTabs','NativeKeepAllAutoLines','NativeKeepAllTextBalance','NativeKeepAllBreakOpportunities','NativeRawTextBalance','NativeVerticalLetterSpacing','NativeNormalTextFlow','NativeNormalBreakOpportunities','NativeCTFontStrokePainter','NativeVisibleControlGlyphs')],HERE/'NativeVerticalIdeographOpticalTracking.swift',HERE/'IdeographPaintProbe.swift']
subprocess.run(['xcrun','swiftc','-O','-swift-version','6',*map(str,sources),'-o',str(OUT/'probe')],check=True)
fixture=json.loads((BASE/'dom.json').read_text())[384]['a']
assert fixture['script']=='han' and fixture['text']=='天地玄黄宇宙洪荒'
subprocess.run(['xcrun','swiftc',str(HERE/'RasterPDF.swift'),'-o',str(OUT/'raster')],check=True)
rows=[]
script=(BASE/'capture.js').read_text().replace("letterSpacing: '-0.012em'","letterSpacing:`${a.tracking}px`").replace('node.remove();return result;','return result;')
for spacing in [-1,0,1]:
 job=dict(fixture,tracking=spacing);name=str(spacing)
 js=re.sub(r' const jobs=.*?;\n',' const jobs='+json.dumps([job],ensure_ascii=False)+';\n',script,count=1)
 (OUT/(name+'.js')).write_text(js)
 subprocess.run([str(ROOT/'build/native-render-parity/vertical-han-font/capture'),str(OUT/(name+'.js')),str(OUT/(name+'.json'))],check=True)
 (OUT/(name+'-web.pdf')).write_bytes((OUT/'web.pdf').read_bytes())
 subprocess.run([str(OUT/'probe'),str(OUT/(name+'.json')),str(OUT/(name+'-native.pdf'))],check=True)
 for kind in ['web','native']:
  subprocess.run([str(OUT/'raster'),str(OUT/(name+'-'+kind+'.pdf')),str(OUT/(name+'-'+kind+'.rgba'))],check=True)
 web=(OUT/(name+'-web.rgba')).read_bytes();native=(OUT/(name+'-native.rgba')).read_bytes()
 assert len(web)==len(native)==780*1400*4
 rows.append(dict(tracking=spacing,pixels=780*1400,changedPixels=sum(web[i:i+4]!=native[i:i+4] for i in range(0,len(web),4)),maxChannelDelta=max(abs(w-n) for w,n in zip(web,native))))
report=dict(scope='One literal all-Han scene under three tracking signs; actual WK and staged native PDF captured, then both rasterized identically. No iOS or final fixture equality follows.',rows=rows,sourceSHA256={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[BASE/'dom.json',BASE/'capture.js',HERE/'RasterPDF.swift']})
(OUT/'report.json').write_text(json.dumps(report,indent=2,ensure_ascii=False));print(json.dumps(rows))
