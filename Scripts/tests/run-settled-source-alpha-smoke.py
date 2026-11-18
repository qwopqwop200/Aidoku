#!/usr/bin/env python3
"""Run the actual pure PDF/canvas route with synthetic RGBA; no OCR or Core ML."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
exporter = (ROOT / 'Aidoku/Features/Reader/Translation/ReaderTranslationImageExporter.swift').read_text()
layers = exporter[exporter.index('    struct ExportLayers:'):exporter.index('    /// Core Image contexts')]
source = '''
import Foundation
import CoreGraphics
enum NativeTranslationRenderer {
    struct SourcePatch { let image: CGImage; let rect: CGRect }
    struct Result {
        let sourcePatches: [SourcePatch]; let paintBounds: [CGRect]; let sourceRestorationRects: [CGRect]
        let includesSourcePage: Bool
    }
}
enum HostProductionExporter {
''' + layers + '}\n'
source += (ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationPDFCapture.swift').read_text()
source += (ROOT / 'Scripts/image-translation/HostExportCompositor.swift').read_text()
source += r'''
let space = CGColorSpaceCreateDeviceRGB()
let info = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
func image(_ bytes: [UInt8]) -> CGImage {
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                   space: space, bitmapInfo: info, provider: provider, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)!
}
func rgba(_ image: CGImage) -> [UInt8] {
    let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: space, bitmapInfo: info.rawValue)!
    c.setBlendMode(.copy)
    c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self),
        count: image.width * image.height * 4))
}
func alpha(_ bytes: [UInt8]) -> [UInt8] { stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] } }
let bytes: [UInt8] = [
    100,25,10,128, 10,20,30,255, 0,0,0,0, 10,50,4,64,
    64,128,13,128, 30,20,10,255, 0,0,0,0, 10,4,50,64
]
var changed = bytes
changed.replaceSubrange(4..<8, with: [255, 0, 0, 255])
let original = image(bytes)
let frame = CGRect(x: 42.25, y: 87.75, width: 430, height: 215)
let bounds = [[frame.minX, frame.minY, frame.width, frame.height]]
let legacy = HostProductionExporter.ExportLayers(masks: [], surfaces: [], paintBounds: bounds)
let encodedLegacy = try JSONEncoder().encode(legacy)
precondition(!String(decoding: encodedLegacy, as: UTF8.self).contains("includesSourcePage"))
precondition(try! JSONDecoder().decode(HostProductionExporter.ExportLayers.self,
                                       from: encodedLegacy).includesSourcePage == nil)
let marked = HostProductionExporter.ExportLayers(masks: [], surfaces: [], paintBounds: bounds, includesSourcePage: true)
let restoredMarked = try JSONDecoder().decode(HostProductionExporter.ExportLayers.self, from: JSONEncoder().encode(marked))
precondition(restoredMarked.includesSourcePage == true)
for outputSize in [CGSize(width: 4, height: 2), CGSize(width: 8, height: 4)] {
    for settled in [bytes, changed] {
        let pdf = try NativeTranslationPDFCapture.captureDocument(bounds: frame, pixels: outputSize, deviceScale: 1,
            alignsToLogicalBounds: true) { context in
                context.translateBy(x: frame.minX, y: frame.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image(settled), in: CGRect(origin: .zero, size: frame.size))
            }.data
        let direct = rgba(try NativeTranslationPDFCapture.rasterize(data: pdf, pixels: outputSize))
        let replayed = rgba(try HostExportCompositor.composite(image: original, layers: restoredMarked, typography: pdf,
            displayRect: frame, size: outputSize))
        let fresh = rgba(try HostExportCompositor.composite(image: original, rendered: NativeTranslationRenderer.Result(
            sourcePatches: [], paintBounds: [frame], sourceRestorationRects: [], includesSourcePage: true),
            typography: pdf, displayRect: frame, size: outputSize))
        precondition(replayed == direct && fresh == direct)
        let historical = rgba(try HostExportCompositor.composite(image: original, layers: legacy, typography: pdf,
            displayRect: frame, size: outputSize))
        if outputSize.width == 4 {
            precondition(replayed == settled)
            precondition(alpha(historical) == [192,255,0,112,192,255,0,112])
        } else {
            precondition(alpha(historical) != alpha(replayed))
        }
        var invalid = marked
        invalid.sourceRestorations = [[frame.minX, frame.minY, 1, 1]]
        do {
            _ = try HostExportCompositor.composite(image: original, layers: invalid, typography: pdf,
                displayRect: frame, size: outputSize)
            fatalError("Accepted contradictory full-source and restore-source layers")
        } catch {}
    }
}
let size = CGSize(width: 4, height: 2)
let glyphOnly = try NativeTranslationPDFCapture.captureDocument(bounds: frame, pixels: size, alignsToLogicalBounds: true) {
    $0.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    $0.fill(CGRect(x: frame.minX + frame.width/4, y: frame.minY, width: frame.width/4, height: frame.height/2))
}.data
let oldValid = rgba(try HostExportCompositor.composite(image: original, layers: legacy, typography: glyphOnly,
    displayRect: frame, size: size))
precondition(oldValid == changed)
print("PASS: full-source PDF alpha exact for held and translated, fresh and replay, 1×/2× with offset; old overlay/restore contract retained")
'''
subprocess.run(['xcrun', 'swift', '-'], input=source, encoding='utf-8', check=True)
