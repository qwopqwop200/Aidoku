#!/usr/bin/env python3
import hashlib,json,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
OUT=ROOT/'build/native-render-parity/css-coverage-path-tests';OUT.mkdir(parents=True,exist_ok=True)
style=(OVERLAY/'NativeTranslationSourceStylePostPolish.swift').read_text()
panel=style[style.index('    struct Panel {'):style.index('    /// Original readability fallback')]
def method(text,name):return re.search(r'    static func '+name+r'\([\s\S]*?\n    }',text).group()
functions='\n'.join(method(style,name) for name in ['sourceColorContrast','luminance','luminanceContrast','adjustInkForContrast'])
functions += '\n' + re.search(r'    static func valid\(_ rgb:[^\n]+',style).group()
renderer=(OVERLAY/'NativeTranslationRenderer.swift').read_text()
transport=OUT/'Transport.swift';transport.write_text('import CoreGraphics\nimport Foundation\nenum NativeTranslationSourceStylePostPolish {\n'+panel+functions+'\n}\nenum NativeTranslationRenderer {\n'+method(renderer,'color')+'\n'+method(renderer,'usedRect')+'\n}\n')
sourceNames=['NativeCSSCoveragePath','NativeSourceCanvasClip','NativeTranslationRenderer+CoverageClip','NativeTranslationPDFCapture','NativePanelGeometry','NativeCaptionPacking','NativeTranslationCaptionPanelPolish','NativeTranslationRenderer+SourceBacking','NativeTypographyPlateGrowth','NativeTranslationRenderer+PlateCoverage']
sources=[];hashes={}
for name in sourceNames:
 p=OVERLAY/(name+'.swift'); target=OUT/p.name;target.write_bytes(p.read_bytes());sources.append(target);hashes[str(p.relative_to(ROOT))]=hashlib.sha256(p.read_bytes()).hexdigest()
for name in ['NativeCSSCoveragePathTests','NativeSourceBackingPaintTests']:
 p=ROOT/'AidokuTests/Translation/NativeEngine'/(name+'.swift');target=OUT/p.name;target.write_text(p.read_text().replace('@testable import Aidoku\n',''));sources.append(target)
entry=OUT/'Main.swift';entry.write_text('import Foundation\nimport Testing\n@main struct Host { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n')
developer=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip());frameworks=developer/'Platforms/MacOSX.platform/Developer/Library/Frameworks';macro=developer/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
compiled=subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-F',str(frameworks),'-load-plugin-library',str(macro),*map(str,[transport]+sources+[entry]),'-Xlinker','-rpath','-Xlinker',str(frameworks),'-o',str(OUT/'tests')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
(OUT/'compile.log').write_text(compiled.stdout)
if compiled.returncode:print(compiled.stdout);raise SystemExit(compiled.returncode)
run=subprocess.run([str(OUT/'tests')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(OUT/'tests.log').write_text(run.stdout);print(run.stdout)
passed=run.returncode==0
(OUT/'report.json').write_text(json.dumps(dict(passed=passed,sourceHashes=hashes,scope='Production SVG/inset path, current CSS clipping consumer, actual caption-polish none writer, immutable Panel transport, and unchanged backing painter controls; optimized strict Swift6 mac host, no iOS raster claim.'),indent=2))
raise SystemExit(run.returncode)
