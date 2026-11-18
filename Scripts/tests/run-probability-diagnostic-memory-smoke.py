#!/usr/bin/env python3
"""Compile the real probability writer and verify identical float/PNG output."""
from pathlib import Path
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / 'Scripts/image-translation/HostSupport.swift').read_text()
start = source.index('    static func captureProbabilityMap(')
end = source.index('    // Mirror preserves', start)
method = source[start:end]
old_start = method.index('            // The synchronous write')
old_end = method.index('            guard let provider', old_start)
baseline = method[:old_start] + '''            let raw = values.withUnsafeBytes { Data($0) }
            try raw.write(to: folder.appendingPathComponent(name + ".f32"))
            let bytes = values.map { UInt8(min(255, max(0, ($0.isFinite ? $0 : 0) * 255))) }
            let data = Data(bytes)
''' + method[old_end:]
swift = '''import Foundation
import CoreGraphics
import ImageIO
final class HostDumpContext {
    let directory: URL
    var errors: [String] = []
    init(_ directory: URL) { self.directory = directory }
    func capture(_ stage: String, _ value: Any) {
        if stage == "diagnostic-error" { errors.append(String(describing: value)) }
    }
}
enum HostError: Error { case message(String) }
enum HostAnalysis {
    static func encodePNG(_ image: CGImage, to url: URL) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
    }
}
enum Production {
''' + method + '''}
enum Baseline {
''' + baseline + '''}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var fixtures: [([Float], Int, Int)] = [
    ([0, 0.5, 1, -1, 2, .nan, .infinity, -.infinity], 4, 2),
    ((0..<947200).map { Float($0 % 1000) / 999 }, 1280, 740)
]
if CommandLine.arguments.count > 2 {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    fixtures.append((values, values.count, 1))
}
for (index, fixture) in fixtures.enumerated() {
    let (values, width, height) = fixture
    let a = HostDumpContext(root.appendingPathComponent("old-\\(index)"))
    let b = HostDumpContext(root.appendingPathComponent("new-\\(index)"))
    Baseline.captureProbabilityMap(values, width: width, height: height, originX: 0, originY: 0, fullWidth: width, fullHeight: height, context: a)
    Production.captureProbabilityMap(values, width: width, height: height, originX: 0, originY: 0, fullWidth: width, fullHeight: height, context: b)
    precondition(a.errors.isEmpty && b.errors.isEmpty)
    for ext in ["f32", "png"] {
        func data(_ context: HostDumpContext) throws -> Data {
            let files = try FileManager.default.contentsOfDirectory(at: context.directory.appendingPathComponent("analysis/probabilities"), includingPropertiesForKeys: nil)
            return try Data(contentsOf: files.first { $0.pathExtension == ext }!)
        }
        let oldData = try data(a)
        let newData = try data(b)
        precondition(oldData == newData, "\\(ext) differs at fixture \\(index)")
    }
}
let invalid = HostDumpContext(root.appendingPathComponent("invalid"))
Production.captureProbabilityMap([1], width: 2, height: 1, originX: 0, originY: 0, fullWidth: 2, fullHeight: 1, context: invalid)
precondition(!FileManager.default.fileExists(atPath: invalid.directory.path))
print("Probability diagnostics: \\(fixtures.count) fixtures, exact .f32/PNG bytes, invalid geometry ignored")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-probability-memory-') as directory:
    directory = Path(directory)
    (directory / 'main.swift').write_text(swift)
    subprocess.run(['swiftc', '-O', str(directory / 'main.swift'), '-o', str(directory / 'check')], check=True)
    subprocess.run([str(directory / 'check'), str(directory / 'output'), *sys.argv[1:]], check=True)
