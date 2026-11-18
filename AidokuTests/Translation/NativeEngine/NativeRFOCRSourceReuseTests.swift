import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeRFOCRSourceReuseTests {
    private func image(_ gray: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 64, height: 48,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 0.65))
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 24))
        return try #require(context.makeImage())
    }

    private func sameStorage(_ lhs: NativeRFOCRPackedSource, _ rhs: NativeRFOCRPackedSource) -> Bool {
        lhs.withPackedRGB { a in rhs.withPackedRGB { b in a.baseAddress == b.baseAddress } }
    }

    @Test func sharesOnlyTheExactImageWithinOneReaderCall() throws {
        let original = try image(0.2)
        let alternate = try image(0.8)
        let scope = NativeRFOCRSourceReuse(original: original)
        let expected = try NativeRFDETRSourceImage.decode(original)
        #expect(scope.identity(for: original) == nil)
        let a = try scope.source(for: original)
        let wrongImage = try scope.source(for: alternate, consume: true)
        #expect(scope.identity(for: alternate) == nil)
        let b = try scope.source(for: original)
        let consumed = try scope.source(for: original, consume: true)
        scope.releasePixels()
        #expect(scope.identity(for: original) == expected.identity)
        let recomputed = try scope.source(for: original)

        #expect(a.identity == expected.identity && a.withPackedRGB { Data($0) } == expected.rgb)
        #expect(wrongImage.identity != a.identity)
        #expect(sameStorage(a, b))
        #expect(sameStorage(a, consumed))
        #expect(recomputed.identity == a.identity && !sameStorage(a, recomputed))
        scope.close()
        #expect(scope.identity(for: original) == nil)
    }

    @Test func recognitionTakesTheOnlyRGBStorageAfterRFCompletes() throws {
        let page = try image(0.3)
        let scope = NativeRFOCRSourceReuse(original: page)
        let address = try scope.source(for: page).withPackedRGB { UInt(bitPattern: $0.baseAddress!) }
        let source = try scope.source(for: page, consume: true)
        let rgba = try (consume source).rgbaBytes()
        #expect(rgba.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress!) } == address)
        #expect(rgba.count == page.width * page.height * 4)
    }

    @available(iOS 18.0, *)
    @Test func handingPixelsToRecognitionPreservesAnyOutstandingRFRead() throws {
        let page = try image(0.2)
        let scope = NativeRFOCRSourceReuse(original: page)
        let retained = try scope.source(for: page)
        let consumed = try scope.source(for: page, consume: true)
        let canonical = try #require(NativeOCRV2SourcePixelDecoder.decode(page))
        let detector = try #require(NativeOCRCGImageAdapter.makeRGBAFrame(from: page))
        let packed = retained.withPackedRGB { Data($0) }
        #expect(try consumed.rgbaBytes() == canonical.bytes)
        #expect(retained.withPackedRGB { Data($0) } == packed)
        #expect(detector.bytes != canonical.bytes)
    }

    @Test func livePacketRegistrationVerifiesTheSourceAndReplacesStages() throws {
        typealias E = NativeMainEnsembleOCREvidence
        let original = try image(0.2), alternate = try image(0.8), copy = try image(0.2)
        let source = try NativeMainEnsemblePreparedDB.SourceBinding(ocrEvidenceOriginal: original)
        let alternateSource = try NativeMainEnsemblePreparedDB.SourceBinding(ocrEvidenceOriginal: alternate)
        let binding = E.liveBinding(source: source), store = E.Store()
        let stage = try E.project(rows: [], stage: .recognized, space: .normalizedTopLeft, binding: binding)
        let observed = try E.Packet(binding: binding, stages: [stage])
        let unavailable = try E.Packet(binding: binding, stages: [])

        #expect(throws: E.Failure.binding) { try store.register(observed, original: copy, source: source) }
        #expect(throws: E.Failure.binding) { try store.register(observed, original: alternate, source: alternateSource) }
        #expect(throws: E.Failure.binding) { try store.register(observed, original: alternate) }
        try store.register(observed, original: copy)
        #expect(store.read(contentIdentity: source.identity)?.stages[.recognized]?.isEmpty == true)
        try store.register(unavailable, original: original, source: source)
        let replacement = try #require(store.read(contentIdentity: source.identity))
        #expect(replacement.stages[.recognized] == nil)
    }

    @Test func initialLeaseReusesOnlyTheCertifiedOriginalAfterAdmission() throws {
        let original = try image(0.3), samePixels = try image(0.3), different = try image(0.6)
        let source = try NativeMainEnsemblePreparedDB.SourceBinding(original: original)
        let expected = try NativeRFDETRSourceImage.decode(different)
        try NativeRFOCRSourceReuse.$leasedIdentity.withValue(source.verifiedIdentity) {
            let exact = NativeRFOCRSourceReuse(original: original)
            let copy = NativeRFOCRSourceReuse(original: samePixels)
            let other = NativeRFOCRSourceReuse(original: different)
            #expect(exact.identity(for: original) == source.identity)
            #expect(copy.identity(for: samePixels) == nil)
            #expect(other.identity(for: different) == nil)
            let raster = try other.source(for: different, consume: true)
            #expect(raster.identity == expected.identity)
            #expect(raster.withPackedRGB { Data($0) } == expected.rgb)
            exact.close()
            #expect(exact.identity(for: original) == nil)
        }
    }

    @Test func cancelledPublicationKeepsTheReaderPhaseErrorOrder() async throws {
        typealias Source = NativeMainEnsemblePreparedDB.SourceBinding
        let valid = try image(0.3)
        let context = try #require(CGContext(data: nil, width: 16_385, height: 1,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let oversized = try #require(context.makeImage())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try Source(ocrEvidenceOriginal: oversized)
                Issue.record("Live evidence accepted an oversized original")
            } catch NativeRFDETRLayoutError.sourceImageTooLarge {}
            #expect(throws: CancellationError.self) { try Source(original: oversized) }
            return try Source(ocrEvidenceOriginal: valid).identity
        }
        let identity = try await task.value
        #expect(identity == (try NativeRFDETRSourceImage.decode(valid)).identity)
    }

    @Test func closingOneScopeDoesNotInvalidateAnotherScope() throws {
        let original = try image(0.3)
        let closed = NativeRFOCRSourceReuse(original: original)
        let open = NativeRFOCRSourceReuse(original: original)
        let beforeClose = try closed.source(for: original)
        let beforeOpen = try open.source(for: original)
        closed.close()
        let afterClose = try closed.source(for: original)
        let afterOpen = try open.source(for: original)
        #expect(beforeClose.identity == afterClose.identity)
        #expect(!sameStorage(beforeClose, afterClose))
        #expect(sameStorage(beforeOpen, afterOpen))
    }
}
