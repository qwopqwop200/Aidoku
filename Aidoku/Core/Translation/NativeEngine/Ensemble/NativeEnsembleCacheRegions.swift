import CoreGraphics
import Foundation

/// Pass-through candidate. Integrators obtain the benefit by sharing withPage's cache
/// across consumers, rather than running apply before unchanged legacy consumers.
enum EnsembleCandidate08: Ensemble100Candidate {
    static let defaults: [String: Double] = [
        "enabled": 1, "maxCacheMiB": 96, "maxEntries": 512,
        "gridSide": 24, "rfMinConfidence": 0.5, "warmSource": 0
    ]

    static func withPage<T>(_ page: Ensemble100Page, parameters: [String: Double],
                            _ body: (NativeEnsembleCacheRegions?) throws -> T) rethrows -> T {
        guard value("enabled", parameters) > 0 else { return try body(nil) }
        if let context = NativeMainEnsembleCacheContext.from(page) {
            // The outer main scope owns close(); do not release the shared index
            // while the bridge/downstream consumers still need this page.
            return try body(context.regionIndex(for: page))
        }
        let cache = NativeEnsembleCacheRegions(page, parameters: parameters)
        defer { cache.close() }
        return try body(cache)
    }

    static func apply(_ page: Ensemble100Page, parameters: [String: Double]) throws -> Ensemble100Proposal {
        try withPage(page, parameters: parameters) { cache in
            guard let cache else {
                return Ensemble100Proposal(items: page.items, audit: ["agent08": "disabled"])
            }
            var records: [[String: Any]] = []
            var errors: [String] = []
            if value("warmSource", parameters) > 0 {
                do { _ = try cache.withRGBA(.original) { $0.count } }
                catch { errors.append(String(describing: error)) }
            }
            for (index, item) in page.items.enumerated() {
                guard let rect = NativeEnsembleCacheRegions.sourceBounds(item) else {
                    records.append(["itemIndex": index, "status": "missing-or-invalid-sourceBounds"])
                    continue
                }
                let support = try cache.ownership(in: rect)
                var record: [String: Any] = ["itemIndex": index, "status": support.status.rawValue,
                                            "rfRegionIndices": support.regionIndices]
                do { record["removalMaskNonzeroPixels"] = try cache.maskCount(in: rect) }
                catch { record["error"] = String(describing: error) }
                records.append(record)
            }
            return Ensemble100Proposal(items: page.items, audit: [
                "agent08": "page-scoped-cache-pass-through", "items": records, "errors": errors,
                "statistics": cache.statistics,
                "requiresParentConsumerIntegration": NativeMainEnsembleCacheContext.from(page) == nil,
                "evidenceKind": "automated-cache-accounting",
                "rfAuthority": "model support only; OCR bounds remain fallback; no item mutation"
            ])
        }
    }

    fileprivate static func value(_ name: String, _ parameters: [String: Double]) -> Double {
        let fallback = defaults[name] ?? 0
        guard let value = parameters[name], value.isFinite else { return fallback }
        return value
    }
}

/// One immutable page snapshot, explicitly closed at the end of withPage. No static
/// image cache, file reads, labels, rendered outputs, text rewriting, or restoration reuse.
/// Serialized by a recursive lock; borrowed pixel pointers are valid only in their closure.
final class NativeEnsembleCacheRegions {
    enum Plane: Hashable { case original, restored }
    enum Failure: Error, CustomStringConvertible {
        case closed, incompatibleDimensions, allocation, invalidGeometry, missingRFPolygon
        case budgetExceeded(required: Int, available: Int)

        var description: String {
            switch self {
            case .closed: return "Agent08 cache closed"
            case .incompatibleDimensions: return "Agent08 image/mask dimensions differ"
            case .allocation: return "Agent08 CGContext allocation failed"
            case .invalidGeometry: return "Agent08 nonfinite or out-of-page geometry"
            case .missingRFPolygon: return "Agent08 RF box has no segmentation polygon"
            case let .budgetExceeded(required, available):
                return "Agent08 cache budget exceeded: required=\(required), available=\(available)"
            }
        }
    }

    enum OwnershipStatus: String { case rfSupport, ambiguousRF, partialRF, noRF }
    struct Ownership {
        let status: OwnershipStatus
        /// Array positions, NOT queryIDs (which need not be unique).
        let regionIndices: [Int]
        let fallbackSourceBounds: CGRect
    }
    struct Span: Equatable { let lower: Int; let upper: Int } // half-open, source pixel centers

    /// Keys use immutable CGImage identities in addition to the declared source digest.
    /// Replacing mask/restoration, RF geometry/order/confidence, or viewport invalidates compatibility.
    private struct PageKey: Equatable {
        let digest: String
        let images: [ObjectIdentifier]
        let viewport: [CGFloat]
        let rf: [[UInt64]]

        init(_ page: Ensemble100Page) {
            digest = page.sourceSHA256
            images = [page.original, page.restored, page.removalMask].map(ObjectIdentifier.init)
            viewport = [page.viewport.width, page.viewport.height]
            rf = page.rfRegions.map { region in
                var words = [UInt64(bitPattern: Int64(region.queryID)), UInt64(bitPattern: Int64(region.classID)),
                             region.confidence.bitPattern]
                words += [region.bounds.minX, region.bounds.minY, region.bounds.width, region.bounds.height]
                    .map { Double($0).bitPattern }
                for ring in [region.exterior] + region.holes {
                    words.append(UInt64(ring.count))
                    for point in ring { words += [Double(point.x).bitPattern, Double(point.y).bitPattern] }
                }
                return words
            }
        }
    }

    private struct RectKey: Hashable {
        let words: [UInt64]
        init(_ rect: CGRect, _ classID: Int) {
            words = [rect.minX, rect.minY, rect.width, rect.height].map { Double($0).bitPattern }
                + [UInt64(bitPattern: Int64(classID))]
        }
    }
    private struct RowKey: Hashable { let region: Int; let row: Int }
    private struct Cached<Value> { let value: Value; let bytes: Int; var tick: Int }

    let width: Int
    let height: Int
    private let key: PageKey
    private let lock = NSRecursiveLock()
    private let limit: Int
    private let entryLimit: Int
    private let gridSide: Int
    private let minConfidence: Double
    private var images: [Plane: CGImage]
    private var maskImage: CGImage?
    private var regions: [Ensemble100RFRegion]
    private var validRegions: [Int] = []
    private var grid: [Int: [Int]] = [:]
    private var rgba: [Plane: [UInt8]] = [:]
    private var mask: [UInt8]?
    private var prefixRows: [Int: Cached<[UInt32]>] = [:]
    private var spanRows: [RowKey: Cached<[Span]>] = [:]
    private var owners: [RectKey: Cached<Ownership>] = [:]
    private var active = true
    private var resident = 0
    private var peak = 0
    private var tick = 0
    private var counters: [String: Int] = [:]

    init(_ page: Ensemble100Page, parameters: [String: Double] = [:]) {
        key = PageKey(page)
        width = page.original.width
        height = page.original.height
        images = [.original: page.original, .restored: page.restored]
        maskImage = page.removalMask
        regions = page.rfRegions
        func value(_ name: String) -> Double { EnsembleCandidate08.value(name, parameters) }
        limit = Int(min(512, max(1, value("maxCacheMiB"))) * 1_048_576)
        entryLimit = Int(min(8192, max(1, value("maxEntries"))))
        gridSide = Int(min(64, max(4, value("gridSide"))))
        minConfidence = min(1, max(0, value("rfMinConfidence")))
        buildIndex()
    }

    var statistics: [String: Int] {
        locked {
            var result = counters
            result["trackedPayloadBytes"] = resident
            result["peakTrackedPayloadBytes"] = peak
            result["budgetBytes"] = limit
            result["entryCount"] = prefixRows.count + spanRows.count + owners.count
            result["active"] = active ? 1 : 0
            result["validRFRegions"] = validRegions.count
            return result
        }
    }

    func matches(_ page: Ensemble100Page) -> Bool { locked { active && key == PageKey(page) } }

    func close() {
        locked {
            active = false
            images.removeAll(); maskImage = nil; regions.removeAll(); validRegions.removeAll(); grid.removeAll()
            rgba.removeAll(); mask = nil; prefixRows.removeAll(); spanRows.removeAll(); owners.removeAll()
            resident = 0
        }
    }

    /// Same decode recipe for all consumers: sRGB, premultiplied RGBA8, big-endian
    /// component order, upright/top-left row 0. No resize, interpolation or unpremultiplication.
    func withRGBA<T>(_ plane: Plane, _ body: (UnsafeBufferPointer<UInt8>) throws -> T) throws -> T {
        try locked {
            try checkOpen()
            if rgba[plane] == nil {
                guard let image = images[plane], image.width == width, image.height == height else {
                    throw Failure.incompatibleDimensions
                }
                let count = try pixelCount(channels: 4)
                try reserve(count)
                let bytes = try decode(image, gray: false, count: count)
                rgba[plane] = bytes
                allocated(count)
                increment("rgbaDecodes")
            } else { increment("rgbaHits") }
            return try rgba[plane]!.withUnsafeBufferPointer(body)
        }
    }

    /// Removal mask retains its exact grayscale byte values; nonzero is only the
    /// explicit count predicate. This API never returns RF polygons as removal truth.
    func withMask<T>(_ body: (UnsafeBufferPointer<UInt8>) throws -> T) throws -> T {
        try locked {
            try ensureMask()
            return try mask!.withUnsafeBufferPointer(body)
        }
    }

    /// Integer pixel-center inclusion in a normalized OCR source rectangle.
    /// Lazy row-prefix sums are shared across overlapping items; no Nxpage integral buffer.
    func maskCount(in normalizedRect: CGRect) throws -> Int {
        try locked {
            try ensureMask()
            let rect = try validated(normalizedRect)
            let xs = pixelRange(rect.minX, rect.maxX, width)
            let ys = pixelRange(rect.minY, rect.maxY, height)
            var total = 0
            for y in ys {
                tick += 1
                if var row = prefixRows[y] {
                    increment("maskPrefixHits")
                    row.tick = tick; prefixRows[y] = row
                    total += Int(row.value[xs.upperBound] - row.value[xs.lowerBound])
                    continue
                }
                let bytes = (width + 1) * MemoryLayout<UInt32>.stride
                // Under pressure, scan just this row segment rather than changing results.
                if (try? reserve(bytes, entry: true)) == nil {
                    increment("maskDirectRows")
                    for x in xs where mask![y * width + x] != 0 { total += 1 }
                    continue
                }
                var prefix = [UInt32](repeating: 0, count: width + 1)
                for x in 0..<width { prefix[x + 1] = prefix[x] + (mask![y * width + x] == 0 ? 0 : 1) }
                increment("maskPrefixRowsBuilt")
                prefixRows[y] = Cached(value: prefix, bytes: bytes, tick: tick)
                allocated(bytes)
                total += Int(prefix[xs.upperBound] - prefix[xs.lowerBound])
            }
            return total
        }
    }

    func regionIndices(intersecting rect: CGRect, classID: Int? = nil) throws -> [Int] {
        try locked {
            try checkOpen()
            let rect = try validated(rect)
            increment("regionQueries")
            let pool: [Int]
            if grid.isEmpty { pool = validRegions } else {
                var found = Set<Int>()
                for cell in cells(rect) { for index in grid[cell] ?? [] { found.insert(index) } }
                pool = found.sorted()
            }
            return pool.filter {
                (classID == nil || regions[$0].classID == classID) && regions[$0].bounds.intersects(rect)
            }
        }
    }

    /// Conservative nine-anchor RF association, explicitly geometry/model evidence.
    /// It does not merge paragraphs or certify glyph ownership. Consumers must retain
    /// OCR+pixel/heuristic behavior for noRF/partialRF/ambiguousRF (and verify rfSupport).
    func ownership(in rect: CGRect, classID: Int = 2) throws -> Ownership {
        try locked {
            try checkOpen()
            let rect = try validated(rect)
            let cacheKey = RectKey(rect, classID)
            tick += 1
            if var hit = owners[cacheKey] {
                hit.tick = tick; owners[cacheKey] = hit; increment("ownershipHits")
                return hit.value
            }
            let candidates = try regionIndices(intersecting: rect, classID: classID)
            let xs = [rect.minX, rect.midX, rect.maxX]
            let ys = [rect.minY, rect.midY, rect.maxY]
            let complete = candidates.filter { index in
                xs.allSatisfy { x in ys.allSatisfy { y in contains(CGPoint(x: x, y: y), region: regions[index]) } }
            }
            // Any competing polygon touching the OCR box is unresolved, even when
            // just one candidate passes all anchors. Duplicate query IDs are not merged.
            let status: OwnershipStatus = candidates.isEmpty ? .noRF
                : candidates.count > 1 ? .ambiguousRF : complete.count == 1 ? .rfSupport : .partialRF
            let result = Ownership(status: status, regionIndices: candidates, fallbackSourceBounds: rect)
            increment("ownershipMisses")
            let bytes = 96 + candidates.count * MemoryLayout<Int>.stride
            if (try? reserve(bytes, entry: true)) != nil {
                owners[cacheKey] = Cached(value: result, bytes: bytes, tick: tick); allocated(bytes)
            }
            return result
        }
    }

    /// Polygon scan conversion at one original-resolution top-left row. Exterior
    /// minus holes, even-odd within each ring; never allocates a whole RF bitmap.
    func rfSpans(regionIndex: Int, pixelRow: Int) throws -> [Span] {
        try locked {
            try checkOpen()
            guard validRegions.contains(regionIndex), (0..<height).contains(pixelRow) else { throw Failure.invalidGeometry }
            guard !regions[regionIndex].exterior.isEmpty else { throw Failure.missingRFPolygon }
            let rowKey = RowKey(region: regionIndex, row: pixelRow)
            tick += 1
            if var hit = spanRows[rowKey] {
                hit.tick = tick; spanRows[rowKey] = hit; increment("rfSpanHits")
                return hit.value
            }
            let region = regions[regionIndex]
            let y = (CGFloat(pixelRow) + 0.5) / CGFloat(height)
            var outer = crossings(region.exterior, y: y)
            for hole in region.holes {
                for cut in crossings(hole, y: y) {
                    outer = outer.flatMap { span -> [(CGFloat, CGFloat)] in
                        if cut.1 <= span.0 || cut.0 >= span.1 { return [span] }
                        var parts: [(CGFloat, CGFloat)] = []
                        if cut.0 > span.0 { parts.append((span.0, cut.0)) }
                        if cut.1 < span.1 { parts.append((cut.1, span.1)) }
                        return parts
                    }
                }
            }
            let result = outer.compactMap { span -> Span? in
                let range = pixelRange(span.0, span.1, width)
                return range.isEmpty ? nil : Span(lower: range.lowerBound, upper: range.upperBound)
            }
            increment("rfSpanRowsBuilt")
            let bytes = 32 + result.count * MemoryLayout<Span>.stride
            if (try? reserve(bytes, entry: true)) != nil {
                spanRows[rowKey] = Cached(value: result, bytes: bytes, tick: tick); allocated(bytes)
            }
            return result
        }
    }

    static func sourceBounds(_ item: [String: Any]) -> CGRect? {
        guard let values = item["sourceBounds"] as? [Double], values.count == 4,
              values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
        let rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        return unit.contains(rect) ? rect : nil
    }

    private static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
    private func checkOpen() throws { if !active { throw Failure.closed } }
    private func increment(_ name: String) { counters[name, default: 0] += 1 }
    private func allocated(_ bytes: Int) { resident += bytes; peak = max(peak, resident) }

    private func validated(_ rect: CGRect) throws -> CGRect {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0, Self.unit.contains(rect) else { throw Failure.invalidGeometry }
        return rect
    }

    private func pixelRange(_ lower: CGFloat, _ upper: CGFloat, _ side: Int) -> Range<Int> {
        let start = min(side, max(0, Int(ceil(lower * CGFloat(side) - 0.5))))
        let end = min(side, max(start, Int(ceil(upper * CGFloat(side) - 0.5))))
        return start..<end
    }

    private func pixelCount(channels: Int) throws -> Int {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let (count, secondOverflow) = pixels.multipliedReportingOverflow(by: channels)
        guard !overflow, !secondOverflow, width > 0, height > 0, width < Int(UInt32.max) else { throw Failure.invalidGeometry }
        return count
    }

    private func ensureMask() throws {
        try checkOpen()
        if mask != nil { increment("maskHits"); return }
        guard let image = maskImage, image.width == width, image.height == height else { throw Failure.incompatibleDimensions }
        let count = try pixelCount(channels: 1)
        try reserve(count)
        mask = try decode(image, gray: true, count: count)
        allocated(count); increment("maskDecodes")
    }

    private func decode(_ image: CGImage, gray: Bool, count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
            let info = gray ? 0 : CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * (gray ? 1 : 4), space: space, bitmapInfo: info) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            // CGImage provider row 0 remains buffer row 0. A UIKit-style flip here
            // would invert saved source/mask coordinates (covered by asymmetric fixtures).
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw Failure.allocation }
        return bytes
    }

    private func reserve(_ bytes: Int, entry: Bool = false) throws {
        while bytes > limit - resident || (entry && prefixRows.count + spanRows.count + owners.count >= entryLimit) {
            let oldestPrefix = prefixRows.min { $0.value.tick < $1.value.tick }
            let oldestSpan = spanRows.min { $0.value.tick < $1.value.tick }
            let oldestOwner = owners.min { $0.value.tick < $1.value.tick }
            let minimum = min(oldestPrefix?.value.tick ?? Int.max, oldestSpan?.value.tick ?? Int.max,
                              oldestOwner?.value.tick ?? Int.max)
            guard minimum != Int.max else { throw Failure.budgetExceeded(required: bytes, available: limit - resident) }
            if let old = oldestPrefix, old.value.tick == minimum {
                resident -= old.value.bytes; prefixRows.removeValue(forKey: old.key)
            } else if let old = oldestSpan, old.value.tick == minimum {
                resident -= old.value.bytes; spanRows.removeValue(forKey: old.key)
            } else if let old = oldestOwner {
                resident -= old.value.bytes; owners.removeValue(forKey: old.key)
            }
            increment("entryEvictions")
        }
    }

    private func buildIndex() {
        validRegions = regions.indices.filter { index in
            let region = regions[index]
            let rings = [region.exterior] + region.holes
            let boxOnly = region.exterior.isEmpty && region.holes.isEmpty
            return (0...3).contains(region.classID) && region.confidence.isFinite
                && region.confidence >= minConfidence && region.confidence <= 1
                && (try? validated(region.bounds)) != nil
                && (boxOnly || rings.allSatisfy { ring in
                    ring.count >= 3 && ring.allSatisfy {
                        $0.x.isFinite && $0.y.isFinite && $0.x >= region.bounds.minX && $0.x <= region.bounds.maxX
                            && $0.y >= region.bounds.minY && $0.y <= region.bounds.maxY
                    }
                })
        }
        counters["invalidOrLowConfidenceRFRegions"] = regions.count - validRegions.count
        counters["boxOnlyRFRegions"] = validRegions.filter { regions[$0].exterior.isEmpty }.count
        guard !validRegions.isEmpty else { return }
        // Estimate first, build only if the entire index fits. Otherwise query all
        // valid bounds; region evidence is not truncated because of the budget.
        let references = validRegions.reduce(0) { $0 + cells(regions[$1].bounds).count }
        let bytes = references * MemoryLayout<Int>.stride + gridSide * gridSide * 32
        guard bytes <= limit / 8 else { increment("gridBudgetFallbacks"); return }
        for index in validRegions { for cell in cells(regions[index].bounds) { grid[cell, default: []].append(index) } }
        allocated(bytes); increment("gridBuilds")
    }

    private func cells(_ rect: CGRect) -> [Int] {
        let left = max(0, min(gridSide - 1, Int(floor(rect.minX * CGFloat(gridSide)))))
        let right = max(left, min(gridSide - 1, Int(floor(rect.maxX * CGFloat(gridSide)))))
        let top = max(0, min(gridSide - 1, Int(floor(rect.minY * CGFloat(gridSide)))))
        let bottom = max(top, min(gridSide - 1, Int(floor(rect.maxY * CGFloat(gridSide)))))
        return (top...bottom).flatMap { y in (left...right).map { y * gridSide + $0 } }
    }

    private func crossings(_ ring: [CGPoint], y: CGFloat) -> [(CGFloat, CGFloat)] {
        var xs: [CGFloat] = []
        for index in ring.indices {
            let a = ring[index], b = ring[(index + 1) % ring.count]
            if (a.y > y) != (b.y > y) { xs.append(a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y)) }
        }
        xs.sort()
        return stride(from: 0, to: max(0, xs.count - 1), by: 2).map { (xs[$0], xs[$0 + 1]) }
    }

    private func contains(_ point: CGPoint, region: Ensemble100RFRegion) -> Bool {
        guard !region.exterior.isEmpty else { return false }
        func inRing(_ ring: [CGPoint]) -> Bool {
            crossings(ring, y: point.y).contains { $0.0 <= point.x && point.x < $0.1 }
        }
        return inRing(region.exterior) && !region.holes.contains(where: inRing)
    }
}

// Compatibility for existing region consumers and independent component tests.
typealias Ensemble08PageCache = NativeEnsembleCacheRegions
