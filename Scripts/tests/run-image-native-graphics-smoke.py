#!/usr/bin/env python3
"""Exercise the actual host Core Graphics adapter without OCR or a provider."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = r'''
import Foundation
import CoreGraphics

func rgba(_ image: CGImage) -> [UInt8] {
    let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
}
@main struct Check {
    static func main() throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format)
        precondition(UIGraphicsGetCurrentContext() == nil)
        let source = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            precondition(UIGraphicsGetCurrentContext() === context)
            context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 0, 0, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
            context.setFillColor(CGColor(colorSpace: colorSpace, components: [0, 0, 1, 0.5])!)
            context.fill(CGRect(x: 0, y: 1, width: 2, height: 1))
            _ = renderer.image { nested in
                precondition(UIGraphicsGetCurrentContext() === nested.cgContext)
                precondition(nested.cgContext !== context)
            }
            precondition(UIGraphicsGetCurrentContext() === context)
        }
        precondition(UIGraphicsGetCurrentContext() == nil)
        precondition(source.size == CGSize(width: 2, height: 2) && source.scale == 2)
        let bytes = rgba(source.cgImage!)
        precondition(Array(bytes[0..<4]) == [255, 0, 0, 255], "top-left fill orientation")
        precondition(Array(bytes[48..<52]) == [0, 0, 128, 128], "bottom partial-alpha premultiplication")
        let copied = renderer.image { _ in source.draw(in: CGRect(x: 0, y: 0, width: 2, height: 2), blendMode: .copy, alpha: 1) }
        precondition(rgba(copied.cgImage!) == bytes, "UIImage draw source orientation and alpha")
        // The host must link the production compositor, including its worker draw API.
        let canvasSource = CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue), provider: CGDataProvider(data: Data(bytes) as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let canvas = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        canvas.translateBy(x: 0, y: 4)
        canvas.scaleBy(x: 2, y: -2)
        let didDraw = try NativeSourceCanvasHierarchyCompositor.draw(source: canvasSource,
            sourceFrame: CGRect(x: 0, y: 0, width: 2, height: 2), viewport: CGSize(width: 2, height: 2), scale: 2, in: canvas)
        precondition(didDraw, "production worker compositor did not admit the host bitmap")
        precondition(rgba(canvas.makeImage()!) == bytes, "shared source-canvas orientation and partial alpha")
        let dimmed = renderer.image { _ in source.draw(in: CGRect(x: 0, y: 0, width: 2, height: 2), blendMode: .normal, alpha: 0.5) }
        precondition(Array(rgba(dimmed.cgImage!)[0..<4]) == [128, 0, 0, 128], "draw alpha")
        let inherited = renderer.image { rendererContext in
            rendererContext.cgContext.setAlpha(0.5)
            source.draw(in: CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        precondition(rgba(inherited.cgImage!) == rgba(dimmed.cgImage!), "basic image draw preserves caller alpha")
        for size in [CGSize.zero, CGSize(width: -1, height: 2), CGSize(width: CGFloat.infinity, height: 2), CGSize(width: 4000, height: 4000)] {
            var entered = false
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in entered = true }
            precondition(image.cgImage == nil && !entered, "invalid/over-budget bitmap must not paint")
        }
        format.scale = .nan
        precondition(renderer.image { _ in preconditionFailure("invalid scale invoked painter") }.cgImage == nil)
        precondition(UIGraphicsGetCurrentContext() == nil)
        print("PASS: native graphics and shared compositor orientation, partial alpha, copy, nested stack, scale and allocation bounds")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="aidoku-native-graphics-") as temporary:
    directory = Path(temporary)
    fixture = directory / 'Check.swift'
    fixture.write_text(FIXTURE)
    binary = directory / 'check'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library',
                    str(ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeSourceCanvasHierarchyCompositor.swift'),
                    str(ROOT / 'Scripts/image-translation/HostNativeGraphics.swift'),
                    str(ROOT / 'Scripts/image-translation/HostTypographyBridge.swift'), str(fixture), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
