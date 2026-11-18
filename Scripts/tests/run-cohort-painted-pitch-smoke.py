#!/usr/bin/env python3
"""Exercise production pitch quantisation; no OCR, API or app cache."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationRenderer+CohortTextBoxes.swift').read_text()
start = source.index('    static func cohortClearedPaintedPitch(')
end = source.index('\n    struct CohortTextBudget', start)
method = source[start:end]
harness = '''import Foundation
import CoreGraphics
enum NativeTranslationRenderer {
''' + method + '''
}
func check(_ value: Bool) { precondition(value) }
// Old repeated fractional correction never crosses a native floor boundary.
let old = floor(9.3 + 0.25 - (-0.25))
check(old == 9)
let corrected = NativeTranslationRenderer.cohortClearedPaintedPitch(current: 9.3, observedGap: -0.25)!
check(corrected == 10 && corrected - floor(9.3) - 0.25 >= 0.25)
check(NativeTranslationRenderer.cohortClearedPaintedPitch(current: 10, observedGap: 0.1) == 11)
check(NativeTranslationRenderer.cohortClearedPaintedPitch(current: 6.8, observedGap: -2.25) == 10)
check(NativeTranslationRenderer.cohortClearedPaintedPitch(current: 10, observedGap: 1) == 10)
check(NativeTranslationRenderer.cohortClearedPaintedPitch(current: .nan, observedGap: 0) == nil)
check(NativeTranslationRenderer.cohortClearedPaintedPitch(current: 10, observedGap: .infinity) == nil)
check(NativeTranslationRenderer.cohortClearedPaintedPitch(current: -1, observedGap: 0) == nil)
check(NativeTranslationRenderer.cohortClearedPaintedPitch(current: 10, observedGap: 0, minimumGap: -1) == nil)
for pitch: CGFloat in [5, 6.8, 9.3, 10.75, 30.2] {
    for gap: CGFloat in [-3, -0.25, 0, 0.1, 0.249] {
        let revised = NativeTranslationRenderer.cohortClearedPaintedPitch(current: pitch, observedGap: gap)!
        check(gap + floor(revised) - floor(pitch) >= 0.25)
    }
}
print("PASS: production painted pitch reaches requested clearance after floor quantisation; invalid evidence remains unknown")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-cohort-pitch-') as directory:
    temporary = Path(directory)
    (temporary / 'main.swift').write_text(harness)
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(temporary / 'modules'),
                    str(temporary / 'main.swift'), '-o', str(temporary / 'probe')], check=True)
    subprocess.run([str(temporary / 'probe')], check=True)
