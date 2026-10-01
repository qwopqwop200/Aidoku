import Testing
import UIKit
@testable import Aidoku

/// Output-size ownership controls. Pixel equality to literal Web snapshots remains
/// the unchanged serialized alpha harness; native repeats do not replace that oracle.
@Suite(.serialized) @MainActor struct NativeSourceCanvasSnapshotOutputTests {
    private let page = CGSize(width: 32, height: 24)
    private let frame = CGRect(x: 8, y: 4, width: 8, height: 8)

    @Test func unsupportedOutputSizesDeclineBeforeHierarchyMutation() throws {
        let scale = try activeScale()
        let prefix = try pattern(width: Int(page.width * scale), height: Int(page.height * scale), translucent: true)
        let source = try pattern(width: 32, height: 32, translucent: false)
        let before = hierarchySignature()
        let outputs: [CGSize] = [.zero, .init(width: CGFloat.nan, height: 12),
            .init(width: CGFloat.leastNonzeroMagnitude, height: CGFloat.leastNonzeroMagnitude),
            .init(width: -16, height: -12), .init(width: 64, height: 48),
            .init(width: 16, height: 11), .init(width: page.width * 0.501, height: page.height * 0.501)]
        for output in outputs {
            let request = NativeSourceCanvasHierarchyCompositor.Request(prefix: prefix, source: source,
                viewport: page, scale: scale, sourceFrame: frame, outputSize: output)
            #expect(try NativeSourceCanvasHierarchyCompositor.compose(request) == nil)
            #expect(hierarchySignature() == before)
        }
    }

    @Test(arguments: [false, true]) func defaultFullOutputEquivalentAndHalfCaptureRestoresHierarchy(translucent: Bool) throws {
        let scale = try activeScale()
        let prefix = try pattern(width: Int(page.width * scale), height: Int(page.height * scale), translucent: translucent)
        let source = try pattern(width: 32, height: 32, translucent: true)
        let before = hierarchySignature()
        let original = try bytes(prefix)
        let defaultRequest = NativeSourceCanvasHierarchyCompositor.Request(prefix: prefix, source: source,
            viewport: page, scale: scale, sourceFrame: frame)
        let defaultImage = try #require(try NativeSourceCanvasHierarchyCompositor.compose(defaultRequest))
        let fullRequest = NativeSourceCanvasHierarchyCompositor.Request(prefix: prefix, source: source,
            viewport: page, scale: scale, sourceFrame: frame, outputSize: page)
        let fullImage = try #require(try NativeSourceCanvasHierarchyCompositor.compose(fullRequest))
        let defaultBytes = try bytes(defaultImage), fullBytes = try bytes(fullImage)
        #expect(defaultBytes == fullBytes, "Explicit full output preserves the existing default path")
        #expect(fullImage.width == prefix.width && fullImage.height == prefix.height)
        #expect(hierarchySignature() == before)
        let half = CGSize(width: page.width / 2, height: page.height / 2)
        let request = NativeSourceCanvasHierarchyCompositor.Request(prefix: prefix, source: source,
            viewport: page, scale: scale, sourceFrame: frame, outputSize: half)
        var first: [UInt8]?
        for _ in 0..<2 {
            let output = try #require(try NativeSourceCanvasHierarchyCompositor.compose(request))
            #expect(output.width == Int(half.width * scale) && output.height == Int(half.height * scale))
            let result = try bytes(output)
            #expect(result.enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 }, "Nonblank capture sentinel")
            if let first { #expect(result == first) } else { first = result }
            #expect(hierarchySignature() == before)
        }
        let finalPrefix = try bytes(prefix)
        #expect(finalPrefix == original, "Immutable full-resolution prefix is unchanged")
    }

    @Test(arguments: [3, 4, 5]) func targetCaptureCancellationRestoresHierarchy(checkpoint: Int) throws {
        let scale = try activeScale()
        let prefix = try pattern(width: Int(page.width * scale), height: Int(page.height * scale), translucent: true)
        let source = try pattern(width: 32, height: 32, translucent: false)
        let request = NativeSourceCanvasHierarchyCompositor.Request(prefix: prefix, source: source,
            viewport: page, scale: scale, sourceFrame: frame,
            outputSize: CGSize(width: page.width / 2, height: page.height / 2))
        let before = hierarchySignature()
        var calls = 0
        do {
            _ = try NativeSourceCanvasHierarchyCompositor.compose(request, checkCancellation: {
                calls += 1
                if calls == checkpoint { throw CancellationError() }
            })
            Issue.record("Injected cancellation must propagate at requested target capture checkpoint")
        } catch is CancellationError { }
        #expect(calls == checkpoint)
        #expect(hierarchySignature() == before)
    }

    private func activeScale() throws -> CGFloat {
        let window = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
            .first { !$0.isHidden && $0.alpha > 0 && $0.rootViewController?.viewIfLoaded?.window === $0 })
        return window.screen.scale
    }
    private func hierarchySignature() -> [String] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).map {
            "\(ObjectIdentifier($0)):\($0.isKeyWindow):\($0.isHidden):\($0.alpha):\($0.frame):" +
                ($0.rootViewController?.viewIfLoaded?.subviews.map { String(describing: ObjectIdentifier($0)) }.joined(separator: ",") ?? "nil")
        }.sorted()
    }
    private func pattern(width: Int, height: Int, translucent: Bool) throws -> CGImage {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            let top = y < height / 2
            let color: [UInt8] = translucent ? (top ? [64,24,96,128] : [48,144,72,192])
                : (top ? [201,31,77,255] : [17,183,91,255])
            for c in 0..<4 { rgba[i+c] = color[c] }
            if x < width / 4 { rgba[i] /= 2 }
        } }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }
    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
}
