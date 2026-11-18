#!/usr/bin/env python3
"""Focused production interval geometry; no OCR, network or app build cache."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationRenderer+TextBoxes.swift').read_text()
# Integration contract: cluster membership and the final alignment target
# share observed source ink tops; detector envelopes remain erasure owners.
assert 'let sourceTops = group.map { observedTopOwners[$0].minY }.sorted()' in source
assert 'let sourceTops = group.map { owners[$0].minY }.sorted()' not in source
start = source.index('    static func captionBaselineInterval(')
end = source.index('\n    /// A visible opaque outline', start)
method = source[start:end]
harness = '''import Foundation
import CoreGraphics
enum NativeTranslationRenderer {
    static func valid(_ r: CGRect) -> Bool {
        [r.minX, r.minY, r.width, r.height].allSatisfy(\\.isFinite) && r.width > 0 && r.height > 0
    }
''' + method + '''
}
func check(_ value: Bool) { precondition(value) }
let space = CGRect(x: 0, y: 10, width: 40, height: 100)
let ink = CGRect(x: 2, y: 50, width: 20, height: 30)
let a = NativeTranslationRenderer.captionBaselineInterval(ink: ink, baseline: 60, space: space)!
check(a.lowerBound == 20 && a.upperBound == 90)
// Outline-inclusive bounds affect the permitted baseline, not panel colour/size.
let b = NativeTranslationRenderer.captionBaselineInterval(ink: ink.insetBy(dx: -2, dy: -2), baseline: 60, space: space)!
check(b.lowerBound == 22 && b.upperBound == 88)
check(NativeTranslationRenderer.captionBaselineInterval(ink: ink.offsetBy(dx: -3, dy: 0), baseline: 60, space: space) == nil)
check(NativeTranslationRenderer.captionBaselineInterval(ink: CGRect(x: 2, y: 0, width: 10, height: 101), baseline: 5, space: space) == nil)
check(NativeTranslationRenderer.captionBaselineInterval(ink: ink, baseline: .nan, space: space) == nil)
check(NativeTranslationRenderer.captionBaselineInterval(ink: ink, baseline: 60, space: .zero) == nil)
// Preserve translated relative geometry across scale/translation.
let scaledInk = CGRect(x: 104, y: 250, width: 40, height: 60)
let scaledSpace = CGRect(x: 100, y: 170, width: 80, height: 200)
let c = NativeTranslationRenderer.captionBaselineInterval(ink: scaledInk, baseline: 270, space: scaledSpace)!
check(c.lowerBound == 190 && c.upperBound == 330)
// Shared intersection clamps once; infeasible cohorts never become partial commits.
let ranges: [ClosedRange<CGFloat>] = [a, 30...80, 25...75]
let lower = ranges.map(\\.lowerBound).max()!, upper = ranges.map(\\.upperBound).min()!
check(lower == 30 && upper == 75)
check(min(upper, max(lower, 20)) == 30)
check(max(a.lowerBound, 100) > min(a.upperBound, 110))
print("PASS: production baseline interval, outlines, scale, shared clamp and invalid/infeasible bounds")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-caption-interval-') as directory:
    temporary = Path(directory)
    (temporary / 'main.swift').write_text(harness)
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(temporary / 'modules'),
                    str(temporary / 'main.swift'), '-o', str(temporary / 'probe')], check=True)
    subprocess.run([str(temporary / 'probe')], check=True)
