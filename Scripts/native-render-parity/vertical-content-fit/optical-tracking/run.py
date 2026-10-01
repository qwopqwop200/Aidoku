#!/usr/bin/env python3
from pathlib import Path
import json,re,subprocess,hashlib,sys
ROOT=Path(__file__).resolve().parents[4];HERE=Path(__file__).resolve().parent
O=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
OUT=ROOT/'build/native-render-parity/vertical-optical-tracking';OUT.mkdir(parents=True,exist_ok=True)
BASE=ROOT/'build/native-render-parity/vertical-content-fit'
allrows=json.loads((BASE/'dom.json').read_text())
indices=list(range(336,448))+list(range(188,224)) if '--controls' in sys.argv else [196,197,396,397,414,415,424,425,426,427,444,445]
(OUT/'inputs.json').write_text(json.dumps([allrows[i] for i in indices],ensure_ascii=False))
layout=(O/'NativeTranslationLayout.swift').read_text()
(OUT/'Models.swift').write_text(layout.split('/// Actor confinement')[0].replace('import UIKit\n',''))
geometry=re.search(r'    static func validGeometry\([\s\S]*?\n    }',layout).group()
(OUT/'Shims.swift').write_text('import CoreGraphics\nstruct UIEdgeInsets {var top:CGFloat;var left:CGFloat;var bottom:CGFloat;var right:CGFloat}\nextension CGRect {func inset(by i:UIEdgeInsets)->CGRect {CGRect(x:minX+i.left,y:minY+i.top,width:width-i.left-i.right,height:height-i.top-i.bottom)}}\nenum NativeTranslationLayoutPlanner {\n'+geometry+'\n}\n')
post=(O/'NativeTypographyPostPolish.swift').read_text()
(OUT/'PostAdapter.swift').write_text('import Foundation\nimport CoreGraphics\nenum NativeTypographyPostPolish {\n'+post[post.index('    struct ContentFitMetrics:'):post.index('    struct Candidate {')]+'\n}\n')
core=(O/'NativeTranslationTypography.swift').read_text()
needle='        return result\n    }\n\n    /// CSS keep-all'
assert needle in core
call='NativeVerticalLetterSpacing' if '--tracking-only' in sys.argv else 'NativeVerticalOpticalTracking' if '--tracking' in sys.argv else 'NativeVerticalOpticalKern'
hook='        if style.vertical { '+call+'.apply(to: result) }\n'
candidate=core if hook in core else core.replace(needle,hook+needle,1)
if '--tracking' in sys.argv or '--tracking-only' in sys.argv:
 candidate=candidate.replace('scalar.start > range.location ? style.tracking / 2 : 0','!style.vertical && scalar.start > range.location ? style.tracking / 2 : 0').replace('scalar.end < range.location + range.length ? style.tracking / 2 : 0','!style.vertical && scalar.end < range.location + range.length ? style.tracking / 2 : 0')
if '--ideographs' in sys.argv:
 call='NativeVerticalIdeographOpticalTracking'
 candidate=core.replace(needle,'        if style.vertical { NativeVerticalIdeographOpticalTracking.apply(to: result) }\n'+needle,1)
 candidate=candidate.replace('        let offset: CGPoint\n        if style.vertical {','        var offset: CGPoint\n        if style.vertical {',1)
 candidate=candidate.replace('        let painted = ink.offsetBy(dx: offset.x, dy: offset.y)','        if style.vertical { offset.y += NativeVerticalIdeographOpticalTracking.paintCenterShift(frame: frame, attributed: attributed) }\n        let painted = ink.offsetBy(dx: offset.x, dy: offset.y)',1)
(OUT/'TypographyCandidate.swift').write_text(candidate)
import difflib
(OUT/(call+'.patch')).write_text(''.join(difflib.unified_diff(core.splitlines(True),candidate.splitlines(True),fromfile='NativeTranslationTypography.swift',tofile='NativeTranslationTypography.swift')))
probe=(HERE.parent/'Probe.swift').read_text().replace('"content":[content.width,content.height]','"content":[content.width,content.height],"scalarRanges":layout.rangeBounds.map {[$0.minX+unit(pads[3]),$0.minY+unit(pads[0]),$0.width,$0.height]}')
(OUT/'Probe.swift').write_text(probe)
common=[O/'NativeTextPaintGeometry.swift',O/'NativeVerticalContentFit.swift',*[O/(n+'.swift') for n in ('NativePreformattedTabs','NativeKeepAllAutoLines','NativeKeepAllTextBalance','NativeKeepAllBreakOpportunities','NativeRawTextBalance','NativeVerticalLetterSpacing','NativeNormalTextFlow','NativeNormalBreakOpportunities','NativeCTFontStrokePainter','NativeVisibleControlGlyphs')],OUT/'Models.swift',OUT/'Shims.swift',OUT/'PostAdapter.swift',OUT/'Probe.swift']
for name,core in [('before',O/'NativeTranslationTypography.swift'),('after',OUT/'TypographyCandidate.swift')]:
 sources=[core,*common]
 if not any(p.name == call+'.swift' for p in common): sources.append(HERE/(call+'.swift'))
 subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete',*map(str,sources),'-o',str(OUT/name)],check=True)
 subprocess.run([str(OUT/name),str(OUT/'inputs.json'),str(OUT/(name+'.json'))],check=True)
before=json.loads((OUT/'before.json').read_text());after=json.loads((OUT/'after.json').read_text())
rows=[]
for i,b,a in zip(indices,before,after):
 w=allrows[i];rows.append(dict(index=i,webInline=w['itemBox'][3],webMetrics=w['client']+w['scroll'],before=b,after=a,metricExact=w['client']+w['scroll']==a['metrics'],inlineExact=w['itemBox'][3]==a['inline']))
report=dict(cases=len(rows),metricExact=sum(r['metricExact'] for r in rows),inlineExact=sum(r['inlineExact'] for r in rows),rows=rows,policy=call,scriptCounts={script:sum(allrows[i]['a']['script']==script for i in indices) for script in ['han','korean','japanese']},scope='Scoped real Core Text CSSOM/inline geometry against original captured WK inputs. This does not establish glyph paint or final image equality; optical policies remain staged.',sourceSHA256={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [O/'NativeTranslationTypography.swift',OUT/'TypographyCandidate.swift',HERE/(call+'.swift'),*common]})
(OUT/('ideograph-controls-report.json' if '--ideographs' in sys.argv else 'tracking-only-report.json' if '--tracking-only' in sys.argv else 'tracking-controls-report.json' if '--tracking' in sys.argv else 'controls-report.json' if '--controls' in sys.argv else 'report.json')).write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps({k:v for k,v in report.items() if k not in ('rows','sourceSHA256')},ensure_ascii=False))
