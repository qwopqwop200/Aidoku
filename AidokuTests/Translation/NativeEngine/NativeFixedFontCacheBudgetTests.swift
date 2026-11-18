import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeFixedFontCacheBudgetTests {
    private func image(_ value: UInt8) throws -> CGImage {
        let data = Data(repeating: value, count: 8 * 8 * 4)
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test func discardedCandidateReleasesOnlyItsOwnRetainedResources() throws {
        let cache = NativeFixedFontRecovery.CacheBudget(maxPixels: 128, maxRuns: 4, maxBytes: 2200)
        let incumbent = try image(255), discarded = try image(127), replacement = try image(63)
        try cache.retain(owner: "incumbent", image: incumbent, runCount: 2, metadataBytes: 0)
        let retained = cache.audit
        try cache.retain(owner: "discarded", image: discarded, runCount: 2, metadataBytes: 0)
        #expect(throws: NativeFixedFontRecovery.CacheBudgetFailure.self) {
            try cache.retain(owner: "replacement", image: replacement, runCount: 2, metadataBytes: 0)
        }
        cache.releaseDiscarded(image: discarded)
        #expect(cache.audit == retained)
        try cache.retain(owner: "replacement", image: replacement, runCount: 2, metadataBytes: 0)
        #expect(cache.pixels == 128 && cache.runs == 4 && cache.bytes == 2144)
        // Re-retaining an incumbent must remain a no-op after another release.
        let full = cache.audit
        try cache.retain(owner: "incumbent", image: incumbent, runCount: 2, metadataBytes: 0)
        #expect(cache.audit == full)
    }

    @Test func repeatedOrUnknownDiscardNeverUndercountsAcceptedImages() throws {
        let cache = NativeFixedFontRecovery.CacheBudget()
        let incumbent = try image(255), discarded = try image(127), unknown = try image(63)
        try cache.retain(owner: "incumbent", image: incumbent, runCount: 3, metadataBytes: 100)
        let retained = cache.audit
        try cache.retain(owner: "discarded", image: discarded, runCount: 4, metadataBytes: 200)
        cache.releaseDiscarded(image: discarded)
        cache.releaseDiscarded(image: discarded)
        cache.releaseDiscarded(image: unknown)
        #expect(cache.audit == retained)
    }

    @Test func discardedCandidatesDoNotConsumeTheNextGenerationBudget() throws {
        let cache = NativeFixedFontRecovery.CacheBudget(maxPixels: 64, maxRuns: 2, maxBytes: 1100)
        for value in [UInt8(255), 127, 63, 31] {
            let candidate = try image(value)
            try cache.checkImage(owner: "owner", width: 8, height: 8)
            try cache.retain(owner: "owner", image: candidate, runCount: 2, metadataBytes: 0)
            cache.releaseDiscarded(image: candidate)
            #expect(cache.pixels == 0 && cache.runs == 0 && cache.bytes == 0)
        }
    }
}
