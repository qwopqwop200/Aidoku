import Testing
@testable import Aidoku

struct NativeExteriorSurfacePoolTests {
    private func crop(unsafe: Bool = false) -> NativeTranslationSurfacePool.Crop {
        var safe = [UInt8](repeating: 1, count: 48 * 96)
        if unsafe { safe[22 * 48 + 20] = 0 }
        return .init(safe: safe, luminance: [UInt8](repeating: 240, count: safe.count),
                     width: 48, height: 96, x: 0, y: 0, sx: 1, sy: 1,
                     imageWidth: 48, imageHeight: 96, frameWidth: 16, frameHeight: 32)
    }

    @Test func exactInteriorExtremaKeepExteriorProbeWithinFrozenAllowance() throws {
        let cache = NativeTranslationSurfacePool.Cache()
        let pool = try #require(cache.pool(crop(), safeIdentity: "safe", luminanceIdentity: "luma"))
        var budget = 400, sampled = 0
        let range = cache.range(pool, boxes: [.init(left: -4, top: 20, right: 52, bottom: 40)], lookupBudget: &budget) { x, y in
            #expect(x < 0 || x >= 48)
            #expect(y >= 20 && y < 40)
            sampled += 1
            return 255
        }
        #expect(range == [239.5 / 255, 1])
        #expect(budget == 0)
        #expect(sampled == 160)
        #expect(!cache.lastLookupExhausted)
    }

    @Test func unsafeInteriorCannotBePromotedByMatchingExterior() throws {
        let cache = NativeTranslationSurfacePool.Cache()
        let pool = try #require(cache.pool(crop(unsafe: true), safeIdentity: "safe", luminanceIdentity: "luma"))
        var budget = 400
        let range = cache.range(pool, boxes: [.init(left: -4, top: 20, right: 52, bottom: 40)], lookupBudget: &budget) { _, _ in 255 }
        #expect(range == nil)
        #expect(!cache.lastLookupExhausted)
    }

    @Test func rejectedExteriorAndInsufficientAllowanceRemainFailures() throws {
        let cache = NativeTranslationSurfacePool.Cache()
        let pool = try #require(cache.pool(crop(), safeIdentity: "safe", luminanceIdentity: "luma"))
        let boxes = [NativeTranslationSurfacePool.Box(left: -4, top: 20, right: 52, bottom: 40)]
        var budget = 400
        #expect(cache.range(pool, boxes: boxes, lookupBudget: &budget, exterior: { _, _ in nil }) == nil)
        budget = 399
        #expect(cache.range(pool, boxes: boxes, lookupBudget: &budget, exterior: { _, _ in 255 }) == nil)
        #expect(cache.lastLookupExhausted)
        #expect(budget == 399)
    }
}
