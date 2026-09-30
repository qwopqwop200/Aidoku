#!/usr/bin/env python3
"""Validate production packed hue/dark masks against the frozen per-band algorithm."""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=ROOT / "Aidoku/Core/Translation/ReaderTranslationChromaticBalloon.swift")
source = parser.parse_args().source.read_text()
start = source.index("        let darkBit:", source.index("    static func interiors("))
end = source.index("        let boxes =", start)
classification = source[start:end]
start = source.index("        for band in 0..<13 {", end)
end = source.index("            for solid in", start)
selection = source[start:end].replace("let hue = band * 15, bit =", "let bit =")
candidate = "func candidate(_ rgba: [UInt8], _ w: Int, _ h: Int) -> [[UInt8]] {\nlet n=w*h\nvar output:[[UInt8]]=[]\n" + classification + selection + """
output.append(membership.map { $0 & bit == 0 ? 0 : 1 })
output.append(dilatedBits.map { $0 & bit == 0 ? 0 : 1 })
}
return output
}
"""

BASELINE = r'''
func baseline(_ rgba: [UInt8], _ w: Int, _ h: Int) -> [[UInt8]] {
let n=w*h
var output:[[UInt8]]=[]
        var hues = [Int16](repeating: -1000, count: n)
        var presentHues = [Bool](repeating: false, count: 180)
        var darkInk = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            let r = Int(rgba[i * 4]), g = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2])
            let high = max(r, g, b), low = min(r, g, b), delta = high - low
            if high <= 110 && delta <= 40 { darkInk[i] = 1 }
            guard delta >= 28, delta * 255 >= high * 45 else { continue }
            let value: Int
            if high == r { value = 30 * (g - b) / delta }
            else if high == g { value = 60 + 30 * (b - r) / delta }
            else { value = 120 + 30 * (r - g) / delta }
            let normalized = (value + 180) % 180
            hues[i] = Int16(normalized)
            presentHues[normalized] = true
        }
        let populatedHues = presentHues.indices.filter { presentHues[$0] }
        for hue in Array(stride(from: 0, to: 180, by: 15)) + [180] {
            guard !Task.isCancelled else { break }
            // With no matching ink, the hollow mask is one edge-touching page
            // component and the solid mask is empty. Neither can yield a balloon.
            guard hue == 180 || populatedHues.contains(where: {
                let distance = abs($0 - hue)
                return min(distance, 180 - distance) <= 12
            }) else { continue }
            var ink = hue == 180 ? darkInk : [UInt8](repeating: 0, count: n)
            for i in 0..<n where hue != 180 && hues[i] >= 0 {
                let d = abs(Int(hues[i]) - hue)
                if min(d, 180 - d) <= 12 { ink[i] = 1 }
            }
            // Close only one-pixel breaks in a coloured outline; never bridge a wide open side.
            // Translucent artwork of the same hue is not the drawn outline. Keep
            // the low-saturation mask for solid tinted balloons only.
            var outline = ink
            if hue != 180 {
                for i in 0..<n where outline[i] != 0 {
                    let k = i * 4
                    let high = max(rgba[k], rgba[k + 1], rgba[k + 2])
                    let low = min(rgba[k], rgba[k + 1], rgba[k + 2])
                    if Int(high) - Int(low) < 80 { outline[i] = 0 }
                }
            }
            var dilated = outline
            for y in 1..<(h - 1) { for x in 1..<(w - 1) where outline[y * w + x] == 1 {
                for yy in (y - 1)...(y + 1) { for xx in (x - 1)...(x + 1) { dilated[yy * w + xx] = 1 } }
            } }
output.append(ink); output.append(dilated)
}
return output
}

'''

HARNESS = r'''
let palette:[[UInt8]]=[[0,0,0,255],[110,110,110,255],[111,111,111,255],[110,70,70,255],[110,69,69,255],[255,0,0,255],[255,175,175,255],[255,176,176,255],[128,100,100,255],[128,101,101,255],[0,255,0,255],[0,0,255,255],[255,255,255,255]]
var cases=0
for color in palette {
 for bits in 0..<512 {
  var p=[UInt8]();for i in 0..<9 {p += bits & (1<<i) == 0 ? palette.last! : color}
  precondition(baseline(p,3,3)==candidate(p,3,3),"3x3 perimeter dilation mismatch")
  cases += 1
 }
}
var seed:UInt64=173
func random()->UInt64 {seed ^= seed<<13;seed ^= seed>>7;seed ^= seed<<17;return seed}
for _ in 0..<1024 {
 let w=3+Int(random()%30),h=3+Int(random()%30)
 var p=[UInt8]();for _ in 0..<(w*h) {for _ in 0..<3 {p.append(UInt8(random()%256))};p.append(255)}
 precondition(baseline(p,w,h)==candidate(p,w,h),"random RGB mask mismatch")
 cases += 1
}
print("EXACT \(cases) complete ordered ink/dilation mask sets")
'''

with tempfile.TemporaryDirectory(prefix="aidoku-chromatic-bands-") as directory:
    root = Path(directory)
    (root / "main.swift").write_text("import Foundation\n" + BASELINE + candidate + HARNESS)
    subprocess.run(["swiftc", "-O", str(root / "main.swift"), "-o", str(root / "test")], check=True)
    subprocess.run([str(root / "test")], check=True)
