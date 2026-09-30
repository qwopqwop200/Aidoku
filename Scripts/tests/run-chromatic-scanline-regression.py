#!/usr/bin/env python3
"""Compare the production chromatic component scan with pixel BFS on exhaustive masks."""
from pathlib import Path
import subprocess
import argparse
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=ROOT / "Aidoku/Core/Translation/ReaderTranslationChromaticBalloon.swift")
source = parser.parse_args().source.read_text()
start = source.index("                for start in 0..<n where labels[start]")
end = source.index("                var candidates:", start)
body = source[start:end].replace("components.append(component)",
                                 "maximumQueue = max(maximumQueue, queue.count); components.append(component)")
BASELINE = r'''
import Foundation
struct Component: Equatable { var count = 0; var l = Int.max; var t = Int.max; var r = 0; var b = 0; var edge = false }

func baseline(_ mask: [UInt8], _ w: Int, _ h: Int, _ solid: Bool) -> ([Int32], [Component], Int) {
let n = w*h
var maximumQueue = 0
var labels = [Int32](repeating: -1, count:n), components: [Component] = [], queue: [Int] = []
                for start in 0..<n where labels[start] < 0 && (mask[start] == 1) == solid {
                    var component = Component(), head = 0
                    queue.removeAll(keepingCapacity: true); queue.append(start)
                    let id = Int32(components.count); labels[start] = id
                    while head < queue.count {
                        let i = queue[head]; head += 1
                        let x = i % w, y = i / w
                        component.count += 1
                        component.l = min(component.l, x); component.r = max(component.r, x)
                        component.t = min(component.t, y); component.b = max(component.b, y)
                        if x == 0 || y == 0 || x == w - 1 || y == h - 1 { component.edge = true }
                        for next in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1]
                        where next >= 0 && labels[next] < 0 && (mask[next] == 1) == solid {
                            labels[next] = id; queue.append(next)
                        }
                    }
                    maximumQueue = max(maximumQueue, queue.count); components.append(component)
                }

return (labels,components,maximumQueue)
}

'''
HARNESS = r'''
var cases = 0
func check(_ mask: [UInt8], _ w: Int, _ h: Int) {
    for solid in [false,true] {
        let a = baseline(mask,w,h,solid), b = candidate(mask,w,h,solid)
        precondition(a.0 == b.0 && a.1 == b.1, "Connectivity mismatch \(w)x\(h) mask \(mask)")
        precondition(b.2 <= w*h, "Queue bound exceeded")
        cases += 1
    }
}
for h in 1...4 { for w in 1...4 {
    for bits in 0..<(1 << (w*h)) { check((0..<(w*h)).map { UInt8((bits >> $0)&1) },w,h) }
} }
var state: UInt64 = 0x84291
for w in [7,31,128,511] { for h in [9,32,127] { for threshold in [0,1,64,128,192,254,255] {
    var mask: [UInt8] = []
    for _ in 0..<(w*h) { state = state &* 6364136223846793005 &+ 1442695040888963407;mask.append((state >> 56) < threshold ? 1:0) }
    check(mask,w,h)
} } }
for mode in 0..<4 {
    let w = 1024, h = 1024
    let mask: [UInt8] = (0..<(w*h)).map { i in
        switch mode { case 0: return 0; case 1:return 1;case 2:return UInt8((i/w+i%w)%2);default:return UInt8((i/w)%2) }
    }
    check(mask,w,h)
    let a = baseline(mask,w,h,false), b = candidate(mask,w,h,false)
    print("QUEUE mode=\(mode) baselineIndices=\(a.2) candidateIndices=\(b.2)")
}
print("SCANLINE_EXACT cases=\(cases)")
'''
# Unrelated bit planes must never affect the selected component labels.
packed = "& bit" in body
mask_setup = """
    let bit = UInt16(1) << (cases % 13)
    let mask: [UInt16] = input.enumerated().map { index, value in
        (UInt16(truncatingIfNeeded: index &* 73) & ~bit) | (value == 0 ? 0 : bit)
    }
""" if packed else "let mask = input\n"
candidate = """
func candidate(_ input: [UInt8], _ w: Int, _ h: Int, _ solid: Bool) -> ([Int32], [Component], Int) {
    let n = w * h
    var maximumQueue = 0
    var labels = [Int32](repeating: -1, count: n), components: [Component] = [], queue: [Int] = []
""" + mask_setup + body + "return (labels, components, maximumQueue)\n}\n"
with tempfile.TemporaryDirectory(prefix="aidoku-chromatic-scanline-") as temporary:
    path = Path(temporary)
    (path / "main.swift").write_text(BASELINE + candidate + HARNESS)
    subprocess.run(["swiftc", "-O", str(path / "main.swift"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
