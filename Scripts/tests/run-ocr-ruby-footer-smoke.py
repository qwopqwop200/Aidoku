#!/usr/bin/env python3
"""Replay cached ruby geometry through the production merger; no OCR or network.

Compile only pure grouping sources into a temporary binary, separate from every
app/image-translation build cache. Execute the same cases as the Swift test suite.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
OCR = ROOT / 'Aidoku/Core/Translation/NativeEngine/OCR'
existing = ROOT / 'Scripts/tests/run-ocr-merger-evidence-smoke.py'
prefix = existing.read_text().split("corpus=r'''", 1)[0]
namespace = {'__file__': str(existing)}
exec(prefix, namespace)
pipeline = (OCR / 'NativeCoreMLOCRPipeline.swift').read_text()
bounds = namespace['span'](pipeline, '    static func bounds(for polygon:', '    static func intersectionArea(')
namespace['support'] += 'extension NativeOCRScopeGeometry {\n' + bounds + '}\n'
tests = (ROOT / 'AidokuTests/Translation/NativeEngine/NativeOCRRubyFooterTests.swift').read_text()
tests = tests.replace('import Testing\n', '').replace('@testable import Aidoku\n', '')
tests = re.sub(r'    @Test\(arguments:.*\)\n', '', tests)
tests = tests.replace('@Test ', '').replace('#expect', 'check')
main = namespace['support'] + '''
// Host-only carrier for the production reading-hint helper; no UIKit/service runtime.
struct ReaderTranslationRegion: Equatable {
    let id: String
    let rect: CGRect
    let source: String
    var auxiliaryInkRects: [CGRect] = []
}
func check(_ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL \\(file):\\(line)\\n".utf8))
        exit(1)
    }
}
''' + namespace['harness'] + tests + '''
let suite = NativeOCRRubyFooterTests()
for scale: CGFloat in [0.5, 1, 2] {
    suite.cachedFooterRestoresColumnOrderAndKeepsRubyInk(scale: scale)
}
suite.boundariesAndInkVetoRubyAndFooterOwnership()
suite.ambiguousMissingAndIndependentColumnsDoNotBorrowRubyOwnership()
print("PASS: cached ruby footer, alternate words, scale/order, exact ink ownership, boundary/ink and ambiguous-column vetoes")
'''
names = ['BrowserOCRSourceOrientation', 'PaddleOCRTypes', 'NativeOCRSpatialIndex',
         'NativeOCRAuxiliaryOwnership', 'NativeOCRTextLineMerger',
         'NativeOCRSlantedDependentColumns', 'NativeOCRDetectorSeedEvidence',
         'NativeOCRSourceROIProbabilityEvidence', 'NativeOCRRegionSeparator']
with tempfile.TemporaryDirectory(prefix='aidoku-ruby-footer-') as directory:
    temporary = Path(directory)
    (temporary / 'main.swift').write_text(main)
    sources = []
    for name in names:
        snapshot = temporary / (name + '.swift')
        snapshot.write_text((OCR / snapshot.name).read_text())
        sources.append(str(snapshot))
    subprocess.run(['xcrun', 'swiftc', '-Onone', '-module-cache-path', str(temporary / 'modules'), *sources,
                    str(temporary / 'main.swift'), '-o', str(temporary / 'probe')], check=True)
    subprocess.run([str(temporary / 'probe')], check=True)
