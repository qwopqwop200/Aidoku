import CoreGraphics
import CoreML
import Testing
@testable import Aidoku

@Suite struct NativeAOTCompositionReuseTests {
    @Test func opaqueRestorationChecksEveryExteriorChannelIncludingThePartialSpan() throws {
        let width = 517
        let source = try NativeAOTAlphaComposition.prepare(
            canonicalRGBA: (0..<(width * 4)).map { $0 % 4 == 3 ? 255 : 193 },
            width: width, height: 1, encoding: .premultipliedRGBA8)
        var mask = [UInt8](repeating: 0, count: width)
        var restored = source.inferenceRGB
        for p in [0, 254, 256, 510, 512, 515] {
            mask[p] = 255
            restored[p * 3 + 1] = 21
        }
        let valid = try NativeAOTValidatedMask(validating: mask, width: width, height: 1, domain: .strict255)
        let image = try NativeAOTAlphaComposition.makeImage(source: source, restoredRGB: restored, validatedMask: valid)
        #expect(try NativeAOTAlphaComposition.prepare(source: image).inferenceRGB == restored)
        for p in [1, 255, 257, 511, 513, 516] {
            for channel in 0..<3 {
                var corrupted = restored
                corrupted[p * 3 + channel] ^= 1
                do {
                    _ = try NativeAOTAlphaComposition.makeImage(source: source, restoredRGB: corrupted, validatedMask: valid)
                    Issue.record("Exterior edit accepted at pixel \(p), channel \(channel)")
                } catch NativeAOTAlphaComposition.Failure.opaqueOutsideMismatch {}
            }
        }
    }

    @Test func canonicalByteAdmissionRejectsInvalidBytesBeforeModelLoad() throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let source = try #require(context.makeImage())
        let backend = NativeMainAOTBackend.shared
        do {
            _ = try backend.restore(source: source, canonicalMaskBytes: [0, 1])
            Issue.record("Canonical byte handoff must reject logical 1")
        } catch NativeMainAOTBackend.Failure.maskFormat {}
        do {
            _ = try backend.restore(source: source, canonicalMaskBytes: [255])
            Issue.record("Canonical byte handoff must reject mismatched dimensions")
        } catch NativeMainAOTBackend.Failure.maskDimensions {}
        let empty = try backend.restore(source: source, canonicalMaskBytes: [0, 0])
        #expect(empty.image === source)
        #expect(empty.coordinateAudit["inferenceCalls"] as? Int == 0)
    }

    @Test func skippedRowsAndClampedEdgesPreserveRGBA() throws {
        let raw = try MLMultiArray(shape: [1, 3, 1024, 1024], dataType: .float16)
        let values = raw.dataPointer.assumingMemoryBound(to: Float16.self)
        for channel in 0..<3 {
            let plane = channel * 1024 * 1024
            values[plane] = -1
            values[plane + 1] = 1
            values[plane + 1024] = 1
            values[plane + 1025] = -1
        }
        let width = 4, height = 6
        let source = [UInt8](repeating: 17, count: width * height * 4)
        let selected = [(pixel: 5, expected: UInt8(64)), (pixel: 14, expected: 106), (pixel: 18, expected: 64)]
        var mask = [UInt8](repeating: 0, count: width * height)
        var expected = source
        for (pixel, value) in selected {
            mask[pixel] = 255
            for channel in 0..<3 { expected[pixel * 4 + channel] = value }
        }
        let actual = try NativeResidentAOT.composeRGBA(source: source, finalMask: mask,
            width: width, height: height, raw: raw, content: (2, 2))
        #expect(actual == expected)
    }
}
