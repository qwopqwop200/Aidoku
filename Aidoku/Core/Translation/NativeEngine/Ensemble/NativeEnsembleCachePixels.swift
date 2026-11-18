import CoreGraphics
import Foundation

/// Explicit consumer adapter, not a pass-through candidate. Supported recipes are
/// preserve source-surface RGBA, removal-mask gray, and ROI palette sampling rules.
/// No pixel arithmetic, alpha conversion, coordinate flip, or full-page-to-ROI shortcut.
final class NativeEnsembleCachePixels {
    static let evidenceKey = "ensemblePagePixelCache"
    static let defaults: [String: Double] = ["enabled": 1, "maxCacheMiB": 96, "maxEntries": 256]

    struct Recipe: Hashable {
        fileprivate enum Kind: Hashable { case gray06, rgba03, rgba07 }
        fileprivate let kind: Kind
        fileprivate let width: Int
        fileprivate let height: Int
        // Preserve the exact ROI doubles and all of the original arithmetic.
        // CGRect itself is not used as a dictionary key or rounded/quantized.
        fileprivate let roi: [UInt64]

        static let candidate06Gray = Recipe(kind: .gray06, width: 0, height: 0, roi: [])

        static func candidate03RGBA(width: Int, height: Int) -> Recipe {
            Recipe(kind: .rgba03, width: width, height: height, roi: [])
        }

        static func candidate07RGBA(roi: CGRect, width: Int, height: Int) -> Recipe {
            Recipe(kind: .rgba07, width: width, height: height,
                   roi: [roi.minX, roi.minY, roi.width, roi.height].map { Double($0).bitPattern })
        }
    }

    private struct Key: Hashable {
        let image: ObjectIdentifier
        let sourceWidth: Int
        let sourceHeight: Int
        let recipe: Recipe
    }

    private struct Entry {
        // Retain identity while cached: prevents recycled ObjectIdentifier hits.
        let image: CGImage
        let bytes: [UInt8]
        var used: UInt64
    }

    private struct Plan { let width: Int; let height: Int; let count: Int }
    private let lock = NSLock()
    private let budget: Int
    private let entryLimit: Int
    private let enabled: Bool
    private var active = true
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private var resident = 0
    private var peak = 0
    private var counts: [String: Int] = [:]

    init(maxCacheMiB: Double = 96, maxEntries: Int = 256, enabled: Bool = true) {
        let finiteMiB = maxCacheMiB.isFinite ? maxCacheMiB : 96
        budget = Int(min(1024, max(0, finiteMiB)) * 1_048_576)
        entryLimit = min(4096, max(0, maxEntries))
        self.enabled = enabled
    }

    /// All candidate consumers for ONE page must run inside this closure. The
    /// returned page preserves every field and adds only the in-memory adapter.
    /// It must not be serialized; serialize statistics instead. Captured cache
    /// references are cleared at exit and subsequently decode uncached.
    static func withPage<T>(_ page: Ensemble100Page, parameters: [String: Double] = [:],
                            _ body: (Ensemble100Page, NativeEnsembleCachePixels) throws -> T) rethrows -> T {
        if let context = NativeMainEnsembleCacheContext.from(page) {
            // Main scope owns lifetime/configuration. A nested consumer must not
            // allocate another page cache or close the outer shared one.
            return try body(page, context.pixelCache)
        }
        func value(_ key: String) -> Double {
            guard let v = parameters[key], v.isFinite else { return defaults[key]! }
            return v
        }
        let cache = NativeEnsembleCachePixels(maxCacheMiB: value("maxCacheMiB"),
            maxEntries: Int(min(4096, max(0, value("maxEntries")))), enabled: value("enabled") > 0)
        defer { cache.close() }
        var evidence = page.savedEvidence
        evidence[evidenceKey] = cache
        let scoped = Ensemble100Page(sourceSHA256: page.sourceSHA256, original: page.original,
            restored: page.restored, removalMask: page.removalMask, viewport: page.viewport,
            items: page.items, rfRegions: page.rfRegions, savedEvidence: evidence)
        return try body(scoped, cache)
    }

    var statistics: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        var result = counts
        result["cachedPayloadBytes"] = resident
        result["peakCachedPayloadBytes"] = peak
        result["budgetBytes"] = budget
        result["entries"] = entries.count
        result["active"] = active ? 1 : 0
        return result
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        active = false
        entries.removeAll(keepingCapacity: false)
        resident = 0
    }

    /// Returned arrays have Swift value semantics. A mutating consumer gets a COW
    /// copy; cached arrays/other consumers cannot be mutated through this API.
    func gray(image: CGImage, recipe: Recipe = .candidate06Gray) -> [UInt8]? {
        guard recipe.kind == .gray06 else { return rejectedRecipe() }
        return pixels(image, recipe: recipe)
    }

    func rgba(image: CGImage, recipe: Recipe) -> [UInt8]? {
        guard recipe.kind != .gray06 else { return rejectedRecipe() }
        return pixels(image, recipe: recipe)
    }

    /// Suitable for consumers whose cache is absent. Unlike `cache?.gray ?? decode`,
    /// these wrappers never retry a genuine CGContext/cropping allocation failure.
    static func gray(image: CGImage, recipe: Recipe = .candidate06Gray,
                     cache: NativeEnsembleCachePixels?) -> [UInt8]? {
        if let cache { return cache.gray(image: image, recipe: recipe) }
        guard recipe.kind == .gray06 else { return nil }
        return uncached(image, recipe: recipe)
    }

    static func rgba(image: CGImage, recipe: Recipe, cache: NativeEnsembleCachePixels?) -> [UInt8]? {
        if let cache { return cache.rgba(image: image, recipe: recipe) }
        guard recipe.kind != .gray06 else { return nil }
        return uncached(image, recipe: recipe)
    }

    private func rejectedRecipe() -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        counts["invalidRecipeCalls", default: 0] += 1
        return nil
    }

    private func pixels(_ image: CGImage, recipe: Recipe) -> [UInt8]? {
        // Serialize lookup+decode+insert to avoid duplicate concurrent misses.
        lock.lock(); defer { lock.unlock() }
        counts["requests", default: 0] += 1
        let key = Key(image: ObjectIdentifier(image), sourceWidth: image.width,
                      sourceHeight: image.height, recipe: recipe)
        clock &+= 1
        if active, var entry = entries[key] {
            entry.used = clock; entries[key] = entry
            counts["hits", default: 0] += 1
            return entry.bytes
        }
        counts["misses", default: 0] += 1
        guard let plan = Self.plan(image, recipe: recipe) else {
            counts["invalidGeometryCalls", default: 0] += 1
            return nil
        }
        let admit = active && enabled && entryLimit > 0 && plan.count <= budget
        if admit {
            // Evict before allocating the new decode, not after. Caller-owned
            // COW copies and CoreGraphics scratch storage are outside this budget.
            while resident > budget - plan.count || entries.count >= entryLimit {
                guard let oldest = entries.min(by: { $0.value.used < $1.value.used }) else { break }
                resident -= oldest.value.bytes.count
                entries.removeValue(forKey: oldest.key)
                counts["evictions", default: 0] += 1
            }
        } else {
            let reason = !active ? "closedBypasses" : !enabled ? "disabledBypasses" : "budgetBypasses"
            counts[reason, default: 0] += 1
        }
        counts["decodeAttempts", default: 0] += 1
        let kind = recipe.kind == .gray06 ? "grayDecodes" : recipe.kind == .rgba03 ? "rgba03Decodes" : "rgba07Decodes"
        counts[kind, default: 0] += 1
        guard let bytes = Self.decode(image, recipe: recipe, plan: plan) else {
            counts["decodeFailures", default: 0] += 1
            return nil
        }
        counts["decodeSuccesses", default: 0] += 1
        if admit {
            entries[key] = Entry(image: image, bytes: bytes, used: clock)
            resident += bytes.count; peak = max(peak, resident)
        }
        return bytes
    }

    private static func plan(_ image: CGImage, recipe: Recipe) -> Plan? {
        let w = recipe.kind == .gray06 ? image.width : recipe.width
        let h = recipe.kind == .gray06 ? image.height : recipe.height
        guard w > 0, h > 0 else { return nil }
        let channels = recipe.kind == .gray06 ? 1 : 4
        let (pixels, overflow) = w.multipliedReportingOverflow(by: h)
        let (count, moreOverflow) = pixels.multipliedReportingOverflow(by: channels)
        guard !overflow, !moreOverflow, w <= Int.max / channels else { return nil }
        if recipe.kind == .rgba07 {
            let v = recipe.roi.map { Double(bitPattern: $0) }
            guard v.count == 4, v.allSatisfy(\.isFinite), v[2] > 0, v[3] > 0 else { return nil }
            let rect = crop(image, recipe: recipe)
            guard [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite),
                  !rect.integral.isInfinite else { return nil }
        }
        return Plan(width: w, height: h, count: count)
    }

    private static func uncached(_ image: CGImage, recipe: Recipe) -> [UInt8]? {
        guard let plan = plan(image, recipe: recipe) else { return nil }
        return decode(image, recipe: recipe, plan: plan)
    }

    private static func crop(_ image: CGImage, recipe: Recipe) -> CGRect {
        let v = recipe.roi.map { Double(bitPattern: $0) }
        return CGRect(x: v[0] * Double(image.width), y: v[1] * Double(image.height),
                      width: v[2] * Double(image.width), height: v[3] * Double(image.height))
    }

    private static func decode(_ image: CGImage, recipe: Recipe, plan: Plan) -> [UInt8]? {
        let gray = recipe.kind == .gray06
        let space: CGColorSpace
        if gray { space = CGColorSpaceCreateDeviceGray() }
        else {
            guard let rgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            space = rgb
        }
        let input: CGImage
        let drawRect: CGRect
        if recipe.kind == .rgba07 {
            let nominal = crop(image, recipe: recipe)
            let actual = nominal.integral
            guard let part = image.cropping(to: actual) else { return nil }
            input = part
            // Exact candidate07 formula, including the Y correction and integral
            // expansion. Do not replace with direct full-page sampling/slicing.
            drawRect = CGRect(x: (actual.minX - nominal.minX) / nominal.width * Double(plan.width),
                y: (nominal.maxY - actual.maxY) / nominal.height * Double(plan.height),
                width: actual.width / nominal.width * Double(plan.width),
                height: actual.height / nominal.height * Double(plan.height))
        } else {
            input = image
            drawRect = CGRect(x: 0, y: 0, width: plan.width, height: plan.height)
        }
        var bytes = [UInt8](repeating: 0, count: plan.count)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            let info = gray ? 0 : CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let context = CGContext(data: raw.baseAddress, width: plan.width, height: plan.height,
                bitsPerComponent: 8, bytesPerRow: plan.width * (gray ? 1 : 4), space: space, bitmapInfo: info) else { return false }
            context.interpolationQuality = recipe.kind == .rgba03 ? .medium : .none
            // Original recipes use default source-over, zero-initialized storage,
            // identity CTM, default intent/antialiasing. Do not force .copy/flip.
            context.draw(input, in: drawRect)
            return true
        }
        return ok ? bytes : nil
    }
}

// Compatibility for component consumers; no second cache implementation.
typealias Ensemble08NextPixelCache = NativeEnsembleCachePixels
