import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

/// Content/alpha/geometry controls for the worker-only source canvas path.
/// These do not assert pixel identity to UIKit's different minification filter.
struct NativeSourceCanvasDirectCompositionTests {
    private let viewport = CGSize(width: 32, height: 24)
    private let frame = CGRect(x: 8, y: 4, width: 8, height: 8)

    @Test(arguments: [1, 2, 3]) func sourceOverPreservesPrefixOutsideFrameAndAlpha(scale: Int) throws {
        let scale = CGFloat(scale)
        let width = Int(viewport.width * scale), height = Int(viewport.height * scale)
        let prefix = try solid(width: width, height: height, rgba: [20, 40, 60, 128])
        let source = try solid(width: 32, height: 32, rgba: [64, 24, 96, 128])
        let context = try bitmap(prefix: prefix, scale: scale)
        let original = try rgba(context)
        let matrix = context.ctm, clip = context.boundingBoxOfClipPath
        #expect(try NativeSourceCanvasHierarchyCompositor.draw(source: source, sourceFrame: frame,
            viewport: viewport, scale: scale, in: context))
        #expect(context.ctm == matrix)
        #expect(context.boundingBoxOfClipPath == clip)
        let result = try rgba(context)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            if x >= Int(frame.minX * scale), x < Int(frame.maxX * scale),
               y >= Int(frame.minY * scale), y < Int(frame.maxY * scale) {
                // Premultiplied source-over: source + destination * (1 - alpha).
                let expected = [74, 44, 126, 192]
                for channel in 0..<4 { #expect(abs(Int(result[i + channel]) - expected[channel]) <= 1) }
            } else {
                #expect(result[i..<i + 4] == original[i..<i + 4])
            }
        } }
    }

    @Test func sourceRowsKeepTopLeftGeometryOnDetachedWorker() async throws {
        let page = viewport, target = frame, fixture = self
        let result = try await Task.detached {
            let prefix = try fixture.solid(width: 32, height: 24, rgba: [0, 0, 0, 0])
            var data = [UInt8](repeating: 0, count: 8 * 8 * 4)
            for y in 0..<8 { for x in 0..<8 {
                let offset = (y * 8 + x) * 4
                data[offset] = y < 4 ? 255 : 0
                data[offset + 2] = y < 4 ? 0 : 255
                data[offset + 3] = 255
            } }
            let source = try fixture.image(width: 8, height: 8, rgba: data)
            let composed = try #require(try NativeSourceCanvasHierarchyCompositor.compose(.init(
                prefix: prefix, source: source, viewport: page, scale: 1, sourceFrame: target)))
            return try fixture.rgba(fixture.bitmap(prefix: composed, scale: 1))
        }.value
        let top = (4 * 32 + 8) * 4, bottom = (11 * 32 + 8) * 4
        #expect(Array(result[top..<top + 4]) == [255, 0, 0, 255])
        #expect(Array(result[bottom..<bottom + 4]) == [0, 0, 255, 255])
        #expect(result[0..<4].allSatisfy { $0 == 0 })
    }

    @Test(arguments: [1, 2, 3])
    func directWorkerDrawPreservesAllFourCornersAtTopLeftPlacement(scale: Int) async throws {
        let page = viewport, target = frame, fixture = self
        let scale = CGFloat(scale)
        let samples = try await Task.detached {
            let width = Int(page.width * scale), height = Int(page.height * scale)
            let prefix = try fixture.solid(width: width, height: height, rgba: [20, 40, 60, 128])
            let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255],
                                    [0, 0, 255, 255], [255, 255, 0, 255]]
            var sourceBytes = [UInt8](repeating: 0, count: 24 * 24 * 4)
            for y in 0..<24 { for x in 0..<24 {
                let color = colors[(y < 12 ? 0 : 2) + (x < 12 ? 0 : 1)]
                let offset = (y * 24 + x) * 4
                for channel in 0..<4 { sourceBytes[offset + channel] = color[channel] }
            } }
            let source = try fixture.image(width: 24, height: 24, rgba: sourceBytes)
            let context = try fixture.bitmap(prefix: prefix, scale: scale)
            #expect(try NativeSourceCanvasHierarchyCompositor.draw(source: source, sourceFrame: target,
                viewport: page, scale: scale, in: context))
            let result = try fixture.rgba(context)
            func pixel(_ x: CGFloat, _ y: CGFloat) -> [UInt8] {
                let offset = (Int(y * scale) * width + Int(x * scale)) * 4
                return Array(result[offset..<offset + 4])
            }
            // Sample inside each quadrant, away from interpolation boundaries.
            // An upside-down draw, mirrored draw, or bottom-left placement fails.
            return [pixel(target.minX + 1, target.minY + 1), pixel(target.maxX - 2, target.minY + 1),
                    pixel(target.minX + 1, target.maxY - 2), pixel(target.maxX - 2, target.maxY - 2),
                    pixel(target.minX - 1, target.minY + 1), pixel(target.minX + 1, target.minY - 1),
                    pixel(target.maxX, target.minY + 1), pixel(target.minX + 1, target.maxY)]
        }.value
        #expect(Array(samples.prefix(4)) == [[255, 0, 0, 255], [0, 255, 0, 255],
                                           [0, 0, 255, 255], [255, 255, 0, 255]])
        #expect(samples.suffix(4).allSatisfy { $0 == [20, 40, 60, 128] })
    }

    @Test func unsupportedGeometryAndTransformLeaveWorkerBitmapUnchanged() throws {
        let prefix = try solid(width: 32, height: 24, rgba: [20, 40, 60, 128])
        let source = try solid(width: 32, height: 32, rgba: [64, 24, 96, 128])
        let context = try bitmap(prefix: prefix, scale: 1)
        let original = try rgba(context)
        for invalid in [CGRect(x: -1, y: 4, width: 8, height: 8),
                        CGRect(x: 8.5, y: 4, width: 8, height: 8),
                        CGRect(x: 30, y: 4, width: 8, height: 8), .zero] {
            #expect(try !NativeSourceCanvasHierarchyCompositor.draw(source: source, sourceFrame: invalid,
                viewport: viewport, scale: 1, in: context))
            #expect(try rgba(context) == original)
        }
        context.translateBy(x: 1, y: 0)
        #expect(try !NativeSourceCanvasHierarchyCompositor.draw(source: source, sourceFrame: frame,
            viewport: viewport, scale: 1, in: context))
        #expect(try rgba(context) == original)
    }

    @Test func cancelledWorkerDeclinesBeforePainting() async throws {
        let page = viewport, target = frame
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let prefix = try solid(width: 32, height: 24, rgba: [20, 40, 60, 128])
            let source = try solid(width: 32, height: 32, rgba: [64, 24, 96, 128])
            let context = try bitmap(prefix: prefix, scale: 1)
            let original = try rgba(context)
            do {
                _ = try NativeSourceCanvasHierarchyCompositor.draw(source: source, sourceFrame: target,
                    viewport: page, scale: 1, in: context)
                Issue.record("Cancelled worker must throw before painting")
            } catch is CancellationError { }
            #expect(try rgba(context) == original)
        }
        try await task.value
    }

    private func solid(width: Int, height: Int, rgba: [UInt8]) throws -> CGImage {
        try image(width: width, height: height, rgba: Array(repeating: rgba, count: width * height).flatMap { $0 })
    }

    private func image(width: Int, height: Int, rgba: [UInt8]) throws -> CGImage {
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }

    private func bitmap(prefix: CGImage, scale: CGFloat) throws -> CGContext {
        let context = try #require(CGContext(data: nil, width: prefix.width, height: prefix.height,
            bitsPerComponent: 8, bytesPerRow: prefix.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setBlendMode(.copy)
        context.draw(prefix, in: CGRect(x: 0, y: 0, width: prefix.width, height: prefix.height))
        context.setBlendMode(.normal)
        context.translateBy(x: 0, y: CGFloat(prefix.height))
        context.scaleBy(x: scale, y: -scale)
        return context
    }

    private func rgba(_ context: CGContext) throws -> [UInt8] {
        let pointer = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: context.height * context.bytesPerRow))
    }
}
