#!/usr/bin/env python3
"""Check document-only PDF capture against the existing bitmap capture."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CHECK = r'''
import Foundation
import CoreGraphics
@main struct Check {
    static func main() throws {
        var cases = 0
        for scale: CGFloat in [1, 2, 3] {
            for origin in [CGPoint.zero, CGPoint(x: -0.25, y: 0.75)] {
                let bounds = CGRect(origin: origin, size: CGSize(width: 96.75, height: 65.25))
                let pixels = CGSize(width: 194, height: 131)
                let paint: (CGContext) -> Void = { context in
                    context.setFillColor(CGColor(red: 0.3, green: 0.8, blue: 0.2, alpha: 0.6))
                    context.fill(CGRect(x: 6.25, y: 12.5, width: 57.75, height: 28.25))
                    NativeTranslationPDFCapture.drawFallbackGradient(context: context,
                        frame: CGRect(x: 21.25, y: 40.75, width: 62.2, height: 18.8),
                        lightSurface: true, deviceScale: scale)
                    context.setStrokeColor(CGColor(red: 0.8, green: 0.1, blue: 0.4, alpha: 1))
                    context.setLineWidth(1.7)
                    context.move(to: CGPoint(x: 2, y: 3)); context.addLine(to: CGPoint(x: 82, y: 53)); context.strokePath()
                }
                let bitmap = try NativeTranslationPDFCapture.capture(bounds: bounds, pixels: pixels,
                    deviceScale: scale, paint: paint)
                let document = try NativeTranslationPDFCapture.captureDocument(bounds: bounds, pixels: pixels,
                    deviceScale: scale, paint: paint)
                let replay = try NativeTranslationPDFCapture.rasterize(data: document.data, pixels: pixels)
                precondition(bitmap.mediaBox == document.mediaBox)
                precondition(bitmap.image.width == replay.width && bitmap.image.height == replay.height)
                let bitmapBytes = bitmap.image.dataProvider!.data! as Data
                let replayBytes = replay.dataProvider!.data! as Data
                precondition(bitmapBytes == replayBytes, "Document paint changed raster bytes")
                cases += 1
            }
        }
        for scale: CGFloat in [0, -.infinity, .nan] {
            do {
                _ = try NativeTranslationPDFCapture.captureDocument(bounds: CGRect(x: 0, y: 0, width: 20, height: 20),
                    pixels: CGSize(width: 20, height: 20), deviceScale: scale) { _ in }
                preconditionFailure("Invalid document geometry accepted")
            } catch NativeTranslationPDFCapture.CaptureError.invalidGeometry {}
        }
        print("PDF-only document: \(cases) exact raster byte cases; original bitmap capture and invalid geometry preserved")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='aidoku-pdf-document-') as directory:
    directory = Path(directory)
    (directory / 'check.swift').write_text(CHECK)
    subprocess.run(['swiftc', '-O', str(ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationPDFCapture.swift'),
                    str(directory / 'check.swift'), '-o', str(directory / 'check')], check=True)
    subprocess.run([str(directory / 'check')], check=True)
