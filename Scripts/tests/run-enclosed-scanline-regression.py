#!/usr/bin/env python3
"""Check the actual lazy light-component labeling against pixel BFS in two seed orders."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "Aidoku/Core/Translation/ReaderTranslationEnclosedBackground.swift").read_text()
start = source.index("        private func label(at seed: Int)")
end = source.index("        private static let light:", start)
candidate = source[start:end].replace("private func label", "func label")
HEADER = r'''
import Foundation
struct Stats: Equatable {
    var count = 0
    var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
    var touchesEdge = false
}
'''
FIELDS = r'''
    let width: Int, height: Int
    let pixels: [UInt8]
    var labels: [Int32], stats: [Stats] = []
    private static let light: UInt8 = 225
    init(_ pixels: [UInt8], _ width: Int, _ height: Int) {
        self.pixels = pixels; self.width = width; self.height = height
        self.labels = [Int32](repeating: -1, count: pixels.count)
    }
'''
BASELINE = r'''
        func label(at seed: Int) -> Int {
            if labels[seed] >= 0 { return Int(labels[seed]) }
            let id = Int32(stats.count)
            var value = Stats()
            var queue = [seed]
            labels[seed] = id
            var cursor = 0
            while cursor < queue.count {
                let point = queue[cursor]; cursor += 1
                let x = point % width, y = point / width
                value.count += 1
                value.minX = min(value.minX, x); value.maxX = max(value.maxX, x)
                value.minY = min(value.minY, y); value.maxY = max(value.maxY, y)
                if x == 0 || y == 0 || x == width - 1 || y == height - 1 { value.touchesEdge = true }
                @inline(__always) func visit(_ next: Int) {
                    guard labels[next] < 0, pixels[next] >= Self.light else { return }
                    labels[next] = id
                    queue.append(next)
                }
                if x > 0 { visit(point - 1) }
                if x < width - 1 { visit(point + 1) }
                if y > 0 { visit(point - width) }
                if y < height - 1 { visit(point + width) }
            }
            stats.append(value)
            return Int(id)
        }

'''
HARNESS = r'''

var count = 0
func check(_ mask: [UInt8], _ width: Int, _ height: Int) {
    for reversed in [false, true] {
        let a = Baseline(mask,width,height), b = Candidate(mask,width,height)
        let indices = reversed ? Array(mask.indices.reversed()) : Array(mask.indices)
        for index in indices where mask[index] >= 225 {
            precondition(a.label(at:index) == b.label(at:index))
        }
        precondition(a.labels == b.labels && a.stats == b.stats, "Labels/stats mismatch")
        count += 1
    }
}
for h in 1...4 { for w in 1...4 {
    for bits in 0..<(1 << (w*h)) { check((0..<(w*h)).map { ((bits >> $0)&1) == 1 ? 255 : 0 },w,h) }
} }
var state: UInt64 = 0x99117
for width in [7,31,128,511] { for height in [9,32,127] { for threshold in [0,1,64,128,192,254,255] {
    var mask: [UInt8] = []
    for _ in 0..<(width*height) { state = state &* 6364136223846793005 &+ 1442695040888963407; mask.append((state >> 56) < threshold ? 225 : 224) }
    check(mask,width,height)
} } }
print("ENCLOSED_LABEL_EXACT cases=\(count) seedOrders=forward,reverse thresholdBoundary=224,225")
'''

with tempfile.TemporaryDirectory(prefix="aidoku-enclosed-scanline-") as temporary:
    path = Path(temporary)
    swift = HEADER + "class Baseline {\n" + FIELDS + BASELINE + "}\nclass Candidate {\n" + FIELDS + candidate + "}\n" + HARNESS
    (path / "main.swift").write_text(swift)
    subprocess.run(["swiftc", "-O", str(path / "main.swift"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
