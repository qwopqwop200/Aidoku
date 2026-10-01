import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeCanvasAffineTextureResamplerTests {
    private func image(_ bytes: Data, width: Int, height: Int) throws -> CGImage {
        try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func source() throws -> CGImage {
        var bytes = Data(count: 16 * 12 * 4)
        for i in 0..<(16 * 12) {
            let a = [0, 64, 128, 255][i % 4]
            bytes[i * 4] = UInt8((i * 23 % 256) * a / 255)
            bytes[i * 4 + 1] = UInt8((i * 41 % 256) * a / 255)
            bytes[i * 4 + 2] = UInt8((i * 11 % 256) * a / 255)
            bytes[i * 4 + 3] = UInt8(a)
        }
        return try image(bytes, width: 16, height: 12)
    }
    private func crop(_ bytes: Data, rect: CGRect, width: Int) -> Data {
        var result = Data()
        for row in Int(rect.minY)..<Int(rect.maxY) {
            result.append(bytes[((row * width + Int(rect.minX)) * 4)..<((row * width + Int(rect.maxX)) * 4)])
        }
        return result
    }
    @Test func opacityPreflightUsesActualCanonicalAlphaAndSameSession() throws {
        let opaqueBytes = Data([11, 22, 33, 255, 44, 55, 66, 255, 77, 88, 99, 255])
        let opaque = try image(opaqueBytes, width: 3, height: 1), translucent = try source()
        // Both images have the same premultipliedLast alpha-info enum.
        #expect(opaque.alphaInfo == translucent.alphaInfo)
        let session = NativeCanvasTextureResampler.Session()
        defer { session.close() }
        #expect(try NativeCanvasTextureResampler.isOpaqueSource(image: opaque, session: session))
        #expect(try NativeCanvasTextureResampler.isOpaqueSource(image: opaque, session: session))
        #expect(try !NativeCanvasTextureResampler.isOpaqueSource(image: translucent, session: session))
        #expect(try !NativeCanvasTextureResampler.isOpaqueSource(image: translucent, session: session))
        let size = CGSize(width: 3, height: 1), rect = CGRect(origin: .zero, size: size)
        let filtered = try NativeCanvasTextureResampler.affineCanvasImage(image: opaque, domRect: rect,
            userToPixelTransform: .identity, viewportPixelSize: size, cropPixels: rect, session: session)
        #expect(filtered.dataProvider!.data! as Data == opaqueBytes)
        // Explicit translucent filtering can populate the previously metadata-only entry.
        let transparentSize = CGSize(width: 16, height: 12)
        _ = try NativeCanvasTextureResampler.affineCanvasImage(image: translucent,
            domRect: CGRect(origin: .zero, size: transparentSize), userToPixelTransform: .identity,
            viewportPixelSize: transparentSize, cropPixels: CGRect(origin: .zero, size: transparentSize), session: session)
        #expect(try !NativeCanvasTextureResampler.isOpaqueSource(image: translucent, session: session))
        session.close()
        do {
            _ = try NativeCanvasTextureResampler.isOpaqueSource(image: opaque, session: session)
            Issue.record("Closed session exposed cached opacity")
        } catch NativeCanvasTextureResampler.Failure.closedSession {} catch { Issue.record("Unexpected opacity error: \(error)") }
    }
    @Test func cancelledOpacityPreflightCannotAdmitRawPaint() async throws {
        let input = try source(), session = NativeCanvasTextureResampler.Session()
        defer { session.close() }
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try NativeCanvasTextureResampler.isOpaqueSource(image: input, session: session)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
    @Test func projectedQuadExposesSamplingWindowSeparatelyFromClip() throws {
        let geometry = try NativeCanvasTextureResampler.affineCanvasGeometry(
            domRect: CGRect(x: 10.25, y: 10.5, width: 93.25, height: 77.75),
            userToPixelTransform: CGAffineTransform(scaleX: 3, y: 3))
        #expect(geometry.localFrame == CGRect(x: 10, y: 11, width: 94, height: 77))
        #expect(geometry.pixelQuad == [CGPoint(x: 30, y: 33), CGPoint(x: 312, y: 33), CGPoint(x: 312, y: 264), CGPoint(x: 30, y: 264)])
        #expect(geometry.samplingCrop(viewportPixelSize: CGSize(width: 320, height: 160)) == CGRect(x: 29, y: 32, width: 284, height: 128))
        let mirrored = try NativeCanvasTextureResampler.affineCanvasGeometry(domRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            userToPixelTransform: CGAffineTransform(a: -2, b: 0, c: 0, d: 3, tx: 17, ty: -5))
        #expect(mirrored.pixelQuad == [CGPoint(x: 17, y: -5), CGPoint(x: -3, y: -5), CGPoint(x: -3, y: 25), CGPoint(x: 17, y: 25)])
        #expect(mirrored.samplingCrop(viewportPixelSize: CGSize(width: 40, height: 30)) == CGRect(x: 0, y: 0, width: 18, height: 26))
    }
    @Test func identityReturnsRawPMAOrCompositesExactlyOnce() throws {
        let bytes = Data([0, 0, 0, 0, 30, 20, 10, 128, 70, 80, 90, 255])
        let source = try image(bytes, width: 3, height: 1), size = CGSize(width: 3, height: 1), rect = CGRect(origin: .zero, size: size)
        let raw = try NativeCanvasTextureResampler.affineCanvasImage(image: source, domRect: rect,
            userToPixelTransform: .identity, viewportPixelSize: size, cropPixels: rect)
        #expect(raw.dataProvider!.data! as Data == bytes)
        let composite = try NativeCanvasTextureResampler.affineCanvasImage(image: source, domRect: rect,
            userToPixelTransform: .identity, viewportPixelSize: size, cropPixels: rect,
            backgroundRGBA: Data([11, 22, 33, 64, 50, 40, 30, 128, 41, 65, 87, 255]))
        #expect(composite.dataProvider!.data! as Data == Data([11, 22, 33, 64, 55, 40, 25, 192, 70, 80, 90, 255]))
    }
    @Test(arguments: [0, 1, 2]) func affineTilesPreserveFullPlaneAndPMA(mode: Int) throws {
        let transform: CGAffineTransform
        switch mode {
        case 0: transform = CGAffineTransform(a: 2.7, b: 0, c: 0, d: 3.3, tx: 0, ty: 0)
        case 1: transform = CGAffineTransform(a: 3, b: 0, c: 0, d: 3, tx: 0.75, ty: 1.125)
        default: transform = CGAffineTransform(a: 3 * cos(0.035), b: 3 * sin(0.035), c: -3 * sin(0.035), d: 3 * cos(0.035), tx: 0, ty: 0)
        }
        let size = CGSize(width: 701, height: 337), fullRect = CGRect(origin: .zero, size: size)
        let visible = CGRect(x: 71, y: 27, width: 411, height: 211), frame = CGRect(x: -10.5, y: -10.5, width: 150.25, height: 99.25)
        let input = try source(), session = NativeCanvasTextureResampler.Session()
        defer { session.close() }
        var backing = Data(count: 701 * 337 * 4)
        for i in 0..<(701 * 337) {
            backing[i * 4] = UInt8(i % 63); backing[i * 4 + 1] = UInt8(i % 91)
            backing[i * 4 + 2] = 17; backing[i * 4 + 3] = 128
        }
        for withBacking in [false, true] {
            let full = try NativeCanvasTextureResampler.affineCanvasImage(image: input, domRect: frame,
                userToPixelTransform: transform, viewportPixelSize: size, cropPixels: fullRect,
                backgroundRGBA: withBacking ? backing : nil, session: session)
            let part = try NativeCanvasTextureResampler.affineCanvasImage(image: input, domRect: frame,
                userToPixelTransform: transform, viewportPixelSize: size, cropPixels: visible,
                backgroundRGBA: withBacking ? crop(backing, rect: visible, width: 701) : nil, session: session)
            let fullBytes = full.dataProvider!.data! as Data, partBytes = part.dataProvider!.data! as Data
            #expect(partBytes == crop(fullBytes, rect: visible, width: 701))
            for i in stride(from: 0, to: partBytes.count, by: 4) {
                let alpha = partBytes[i + 3]
                #expect(partBytes[i] <= alpha && partBytes[i + 1] <= alpha && partBytes[i + 2] <= alpha)
            }
            // Outside the transformed quad, sampling preserves the destination rather than filling a bbox.
            let last = fullBytes.suffix(4)
            #expect(Data(last) == (withBacking ? Data(backing.suffix(4)) : Data([0, 0, 0, 0])))
        }
    }
    @Test func validatesBeforeSourceAndAllocatesOnlyVisibleCrop() throws {
        let input = try source(), closed = NativeCanvasTextureResampler.Session()
        closed.close()
        let viewport = CGSize(width: 16384, height: 16384), visible = CGRect(x: 16000, y: 16000, width: 8, height: 8)
        let result = try NativeCanvasTextureResampler.affineCanvasImage(image: input,
            domRect: CGRect(x: 15999.75, y: 15999.25, width: 20.5, height: 20.5), userToPixelTransform: .identity,
            viewportPixelSize: viewport, cropPixels: visible)
        #expect(result.width == 8 && result.height == 8 && (result.dataProvider!.data! as Data).count == 256)
        let invalidInputs: [(CGRect, CGAffineTransform, Data?)] = [
            (CGRect(x: 0, y: 0, width: -1, height: 1), .identity, nil),
            (CGRect(x: 0, y: 0, width: 1, height: 1), CGAffineTransform(a: 1, b: 0, c: 1, d: 0, tx: 0, ty: 0), nil),
            (CGRect(x: 0, y: 0, width: 1, height: 1), CGAffineTransform(a: .infinity, b: 0, c: 0, d: 1, tx: 0, ty: 0), nil),
            (CGRect(x: 0, y: 0, width: 1, height: 1), .identity, Data(count: 3))
        ]
        for (frame, transform, background) in invalidInputs {
            do {
                _ = try NativeCanvasTextureResampler.affineCanvasImage(image: input, domRect: frame,
                    userToPixelTransform: transform, viewportPixelSize: viewport, cropPixels: visible,
                    backgroundRGBA: background, session: closed)
                Issue.record("Invalid affine input admitted")
            } catch NativeCanvasTextureResampler.Failure.invalidGeometry {
                // No source-session access or source upload preceded validation.
            } catch { Issue.record("Source consulted before validation: \(error)") }
        }
        do {
            _ = try NativeCanvasTextureResampler.affineCanvasImage(image: input, domRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                userToPixelTransform: .identity, viewportPixelSize: viewport, cropPixels: visible, session: closed)
            Issue.record("Closed affine session admitted")
        } catch NativeCanvasTextureResampler.Failure.closedSession {} catch { Issue.record("Unexpected closed-session error: \(error)") }
    }
    @Test func cancelledAffineNeverPublishesATile() async throws {
        let input = try source()
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try NativeCanvasTextureResampler.affineCanvasImage(image: input, domRect: CGRect(x: 0, y: 0, width: 170, height: 90),
                userToPixelTransform: .identity, viewportPixelSize: CGSize(width: 960, height: 480),
                cropPixels: CGRect(x: 0, y: 0, width: 960, height: 480))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
