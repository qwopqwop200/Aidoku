import CoreGraphics
import Testing
@testable import Aidoku

struct NativeSourceRFHandoffTests {
    private func image(gray: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try #require(context.makeImage())
    }

    private func region(_ query: Int) -> Ensemble100RFRegion {
        .init(queryID: query, classID: 2, confidence: 0.9,
            bounds: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), exterior: [], holes: [])
    }

    @Test func sameCallFreshRFReplacesThePreAppearanceSnapshot() throws {
        let source = try image(gray: 1)
        let identity = try NativeRFDETRSourceImage.decode(source).identity
        let output = NativeLiveSourceAppearance.Output(items: [], sourceRF: .init(sourceIdentity: identity,
            modelWeightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256, regions: [region(7)]))
        let resolved = try output.resolvedRegions(original: source, fallback: [region(2)])
        #expect(resolved.map(\.queryID) == [7])
        #expect(try output.resolvedRegions(original: source, fallback: [region(2)],
            useFreshSourceRF: false).map(\.queryID) == [2])
        let absent = NativeLiveSourceAppearance.Output(items: [])
        #expect(try absent.resolvedRegions(original: source, fallback: [region(2)]).map(\.queryID) == [2])
    }

    @Test func freshEmptyRFDoesNotResurrectOldRegions() throws {
        let source = try image(gray: 1)
        let identity = try NativeRFDETRSourceImage.decode(source).identity
        let output = NativeLiveSourceAppearance.Output(items: [], sourceRF: .init(sourceIdentity: identity,
            modelWeightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256, regions: []))
        #expect(try output.resolvedRegions(original: source, fallback: [region(2)]).isEmpty)
    }

    @Test func mismatchedSourceOrCheckpointCannotEnterPlacement() throws {
        let source = try image(gray: 1), other = try image(gray: 0)
        let identity = try NativeRFDETRSourceImage.decode(source).identity
        let valid = NativeLiveSourceAppearance.Output(items: [], sourceRF: .init(sourceIdentity: identity,
            modelWeightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256, regions: [region(7)]))
        #expect(throws: NativeLiveSourceAppearance.Failure.self) {
            try valid.resolvedRegions(original: other, fallback: [region(2)])
        }
        let wrongCheckpoint = NativeLiveSourceAppearance.Output(items: [], sourceRF: .init(sourceIdentity: identity,
            modelWeightsSHA256: String(repeating: "0", count: 64), regions: [region(7)]))
        #expect(throws: NativeLiveSourceAppearance.Failure.self) {
            try wrongCheckpoint.resolvedRegions(original: source, fallback: [region(2)])
        }
    }
}
