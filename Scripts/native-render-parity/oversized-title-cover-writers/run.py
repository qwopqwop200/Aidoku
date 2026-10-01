#!/usr/bin/env python3
"""Unchanged production cover writer plus its actual Swift Testing regression."""
from pathlib import Path
import hashlib, json, subprocess
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'build/native-render-parity/oversized-title-cover-writers';OUT.mkdir(parents=True,exist_ok=True)
OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
TEST=ROOT/'Scripts/native-render-parity/oversized-title-cover-writers/NativeOversizedTitleCoverWriterTests.staged.swift'
promoted=ROOT/'AidokuTests/Translation/NativeEngine/NativeOversizedTitleCoverWriterTests.swift'
if promoted.exists(): TEST=promoted
adapted=OUT/'AppTests.swift';adapted.write_text(TEST.read_text().replace('@testable import Aidoku\n',''))
entry=OUT/'Main.swift';entry.write_text('import Foundation\nimport Testing\n@main enum Main {static func main() async {exit(await Testing.__swiftPMEntryPoint())}}\n')
readerSource=OVERLAY/'NativeSourceColorSamplingStage.swift'
reader=OUT/'NativeSourcePixelReader.swift'
reader.write_text('import Foundation\nimport CoreGraphics\nfinal class NativeSourcePixelReader {'+readerSource.read_text().split('final class NativeSourcePixelReader {',1)[1])
names=['NativeCSSCoveragePath','NativePanelGeometry','NativeTranslationSourceStylePostPolish','NativeTranslationGlossPlacement','NativeTranslationEffectGloss','NativeTranslationOversizedTitleGloss']
sources=[OVERLAY/(name+'.swift') for name in names]
dev=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip());frameworks=dev/'Platforms/MacOSX.platform/Developer/Library/Frameworks';macro=dev/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
cmd=['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-F',str(frameworks),'-load-plugin-library',str(macro),*[str(p) for p in sources],str(reader),str(adapted),str(entry),'-Xlinker','-rpath','-Xlinker',str(frameworks),'-o',str(OUT/'tests')]
subprocess.run(cmd,check=True,cwd=ROOT)
result=subprocess.run([str(OUT/'tests')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,cwd=ROOT)
(OUT/'tests.log').write_text(result.stdout);print(result.stdout,end='')
passed=result.returncode==0 and 'Test run with 3 tests' in result.stdout
report={'passed':passed,'tests':3,'scope':'Actual production OversizedTitleGloss+Panel+Backing+CSS declaration policy; no oracle/raster equality claim; original test import removed only for isolated host module','sources':[{ 'file':str(p.relative_to(ROOT)),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sources+[readerSource,TEST]]}
(OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
raise SystemExit(0 if passed else 1)
