#!/usr/bin/env python3
"""Exercise the production quarter-point fitting search without app/cache builds."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = r'''
import CoreGraphics
import Foundation
@main struct Check {
    static func main() {
        // The former nine continuous bisections select 9.75 for this 10pt
        // boundary. The retained quarter must itself be the measured candidate.
        var low: CGFloat = 5, high: CGFloat = 17
        for _ in 0..<9 {
            let middle = (low + high) / 2
            if middle <= 10 { low = middle } else { high = middle }
        }
        precondition(floor(low * 4) / 4 == 9.75)
        precondition(NativeTranslationFontFitSearch.largestFitting(minimum: 5, maximum: 17) { $0 <= 10 } == 10)
        var count = 0
        for boundary in stride(from: CGFloat(5), through: 30, by: 0.25) {
            var measured: [CGFloat] = []
            let font = NativeTranslationFontFitSearch.largestFitting(minimum: 5, maximum: 31.13) {
                measured.append($0); return $0 <= boundary
            }
            precondition(font == boundary && measured.contains(boundary))
            precondition(measured.count <= 8)
            count += 1
        }
        precondition(NativeTranslationFontFitSearch.largestFitting(minimum: 5.1, maximum: 5.2) { _ in true } == 5.1)
        precondition(NativeTranslationFontFitSearch.largestFitting(minimum: 5, maximum: 17) { _ in false } == nil)
        precondition(NativeTranslationFontFitSearch.largestFitting(minimum: .nan, maximum: 17) { _ in true } == nil)
        print("PASS: \(count) exact quarter boundaries, measured returned sizes, minimum and invalid inputs")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="aidoku-font-fit-") as temporary:
    directory = Path(temporary)
    fixture = directory / "Check.swift"
    fixture.write_text(FIXTURE)
    binary = directory / "check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                    str(ROOT / "Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationFontFitSearch.swift"),
                    str(fixture), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
