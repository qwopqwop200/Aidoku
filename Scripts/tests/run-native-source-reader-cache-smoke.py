#!/usr/bin/env python3
"""Exercise production bounded source-reader promotion and exact cached pixels."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
base = root / 'Aidoku/Core/Translation/NativeEngine/Overlay'
sampling = (base / 'NativeSourceColorSamplingStage.swift').read_text()
protocol = sampling[sampling.index('protocol NativeSourcePixelReading'):sampling.index('/// Per-page sampling')]
reader = sampling[sampling.index('final class NativeSourcePixelReader:'):]
# Test-local draw counts observe the production transport without changing its pixels.
reader = reader.replace('    private let image: CGImage', '    static var draws = 0\n    static var wholeDraws = 0\n    private let image: CGImage', 1)
reader = reader.replace('        guard [x, y, sourceWidth', '        draws += 1\n        if width == image.width && height == image.height { wholeDraws += 1 }\n        guard [x, y, sourceWidth', 1)
reference = reader.replace('NativeSourcePixelReader', 'ReferenceReader')
program = '''import CoreGraphics
import Foundation
''' + protocol + reader + reference + '''
let width = 2048, height = 1536
var rgba = [UInt8](repeating: 0, count: width * height * 4)
for i in 0..<(width * height) {
    rgba[i * 4] = UInt8(i % 251); rgba[i * 4 + 1] = UInt8((i / width) % 241)
    rgba[i * 4 + 2] = UInt8((i / 7) % 239); rgba[i * 4 + 3] = 255
}
let provider = CGDataProvider(data: Data(rgba) as CFData)!
let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
    decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
for reads in [3, 6] {
    NativeSourcePixelReader.draws = 0; NativeSourcePixelReader.wholeDraws = 0
    ReferenceReader.draws = 0; ReferenceReader.wholeDraws = 0
    let candidate = NativeSourcePixelReader(image: image), reference = ReferenceReader(image: image, limit: 0)
    for index in 0..<reads {
        let x = Double(17 + index * 13), y = Double(23 + index * 11)
        let a = try candidate.read(x: x, y: y, sourceWidth: 507, sourceHeight: 807, width: 507, height: 807)
        let b = try reference.read(x: x, y: y, sourceWidth: 507, sourceHeight: 807, width: 507, height: 807)
        precondition(a == b, "page cache changed source RGBA")
    }
    precondition(NativeSourcePixelReader.wholeDraws == 1)
    precondition(ReferenceReader.wholeDraws == 0)
    precondition(NativeSourcePixelReader.draws == 4 && ReferenceReader.draws == reads)
    candidate.release(); reference.release()
}
// A conservative extra candidate must keep the general page cache available.
let general = NativeSourcePixelReader(image: image)
let startWhole = NativeSourcePixelReader.wholeDraws
for _ in 0..<4 { _ = try general.read(x: 31, y: 41, sourceWidth: 100, sourceHeight: 100, width: 100, height: 100) }
precondition(NativeSourcePixelReader.wholeDraws == startWhole + 1)
print("PASS: exact cached/uncached RGBA for short/long source plans; bounded page promotion and general cache preserved")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-source-reader-') as temporary:
    source = Path(temporary) / 'main.swift'
    binary = Path(temporary) / 'check'
    source.write_text(program)
    subprocess.run(['swiftc', '-O', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
