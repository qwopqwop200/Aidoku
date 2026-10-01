import Testing
import UIKit
@testable import Aidoku

/// Capability/ownership controls only. Literal Web pixel parity is a separate
/// serialized diagnostic, not inferred from repeated native captures.
@Suite(.serialized) @MainActor struct NativeSourceCanvasHierarchyCompositorTests {
    private let page = CGSize(width: 32, height: 24)
    private let frame = CGRect(x: 8, y: 4, width: 8, height: 8)

    @Test func unsupportedRequestsLeaveExistingHierarchyUnchanged() throws {
        let scale = try activeScale()
        let prefix = try pattern(width: Int(page.width * scale), height: Int(page.height * scale), translucent: true)
        let source = try pattern(width: 32, height: 32, translucent: false)
        let before = hierarchySignature()
        let requests: [NativeSourceCanvasHierarchyCompositor.Request] = [
            .init(prefix: prefix, source: source, viewport: page, scale: scale, sourceFrame: .zero),
            .init(prefix: prefix, source: source, viewport: page, scale: scale, sourceFrame: CGRect(x: CGFloat.nan, y: 0, width: 8, height: 8)),
            .init(prefix: prefix, source: source, viewport: page, scale: scale, sourceFrame: CGRect(x: -1, y: 0, width: 8, height: 8)),
            .init(prefix: prefix, source: source, viewport: page, scale: scale, sourceFrame: CGRect(x: 0, y: 0, width: 1_000_000, height: 1_000_000)),
            .init(prefix: prefix, source: source, viewport: page, scale: scale, sourceFrame: CGRect(x: 0.1, y: 0, width: 8, height: 8)),
            .init(prefix: prefix, source: source, viewport: page, scale: scale, sourceFrame: frame, opacity: 0.5),
            .init(prefix: prefix, source: source, viewport: page, scale: scale, sourceFrame: frame, blendMode: .copy),
            .init(prefix: source, source: source, viewport: page, scale: scale, sourceFrame: frame),
            .init(prefix: prefix, source: source, viewport: CGSize(width: 20_000, height: 20_000), scale: scale, sourceFrame: frame)
        ]
        for request in requests {
            #expect(try NativeSourceCanvasHierarchyCompositor.compose(request) == nil)
            #expect(hierarchySignature() == before)
        }
    }

    @Test(arguments: [false, true]) func repeatedCapturesRestoreHierarchyAndPreserveAsymmetricPrefix(translucent: Bool) throws {
        let scale = try activeScale()
        let width = Int(page.width * scale), height = Int(page.height * scale)
        let prefix = try pattern(width: width, height: height, translucent: translucent)
        let source = try pattern(width: 32, height: 32, translucent: true)
        let original = try bytes(prefix)
        let before = hierarchySignature()
        var first: [UInt8]?
        for _ in 0..<3 {
            let request = NativeSourceCanvasHierarchyCompositor.Request(prefix: prefix, source: source,
                viewport: page, scale: scale, sourceFrame: frame)
            let image = try #require(try NativeSourceCanvasHierarchyCompositor.compose(request))
            #expect(image.width == width && image.height == height)
            let captured = try bytes(image)
            let left = Int(frame.minX * scale), right = Int(frame.maxX * scale)
            let top = Int(frame.minY * scale), bottom = Int(frame.maxY * scale)
            var changedInside = 0, changedOutside = 0
            for y in 0..<height { for x in 0..<width {
                let i = (y * width + x) * 4
                let changed = (0..<4).contains { captured[i + $0] != original[i + $0] }
                if x >= left && x < right && y >= top && y < bottom { changedInside += changed ? 1 : 0 }
                else { changedOutside += changed ? 1 : 0 }
            } }
            #expect(changedInside > 0)
            #expect(changedOutside == 0, "Exact1:1 prefix preservation outside source; no Web equivalence claim")
            if let first { #expect(captured == first) } else { first = captured }
            #expect(hierarchySignature() == before)
        }
    }

    @Test func cancelledTaskBeforeCaptureLeavesExistingHierarchyUnchanged() async throws {
        let scale = try activeScale()
        let prefix = try pattern(width: Int(page.width * scale), height: Int(page.height * scale), translucent: true)
        let source = try pattern(width: 32, height: 32, translucent: false)
        let request = NativeSourceCanvasHierarchyCompositor.Request(prefix: prefix, source: source,
            viewport: page, scale: scale, sourceFrame: frame)
        let before = hierarchySignature()
        let task = Task { @MainActor in try NativeSourceCanvasHierarchyCompositor.compose(request) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled task must propagate CancellationError")
        } catch is CancellationError { }
        #expect(hierarchySignature() == before)
    }

    @Test(arguments: [3, 4, 5]) func injectedPostDisplayCaptureOrCleanupCancellationRestoresHierarchy(checkpoint: Int) throws {
        let scale = try activeScale()
        let prefix = try pattern(width: Int(page.width * scale), height: Int(page.height * scale), translucent: true)
        let source = try pattern(width: 32, height: 32, translucent: false)
        let request = NativeSourceCanvasHierarchyCompositor.Request(prefix: prefix, source: source,
            viewport: page, scale: scale, sourceFrame: frame)
        let before = hierarchySignature()
        var calls = 0
        do {
            _ = try NativeSourceCanvasHierarchyCompositor.compose(request, checkCancellation: {
                calls += 1
                if calls == checkpoint { throw CancellationError() }
            })
            Issue.record("Injected cancellation must propagate at its requested synchronous checkpoint")
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
