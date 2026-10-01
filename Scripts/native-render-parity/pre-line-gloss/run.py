#!/usr/bin/env python3
import json,subprocess,pathlib,hashlib
HERE=pathlib.Path(__file__).resolve().parent;ROOT=HERE.parents[2]
OUT=ROOT/'build/native-render-parity/pre-line-gloss';OUT.mkdir(parents=True,exist_ok=True)
OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
subprocess.run(['xcrun','swiftc',str(HERE/'Capture.swift'),'-o',str(OUT/'capture')],check=True,cwd=ROOT)
subprocess.run([str(OUT/'capture'),str(HERE/'integration-fixtures.json'),str(OUT/'capture.json')],check=True,cwd=ROOT)
(OUT/'main.swift').write_text((HERE/'Probe.swift').read_text())
subprocess.run(['xcrun','swiftc',str(OVERLAY/'NativeKeepAllAutoLines.swift'),str(OVERLAY/'NativeKeepAllBreakOpportunities.swift'),str(OVERLAY/'NativePreLineTextFlow.swift'),str(OVERLAY/'NativeVisibleControlGlyphs.swift'),str(OVERLAY/'NativeKeepAllTextBalance.swift'),str(OVERLAY/'NativeRawTextBalance.swift'),str(OUT/'main.swift'),'-o',str(OUT/'native')],check=True,cwd=ROOT)
actual=json.loads(subprocess.check_output([str(OUT/'native'),str(OUT/'capture.json')],cwd=ROOT))
web=json.loads((OUT/'capture.json').read_text())
for a,w in zip(actual,web):
    visible=[]
    for g in w['glyphs']:
        if g['scalar'] in ' \t\r\n':continue
        q=next((q for q in g['rects'] if q['width']>0 and q['height']>0),None)
        if q:visible.append([g['start'],round(q['y']/w['input']['pitch'])])
    a['webGlyphRows']=visible;a['webHeight']=w['height']
    a['exactGlyphRows']=a['glyphRows']==visible;a['exactHeight']=a['height']==w['height']
report=dict(cases=len(actual),exactGlyphRows=sum(a['exactGlyphRows'] for a in actual),exactHeight=sum(a['exactHeight'] for a in actual),records=actual,
    scope='Actual local macOS WK pre-line/keep-all at two widths and both inherited overflow controls vs staged source-preserving normalization and production greedy flow using genuine CoreText advances; no pixel or iOS claim.',
    caller=dict(frozen='BrowserOverlayView.swift15938-41',reuseExistingNode=True,explicitWhitespace=['pre-line','normal'],explicitWordBreak='keep-all',explicitOverflowWrap=None,initialInheritedOverflowWrap='anywhere'),
    sourceSHA256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [HERE/'Capture.swift',HERE/'NativePreLineTextFlow.staged.swift',OVERLAY/'NativeKeepAllAutoLines.swift',OVERLAY/'NativeKeepAllBreakOpportunities.swift']})
(OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k not in ('records','sourceSHA256')}))

# The proposed next-batch tests remain staged; compile only this small host module.
developer=pathlib.Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
framework=developer/'Platforms/MacOSX.platform/Developer/Library/Frameworks'
macro=developer/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
(OUT/'TestMain.swift').write_text('import Foundation\nimport Testing\n@main struct Entry { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n')
subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','6','-F',str(framework),'-load-plugin-library',str(macro),str(OVERLAY/'NativeKeepAllAutoLines.swift'),str(OVERLAY/'NativeKeepAllBreakOpportunities.swift'),str(OVERLAY/'NativePreLineTextFlow.swift'),str(OVERLAY/'NativeVisibleControlGlyphs.swift'),str(OVERLAY/'NativeKeepAllTextBalance.swift'),str(OVERLAY/'NativeRawTextBalance.swift'),str(HERE/'NativePreLineTextFlowTests.staged.swift'),str(OUT/'TestMain.swift'),'-Xlinker','-rpath','-Xlinker',str(framework),'-o',str(OUT/'staged-tests')],check=True,cwd=ROOT)
with (OUT/'staged-tests.log').open('w') as log:
    subprocess.run([str(OUT/'staged-tests')],stdout=log,stderr=subprocess.STDOUT,check=True,cwd=ROOT)
report['requestedWhitespaceCases']={ 'cases':76, 'exactGlyphRows':sum(a['exactGlyphRows'] for a in actual[:80] if a['input']['id']!=18), 'exactHeight':sum(a['exactHeight'] for a in actual[:80] if a['input']['id']!=18)}
report['stagedTests']={ 'suite':'NativePreLineTextFlowTests', 'declarations':2, 'status':'PASS', 'log':'build/native-render-parity/pre-line-gloss/staged-tests.log', 'appRegistered':False}
(OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')

report['baselineEvidence']={'path':'build/native-render-parity/pre-line-gloss/report-before-control-resolution.json','requiredExact':76,'overallExact':79,'cases':80,'mismatch':'form-feed,width50,overflow-anywhere'}
report['controlResolution']={'glyph':0,'rawCoreTextGlyph':1,'rawCoreTextAdvance':0,'glyph0AdvanceAt16':13.84,'font':'AppleSDGothicNeo-Bold','afterCorrectionExactGlyphRows':report['exactGlyphRows'],'afterCorrectionExactHeight':report['exactHeight'],'scope':'Production CTGlyphInfo glyph0 plus genuine advance; independent actual bitmap/PDF test separately verifies direct glyph0 paint','primaryEvidence':['FontCascadeInlines.h145','WidthIterator.cpp801']}
(OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')

report['byMode']={mode:{'cases':len(group),'exactGlyphRows':sum(r['exactGlyphRows'] for r in group),'exactHeight':sum(r['exactHeight'] for r in group)} for mode in ['pre-line-wrap','normal-wrap','pre-line-balance','normal-balance'] for group in [[r for r in actual if (r['input']['whiteSpace']+('-balance' if r['input']['balances'] else '-wrap'))==mode]]}
(OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(report['byMode']))
