import Foundation

/// Actual cache transport: retry only for the caller's exhausted lookup budget.
@main enum SurfacePoolLookupBudgetMain {
    static func main() {
        typealias Surface = NativeTranslationSurfacePool
        func crop(_ safe: [UInt8]) -> Surface.Crop {
            .init(safe: safe, luminance: [UInt8](repeating: 42, count: 256), width: 16, height: 16,
                  x: 0, y: 0, sx: 1, sy: 1, imageWidth: 16, imageHeight: 16, frameWidth: 4, frameHeight: 4)
        }
        let cache = Surface.Cache(), raster = crop([UInt8](repeating: 1, count: 256))
        let pool = cache.pool(raster, safeIdentity: "safe", luminanceIdentity: "lum")!
        let rect = Surface.Box(left: 0, top: 0, right: 2, bottom: 2)
        var budget = 0
        precondition(cache.range(pool, boxes: [rect], lookupBudget: &budget) == nil)
        precondition(cache.lastLookupExhausted && budget == 0)
        budget = 4
        precondition(cache.range(pool, boxes: [rect], lookupBudget: &budget) != nil)
        precondition(!cache.lastLookupExhausted && budget == 0)
        var unsafe = [UInt8](repeating: 1, count: 256); unsafe[0] = 0
        let unsafePool = cache.pool(crop(unsafe), safeIdentity: "unsafe", luminanceIdentity: "lum")!
        budget = 4
        precondition(cache.range(unsafePool, boxes: [rect], lookupBudget: &budget) == nil)
        precondition(!cache.lastLookupExhausted && budget == 0)
        budget = 0
        precondition(cache.range(pool, boxes: [rect], lookupBudget: &budget) == nil && cache.lastLookupExhausted)
        let invalid = Surface.Box(left: -1, top: 0, right: 1, bottom: 2)
        precondition(cache.range(pool, boxes: [invalid], lookupBudget: &budget) == nil)
        precondition(!cache.lastLookupExhausted && budget == 0)
        print("SurfacePool lookup exhaustion/reset/safe retry/unsafe/off-grid: 5 checks passed")
    }
}
