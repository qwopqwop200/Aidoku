#!/usr/bin/env python3
"""Lossless host diagnostics/storage checks, with isolated native compilation."""
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='aidoku-output-storage-') as temp:
    folder = Path(temp)
    source = (ROOT / 'Scripts/image-translation/HostSupport.swift').read_text()
    context = source[source.index('final class HostDumpContext:'):source.index('\nenum HostDump {')]
    harness = r'''
import Foundation
import AppKit
import ImageIO
import CoreGraphics
import CoreText
import Darwin

enum HostError: Error { case message(String) }
enum HostDump { static func json(_ value: Any) -> Any { value } }
CONTEXT
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let dump = HostDumpContext(directory: directory, quiet: true)
dump.capture("stored", ["text": "한글 日本語", "nested": [["value": 1]], "false": false])
try dump.requireComplete()
let image = directory.appendingPathComponent("0001")
try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
let cg = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
cg.setFillColor(CGColor(gray: 1, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
try HostAnalysis.encodePNG(cg.makeImage()!, to: image.appendingPathComponent("input.png"))
try HostAnalysis.encodePNG(cg.makeImage()!, to: image.appendingPathComponent("final.png"))
let original = try Data(contentsOf: image.appendingPathComponent("final.png"))
let record: [String: Any] = ["id": "x", "rect": ["x": 0.2, "y": 0.2, "width": 0.5, "height": 0.2],
    "source": "a", "sourceOrientation": "horizontal"]
for (i, stage) in ["grouped-regions", "ordered-regions", "final-regions"].enumerated() {
    let data = try JSONSerialization.data(withJSONObject: ["stage": stage, "value": [record]])
    try data.write(to: image.appendingPathComponent("00\(i + 1)-\(stage).json"))
}
try HostAnalysis.generate(imageDirectory: image, root: URL(fileURLWithPath: CommandLine.arguments[2]))
try HostAnalysis.publishFinal(imageDirectory: image, runDirectory: directory)
let collection = directory.appendingPathComponent("final/0001-image.png")
precondition(try Data(contentsOf: collection) == original)
// Atomic replacement of the source must leave the old collection intact until republished.
try Data([1,2,3]).write(to: image.appendingPathComponent("final.png"), options: .atomic)
precondition(try Data(contentsOf: collection) == original)
try HostAnalysis.publishFinal(imageDirectory: image, runDirectory: directory)
precondition(try Data(contentsOf: collection) == Data([1,2,3]))
// Regenerate after changing one stage: shared sibling previews must remain unchanged.
let sibling = image.appendingPathComponent("analysis/02-ordered-regions.png")
let bytes = try Data(contentsOf: sibling)
let changed = try JSONSerialization.data(withJSONObject: ["stage": "grouped-regions", "value": []])
try changed.write(to: image.appendingPathComponent("001-grouped-regions.json"), options: .atomic)
try HostAnalysis.generate(imageDirectory: image, root: URL(fileURLWithPath: CommandLine.arguments[2]))
precondition(try Data(contentsOf: sibling) == bytes)
print("native storage regression passed")
'''.replace('CONTEXT', context).replace('precondition(try Data(', 'precondition(try! Data(')
    (folder / 'main.swift').write_text(harness)
    started = time.perf_counter()
    subprocess.run(['swiftc', str(ROOT / 'Scripts/image-translation/HostAnalysis.swift'), str(folder / 'main.swift'), '-o', str(folder / 'test')], check=True)
    built = time.perf_counter()
    subprocess.run([str(folder / 'test'), str(folder / 'run'), str(ROOT)], check=True)
    finished = time.perf_counter()
    stored = folder / 'run/001-stored.json'
    assert '\n' not in stored.read_text()
    assert json.loads(stored.read_text()) == {'stage': 'stored', 'value': {'text': '한글 日本語', 'nested': [{'value': 1}], 'false': False}}
    previews = folder / 'run/0001/analysis'
    assert (previews / '02-ordered-regions.png').stat().st_ino == (previews / '03-final-regions.png').stat().st_ino
    assert (previews / '01-grouped-regions.png').stat().st_ino != (previews / '02-ordered-regions.png').stat().st_ino
    main = (ROOT / 'Scripts/image-translation/PipelineMain.swift').read_text()
    assert 'src="final.png"' in main and 'let encodedImage = finalPNG.base64EncodedString()' not in main
    print(f'Build {built-started:.3f}s; test {finished-built:.3f}s; compact JSON, PNG identity, regeneration and final relinking passed')
