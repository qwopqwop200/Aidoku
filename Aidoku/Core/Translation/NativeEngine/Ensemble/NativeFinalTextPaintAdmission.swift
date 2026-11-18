import CoreFoundation
import CoreGraphics
import CryptoKit
import Foundation

/// Final retained alpha, including every source band and translated shadow.
/// Geometry proposals never certify this pass; no source image classification.
enum NativeFinalTextPaintAdmission {
    /// Transaction-local optional veto. It cannot filter text or replace an
    /// incumbent. Unknown evidence preserves the already admitted placement.
    final class RetainedSourceRiskGate: @unchecked Sendable {
        let evaluate: (Footprint, Footprint) -> Bool?
        init(evaluate: @escaping (Footprint, Footprint) -> Bool?) { self.evaluate = evaluate }
    }
    @TaskLocal static var retainedSourceRiskGate: RetainedSourceRiskGate?

    struct Run: Equatable { let y: Int; let left: Int; let right: Int }
    private struct Offset: Hashable { let x: CGFloat; let y: CGFloat }
    /// Placement tries many positions of the same immutable raster. Its row
    /// intervals share storage and apply their integer displacement on access.
    struct TranslatedRuns: RandomAccessCollection {
        let source: [Run]
        var dx = 0, dy = 0
        var startIndex: Int { source.startIndex }
        var endIndex: Int { source.endIndex }
        subscript(position: Int) -> Run {
            let row = source[position]
            return Run(y: row.y + dy, left: row.left + dx, right: row.right + dx)
        }
    }
    struct Footprint {
        private(set) var runs: TranslatedRuns
        private(set) var bounds: CGRect
        let pixels: Int
        var readableBounds: CGRect? = nil
        init(runs: [Run], bounds: CGRect, pixels: Int, readableBounds: CGRect? = nil) {
            self.runs = TranslatedRuns(source: runs)
            self.bounds = bounds
            self.pixels = pixels
            self.readableBounds = readableBounds
        }
        func translated(_ offset: CGPoint) -> Footprint {
            var shifted = self
            shifted.runs.dx += Int(offset.x)
            shifted.runs.dy += Int(offset.y)
            shifted.bounds = bounds.offsetBy(dx: offset.x, dy: offset.y)
            shifted.readableBounds = readableBounds?.offsetBy(dx: offset.x, dy: offset.y)
            return shifted
        }
    }
    // Compact storage is optional. A coordinate outside Int16 uses the normal search.
    private struct SavedRun {
        let y: Int16, left: Int16, right: Int16
        init?(_ run: Run) {
            guard let y = Int16(exactly: run.y), let left = Int16(exactly: run.left),
                  let right = Int16(exactly: run.right) else { return nil }
            self.y = y; self.left = left; self.right = right
        }
        func matches(_ run: Run) -> Bool {
            Int(y) == run.y && Int(left) == run.left && Int(right) == run.right
        }
    }
    private struct SavedAnswer {
        let x: Int16, y: Int16
        let valid: Bool
        init?(_ shift: Offset, valid: Bool) {
            guard let x = Int16(exactly: shift.x), let y = Int16(exactly: shift.y) else { return nil }
            self.x = x; self.y = y; self.valid = valid
        }
    }
    private struct OwnerSearchGeometry: Equatable {
        let bounds: CGRect
        let readableBounds: CGRect?
        let pixels: Int
        let spacing: PeerSpacing
        let preferred: CGPoint
        let hasDomain: Bool
        let projected: [CGPoint]?
    }
    private struct SavedOwner {
        let geometry: OwnerSearchGeometry
        let runEnd: Int
        let answerEnd: Int
    }
    /// Only bounded value storage outlives a failed search. Identifiers are
    /// resolved from the current fills when reporting the blocked indices.
    private struct FailedSearch {
        let page: CGRect
        let margin: CGFloat
        let order: [Int]
        let owners: [SavedOwner]
        let runs: [SavedRun]
        let answers: [SavedAnswer]
        let attempts: Int
        let deepest: Int
        let blockedOwner: Int
        let blockedPeers: [Int]

        var retainedBytes: Int {
            // Charge allocated capacity, including shared proposal buffers.
            // The fixed allowance covers array headers and entry metadata.
            512 + owners.capacity * MemoryLayout<SavedOwner>.stride +
                runs.capacity * MemoryLayout<SavedRun>.stride + answers.capacity * MemoryLayout<SavedAnswer>.stride +
                (order.capacity + blockedPeers.capacity) * MemoryLayout<Int>.stride +
                owners.reduce(0) { $0 + ($1.geometry.projected?.capacity ?? 0) * MemoryLayout<CGPoint>.stride + 64 }
        }
    }
    private final class FailureMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(fingerprint: Int, failure: FailedSearch, bytes: Int)] = []
        private var bytes = 0
        private let byteLimit = 2 * 1024 * 1024

        func find(_ prefixes: [Int]) -> FailedSearch? {
            lock.lock(); defer { lock.unlock() }
            return entries.last { entry in
                let depth = entry.failure.deepest
                return depth < prefixes.count && entry.fingerprint == prefixes[depth]
            }?.failure
        }
        func store(_ failure: FailedSearch, fingerprint: Int) {
            let charge = failure.retainedBytes
            guard charge <= byteLimit else { return }
            lock.lock(); defer { lock.unlock() }
            if let previous = entries.firstIndex(where: { $0.fingerprint == fingerprint }) {
                bytes -= entries.remove(at: previous).bytes
            }
            while entries.count >= 12 || charge > byteLimit - bytes {
                bytes -= entries.removeFirst().bytes
            }
            entries.append((fingerprint, failure, charge))
            bytes += charge
        }
    }
    @TaskLocal private static var failureMemo: FailureMemo?
    /// Optional request-local geometry cache. It retains no CGImages and never
    /// caches admission. The same live immutable image may reuse its exact RGBA digest.
    final class RetainedFootprintMemo: @unchecked Sendable {
        private struct Key: Hashable {
            let width: Int
            let height: Int
            let digest: Data
            let parameters: [UInt64]
            let pendingContour: String?
        }
        private struct Entry { let local: Footprint; let bytes: Int; var lastUse: Int }
        private final class RasterDigest {
            weak var image: CGImage?
            let digest: Data
            init(image: CGImage, digest: Data) { self.image = image; self.digest = digest }
        }
        private let lock = NSLock()
        private var entries: [Key: Entry] = [:]
        private var rasterDigests: [ObjectIdentifier: RasterDigest] = [:]
        /// Each source has one deterministic alpha-bound crop. Cache its bounds and the
        /// SHA actually measured from that crop. Preserve the original cropping call and
        /// its returned image identity on every request; neither dictionary owns images.
        private final class TightCropWitness {
            weak var source: CGImage?
            let bounds: CGRect
            var digest: Data?
            init(source: CGImage, bounds: CGRect) {
                self.source = source
                self.bounds = bounds
            }
        }
        private struct CroppedRaster {
            weak var image: CGImage?
            let witness: TightCropWitness
        }
        private var cropSources: [ObjectIdentifier: TightCropWitness] = [:]
        private var croppedRasters: [ObjectIdentifier: CroppedRaster] = [:]
        // Charge both maps and a source witness retained only through an old output.
        // Reserve at most 1/16 of the payload budget (64 KiB at the default entry cap).
        private let cropEntryLimit: Int
        private static let cropPairCharge = 512
        private var tightBoundsHits = 0, tightDigestHits = 0
        private var rasterDigestIdentityHits = 0
        private var bytes = 0, hits = 0, misses = 0, bypasses = 0, rgbaBytesRead = 0, evictions = 0, sequence = 0
        private let byteLimit: Int, entryLimit: Int
        init(byteLimit: Int = 16 * 1024 * 1024, entryLimit: Int = 128) {
            let budget = max(0, min(16 * 1024 * 1024, byteLimit))
            self.entryLimit = max(0, min(128, entryLimit))
            cropEntryLimit = min(self.entryLimit, budget / 16 / Self.cropPairCharge)
            self.byteLimit = budget - cropEntryLimit * Self.cropPairCharge
        }
        fileprivate func tightBounds(for source: CGImage, measure: () throws -> CGRect) throws -> CGRect {
            let key = ObjectIdentifier(source)
            lock.lock()
            if let entry = cropSources[key], entry.source === source {
                tightBoundsHits += 1
                lock.unlock()
                return entry.bounds
            }
            lock.unlock()
            let bounds = try measure()
            guard cropEntryLimit > 0 else { return bounds }
            lock.lock(); defer { lock.unlock() }
            if cropSources.count >= cropEntryLimit { cropSources = cropSources.filter { $0.value.source != nil } }
            if cropSources.count < cropEntryLimit {
                cropSources[key] = TightCropWitness(source: source, bounds: bounds)
            }
            return bounds
        }
        fileprivate func recordTightCrop(_ crop: CGImage, from source: CGImage, bounds: CGRect) {
            guard cropEntryLimit > 0 else { return }
            lock.lock(); defer { lock.unlock() }
            guard let witness = cropSources[ObjectIdentifier(source)],
                  witness.source === source, witness.bounds == bounds else { return }
            if croppedRasters.count >= cropEntryLimit { croppedRasters = croppedRasters.filter { $0.value.image != nil } }
            if croppedRasters.count < cropEntryLimit {
                croppedRasters[ObjectIdentifier(crop)] = CroppedRaster(image: crop, witness: witness)
            }
        }
        private func rasterDigest(_ image: CGImage) -> Data? {
            let identity = ObjectIdentifier(image)
            lock.lock()
            if let cached = rasterDigests[identity], cached.image === image {
                // Compare the actual live object, not just a recycled address.
                rasterDigestIdentityHits += 1
                lock.unlock()
                return cached.digest
            }
            let measuredCrop = croppedRasters[identity].flatMap { $0.image === image ? $0.witness : nil }
            if let digest = measuredCrop?.digest {
                tightDigestHits += 1
                lock.unlock()
                return digest
            }
            lock.unlock()
            guard let rgba = try? NativeMandatoryDisplayStroke.rgba(image) else { return nil }
            var sha = SHA256()
            rgba.withUnsafeBytes { sha.update(bufferPointer: $0) }
            let digest = Data(sha.finalize())
            lock.lock(); defer { lock.unlock() }
            rgbaBytesRead += rgba.count
            measuredCrop?.digest = digest
            if entryLimit > 0 {
                if rasterDigests.count >= entryLimit {
                    rasterDigests = rasterDigests.filter { $0.value.image != nil }
                }
                if rasterDigests.count < entryLimit {
                    rasterDigests[identity] = RasterDigest(image: image, digest: digest)
                }
            }
            return digest
        }
        private func key(_ fill: NativeAOTTranslationPageComposer.TranslatedFillPrimitive) -> Key? {
            guard fill.frame == fill.frame.integral, fill.frame.minX.isFinite, fill.frame.minY.isFinite,
                  abs(fill.frame.minX) <= 1_000_000, abs(fill.frame.minY) <= 1_000_000,
                  fill.frame.width == CGFloat(fill.image.width), fill.frame.height == CGFloat(fill.image.height),
                  fill.image.height > 0, fill.image.width > 0, fill.image.width <= 4_000_000 / fill.image.height,
                  fill.sourceStyle?.roundedContour == nil else { return nil }
            var parameters: [UInt64] = [Double(fill.fontOutputPixels).bitPattern,
                Double(fill.displayStrokeRatio ?? 0.20).bitPattern,
                fill.sourceContourOnly ? 1 : 0, fill.hasFinalEffects ? 1 : 0]
            if let style = fill.sourceStyle {
                guard style.bands.count <= 4, style.bands.allSatisfy({ $0.rgb.count == 3 }) else { return nil }
                parameters += [1, style.sourceFontPixels.bitPattern, UInt64(style.bands.count)]
                for band in style.bands { parameters += [band.width.bitPattern] + band.rgb.map(\.bitPattern) }
                if let shadow = style.shadow {
                    guard shadow.rgb.count == 3, shadow.offset.count == 2 else { return nil }
                    parameters += [1] + shadow.rgb.map(\.bitPattern) + shadow.offset.map(\.bitPattern)
                } else { parameters.append(0) }
            } else { parameters.append(0) }
            guard let digest = rasterDigest(fill.image) else { return nil }
            return Key(width: fill.image.width, height: fill.image.height,
                digest: digest, parameters: parameters,
                pendingContour: fill.sourceStyle?.pendingRoundedContour?.identity)
        }
        fileprivate func value(_ fill: NativeAOTTranslationPageComposer.TranslatedFillPrimitive,
                   compute: () throws -> Footprint) throws -> Footprint {
            guard let key = key(fill) else {
                lock.lock(); bypasses += 1; lock.unlock()
                return try compute()
            }
            lock.lock()
            sequence += 1
            if var entry = entries[key] {
                entry.lastUse = sequence; entries[key] = entry
                hits += 1; lock.unlock()
                return entry.local.translated(fill.frame.origin)
            }
            misses += 1; lock.unlock()
            let actual = try compute()
            guard actual.runs.count <= 250_000 else { return actual }
            let local = actual.translated(CGPoint(x: -fill.frame.minX, y: -fill.frame.minY))
            let charge = local.runs.count * MemoryLayout<Run>.stride + key.parameters.count * 8
                + (key.pendingContour?.utf8.count ?? 0) + key.digest.count + 128
            lock.lock(); defer { lock.unlock() }
            if entries[key] == nil, entryLimit > 0, charge <= byteLimit {
                while entries.count >= entryLimit || charge > byteLimit - bytes {
                    guard let victim = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
                    bytes -= victim.value.bytes; entries.removeValue(forKey: victim.key); evictions += 1
                }
                sequence += 1
                entries[key] = Entry(local: local, bytes: charge, lastUse: sequence); bytes += charge
            } else { bypasses += 1 }
            return actual
        }
        var audit: [String: Any] {
            lock.lock(); defer { lock.unlock() }
            return ["hits": hits, "rasterizationMisses": misses, "bypasses": bypasses, "evictions": evictions,
                "entries": entries.count, "entryLimit": entryLimit,
                "geometryAndKeyPayloadBytes": bytes, "geometryAndKeyPayloadByteLimit": byteLimit,
                "tightBoundsHits": tightBoundsHits, "tightDigestHits": tightDigestHits,
                "tightSourceEntries": cropSources.count, "croppedRasterEntries": croppedRasters.count,
                "cropWitnessEntryLimit": cropEntryLimit, "cropWitnessPayloadReserve": cropEntryLimit * Self.cropPairCharge,
                "canonicalRGBABytesRead": rgbaBytesRead, "retainedCGImages": 0,
                "weakRasterDigestEntries": rasterDigests.count, "rasterDigestIdentityHits": rasterDigestIdentityHits,
                "scope": "single request; exact local effect-alpha only; same live immutable image may reuse RGBA digest; no admission or source-policy cache",
                "accounting": "retained run/key payload; excludes dictionary overhead and transient raster/hash allocations, not process RSS"]
        }
    }
    @TaskLocal static var retainedFootprintMemo: RetainedFootprintMemo?
    static func withRetainedFootprintMemo<Value>(_ operation: () throws -> Value) rethrows -> Value {
        if ProcessInfo.processInfo.environment["AIDOKU_RETAINED_FOOTPRINT_MEMO"] == "0" {
            return try $retainedFootprintMemo.withValue(nil, operation: operation)
        }
        guard retainedFootprintMemo == nil else { return try operation() }
        return try $failureMemo.withValue(FailureMemo()) {
            try $retainedFootprintMemo.withValue(RetainedFootprintMemo(), operation: operation)
        }
    }
    enum Failure: Error {
        case invalidGeometry, footprintBudget, clippedEffects, noSafePlacement(String), finalCollision(Int, Int)
        case finalInvariant(String)
    }

    /// Tighten transparent input padding without dropping any antialias pixel.
    static func tight(_ primitive: NativeAOTTranslationPageComposer.TranslatedFillPrimitive) throws
        -> NativeAOTTranslationPageComposer.TranslatedFillPrimitive {
        func measure() throws -> CGRect {
            let bytes = try NativeMandatoryDisplayStroke.rgba(primitive.image)
            return try support(bytes, width: primitive.image.width, height: primitive.image.height).bounds
        }
        let memo = retainedFootprintMemo
        let bounds = try memo?.tightBounds(for: primitive.image, measure: measure) ?? measure()
        guard let image = primitive.image.cropping(to: bounds) else { throw Failure.invalidGeometry }
        memo?.recordTightCrop(image, from: primitive.image, bounds: bounds)
        var result = primitive
        result.image = image
        result.frame = bounds.offsetBy(dx: primitive.frame.minX, dy: primitive.frame.minY)
        return result
    }

    private static func support(_ rgba: [UInt8], width: Int, height: Int) throws -> Footprint {
        var runs: [Run] = [], bounds = CGRect.null, pixels = 0
        var inkLeft=width,inkTop=height,inkRight=0,inkBottom=0
        for y in 0..<height {
            var x = 0
            while x < width {
                if rgba[(y * width + x) * 4 + 3] == 0 { x += 1; continue }
                let left = x
                repeat {
                    if rgba[(y*width+x)*4+3]>=64 { inkLeft=min(inkLeft,x);inkRight=max(inkRight,x+1);inkTop=min(inkTop,y);inkBottom=max(inkBottom,y+1) }
                    x += 1
                } while x < width && rgba[(y * width + x) * 4 + 3] != 0
                runs.append(.init(y: y, left: left, right: x))
                pixels += x - left
                bounds = bounds.union(CGRect(x: left, y: y, width: x - left, height: 1))
            }
        }
        guard pixels > 0 else { throw NativeMandatoryDisplayStroke.Failure.emptyFill }
        return .init(runs:runs,bounds:bounds,pixels:pixels,readableBounds:inkRight>inkLeft ? CGRect(x:inkLeft,y:inkTop,width:inkRight-inkLeft,height:inkBottom-inkTop) : bounds)
    }

    private static func canvas(_ width: Int, _ height: Int, white: Bool = false) throws -> CGContext {
        guard width > 0, height > 0, width <= 8_000_000 / height,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.footprintBudget }
        if white { context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
        return context
    }

    static func footprint(layer: NativeMandatoryDisplayStroke.Prepared, style: NativeSourceStylePaint.Style?,
                          fontPixels: CGFloat, sourceStyleMemo: NativeSourceStylePaint.PlaneMemo? = nil) throws -> Footprint {
        if layer.sourceContourOnly {
            try NativeSourceStylePaint.validateSourceContourOnly(style)
            guard layer.outwardPixels == 0 else { throw Failure.invalidGeometry }
        }
        let scale = style.map { Double(fontPixels) / $0.sourceFontPixels } ?? 1
        let band = (style?.bands.reduce(0) { $0 + $1.width } ?? 0) * scale
        let padding = ceil(Double(layer.outwardPixels) + band) + 4
        guard padding.isFinite, padding <= 516 else { throw Failure.footprintBudget }
        var region = layer.frame.insetBy(dx: -padding, dy: -padding)
        if let shadow = style?.shadow {
            region = region.union(region.offsetBy(dx: shadow.offset[0] * scale, dy: shadow.offset[1] * scale))
        }
        region = region.integral
        guard region.width <= 16_384, region.height <= 16_384 else { throw Failure.footprintBudget }
        let context = try canvas(Int(region.width), Int(region.height))
        // Keep the exact production global pixel transform, including fractional shadows.
        context.translateBy(x: -region.minX, y: -(CGFloat(layer.pageHeight) - region.maxY))
        if let style {
            _ = try NativeSourceStylePaint.paint(style, fill: layer.fill, frame: layer.frame,
                fontPixels: fontPixels, mandatoryOutward: layer.outwardPixels, pageHeight: layer.pageHeight, context: context,
                memo: sourceStyleMemo)
        }
        NativeMandatoryDisplayStroke.paint([layer], in: context)
        guard let image = context.makeImage() else { throw Failure.invalidGeometry }
        let local = try support(NativeMandatoryDisplayStroke.rgba(image), width: image.width, height: image.height)
        guard local.bounds.minX > 0, local.bounds.minY > 0,
              local.bounds.maxX < region.width, local.bounds.maxY < region.height else { throw Failure.clippedEffects }
        return local.translated(region.origin)
    }

    /// Background decisions may change RGB, but cannot change retained alpha.
    /// Exact retained effect-alpha support for bounded post-shape proposals.
    /// This measures the same pixels used by the normal final admission gate.
    static func retainedFootprint(_ fill: NativeAOTTranslationPageComposer.TranslatedFillPrimitive) throws -> Footprint {
        try proposal(fill)
    }

    private static func proposal(_ fill: NativeAOTTranslationPageComposer.TranslatedFillPrimitive) throws -> Footprint {
        try fill.validateSourceContourOnly()
        if let memo = retainedFootprintMemo { return try memo.value(fill) { try uncachedProposal(fill) } }
        return try uncachedProposal(fill)
    }

    private static func uncachedProposal(_ fill: NativeAOTTranslationPageComposer.TranslatedFillPrimitive) throws -> Footprint {
        try fill.validateSourceContourOnly()
        if fill.hasFinalEffects {
            return try support(NativeMandatoryDisplayStroke.rgba(fill.image), width: fill.image.width,
                height: fill.image.height).translated(fill.frame.origin)
        }
        let style = fill.sourceStyle
        let scale = style.map { Double(fill.fontOutputPixels) / $0.sourceFontPixels } ?? 1
        let bands = (style?.bands.reduce(0) { $0 + $1.width } ?? 0) * scale
        let radius = fill.sourceContourOnly ? 0 : max(2, fill.fontOutputPixels * (fill.displayStrokeRatio ?? 0.20))
        guard Double(radius).isFinite, (Double(radius) + bands).isFinite,
              Double(radius) + bands >= 0, Double(radius) + bands <= 512 else { throw Failure.footprintBudget }
        let padding = Int(ceil(Double(radius) + bands)) + 6
        guard padding <= 518 else { throw Failure.footprintBudget }
        let width = fill.image.width + padding * 2, height = fill.image.height + padding * 2
        let white = try canvas(width, height, white: true)
        guard let background = white.makeImage() else { throw Failure.invalidGeometry }
        let local = CGRect(x: padding, y: padding, width: fill.image.width, height: fill.image.height)
        let layer = try NativeMandatoryDisplayStroke.prepare(fill: fill.image, restored: background,
            fontOutputPixels: fill.fontOutputPixels, outwardEm: fill.displayStrokeRatio ?? 0.20,
            fillFrame: local, forcedEndpoint: 0, sourceContourOnly: fill.sourceContourOnly)
        return try footprint(layer: layer, style: style, fontPixels: fill.fontOutputPixels)
            .translated(CGPoint(x: fill.frame.minX - local.minX, y: fill.frame.minY - local.minY))
    }

    static func intersects(_ a: Footprint, _ b: Footprint) -> Bool {
        guard a.bounds.intersects(b.bounds) else { return false }
        var i = 0, j = 0
        while i < a.runs.count && j < b.runs.count {
            let x = a.runs[i], y = b.runs[j]
            if x.y < y.y { i += 1 }
            else if y.y < x.y { j += 1 }
            else if x.left < y.right && y.left < x.right { return true }
            else if x.right <= y.left { i += 1 }
            else { j += 1 }
        }
        return false
    }

    /// Bounded, lazily built alpha bits for heavily backtracked searches.
    /// One zero word on either side lets unaligned rows read across a word boundary.
    struct CollisionBits {
        let minX: Int, minY: Int, width: Int, height: Int, stride: Int
        let words: [UInt64]

        init?(_ footprint: Footprint, remainingWords: inout Int) {
            let runs = footprint.runs.source
            guard remainingWords > 0, runs.count >= 32, let first = runs.first, let last = runs.last else { return nil }
            var left = first.left, right = first.right
            for run in runs { left = min(left, run.left); right = max(right, run.right) }
            guard left >= -4_000_000, right <= 4_000_000, first.y >= -4_000_000, last.y <= 4_000_000 else { return nil }
            let width = right - left, height = last.y - first.y + 1
            let stride = (width + 63) / 64 + 2
            guard width > 0, height > 0, stride <= min(32_768, remainingWords) / height else { return nil }
            var words = [UInt64](repeating: 0, count: stride * height)
            guard words.capacity <= remainingWords else { return nil }
            for run in runs {
                let low = run.left - left, high = run.right - left - 1
                let base = (run.y - first.y) * stride + 1
                let firstWord = base + (low >> 6), lastWord = base + (high >> 6)
                let lowMask = UInt64.max << (low & 63), highMask = UInt64.max >> (63 - (high & 63))
                if firstWord == lastWord {
                    words[firstWord] |= lowMask & highMask
                } else {
                    words[firstWord] |= lowMask
                    for i in (firstWord + 1)..<lastWord { words[i] = .max }
                    words[lastWord] |= highMask
                }
            }
            self.minX = left; self.minY = first.y; self.width = width; self.height = height
            self.stride = stride; self.words = words
            remainingWords -= words.capacity
        }

        func intersects(_ other: Self, dx: Int, dy: Int, otherDX: Int, otherDY: Int) -> Bool {
            let ax = minX + dx, ay = minY + dy, bx = other.minX + otherDX, by = other.minY + otherDY
            let left = max(ax, bx), right = min(ax + width, bx + other.width)
            let top = max(ay, by), bottom = min(ay + height, by + other.height)
            guard left < right, top < bottom else { return false }
            let firstWord = (left - ax) >> 6, lastWord = (right - ax - 1) >> 6
            let relative = ax + firstWord * 64 - bx
            let shift = relative & 63
            var a = (top - ay) * stride + 1 + firstWord
            var b = (top - by) * other.stride + 1 + (relative >> 6)
            for _ in top..<bottom {
                for i in 0...(lastWord - firstWord) {
                    let aligned = (other.words[b + i] >> shift) | (other.words[b + i + 1] << (64 - shift))
                    if words[a + i] & aligned != 0 { return true }
                }
                a += stride; b += other.stride
            }
            return false
        }
    }

    /// Each cell contains the DFS levels with potentially conflicting alpha or
    /// readable rectangles. Clamping both edges preserves overlap outside the page.
    final class PeerGrid {
        private let side: CGFloat
        private let columns: Int, rows: Int
        private var cells: [UInt64]
        init?(page: CGRect, count: Int) {
            guard (8...64).contains(count), page.width > 0, page.height > 0,
                  page.width <= 4_000_000, page.height <= 4_000_000 else { return nil }
            side = max(48, ceil(max(page.width, page.height) / 32))
            columns = max(1, Int(ceil(page.width / side)))
            rows = max(1, Int(ceil(page.height / side)))
            cells = [UInt64](repeating: 0, count: columns * rows)
            guard cells.capacity <= 1024 else { return nil }
        }

        private func cell(_ coordinate: CGFloat, _ count: Int) -> Int {
            Int(min(CGFloat(count - 1), max(0, floor(coordinate / side))))
        }
        private func area(_ footprint: Footprint, padding: CGFloat) -> (Int, Int, Int, Int) {
            let body = footprint.bounds.union(footprint.readableBounds ?? footprint.bounds)
            // One pixel covers subpixel rounding at cell borders. Extreme
            // values use the whole grid, keeping this rejection conservative.
            guard padding >= 0, padding <= 4_000_000, !body.isNull, body.minX >= -4_000_000, body.minY >= -4_000_000,
                  body.maxX <= 8_000_000, body.maxY <= 8_000_000 else { return (0, columns - 1, 0, rows - 1) }
            let rect = body.insetBy(dx: -(padding + 1), dy: -(padding + 1))
            guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else {
                return (0, columns - 1, 0, rows - 1)
            }
            return (cell(rect.minX, columns), cell(rect.maxX, columns), cell(rect.minY, rows), cell(rect.maxY, rows))
        }

        func toggle(_ footprint: Footprint, padding: CGFloat, level: Int) {
            let (left, right, top, bottom) = area(footprint, padding: padding)
            let bit = UInt64(1) << level
            for y in top...bottom {
                let row = y * columns
                for x in left...right { cells[row + x] ^= bit }
            }
        }

        func peers(_ footprint: Footprint, padding: CGFloat) -> UInt64 {
            let (left, right, top, bottom) = area(footprint, padding: padding)
            var mask: UInt64 = 0
            for y in top...bottom {
                let row = y * columns
                for x in left...right { mask |= cells[row + x] }
            }
            return mask
        }
    }

    private struct PeerSpacing: Equatable {
        let guide: CGRect?
        let rotated: Bool
        let font: CGFloat
        init(_ fill: NativeAOTTranslationPageComposer.TranslatedFillPrimitive, page: CGRect) {
            guide = fill.textPlacementGuide?.rect(in: page)
            rotated = abs(fill.textPlacementGuide?.sourceRotationRadians ?? 0) > 1e-6
            font = fill.fontOutputPixels
        }
    }

    private enum SpacingRule {
        case none, rotated(Int), straight(CGFloat)
    }

    private static func spacingRule(_ first: PeerSpacing, _ second: PeerSpacing) -> SpacingRule {
        guard let A = first.guide, let B = second.guide else { return .none }
        if first.rotated || second.rotated {
            // Diagonal source unions can overlap while their separate text
            // lines do not. Neither that union nor a rotated AABB certifies a
            // readable gap: measure the actual retained, fully styled alpha.
            return .rotated(min(8, max(2, Int(ceil(min(first.font, second.font) * 0.12)))))
        }
        let original=A.intersection(B)
        if !original.isNull && original.width*original.height>min(A.width*A.height,B.width*B.height)*0.05 { return .none }
        return .straight(max(1, min(first.font, second.font) * 0.12) / 2)
    }

    private static func blockConflict(_ a: Footprint, _ b: Footprint, rule: SpacingRule) -> Bool {
        switch rule {
        case .none: return false
        case let .rotated(gap): return rotatedPeerConflict(a, b, gap: gap)
        case let .straight(halfGap):
            return (a.readableBounds ?? a.bounds).insetBy(dx: -halfGap, dy: -halfGap)
                .intersects((b.readableBounds ?? b.bounds).insetBy(dx: -halfGap, dy: -halfGap))
        }
    }

    private static func rotatedPeerConflict(_ a:Footprint,_ b:Footprint,gap:Int)->Bool {
        guard a.bounds.insetBy(dx:-CGFloat(gap),dy:-CGFloat(gap)).intersects(b.bounds) else{return false}
        var first=0,work=0
        for row in a.runs {
            while first<b.runs.count && b.runs[first].y<row.y-gap {first+=1}
            var index=first
            while index<b.runs.count && b.runs[index].y<=row.y+gap {
                work+=1
                // Unknown evidence cannot authorize a tight placement.
                if work>2_000_000 {return true}
                let peer=b.runs[index]
                if row.left-gap<peer.right && peer.left<row.right+gap {return true}
                index+=1
            }
        }
        return false
    }

    /// Complete-effect page clearance; explicit zero retains the old boundary.
    private static var pageEdgeMargin: CGFloat {
        ProcessInfo.processInfo.environment["AIDOKU_FINAL_PAGE_EDGE_GUARD"] != "0" ? 1 : 0
    }

    private static func admitted(_ footprint: Footprint, page: CGRect, domain: ((CGRect) -> Bool)?,
                                 pageMargin: CGFloat? = nil) -> Bool {
        let margin = pageMargin ?? pageEdgeMargin
        guard page.insetBy(dx: margin, dy: margin).contains(footprint.bounds) else { return false }
        guard let domain else { return true }
        return footprint.runs.allSatisfy { domain(CGRect(x: $0.left, y: $0.y, width: $0.right - $0.left, height: 1)) }
    }

    static func place(_ input: [NativeAOTTranslationPageComposer.TranslatedFillPrimitive], page: CGRect,
                      cohortOrigins:[String:CGPoint]=[:],fixedOrigins:[String:CGPoint]=[:],readableBodyIDs:Set<String>=[],
                      retainedClusterAnchors:[String:CGFloat]=[:],initialBodyIsolationOverride:Bool?=nil) throws
        -> (fills: [NativeAOTTranslationPageComposer.TranslatedFillPrimitive], audit: [[String: Any]]) {
        guard input.allSatisfy({ $0.textPlacementGuide?.valid ?? true }), input.count <= 256, page.minX == 0, page.minY == 0 else { throw Failure.invalidGeometry }
        // Snapshot settings once per invocation, including all local search retries.
        // A subsequent place call still observes a fresh process environment.
        let placementEnvironment = ProcessInfo.processInfo.environment
        let placementPageMargin: CGFloat = placementEnvironment["AIDOKU_FINAL_PAGE_EDGE_GUARD"] != "0" ? 1 : 0
        let coupledBodyOrder = placementEnvironment["AIDOKU_COUPLED_BODY_ORDER"] != "0"
        let traceCohort = placementEnvironment["AIDOKU_TRACE_COHORT"] == "1"
        let tracePlacement = placementEnvironment["AIDOKU_TEXT_PLACEMENT_TRACE"] == "1"
        // Retention is a complete fixed-origin cohort contract, never a
        // per-owner escape from the normal source target or admission rules.
        if !retainedClusterAnchors.isEmpty {
            let groups=Dictionary(grouping:input.indices.filter {input[$0].sourceClusterAlignment != nil},
                by:{input[$0].sourceClusterAlignment!.groupID})
            for (group,anchor) in retainedClusterAnchors {
                guard anchor.isFinite,let members=groups[group],members.count>=2,
                      let first=members.first,let axis=input[first].sourceClusterAlignment?.axis else {
                    throw Failure.invalidGeometry
                }
                var owners=Set<String>()
                for i in members {
                    guard input[i].sourceClusterAlignment?.axis==axis,
                          let owner=input[i].ownerID,!owner.isEmpty,owners.insert(owner).inserted,
                          let origin=fixedOrigins[owner],origin.x.isFinite,origin.y.isFinite,
                          abs((axis == .top ? origin.y:origin.x)-anchor)<0.01 else {
                        throw Failure.invalidGeometry
                    }
                }
            }
        }
        var fills = try input.map(tight)
        let footprints = try fills.map(proposal)
        for i in fills.indices {
            if let policy=fills[i].textExpansionPolicy,let source=fills[i].textPlacementGuide?.rect(in:page),
               let limit=policy.sourceLineSizeLimit(source:source),
               footprints[i].bounds.width>limit.width || footprints[i].bounds.height>limit.height {
                throw Failure.noSafePlacement(fills[i].ownerID ?? "unknown")
            }
        }
        let packets=NativeBalloonPlacement.sourceNearPackets(fills.map(\.balloonPlacement),guides:fills.map(\.textPlacementGuide),
            fonts:fills.map { CGFloat($0.textExpansionPolicy?.sourceFontPixels ?? Double($0.fontOutputPixels)) },capacities:fills.map { $0.textExpansionPolicy?.allowedRectNormalized },page:page)
        for i in fills.indices {
            fills[i].balloonPlacement=packets[i]
            if let body=fills[i].balloonPlacement?.bodyID,readableBodyIDs.contains(body) {
                fills[i].balloonPlacement!.finalReadabilityGaps=true
            }
        }
        var balloonTargets = try NativeBalloonPlacement.targets(fills.map(\.balloonPlacement),
            bounds: footprints.map(\.bounds), fonts: fills.map(\.fontOutputPixels), page: page,guides:fills.map(\.textPlacementGuide))
        let availableBodyTargets = balloonTargets.map { $0 != nil }
        let inheritedRelaxed=Set(fills.filter(\.balloonTargetRelaxed).compactMap {$0.balloonPlacement?.bodyID}).subtracting(readableBodyIDs)
        for i in fills.indices where fills[i].balloonPlacement.map({inheritedRelaxed.contains($0.bodyID)}) == true {
            balloonTargets[i]=nil
        }
        let clusterTargets = try NativeSourceClusterAlignment.targets(fills.map(\.sourceClusterAlignment),
            bounds: footprints.map(\.bounds), page: page, guides: fills.map(\.textPlacementGuide),
            capacities:fills.map(\.textExpansionPolicy),retainedAnchors:retainedClusterAnchors)
        var cohortHints:[Int:CGPoint]=[:],cohorts:[String:[Int]]=[:]
        for i in fills.indices {
            guard let group=fills[i].sourceClusterAlignment,group.anchorPolicy=="source-near-final-alpha",
                  fills[i].textExpansionPolicy?.insideBalloon==false,fills[i].textPlacementGuide != nil,balloonTargets[i]==nil else {continue}
            cohorts[group.groupID,default:[]].append(i)
        }
        for members in cohorts.values where members.count>1 {
            let vertical=fills[members[0]].sourceClusterAlignment!.axis == .top
            let ordered=members.sorted {
                let a=fills[$0].textPlacementGuide!.rect(in:page),b=fills[$1].textPlacementGuide!.rect(in:page)
                return vertical ? a.midX<b.midX:a.midY<b.midY
            }
            let options=ordered.map { i -> [NativeSourceCohortPacking.Option] in
                let b=footprints[i].bounds,p=fills[i].textExpansionPolicy!
                let shift=fills[i].textPlacementGuide!.preferredShift(bounds:b,page:page)
                let cross=clusterTargets[i] ?? (vertical ? b.minY+shift.y:b.minX+shift.x)
                let extent=vertical ? b.width:b.height
                return p.exteriorPackingIntervals(crossStart:cross,crossExtent:vertical ? b.height:b.width,
                    horizontal:vertical,page:page).compactMap { interval in
                    guard interval.0+extent<=interval.1 else{return nil}
                    return .init(index:i,extent:extent,lower:interval.0,upper:interval.1-extent,
                        preferred:vertical ? b.minX+shift.x:b.minY+shift.y,unit:CGFloat(p.sourceFontPixels),cost:0)
                }
            }
            let gap=ceil(members.map {fills[$0].fontOutputPixels}.max()!*0.12)+1
            if let packed=NativeSourceCohortPacking.pack(options,gap:gap) {
                for (j,i) in ordered.enumerated() {
                    let b=footprints[i].bounds,shift=fills[i].textPlacementGuide!.preferredShift(bounds:b,page:page)
                    cohortHints[i]=vertical ? CGPoint(x:packed.origins[j]-b.minX,y:shift.y):CGPoint(x:shift.x,y:packed.origins[j]-b.minY)
                }
            }
        }
        for members in cohorts.values {
            for i in members {
                guard let id=fills[i].ownerID,let origin=cohortOrigins[id]else{continue}
                let b=footprints[i].bounds,preferred=fills[i].textPlacementGuide!.preferredShift(bounds:b,page:page)
                cohortHints[i]=fills[i].sourceClusterAlignment!.axis == .top
                    ? CGPoint(x:origin.x-b.minX,y:preferred.y):CGPoint(x:preferred.x,y:origin.y-b.minY)
            }
        }
        guard footprints.reduce(0, { $0 + $1.pixels }) <= 32_000_000 else { throw Failure.footprintBudget }
        var order = fills.indices.sorted {
            let a = balloonTargets[$0] != nil ? 2 : (fills[$0].placementDomain != nil ? 1 : 0)
            let b = balloonTargets[$1] != nil ? 2 : (fills[$1].placementDomain != nil ? 1 : 0)
            return a == b ? $0 < $1 : a > b
        }
        var placedIDs: [Int] = []
        let sourceSpacing = fills.map { PeerSpacing($0, page: page) }
        let peerRules = sourceSpacing.map { candidate in sourceSpacing.map { spacingRule($0, candidate) } }
        var placed: [Footprint] = [], shifts = [CGPoint](repeating: .zero, count: fills.count), attempts = 0
        var deepest = 0, blockedOwner = 0
        var blockedPeers: [Int] = []
        func sourceAnchorAllows(_ i:Int,_ bounds:CGRect)->Bool {
            guard balloonTargets[i]==nil,clusterTargets[i]==nil,let policy=fills[i].textExpansionPolicy else{return true}
            return policy.sourceAnchorAllows(bounds,page:page,guide:fills[i].textPlacementGuide)
        }
        // Placement revisits identical owner/offsets during backtracking. The
        // per-run mask predicate is pure for this immutable placement input.
        // Cache its exact result, preserving candidate order and branch limits.
        func nearestFirst(_ points: [CGPoint], to origin: CGPoint) -> [CGPoint] {
            points.map { point in
                (point: point, distance: pow(point.x - origin.x, 2) + pow(point.y - origin.y, 2))
            }.sorted {
                if $0.distance != $1.distance { return $0.distance < $1.distance }
                if $0.point.y != $1.point.y { return $0.point.y < $1.point.y }
                return $0.point.x < $1.point.x
            }.map(\.point)
        }
        let admissionCaching=placementEnvironment["AIDOKU_PLACEMENT_ADMISSION_CACHE"] != "0"
        var admissionCache=[[Offset:Bool]](repeating:[:],count:fills.count)
        // Logical bounds may be fractional while alpha runs have integer
        // translations. Certify the envelope of the very runs tested below.
        let domainEnvelopes = fills.indices.map { i -> CGRect? in
            let runs = footprints[i].runs
            guard fills[i].domainContainsSubrects, runs.count >= 8,
                  let first = runs.first, let last = runs.last else { return nil }
            var left = first.left, right = first.right
            for run in runs {
                left = min(left, run.left)
                right = max(right, run.right)
            }
            // One pixel of slack also encloses any rounding from output-to-
            // source scale conversion. Avoid dense mask scans on sparse art.
            let box = CGRect(x: left - 1, y: first.y - 1, width: right - left + 2, height: last.y - first.y + 3)
            return box.width * box.height <= CGFloat(footprints[i].pixels) * 4 ? box : nil
        }
        let innerPage = page.insetBy(dx: placementPageMargin, dy: placementPageMargin)
        // For a free owner only these peer-derived axis coordinates change
        // between branches. Keep at most one sorted plan per owner and
        // discard all plans when exact supplements or body targets change.
        struct CandidatePlan {
            let xs: ArraySlice<Int>, ys: ArraySlice<Int>, points: [CGPoint], ranked: Bool
        }
        var plans = [CandidatePlan?](repeating: nil, count: fills.count)
        var projected = [[CGPoint]?](repeating: nil, count: fills.count)
        let exactBudget=NativeExactAlphaOrigins.Budget()
        var exactSupplements:[Int:[CGPoint]]=[:],exactEvidence:[Int:[String:Any]]=[:]
        var exactPrepared=Set<Int>(),exactTargetState=""
        func prepareExact(_ owner:Int)throws {
            guard !exactPrepared.contains(owner) else {return}
            let members=fills.indices.filter {i in i==owner || (balloonTargets[owner] != nil && balloonTargets[i] != nil && fills[i].balloonPlacement?.bodyID==fills[owner].balloonPlacement?.bodyID)}
            exactPrepared.formUnion(members)
            var reports:[Int:NativeExactAlphaOrigins.Result]=[:]
            for i in members {
                let cluster:(NativeSourceClusterAlignment.Axis,CGFloat)?
                if let axis=fills[i].sourceClusterAlignment?.axis,let target=clusterTargets[i] {cluster=(axis,target)} else {cluster=nil}
                let body=balloonTargets[i] != nil ? fills[i].balloonPlacement?.rect(in:page):nil
                let report=try NativeExactAlphaOrigins.make(footprints[i],page:page,margin:placementPageMargin,
                    policy:fills[i].textExpansionPolicy,body:body,fixedOrigin:fixedOrigins[fills[i].ownerID ?? ""],
                    cluster:cluster,budget:exactBudget,validate:{fp in
                        sourceAnchorAllows(i,fp.bounds) && (body?.contains(fp.bounds) ?? true) &&
                            admitted(fp,page:page,domain:fills[i].placementDomain,pageMargin:placementPageMargin)
                    })
                reports[i]=report
                exactEvidence[i]=["status":report.status.rawValue,"reason":report.reason,
                    "nativeValidOrigins":report.shifts.count,"remainingWork":exactBudget.remaining,
                    "completeMaskOriginCap":256,"wholePlaceWorkCap":1_000_000]
            }
            guard reports.values.allSatisfy({$0.status == .complete}) else {return}
            if balloonTargets[owner] != nil {
                var common:Set<Offset>?
                for i in members {
                    let target=balloonTargets[i]!
                    let deltas=Set(reports[i]!.shifts.map {Offset(x:$0.x-target.x,y:$0.y-target.y)})
                    common=common.map {$0.intersection(deltas)} ?? deltas
                }
                for i in members {
                    let target=balloonTargets[i]!
                    exactSupplements[i]=(common ?? []).map {CGPoint(x:target.x+$0.x,y:target.y+$0.y)}
                    exactEvidence[i]?["rigidBodyCommonOrigins"]=common?.count ?? 0
                }
            } else {exactSupplements[owner]=reports[owner]!.shifts}
        }
        func candidateAllowed(_ i: Int, _ shift: CGPoint) -> Bool {
            let key = Offset(x: shift.x, y: shift.y)
            if admissionCaching, let allowed = admissionCache[i][key] { return allowed }
            let base = footprints[i]
            let bounds = base.bounds.offsetBy(dx: shift.x, dy: shift.y)
            var valid = sourceAnchorAllows(i, bounds) && innerPage.contains(bounds)
            if valid, let domain = fills[i].placementDomain {
                let dx = Int(shift.x), dy = Int(shift.y)
                let wholeBoxAccepted = domainEnvelopes[i].map {
                    domain($0.offsetBy(dx: CGFloat(dx), dy: CGFloat(dy)))
                } ?? false
                if !wholeBoxAccepted {
                    let runDX = base.runs.dx + dx, runDY = base.runs.dy + dy
                    valid = base.runs.source.allSatisfy { run in
                        domain(CGRect(x: run.left + runDX, y: run.y + runDY, width: run.right - run.left, height: 1))
                    }
                }
            }
            if admissionCaching { admissionCache[i][key] = valid }
            return valid
        }
        func candidates(_ i: Int, countOnly: Bool = false) -> [CGPoint] {
            let b = footprints[i].bounds
            if let owner=fills[i].ownerID,let origin=fixedOrigins[owner] {
                guard origin.x.isFinite,origin.y.isFinite else{return []}
                if let target=clusterTargets[i],let packet=fills[i].sourceClusterAlignment {
                    let actual=packet.axis == .top ? origin.y:origin.x
                    guard abs(actual-target)<0.01 else{return []}
                }
                return [CGPoint(x:origin.x-b.minX,y:origin.y-b.minY)]
            }
            if let target = balloonTargets[i], let packet = fills[i].balloonPlacement {
                if let peer = placedIDs.first(where: { fills[$0].balloonPlacement?.bodyID == packet.bodyID }),
                   let previous = balloonTargets[peer] {
                    return [CGPoint(x: target.x + shifts[peer].x - previous.x,
                                    y: target.y + shifts[peer].y - previous.y)]
                }
                let step = max(1, Int((fills[i].fontOutputPixels * 0.2).rounded()))
                var candidates: [CGPoint] = []
                for y in -4...4 { for x in -4...4 { candidates.append(CGPoint(x: target.x + CGFloat(x * step), y: target.y + CGFloat(y * step))) } }
                for point in exactSupplements[i] ?? [] where !candidates.contains(point) {candidates.append(point)}
                return nearestFirst(candidates, to: target)
            }
            let preferred = cohortHints[i] ?? fills[i].textPlacementGuide?.preferredShift(bounds: b, page: page) ?? .zero
            let margin = placementPageMargin
            var xs: Set<Int> = [Int(preferred.x), 0, Int(ceil(page.minX + margin - b.minX)), Int(floor(page.maxX - margin - b.maxX))]
            var ys: Set<Int> = [Int(preferred.y), 0, Int(ceil(page.minY + margin - b.minY)), Int(floor(page.maxY - margin - b.maxY))]
            for (peerIndex,peer) in placed.enumerated() {
                let core=peer.readableBounds ?? peer.bounds,own=footprints[i].readableBounds ?? b
                let gap=max(1,min(fills[i].fontOutputPixels,fills[placedIDs[peerIndex]].fontOutputPixels)*0.12)
                xs.insert(Int(ceil(core.maxX+gap-own.minX)));xs.insert(Int(floor(core.minX-gap-own.maxX)))
                ys.insert(Int(ceil(core.maxY+gap-own.minY)));ys.insert(Int(floor(core.minY-gap-own.maxY)))
                xs.insert(Int(ceil(peer.bounds.maxX - b.minX)))
                xs.insert(Int(floor(peer.bounds.minX - b.maxX)))
                ys.insert(Int(ceil(peer.bounds.maxY - b.minY)))
                ys.insert(Int(floor(peer.bounds.minY - b.maxY)))
            }
            let orderedX = xs.sorted { abs($0) == abs($1) ? $0 < $1 : abs($0) < abs($1) }.prefix(32)
            let orderedY = ys.sorted { abs($0) == abs($1) ? $0 < $1 : abs($0) < abs($1) }.prefix(32)
            // Feasibility ranking needs only the number of admitted candidates.
            // Opaque domains retain their original callback order.
            let rank = !countOnly || (!fills[i].domainContainsSubrects && fills[i].placementDomain != nil)
            if let plan = plans[i], plan.xs == orderedX, plan.ys == orderedY {
                if plan.ranked || !rank { return plan.points }
                let points = nearestFirst(plan.points, to: preferred)
                plans[i] = CandidatePlan(xs: orderedX, ys: orderedY, points: points, ranked: true)
                return points
            }
            var points = Set<Offset>(), result: [CGPoint] = []
            func add(_ x: Int, _ y: Int) {
                let point = CGPoint(x: x, y: y)
                if points.insert(Offset(x: point.x, y: point.y)).inserted { result.append(point) }
            }
            if let policy=fills[i].textExpansionPolicy {
                let proposals: [CGPoint]
                if let cached = projected[i] {
                    proposals = cached
                } else {
                    var desired=preferred
                    if let target=clusterTargets[i],let packet=fills[i].sourceClusterAlignment {
                        if packet.axis == .top { desired.y=target-b.minY } else { desired.x=target-b.minX }
                    }
                    proposals = policy.projectedShifts(bounds:b,page:page,preferred:desired,font:fills[i].fontOutputPixels)
                    if proposals.count <= 256 { projected[i] = proposals }
                }
                for point in proposals { add(Int(point.x),Int(point.y)) }
            }
            for x in orderedX { for y in orderedY { add(x, y) } }
            let step = max(1, Int((fills[i].fontOutputPixels * 0.25).rounded()))
            for y in -4...4 { for x in -4...4 { add(Int(preferred.x) + x * step, Int(preferred.y) + y * step) } }
            // Broad fallback remains page-independent and never changes font/text.
            for y in 0...12 { for x in 0...12 {
                add(Int((page.width - b.width) * CGFloat(x) / 12 - b.minX),
                    Int((page.height - b.height) * CGFloat(y) / 12 - b.minY))
            } }
            if let target = clusterTargets[i], let packet = fills[i].sourceClusterAlignment {
                // Preserve the free axis for collision search; lock only the
                // source-cluster axis after every centering/refit stage.
                result = result.map { point in
                    packet.axis == .top ? CGPoint(x: point.x, y: target - b.minY)
                        : CGPoint(x: target - b.minX, y: point.y)
                }
                var seen = Set<Offset>()
                result = result.filter { seen.insert(Offset(x: $0.x, y: $0.y)).inserted }
            }
            for point in exactSupplements[i] ?? [] {add(Int(point.x),Int(point.y))}
            let ranked = rank ? nearestFirst(result, to: preferred) : result
            if ranked.count <= 2048 {
                plans[i] = CandidatePlan(xs: orderedX, ys: orderedY, points: ranked, ranked: rank)
            }
            return ranked
        }
        var peerGrid: PeerGrid?
        var peerPadding: [CGFloat] = []
        var collisionBits: [CollisionBits?] = []
        func alphaConflict(_ peer: Int, _ placed: Footprint, _ owner: Int, _ candidate: Footprint) -> Bool {
            guard placed.bounds.intersects(candidate.bounds) else { return false }
            if !collisionBits.isEmpty, let a = collisionBits[peer], let b = collisionBits[owner] {
                return a.intersects(b, dx: placed.runs.dx, dy: placed.runs.dy, otherDX: candidate.runs.dx, otherDY: candidate.runs.dy)
            }
            return intersects(placed, candidate)
        }
        func solve(_ depth: Int) -> Bool {
            if depth == fills.count { return true }
            let i = order[depth]
            if depth >= deepest { deepest=depth;blockedOwner=i;blockedPeers=[] }
            var branches = 0
            for shift in candidates(i) {
                attempts += 1
                if attempts == 2048, collisionBits.isEmpty {
                    var remainingWords = 131_072
                    collisionBits = footprints.map { CollisionBits($0, remainingWords: &remainingWords) }
                    peerGrid = PeerGrid(page: page, count: fills.count)
                    if let peerGrid {
                        peerPadding = fills.map { max(8, max(1, $0.fontOutputPixels * 0.12) / 2) }
                        for j in placed.indices { peerGrid.toggle(placed[j], padding: peerPadding[placedIDs[j]], level: j) }
                    }
                }
                if attempts > 250_000 { return false }
                if balloonTargets[i] != nil, let packet = fills[i].balloonPlacement {
                    let body = packet.rect(in: page)
                    guard body.contains(footprints[i].bounds.offsetBy(dx:shift.x,dy:shift.y)) else { continue }
                }
                guard candidateAllowed(i, shift) else { continue }
                let footprint = footprints[i].translated(shift)
                let recordPeers = depth == deepest && i == blockedOwner
                var conflicted = false
                var level = 0
                var nearby = peerGrid?.peers(footprint, padding: peerPadding[i])
                while level < placed.count {
                    if let remaining = nearby {
                        if remaining == 0 { break }
                        level = remaining.trailingZeroBitCount
                        nearby = remaining & (remaining - 1)
                    }
                    let j = level, peer = placedIDs[j]
                    level += 1
                    if alphaConflict(peer, placed[j], i, footprint) || blockConflict(placed[j], footprint, rule: peerRules[i][peer]) {
                        conflicted = true
                        if recordPeers { blockedPeers.append(peer) } else { break }
                    }
                }
                if conflicted { continue }
                peerGrid?.toggle(footprint, padding: peerPadding[i], level: depth)
                placed.append(footprint); placedIDs.append(i); shifts[i] = shift
                if solve(depth + 1) { return true }
                peerGrid?.toggle(footprint, padding: peerPadding[i], level: depth)
                placed.removeLast(); placedIDs.removeLast(); shifts[i] = .zero; branches += 1
                if branches >= (fills[i].placementDomain != nil ? 64 : 24) { break }
            }
            return false
        }
        func prioritizeConstrainedOwners() throws {
            plans = .init(repeating: nil, count: fills.count)
            if NativeExactAlphaOrigins.enabled {
                let state=balloonTargets.map {String(describing:$0)}.joined(separator:"|")
                if state != exactTargetState {exactSupplements=[:];exactPrepared=[];exactTargetState=state}
            }
            func feasibleCount(_ i: Int) -> Int {
                candidates(i, countOnly: true).reduce(into: 0) { count, point in
                    if candidateAllowed(i, point) { count += 1 }
                }
            }
            var feasible = Dictionary(uniqueKeysWithValues: fills.indices.map { ($0, feasibleCount($0)) })
            if NativeExactAlphaOrigins.enabled {
                let previouslyPrepared = exactPrepared
                for i in fills.indices where feasible[i]==0 {try prepareExact(i)}
                for i in exactPrepared.subtracting(previouslyPrepared) where exactSupplements[i]?.isEmpty == false {
                    plans[i] = nil
                    feasible[i] = feasibleCount(i)
                }
            }
            order.sort {
                let a=feasible[$0]!,b=feasible[$1]!
                return a == b ? (footprints[$0].pixels == footprints[$1].pixels ? $0 < $1 : footprints[$0].pixels > footprints[$1].pixels) : a < b
            }
            if coupledBodyOrder {
                // One body's members share an offset. Resolve them together:
                // otherwise unrelated owners multiply branches before a later
                // forced member can reject the same impossible body offset.
                let ranked=order
                var grouped:[Int]=[],seen=Set<Int>()
                for i in ranked where !seen.contains(i) {
                    grouped.append(i);seen.insert(i)
                    guard balloonTargets[i] != nil,let body=fills[i].balloonPlacement?.bodyID else{continue}
                    for peer in ranked where !seen.contains(peer) && balloonTargets[peer] != nil &&
                        fills[peer].balloonPlacement?.bodyID==body {
                        grouped.append(peer);seen.insert(peer)
                    }
                }
                order=grouped
            }
        }
        try prioritizeConstrainedOwners()
        func initialSearch() -> Bool {
            // Source/body locks, variable supplements and unconstrained custom
            // predicates use the normal search. The ranking pass above has
            // already recomputed current order and owner-local proposals.
            guard let memo = failureMemo, admissionCaching, !tracePlacement, !traceCohort,
                  !fills.isEmpty, fixedOrigins.isEmpty, cohortHints.isEmpty,
                  balloonTargets.allSatisfy({ $0 == nil }), clusterTargets.allSatisfy({ $0 == nil }),
                  exactSupplements.values.allSatisfy(\.isEmpty),
                  fills.indices.allSatisfy({ fills[$0].domainContainsSubrects &&
                      (fills[$0].textExpansionPolicy == nil || projected[$0] != nil) }),
                  footprints.reduce(0, { $0 + $1.runs.count }) <= 160_000 else { return solve(0) }

            func geometry(_ i: Int) -> OwnerSearchGeometry {
                let fp = footprints[i]
                return OwnerSearchGeometry(bounds: fp.bounds, readableBounds: fp.readableBounds, pixels: fp.pixels,
                    spacing: sourceSpacing[i], preferred: fills[i].textPlacementGuide?.preferredShift(bounds: fp.bounds, page: page) ?? .zero,
                    hasDomain: fills[i].placementDomain != nil, projected: projected[i])
            }
            // A cheap index avoids scanning all runs on easy searches. Hits
            // still compare every row and reproduce all visited domain answers.
            var hash = Hasher()
            var prefixes: [Int] = []
            prefixes.reserveCapacity(order.count)
            for i in order {
                let fp = footprints[i]
                hash.combine(i)
                hash.combine(fp.pixels)
                hash.combine(fp.bounds.origin.x)
                hash.combine(fp.bounds.origin.y)
                hash.combine(fp.runs.count)
                if let mid = fp.runs.isEmpty ? nil : fp.runs[fp.runs.count / 2] {
                    hash.combine(mid.y); hash.combine(mid.left); hash.combine(mid.right)
                }
                let prefix = hash
                prefixes.append(prefix.finalize())
            }
            // Before a failed DFS returns, it can only inspect an owner up to
            // its deepest visited level and peers placed at earlier levels.
            if let old = memo.find(prefixes), old.page == page, old.margin == placementPageMargin,
               order.starts(with: old.order) {
                var runStart = 0, answerStart = 0
                let matches = old.order.indices.allSatisfy { level in
                    let i = old.order[level], saved = old.owners[level]
                    defer { runStart = saved.runEnd; answerStart = saved.answerEnd }
                    return saved.geometry == geometry(i) && saved.runEnd - runStart == footprints[i].runs.count &&
                        zip(old.runs[runStart..<saved.runEnd], footprints[i].runs).allSatisfy { $0.matches($1) } &&
                        old.answers[answerStart..<saved.answerEnd].allSatisfy { answer in
                            let shift = CGPoint(x: Int(answer.x), y: Int(answer.y))
                            return candidateAllowed(i, shift) == answer.valid
                        }
                }
                if matches {
                    attempts = old.attempts
                    deepest = old.deepest
                    blockedOwner = old.blockedOwner
                    blockedPeers = old.blockedPeers
                    return false
                }
            }
            let solved = solve(0)
            guard !solved, attempts > 16_000 else { return solved }
            let visited = Array(order.prefix(deepest + 1))
            let answerCount = visited.reduce(0) { $0 + admissionCache[$1].count }
            if answerCount <= 60_000 {
                var owners: [SavedOwner] = [], runs: [SavedRun] = [], answers: [SavedAnswer] = []
                runs.reserveCapacity(visited.reduce(0) { $0 + footprints[$1].runs.count })
                answers.reserveCapacity(answerCount)
                owners.reserveCapacity(visited.count)
                for i in visited {
                    for row in footprints[i].runs {
                        guard let saved = SavedRun(row) else { return false }
                        runs.append(saved)
                    }
                    for (shift, valid) in admissionCache[i] {
                        guard let saved = SavedAnswer(shift, valid: valid) else { return false }
                        answers.append(saved)
                    }
                    owners.append(SavedOwner(geometry: geometry(i), runEnd: runs.count, answerEnd: answers.count))
                }
                memo.store(FailedSearch(page: page, margin: placementPageMargin, order: visited, owners: owners,
                    runs: runs, answers: answers, attempts: attempts, deepest: deepest, blockedOwner: blockedOwner,
                    blockedPeers: Array(Set(blockedPeers)).sorted()), fingerprint: prefixes[deepest])
            }
            return solved
        }
        var solved=initialSearch()
        var relaxedBodies=inheritedRelaxed
        var relaxationReasons=Dictionary(uniqueKeysWithValues:inheritedRelaxed.map {($0,"inherited-relaxation")})
        let finalBodyPolicy = !readableBodyIDs.isEmpty || fills.contains {$0.balloonPlacement?.finalReadabilityGaps == true}
        let isolateInitialBodies=initialBodyIsolationOverride ?? (placementEnvironment["AIDOKU_LOCAL_INITIAL_BODY_FALLBACK"] != "0")
        var initialLocalRelaxations=0
        while !solved && (finalBodyPolicy || isolateInitialBodies) {
            // Initial shaping has a bounded retry budget. Larger/unattributed
            // failures retain the complete legacy glyph-preserving fallback.
            guard finalBodyPolicy || initialLocalRelaxations<8 else{break}
            // A failed body must not erase other bodies' successful source
            // alignment/gutters. Relax only a body implicated by this search.
            let implicated=[blockedOwner]+Array(Set(blockedPeers)).sorted()
            guard let failed=implicated.first(where:{balloonTargets[$0] != nil && fills[$0].placementDomain != nil &&
                fills[$0].balloonPlacement != nil}),let body=fills[failed].balloonPlacement?.bodyID,
                relaxedBodies.insert(body).inserted else{break}
            relaxationReasons[body]=finalBodyPolicy ? "final-local-domain-peer":"initial-local-domain-peer"
            if !finalBodyPolicy {initialLocalRelaxations+=1}
            if traceCohort {
                fputs("body-target-local-fallback \(body) owner=\(fills[failed].ownerID ?? "?")\n",stderr)
            }
            for i in fills.indices where fills[i].balloonPlacement?.bodyID==body {
                balloonTargets[i]=nil
                // Only this owner's source-anchor predicate changed. The
                // mask admission results of peers stay cached.
                admissionCache[i]=[:]
            }
            attempts=0;deepest=0;blockedPeers=[]
            try prioritizeConstrainedOwners()
            solved=solve(0)
        }
        if !solved && !finalBodyPolicy && fills.contains(where:{$0.placementDomain != nil && $0.balloonPlacement != nil}) {
            // Do not lose glyphs when a blocker cannot be attributed, or when
            // bounded local retries cannot find the legacy-safe placement.
            for body in fills.compactMap(\.balloonPlacement?.bodyID) {
                if !relaxedBodies.contains(body) {relaxationReasons[body]="initial-global-compatibility-fallback"}
                relaxedBodies.insert(body)
            }
            balloonTargets=[CGPoint?](repeating:nil,count:fills.count);attempts=0;deepest=0;blockedPeers=[]
            admissionCache=Array(repeating:[:],count:fills.count)
            try prioritizeConstrainedOwners();solved=solve(0)
        }
        guard solved else {
            if tracePlacement {
                fputs("attempts=\(attempts) deepest=\(deepest) blocked=\(fills[blockedOwner].ownerID ?? "?") peers=\(blockedPeers.map { fills[$0].ownerID ?? "?" })\n",stderr)
                let diagnostics = fills.indices.map { i -> [String: Any] in
                    let b=footprints[i].bounds
                    return ["owner":fills[i].ownerID ?? "?","font":fills[i].fontOutputPixels,
                        "bounds":[b.minX,b.minY,b.width,b.height],
                        "validCandidates":candidates(i).filter { admitted(footprints[i].translated($0),page:page,domain:fills[i].placementDomain,pageMargin:placementPageMargin) }.count,
                        "sourceCluster":fills[i].sourceClusterAlignment?.groupID as Any? ?? NSNull()]
                }
                let possible=fills.indices.map { i in candidates(i).map { footprints[i].translated($0) }.filter { admitted($0,page:page,domain:fills[i].placementDomain,pageMargin:placementPageMargin) } }
                var incompatible:[[String]]=[]
                for i in fills.indices { for j in fills.indices where j > i {
                    if !possible[i].contains(where: { a in possible[j].contains(where: { !intersects(a,$0) }) }) {
                        incompatible.append([fills[i].ownerID ?? "?",fills[j].ownerID ?? "?"])
                    }
                } }
                if let data=try? JSONSerialization.data(withJSONObject:incompatible),let line=String(data:data,encoding:.utf8) { fputs("incompatible-pairs "+line+"\n",stderr) }
                if let data=try? JSONSerialization.data(withJSONObject:diagnostics),let line=String(data:data,encoding:.utf8) { fputs(line+"\n",stderr) }
            }
            throw Failure.noSafePlacement(([blockedOwner] + Array(Set(blockedPeers))).sorted().map { input[$0].ownerID ?? "unknown" }.joined(separator: ","))
        }
        if traceCohort {
            for i in fills.indices where fills[i].balloonPlacement != nil {
                fputs("body-gutter-admitted \(fills[i].ownerID ?? "?") target=\(String(describing:balloonTargets[i])) shift=\(shifts[i]) fixed=\(String(describing:fixedOrigins[fills[i].ownerID ?? ""]))\n",stderr)
            }
        }
        var output = fills
        for i in output.indices {
            output[i].frame = output[i].frame.offsetBy(dx: shifts[i].x, dy: shifts[i].y)
            output[i].balloonTargetRelaxed=output[i].balloonPlacement.map {relaxedBodies.contains($0.bodyID)} ?? false
        }
        var result:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]])=(fills:output,audit:output.indices.map { i in
            var row = ["owner": output[i].ownerID ?? String(i), "shiftOutputPixels": [shifts[i].x, shifts[i].y],
             "paintedPixels": footprints[i].pixels, "effectsIncluded": true, "fontChanged": false,
             "sourceAnchorApplied": output[i].textPlacementGuide != nil && balloonTargets[i] == nil,
             "sourceCohortPackingHintUsed":cohortHints[i] != nil,
             "sourceAnchorCorrectionPixels": output[i].textPlacementGuide.map { guide -> [CGFloat] in
                let preferred = guide.preferredShift(bounds: footprints[i].bounds, page: page)
                return [shifts[i].x - preferred.x, shifts[i].y - preferred.y]
             } as Any? ?? NSNull(),
             "balloonCrossAlignment": output[i].balloonPlacement?.crossAlignment?.rawValue as Any? ?? NSNull(),
             "balloonBodyID": output[i].balloonPlacement?.bodyID as Any? ?? NSNull(),
             "balloonBodyPlaced": balloonTargets[i] != nil,
             "sourceParagraphOffsetsPreserved": output[i].balloonPlacement?.preserveSourceOffsets == true,
             "effectiveBalloonRectNormalized":output[i].balloonPlacement?.rectNormalized as Any? ?? NSNull(),
             "readableBoundsOutputPixels":[(footprints[i].readableBounds ?? footprints[i].bounds).minX+shifts[i].x,
                (footprints[i].readableBounds ?? footprints[i].bounds).minY+shifts[i].y,
                (footprints[i].readableBounds ?? footprints[i].bounds).width,(footprints[i].readableBounds ?? footprints[i].bounds).height],
             "balloonCapacityFallback": output[i].balloonPlacement != nil && balloonTargets[i] == nil,
             "balloonTargetRelaxed": output[i].balloonTargetRelaxed,
             "balloonTargetFallbackReason": output[i].balloonPlacement.map { packet in
                balloonTargets[i] != nil ? "none":(relaxationReasons[packet.bodyID] ??
                    (availableBodyTargets[i] ? "search-target-unavailable":"body-target-unavailable-before-search"))
             } as Any? ?? NSNull(),
             "initialLocalBodyRelaxations": initialLocalRelaxations,
             "sourceClusterID": output[i].sourceClusterAlignment?.groupID as Any? ?? NSNull(),
             "sourceClusterAxis": output[i].sourceClusterAlignment?.axis.rawValue as Any? ?? NSNull(),
             "sourceClusterAnchorOutputPixels": clusterTargets[i].map { Double($0) as Any } ?? NSNull(),
             "finalFootprintOutputPixels": [footprints[i].bounds.minX + shifts[i].x,
                footprints[i].bounds.minY + shifts[i].y, footprints[i].bounds.width, footprints[i].bounds.height],
             "pageContained": true, "domainAvailable": output[i].placementDomain != nil,
             "domainContained": output[i].placementDomain != nil, "peerAlphaCollisions": 0,"peerReadableBlockConflicts":0] as [String: Any]
            if let evidence=exactEvidence[i] {row["exactAlphaCandidateEvidence"]=evidence}
            // Exact effective packet after sourceNear/final-readability policy;
            // input packet remains distinct from any authenticated raw request.
            let stateOwner = output[i].ownerID ?? String(i)
            let stateMembers = output[i].balloonPlacement.map { packet in
                output.indices.filter { output[$0].balloonPlacement?.bodyID == packet.bodyID }
                    .map { output[$0].ownerID ?? String($0) }
            } ?? [stateOwner]
            do {
                let state = try NativeBalloonPlacement.RetainedState.capture(owner:stateOwner,
                    inputPacket:input[i].balloonPlacement,effectivePacket:output[i].balloonPlacement,
                    groupOwners:stateMembers,relaxed:output[i].balloonTargetRelaxed,
                    targetPlaced:balloonTargets[i] != nil,fallbackReason:row["balloonTargetFallbackReason"] as? String)
                row[NativeBalloonPlacement.RetainedState.auditKey] = try NativeBalloonPlacement.RetainedState.encode(state)
            } catch {
                // State failure is explicit; never change admitted geometry or
                // manufacture a certain packet for malformed legacy carriers.
                row["retainedBalloonStateCaptureStatus"] = "unavailable-invalid-state"
            }
            if let group=output[i].sourceClusterAlignment?.groupID,retainedClusterAnchors[group] != nil {
                row["retainedSourceClusterAnchorApplied"]=true
            }
            return row
        })
        // Soft target retention is not itself a quality score. Compare with
        // the complete legacy-safe placement before accepting newly held
        // initial targets. Fixed-origin replay already fixes the same geometry.
        let completelyFixed=output.allSatisfy { fill in fill.ownerID.map {fixedOrigins[$0] != nil} ?? false }
        if !finalBodyPolicy,isolateInitialBodies,initialLocalRelaxations>0,!completelyFixed {
            if let legacy=try? place(input,page:page,cohortOrigins:cohortOrigins,fixedOrigins:fixedOrigins,
                readableBodyIDs:readableBodyIDs,retainedClusterAnchors:retainedClusterAnchors,initialBodyIsolationOverride:false),
               legacy.fills.count==output.count,let legacySupports=try? legacy.fills.map({try proposal($0)}) {
                var oldReadable:[CGRect]=[],newReadable:[CGRect]=[]
                var sourceNonGrowing=true,boundedGrowth=true,compared=0
                for i in output.indices {
                    let before=legacySupports[i],after=footprints[i].translated(shifts[i])
                    oldReadable.append(before.readableBounds ?? before.bounds)
                    newReadable.append(after.readableBounds ?? after.bounds)
                    guard let guide=output[i].textPlacementGuide else{continue}
                    compared+=1
                    let source=guide.rect(in:page),font=max(1,output[i].fontOutputPixels)
                    let a=hypot(before.bounds.midX-source.midX,before.bounds.midY-source.midY)/font
                    let b=hypot(after.bounds.midX-source.midX,after.bounds.midY-source.midY)/font
                    let first=guide.preferredShift(bounds:before.bounds,page:page)
                    let second=guide.preferredShift(bounds:after.bounds,page:page)
                    let oldAnchor=hypot(first.x,first.y)/font,newAnchor=hypot(second.x,second.y)/font
                    sourceNonGrowing = sourceNonGrowing && b<=a+1e-9 && newAnchor<=oldAnchor+1e-9
                    boundedGrowth = boundedGrowth && b<=a+0.35 && newAnchor<=oldAnchor+0.35
                }
                var gapsPreserved=true,readabilityImproved=false
                for i in output.indices {for j in output.indices where j>i {
                    let desired=min(output[i].fontOutputPixels,output[j].fontOutputPixels)*0.35
                    let old=NativeAdaptiveTextGutter.clearance(oldReadable[i],oldReadable[j]) ?? desired
                    let new=NativeAdaptiveTextGutter.clearance(newReadable[i],newReadable[j]) ?? desired
                    if new+0.01<min(old,desired){gapsPreserved=false}
                    if let body=output[i].balloonPlacement?.bodyID,output[j].balloonPlacement?.bodyID==body,
                       old+0.01<desired,new+0.01>=desired{readabilityImproved=true}
                }}
                let accepted=gapsPreserved && (sourceNonGrowing || (boundedGrowth && readabilityImproved))
                let status=accepted ? (compared==0 ? "unmeasured-source-body-policy-retained":
                    (sourceNonGrowing ? "source-nongrowing":"bounded-readable-gap-improvement")):
                    "legacy-retained-source-or-gap-regression"
                if !accepted{result=legacy}
                for i in result.audit.indices {
                    result.audit[i]["initialBodySourceGuard"]=status
                    result.audit[i]["initialBodySourceGuardComparedOwners"]=compared
                    result.audit[i]["initialBodySourceGuardGapsPreserved"]=gapsPreserved
                    result.audit[i]["initialBodySourceGuardReadableGapImproved"]=readabilityImproved
                }
            } else {
                for i in result.audit.indices{result.audit[i]["initialBodySourceGuard"]="legacy-probe-unavailable-local-safe-retained"}
            }
        }
        return result
    }

    private static func auditRect(_ row:[String:Any],_ key:String)->CGRect? {
        guard let values=row[key]as?[Any]else{return nil}
        let v=values.compactMap {($0 as?NSNumber)?.doubleValue}
        guard v.count==4,v.allSatisfy(\.isFinite),v[2]>0,v[3]>0 else{return nil}
        return CGRect(x:v[0],y:v[1],width:v[2],height:v[3])
    }

    static func refineFinalPlacement(_ input:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]),
                                     page:CGRect)->(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]) {
        var current=input
        if ProcessInfo.processInfo.environment["AIDOKU_FINAL_BODY_TARGETS"] != "0" {current=refineBodyTargets(current,page:page)}
        if ProcessInfo.processInfo.environment["AIDOKU_ADAPTIVE_GUTTER"] != "0" {current=refineGutters(current,page:page)}
        if ProcessInfo.processInfo.environment["AIDOKU_BODY_INK_SEPARATION"] != "0" {current=refineBodyInkSeparation(current,page:page)}
        if ProcessInfo.processInfo.environment["AIDOKU_CONTOUR_CLEARANCE"] != "0" {current=refineContourClearance(current,page:page)}
        if ProcessInfo.processInfo.environment["AIDOKU_INK_CONTOUR_CLEARANCE"] != "0" {current=refineContourClearance(current,page:page,inkAware:true)}
        if ProcessInfo.processInfo.environment["AIDOKU_PAGE_EDGE_MARGIN"] != "0" {current=refinePageEdgeMargins(current,page:page)}
        return current
    }

    /// An intact tight alpha bbox can still read as clipped when its outline
    /// touches the physical page edge. Add a small margin after shaping, never
    /// shrink/reflow text. Move only in the unconstrained cohort direction;
    /// shared start axes and balloon-body relationships move together.
    private static func refinePageEdgeMargins(_ input:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]),
                                              page:CGRect)->(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]) {
        guard input.fills.count==input.audit.count else{return input}
        var current=input
        for horizontal in [true,false] {
            var parent=Array(current.fills.indices)
            func root(_ i:Int)->Int {var j=i;while parent[j] != j {j=parent[j]};return j}
            func join(_ a:Int,_ b:Int) {parent[root(b)]=root(a)}
            for i in current.fills.indices {for j in current.fills.indices where j<i {
                let a=current.fills[i],b=current.fills[j]
                let sameBody=a.balloonPlacement.map {p in b.balloonPlacement?.bodyID==p.bodyID} ?? false
                let sameAxis=a.sourceClusterAlignment.map {p in
                    b.sourceClusterAlignment?.groupID==p.groupID &&
                        (horizontal ? p.axis == .left:p.axis == .top)
                } ?? false
                if sameBody || sameAxis {join(i,j)}
            }}
            let groups=Dictionary(grouping:current.fills.indices,by:{root($0)})
            for key in groups.keys.sorted() {
                let members=groups[key]!,minimumFont=members.map {current.fills[$0].fontOutputPixels}.min()!
                let rects=members.compactMap {auditRect(current.audit[$0],"finalFootprintOutputPixels")}
                guard rects.count==members.count else{continue}
                let low=rects.map {horizontal ? $0.minX:$0.minY}.min()!
                let high=rects.map {horizontal ? $0.maxX:$0.maxY}.max()!
                let pageLow=horizontal ? page.minX:page.minY,pageHigh=horizontal ? page.maxX:page.maxY
                let margin=min(12,max(2,ceil(minimumFont*0.12)))
                // The mandatory one-pixel admission guard can already separate
                // effects from the edge. Polish any remaining margin deficit,
                // rather than requiring literal contact with that edge.
                guard low<pageLow+margin-0.01 || high>pageHigh-margin+0.01 else{continue}
                let lower=ceil(pageLow+margin-low),upper=floor(pageHigh-margin-high)
                guard lower<=upper else{continue}
                let delta=min(upper,max(lower,0))
                guard delta != 0,abs(delta)<=ceil(minimumFont*0.25)else{continue}
                var fixed:[String:CGPoint]=[:]
                for i in current.fills.indices {
                    guard let id=current.fills[i].ownerID,let rect=auditRect(current.audit[i],"finalFootprintOutputPixels")else{continue}
                    fixed[id]=rect.origin
                }
                guard fixed.count==current.fills.count else{continue}
                for i in members {
                    let id=current.fills[i].ownerID!
                    fixed[id]!.x += horizontal ? delta:0
                    fixed[id]!.y += horizontal ? 0:delta
                }
                // Only a failed isolated attempt can enter the optional joint path.
                // Keep the legacy success path (including its tolerance) unchanged.
                func retryPeers(_ failure:String) {
                    guard ProcessInfo.processInfo.environment["AIDOKU_PAGE_EDGE_PEER_PACKING"] != "0",
                          members.count==1,
                          let joint=pageEdgePeerPacking(current,page:page,seed:members[0],horizontal:horizontal,
                              delta:delta,margin:margin,isolatedFailure:failure) else{return}
                    current=joint
                }
                guard var candidate=try? place(current.fills,page:page,fixedOrigins:fixed)else{
                    retryPeers("admission");continue
                }
                var safe=true
                for i in current.fills.indices {
                    guard let before=auditRect(current.audit[i],"finalFootprintOutputPixels"),
                          let after=auditRect(candidate.audit[i],"finalFootprintOutputPixels"),
                          before.size==after.size,after.origin==fixed[current.fills[i].ownerID!],
                          current.audit[i]["paintedPixels"]as?Int==candidate.audit[i]["paintedPixels"]as?Int else{safe=false;break}
                }
                if !safe {retryPeers("isolated-final-geometry");continue}
                for i in members {for j in current.fills.indices where !members.contains(j) {
                    guard let a=auditRect(current.audit[i],"readableBoundsOutputPixels"),
                          let b=auditRect(candidate.audit[i],"readableBoundsOutputPixels"),
                          let peer=auditRect(current.audit[j],"readableBoundsOutputPixels")else{safe=false;break}
                    let desired=min(current.fills[i].fontOutputPixels,current.fills[j].fontOutputPixels)*0.35
                    let prior=NativeAdaptiveTextGutter.clearance(a,peer) ?? desired
                    if let next=NativeAdaptiveTextGutter.clearance(b,peer),next+0.01<min(prior,desired) {safe=false;break}
                }}
                guard safe else{retryPeers("readable-gutter");continue}
                for i in candidate.audit.indices {
                    var row=current.audit[i];row.merge(candidate.audit[i]){_,new in new};candidate.audit[i]=row
                    if members.contains(i) {
                        candidate.audit[i]["pageEdgeMarginRefined"]=true
                        candidate.audit[i]["pageEdgeMarginPixels"]=margin
                        candidate.audit[i][horizontal ? "pageEdgeShiftXPixels":"pageEdgeShiftYPixels"]=delta
                    }
                }
                current=candidate
            }
        }
        return current
    }

    /// One proposal and at most one full admission. Failure retains the complete
    /// input tuple; diagnostics go to stderr so rejected audits cannot leak in.
    private static func pageEdgePeerPacking(
        _ input:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]),
        page:CGRect,seed:Int,horizontal:Bool,delta:CGFloat,margin:CGFloat,isolatedFailure:String
    )->(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]])? {
        let anchor=input.fills[seed]
        guard anchor.textExpansionPolicy?.insideBalloon==false,anchor.balloonPlacement==nil,
              let cohort=anchor.sourceClusterAlignment,cohort.anchorPolicy=="source-near-final-alpha",
              cohort.axis == (horizontal ? .top:.left),anchor.textPlacementGuide != nil else{return nil}
        var owners:[NativePageEdgePeerPacking.Owner]=[],fixed:[String:CGPoint]=[:]
        for i in input.fills.indices {
            let fill=input.fills[i]
            guard let id=fill.ownerID,!id.isEmpty,fixed[id]==nil,
                  let alpha=auditRect(input.audit[i],"finalFootprintOutputPixels"),
                  let readable=auditRect(input.audit[i],"readableBoundsOutputPixels") else{return nil}
            let capacity:CGRect
            if let policy=fill.textExpansionPolicy {
                guard NativeTextExpansionPolicy.validRect(policy.allowedRectNormalized) else{return nil}
                capacity=NativeTextExpansionPolicy.rect(policy.allowedRectNormalized,page:page)
            } else {capacity=page}
            let packet=fill.sourceClusterAlignment
            let eligible=fill.textExpansionPolicy?.insideBalloon==false && fill.balloonPlacement==nil &&
                packet?.groupID==cohort.groupID && packet?.axis==cohort.axis &&
                packet?.anchorPolicy=="source-near-final-alpha" && fill.textPlacementGuide != nil
            owners.append(.init(id:id,alpha:alpha,readable:readable,capacity:capacity,font:fill.fontOutputPixels,
                cohort:packet?.groupID,axis:packet?.axis,eligibility:eligible ? .exterior:.fixed))
            fixed[id]=alpha.origin
        }
        var diagnostic:[String:Any]=["feature":"AIDOKU_PAGE_EDGE_PEER_PACKING","enabled":true,"defaultEnabled":true,
            "seed":owners[seed].id,"axis":horizontal ? "x":"y","isolatedFailure":isolatedFailure,
            "helperAttempts":1,"admissionAttempts":0,"maxHelperAttempts":1,"maxAdmissionAttempts":1,
            "ownerCount":owners.count,"peerSearchLimitPixels":256,"peerCandidateLimit":257,
            "seedDeltaPixels":delta,"requestedMarginPixels":margin,"quarterFontFraction":0.25]
        func record(_ result:String) {
            diagnostic["result"]=result
            if let data=try? JSONSerialization.data(withJSONObject:diagnostic,options:[.sortedKeys]),
               let line=String(data:data,encoding:.utf8) {fputs("page-edge-peer-packing "+line+"\n",stderr)}
        }
        guard let proposed=NativePageEdgePeerPacking.origins(owners,page:page,seed:owners[seed].id,delta:delta) else {
            record("no-joint-proposal");return nil
        }
        fixed.merge(proposed){_,new in new}
        diagnostic["movedOwnerDeltasPixels"]=Dictionary(uniqueKeysWithValues:owners.compactMap { owner in
            proposed[owner.id].map { (owner.id,[$0.x-owner.alpha.minX,$0.y-owner.alpha.minY]) }
        })
        diagnostic["admissionAttempts"]=1
        // Do not replace/wrap any placementDomain: place sees every original
        // protected/exclusion predicate, cluster target and peer admission rule.
        guard var candidate=try? place(input.fills,page:page,fixedOrigins:fixed),
              candidate.fills.count==input.fills.count,candidate.audit.count==input.audit.count else {
            record("joint-admission-rejected");return nil
        }
        var afterAlpha:[CGRect]=[],afterReadable:[CGRect]=[]
        for i in input.fills.indices {
            let old=input.fills[i],new=candidate.fills[i],owner=owners[i]
            guard let alpha=auditRect(candidate.audit[i],"finalFootprintOutputPixels"),
                  let readable=auditRect(candidate.audit[i],"readableBoundsOutputPixels"),
                  alpha.origin==fixed[owner.id],alpha.size==owner.alpha.size,
                  let oldPixels=input.audit[i]["paintedPixels"]as?Int,
                  let newPixels=candidate.audit[i]["paintedPixels"]as?Int,oldPixels==newPixels,
                  old.image.width==new.image.width,old.image.height==new.image.height,
                  old.fontOutputPixels==new.fontOutputPixels,old.ownerID==new.ownerID,
                  old.balloonPlacement==new.balloonPlacement,old.balloonTargetRelaxed==new.balloonTargetRelaxed else {
                record("final-raster-or-origin-rejected");return nil
            }
            let dx=alpha.minX-owner.alpha.minX,dy=alpha.minY-owner.alpha.minY
            let shift=horizontal ? dx:dy
            guard (horizontal ? dy==0:dx==0),abs(shift)<=owner.font*0.25,
                  readable==owner.readable.offsetBy(dx:dx,dy:dy),
                  new.frame==old.frame.offsetBy(dx:dx,dy:dy),
                  shift==0 || (owner.eligibility == .exterior && owner.cohort==cohort.groupID &&
                    owner.axis==cohort.axis && owner.capacity.contains(alpha)) else {
                record("final-motion-rejected");return nil
            }
            // Recheck the actual policy as well as the unchanged production
            // placementDomain. Capacity boxes alone never certify alpha runs.
            guard let footprint=try? proposal(new),footprint.bounds==alpha,footprint.pixels==newPixels,
                  admitted(footprint,page:page,domain:old.placementDomain),
                  old.textExpansionPolicy.map({policy in footprint.runs.allSatisfy {
                      policy.allows(CGRect(x:$0.left,y:$0.y,width:$0.right-$0.left,height:1),page:page)
                  }}) ?? true else {record("final-domain-rejected");return nil}
            afterAlpha.append(alpha);afterReadable.append(readable)
        }
        for i in owners.indices {for j in owners.indices where j>i {
            if owners[i].cohort==cohort.groupID && owners[j].cohort==cohort.groupID {
                let prior=horizontal ? owners[i].alpha.minX-owners[j].alpha.minX:owners[i].alpha.minY-owners[j].alpha.minY
                let next=horizontal ? afterAlpha[i].minX-afterAlpha[j].minX:afterAlpha[i].minY-afterAlpha[j].minY
                guard (prior<0 && next<0) || (prior>0 && next>0) || (prior==0 && next==0) else {
                    record("final-source-order-rejected");return nil
                }
            }
            guard proposed[owners[i].id] != nil || proposed[owners[j].id] != nil else{continue}
            let desired=min(owners[i].font,owners[j].font)*0.35
            let prior=NativeAdaptiveTextGutter.clearance(owners[i].readable,owners[j].readable) ?? desired
            if let next=NativeAdaptiveTextGutter.clearance(afterReadable[i],afterReadable[j]),next<min(prior,desired) {
                record("final-readable-gutter-rejected");return nil
            }
        }}
        diagnostic["result"]="accepted"
        for i in candidate.audit.indices {
            var row=input.audit[i];row.merge(candidate.audit[i]){_,new in new};candidate.audit[i]=row
            candidate.audit[i]["pageEdgePeerPackingAudit"]=diagnostic
            if let origin=proposed[owners[i].id] {
                candidate.audit[i]["pageEdgePeerPackingRefined"]=true
                candidate.audit[i]["pageEdgePeerPackingDeltaPixels"]=[origin.x-owners[i].alpha.minX,origin.y-owners[i].alpha.minY]
                if i==seed {
                    candidate.audit[i]["pageEdgeMarginRefined"]=true
                    candidate.audit[i]["pageEdgeMarginPixels"]=margin
                    candidate.audit[i][horizontal ? "pageEdgeShiftXPixels":"pageEdgeShiftYPixels"]=delta
                }
            }
        }
        record("accepted")
        return candidate
    }

    /// Retry body targets only after glyph selection. A failed soft body
    /// proposal cannot force smaller fonts, different words or narrower wraps.
    private static func refineBodyTargets(_ input:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]),
                                          page:CGRect)->(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]) {
        let groups=Dictionary(grouping:input.fills.indices.filter {input.fills[$0].balloonPlacement != nil},
            by:{input.fills[$0].balloonPlacement!.bodyID})
        let bodies=Set(groups.keys.filter {key in
            let members=groups[key]!
            return members.count>1 && members.allSatisfy {input.fills[$0].textExpansionPolicy?.insideBalloon==true} &&
                members.contains {input.fills[$0].balloonPlacement?.finalReadabilityGaps != true}
        })
        guard !bodies.isEmpty,input.fills.count==input.audit.count else{return input}
        let movable=Set(bodies.flatMap {groups[$0]!})
        var fixed:[String:CGPoint]=[:]
        for i in input.fills.indices where !movable.contains(i) {
            guard let owner=input.fills[i].ownerID,let bounds=auditRect(input.audit[i],"finalFootprintOutputPixels")else{return input}
            fixed[owner]=bounds.origin
        }
        guard var candidate=try? place(input.fills,page:page,fixedOrigins:fixed,readableBodyIDs:bodies)else{return input}
        // Re-placement may trade a small source offset for paragraph separation,
        // but cannot move a retained owner arbitrarily far from its current fit.
        var rejected=Set<String>()
        var boundaryChecks:[Int:[String:Any]]=[:]
        // A soft body bbox is not original-contour authority. Use the same
        // authenticated original RGB/effective erasure already scoped by the
        // caller; never decode a source or promote a cohort-only physical scope.
        let boundarySource = NativeSourceObstructionRecovery.sourceContext ??
            NativeSourcePhysicalInteriorContext.cohortBoundaryContext ?? NativeSourcePhysicalInteriorContext.current
        for body in bodies {
            var before:CGFloat=0,after:CGFloat=0
            for i in groups[body]! {
                guard let A=auditRect(input.audit[i],"finalFootprintOutputPixels"),
                      let B=auditRect(candidate.audit[i],"finalFootprintOutputPixels"),A.size==B.size,
                      let guide=input.fills[i].textPlacementGuide,
                      let policy=input.fills[i].textExpansionPolicy else{rejected.insert(body);break}
                let font=CGFloat(policy.sourceFontPixels),source=guide.rect(in:page)
                if hypot(A.minX-B.minX,A.minY-B.minY)>font*1.25 {rejected.insert(body);break}
                if A != B {
                    guard let context=boundarySource, context.sourcePageSize==page.size,
                          let oldAlpha=try? retainedFootprint(input.fills[i]),
                          let newAlpha=try? retainedFootprint(candidate.fills[i]),
                          oldAlpha.bounds==A, newAlpha.bounds==B,
                          oldAlpha.pixels==newAlpha.pixels else {
                        boundaryChecks[i]=["status":"unknown-incumbent-body-retained"]
                        rejected.insert(body);break
                    }
                    // New alpha must not cover preserved original edges. Shared
                    // alpha is fixed at page coordinates, not grandfathered by
                    // corresponding raster pixels after translation.
                    let check=context.paintBoundaryClearance(incumbent:input.fills[i],
                        before:oldAlpha,after:newAlpha,page:page)
                    boundaryChecks[i]=check.audit
                    guard check.allowed==true else {rejected.insert(body);break}
                    if let risk=retainedSourceRiskGate,
                       risk.evaluate(oldAlpha,newAlpha) != true {
                        boundaryChecks[i]?["retainedSourceRiskStatus"]="veto-or-unknown"
                        rejected.insert(body);break
                    }
                }
                before+=hypot(A.midX-source.midX,A.midY-source.midY)/font
                after+=hypot(B.midX-source.midX,B.midY-source.midY)/font
            }
            if after>before+CGFloat(groups[body]!.count)*0.35 {rejected.insert(body)}
        }
        if !rejected.isEmpty {
            var carriers=candidate.fills,origins:[String:CGPoint]=[:]
            for i in carriers.indices {
                guard let owner=carriers[i].ownerID,let current=auditRect(candidate.audit[i],"finalFootprintOutputPixels"),
                      let original=auditRect(input.audit[i],"finalFootprintOutputPixels")else{return input}
                if carriers[i].balloonPlacement.map({rejected.contains($0.bodyID)}) == true {
                    carriers[i].balloonTargetRelaxed=true;origins[owner]=original.origin
                } else {origins[owner]=current.origin}
            }
            guard let restored=try? place(carriers,page:page,fixedOrigins:origins)else{return input}
            candidate=restored
        }
        for i in candidate.audit.indices {
            guard let A=auditRect(input.audit[i],"finalFootprintOutputPixels"),let B=auditRect(candidate.audit[i],"finalFootprintOutputPixels"),
                  A.size==B.size,input.audit[i]["paintedPixels"]as?Int==candidate.audit[i]["paintedPixels"]as?Int,
                  movable.contains(i) || A==B else{return input}
            var row=input.audit[i];row.merge(candidate.audit[i]){_,new in new};candidate.audit[i]=row
            if let check=boundaryChecks[i] {
                candidate.audit[i]["finalBodySourceBoundaryCheck"]=check
            }
            if let body=input.fills[i].balloonPlacement?.bodyID,rejected.contains(body) {
                candidate.audit[i]["finalBodySourceBoundaryIncumbentRetained"]=boundaryChecks.keys.contains {
                    input.fills[$0].balloonPlacement?.bodyID==body
                }
            }
            if A != B {candidate.audit[i]["finalBodyTargetsRefined"]=true}
        }
        return candidate
    }

    static func refineContourClearance(_ input:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]),
                               page:CGRect,inkAware:Bool=false)->(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]) {
        guard input.fills.count==input.audit.count else{return input}
        let bodies=Dictionary(grouping:input.fills.compactMap(\.balloonPlacement),by:{$0.bodyID})
        let clusters=Dictionary(grouping:input.fills.compactMap(\.sourceClusterAlignment),by:{$0.groupID})
        let bodyMembers=Dictionary(grouping:input.fills.indices.filter {input.fills[$0].balloonPlacement != nil},
            by:{input.fills[$0].balloonPlacement!.bodyID})
        let requestedInkDrift=Double(ProcessInfo.processInfo.environment["AIDOKU_INK_CONTOUR_SOURCE_DRIFT_EM"] ?? "0.1") ?? 0.1
        let inkDrift:CGFloat=requestedInkDrift.isFinite ? CGFloat(min(0.1,max(0,requestedInkDrift))):0.1
        var current=input
        for i in input.fills.indices {
            let fill=current.fills[i]
            guard let owner=fill.ownerID,let policy=fill.textExpansionPolicy,policy.insideBalloon,
                  let guide=fill.textPlacementGuide,
                  let bounds=auditRect(current.audit[i],"finalFootprintOutputPixels")else{continue}
            let sharedBody=fill.balloonPlacement.map {bodies[$0.bodyID]!.count>1} ?? false
            let sharedCluster=fill.sourceClusterAlignment.map {clusters[$0.groupID]!.count>1} ?? false
            let coupled=sharedBody || sharedCluster
            // A failed soft body target is already independently placed. Its
            // free axis may gain contour clearance without relaxing any new
            // relationship or moving a shared source start. Active coupled
            // body targets remain rigid and use the existing joint planner.
            guard !coupled || inkAware else{continue}
            var lockX=false,lockY=false
            if sharedBody,let body=fill.balloonPlacement {
                let members=bodyMembers[body.bodyID]!
                guard members.allSatisfy({current.fills[$0].balloonTargetRelaxed}) else{continue}
                let horizontal=body.flow == .row
                let alignment=body.crossAlignment ?? .start
                let fraction:CGFloat=alignment == .center ? 0.5:(alignment == .end ? 1:0)
                let cross=members.compactMap {j -> CGFloat? in
                    guard let g=current.fills[j].textPlacementGuide else{return nil}
                    let r=g.rect(in:page)
                    return horizontal ? r.minY+r.height*fraction:r.minX+r.width*fraction
                }
                guard cross.count==members.count else{continue}
                if cross.max()!-cross.min()!<=members.map({current.fills[$0].fontOutputPixels}).min()!*0.5 {
                    if horizontal {lockY=true} else{lockX=true}
                }
            }
            if sharedCluster,let cluster=fill.sourceClusterAlignment {
                if cluster.axis == .top {lockY=true} else{lockX=true}
            }
            guard !lockX || !lockY else{continue}
            var ink:Footprint?
            let plans:[NativeContourTextClearance.Plan]
            if inkAware {
                guard let support=try? proposal(fill),support.bounds==bounds,
                      support.pixels==current.audit[i]["paintedPixels"]as?Int else{continue}
                ink=support
                let rows=NativeInkContourClearance.envelope(support.runs.map {.init(y:$0.y,left:$0.left,right:$0.right)})
                plans=NativeInkContourClearance.plans(rows:rows,bounds:bounds,source:guide.rect(in:page),policy:policy,
                    guide:guide,font:fill.fontOutputPixels,page:page,maximumSourceDriftEm:inkDrift).map {
                    .init(origin:$0.origin,margin:CGFloat($0.margin),oldMargin:CGFloat($0.oldMargin),
                        sourceCostBefore:$0.sourceCostBefore,sourceCostAfter:$0.sourceCostAfter)
                }
            } else {
                plans=NativeContourTextClearance.plans(paint:bounds,source:guide.rect(in:page),policy:policy,
                    guide:guide,font:fill.fontOutputPixels,page:page)
            }
            var placementAttempts=0
            for plan in plans.prefix(64) {
                let proposed=CGRect(origin:plan.origin,size:bounds.size)
                if coupled {
                    let dx=proposed.minX-bounds.minX,dy=proposed.minY-bounds.minY
                    guard (!lockX || dx==0),(!lockY || dy==0),
                          hypot(dx,dy)<=fill.fontOutputPixels*0.25+1e-7 else{continue}
                    if sharedBody,let body=fill.balloonPlacement {
                        let horizontal=body.flow == .row
                        guard bodyMembers[body.bodyID]!.filter({$0 != i}).allSatisfy({j in
                            guard let peer=auditRect(current.audit[j],"finalFootprintOutputPixels")else{return false}
                            let earlier=current.fills[j].balloonPlacement!.order<body.order
                            return horizontal ? (earlier ? peer.midX<proposed.midX:peer.midX>proposed.midX):
                                (earlier ? peer.midY<proposed.midY:peer.midY>proposed.midY)
                        })else{continue}
                    }
                    // Keep a large masked page from re-admitting every owner
                    // dozens of times for a marginal soft-clearance polish.
                    guard placementAttempts<8 else{break}
                }
                if current.audit[i]["balloonBodyPlaced"]as?Bool == true,
                   let body=fill.balloonPlacement,!body.rect(in:page).contains(proposed) {continue}
                var origins:[String:CGPoint]=[:]
                for (j,f)in current.fills.enumerated() {
                    guard let id=f.ownerID,let r=auditRect(current.audit[j],"finalFootprintOutputPixels")else{continue}
                    origins[id]=r.origin
                }
                guard origins.count==current.fills.count else{break}
                origins[owner]=plan.origin
                placementAttempts+=1
                guard let candidate=try? place(current.fills,page:page,fixedOrigins:origins),
                      candidate.audit.count==current.audit.count else{continue}
                var valid=true
                for j in current.fills.indices {
                    guard let a=auditRect(current.audit[j],"finalFootprintOutputPixels"),
                          let b=auditRect(candidate.audit[j],"finalFootprintOutputPixels"),
                          a.size==b.size,(j==i ? b==proposed:a==b),
                          current.fills[j].fontOutputPixels==candidate.fills[j].fontOutputPixels,
                          (current.audit[j]["paintedPixels"]as?Int)==(candidate.audit[j]["paintedPixels"]as?Int),
                          (current.audit[j]["balloonBodyPlaced"]as?Bool)==(candidate.audit[j]["balloonBodyPlaced"]as?Bool)
                    else{valid=false;break}
                }
                guard valid else{continue}
                guard let moved=auditRect(candidate.audit[i],"readableBoundsOutputPixels"),
                      let previous=auditRect(current.audit[i],"readableBoundsOutputPixels")else{continue}
                for j in current.fills.indices where j != i {
                    guard let peer=auditRect(current.audit[j],"readableBoundsOutputPixels")else{valid=false;break}
                    let desired=min(fill.fontOutputPixels,current.fills[j].fontOutputPixels)*0.35
                    let old=NativeAdaptiveTextGutter.clearance(previous,peer) ?? desired
                    if let new=NativeAdaptiveTextGutter.clearance(moved,peer),new+0.01<min(old,desired) {valid=false;break}
                }
                guard valid else{continue}
                var annotated=candidate
                for j in annotated.audit.indices {
                    var row=current.audit[j];row.merge(annotated.audit[j]){_,new in new};annotated.audit[j]=row
                }
                if inkAware,let ink {
                    let prior=current.audit[i]
                    if prior["contourClearanceRefined"]as?Bool == true {
                        annotated.audit[i]["priorRectangleContourClearance"]=[
                            "beforePixels":prior["contourClearanceBeforePixels"]!,
                            "afterPixels":prior["contourClearanceAfterPixels"]!,
                            "bounds":prior["finalFootprintOutputPixels"]!]
                        for key in ["contourClearanceRefined","contourClearanceBeforePixels","contourClearanceAfterPixels",
                                    "contourClearanceSourceCostBefore","contourClearanceSourceCostAfter"] {
                            annotated.audit[i].removeValue(forKey:key)
                        }
                    }
                    annotated.audit[i]["inkContourClearanceRefined"]=true
                    annotated.audit[i]["inkContourClearanceBeforePixels"]=plan.oldMargin
                    annotated.audit[i]["inkContourClearanceAfterPixels"]=plan.margin
                    annotated.audit[i]["inkContourSourceCostBefore"]=plan.sourceCostBefore
                    annotated.audit[i]["inkContourSourceCostAfter"]=plan.sourceCostAfter
                    annotated.audit[i]["inkContourSourceDriftLimitEm"]=inkDrift
                    if coupled {
                        annotated.audit[i]["inkContourCoupledFreeAxisRefined"]=true
                        annotated.audit[i]["inkContourSharedXPreserved"]=lockX
                        annotated.audit[i]["inkContourSharedYPreserved"]=lockY
                    }
                    // Only changed owners carry sparse support. Independent
                    // replay verifies the ENTIRE native RGBA translation, so
                    // overlapping peer rectangles cannot contaminate metrics.
                    if fill.hasFinalEffects {
                        annotated.audit[i]["inkContourBeforeRuns"]=ink.runs.map {[$0.y,$0.left,$0.right]}
                    } else {
                        let rows=NativeInkContourClearance.envelope(ink.runs.map {.init(y:$0.y,left:$0.left,right:$0.right)})
                        annotated.audit[i]["inkContourBeforeEnvelope"]=rows.map {[$0.y,$0.left,$0.right]}
                    }
                } else {
                    annotated.audit[i]["contourClearanceRefined"]=true
                    annotated.audit[i]["contourClearanceBeforePixels"]=plan.oldMargin
                    annotated.audit[i]["contourClearanceAfterPixels"]=plan.margin
                    annotated.audit[i]["contourClearanceSourceCostBefore"]=plan.sourceCostBefore
                    annotated.audit[i]["contourClearanceSourceCostAfter"]=plan.sourceCostAfter
                }
                current=annotated;break
            }
        }
        return current
    }

    /// Final-only refinement: no re-shaping, re-fitting or font changes. A
    /// failed extra-clearance proposal returns the already admitted layout.
    static func refineGutters(_ input:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]),
                              page:CGRect)->(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]) {
        guard input.fills.count==input.audit.count else{return input}
        let retainedReplay=NativeReadablePeerGutter.enabled
        // A retained fallback may lock the shared start with a fixed-anchor
        // packet. It still has source guides and must receive local gutter
        // refinement without recomputing or moving that common baseline.
        var members:[NativeAdaptiveTextGutter.Member]=[]
        for (i,fill)in input.fills.enumerated() {
            guard let owner=fill.ownerID,let policy=fill.textExpansionPolicy,
                  let guide=fill.textPlacementGuide,
                  let bounds=auditRect(input.audit[i],"finalFootprintOutputPixels")else{continue}
            let group:String,axis:NativeSourceClusterAlignment.Axis,preferred:CGPoint
            if policy.insideBalloon {
                // Once a soft coupled body target has failed, preserve the
                // already admitted staggered starts and reopen only its free
                // axis for a mask-checked paragraph gutter polish.
                guard fill.balloonTargetRelaxed,let body=fill.balloonPlacement else{continue}
                group="balloon:"+body.bodyID;axis=body.flow == .row ? .top:.left
                preferred=bounds.origin
            } else {
                guard let cluster=fill.sourceClusterAlignment,input.audit[i]["balloonBodyPlaced"]as?Bool != true else{continue}
                let shift=guide.preferredShift(bounds:bounds,page:page)
                group=cluster.groupID;axis=cluster.axis
                preferred=CGPoint(x:bounds.minX+shift.x,y:bounds.minY+shift.y)
            }
            members.append(.init(owner:owner,group:group,axis:axis,source:guide.rect(in:page),painted:bounds,
                capacity:NativeTextExpansionPolicy.rect(policy.allowedRectNormalized,page:page),
                preferred:preferred,referenceFont:CGFloat(policy.sourceFontPixels),displayFont:fill.fontOutputPixels))
        }
        let proposals=NativeAdaptiveTextGutter.plans(members,page:page,pageEdgeMargin:pageEdgeMargin)
        let trace=ProcessInfo.processInfo.environment["AIDOKU_TRACE_COHORT"] == "1"
        if trace {fputs("gutter-proposals \(members.map(\.owner)) count=\(proposals.count)\n",stderr)}
        if !retainedReplay,proposals.isEmpty {return input}
        let byOwner=Dictionary(uniqueKeysWithValues:members.map {($0.owner,$0)})
        let groups=Dictionary(grouping:members,by:{$0.group})
        var rejections:[String:Int]=[:],admittedProposals=0
        func rejected(_ reason:String) {
            if retainedReplay {rejections[reason,default:0]+=1}
        }
        // One page-level record, at most 256 adjacent-pair rows. Missing
        // clearances remain explicit rather than being certified as a pass.
        func diagnosed(_ result:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]))
            ->(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]) {
            guard retainedReplay,!result.audit.isEmpty else{return result}
            var pairs:[[String:Any]]=[]
            let rows=Dictionary(result.audit.compactMap {row -> (String,[String:Any])? in
                guard let owner=row["owner"]as?String else{return nil};return (owner,row)
            },uniquingKeysWith:{first,_ in first})
            for group in groups.keys.sorted() {
                let cohort=groups[group]!,horizontal=cohort[0].axis == .top
                let ordered=cohort.sorted {
                    let a=horizontal ? $0.source.midX:$0.source.midY,b=horizontal ? $1.source.midX:$1.source.midY
                    return a==b ? $0.owner<$1.owner:a<b
                }
                for (left,right) in zip(ordered,ordered.dropFirst()) where pairs.count<256 {
                    var pair:[String:Any]=["group":group,"first":left.owner,"second":right.owner,
                        "desiredGapPixels":NativeAdaptiveTextGutter.desiredGap(left,right)]
                    if let a=rows[left.owner].flatMap({auditRect($0,"finalFootprintOutputPixels")}),
                       let b=rows[right.owner].flatMap({auditRect($0,"finalFootprintOutputPixels")}) {
                        pair["achievedFootprintGapPixels"]=horizontal ? b.minX-a.maxX:b.minY-a.maxY
                    }
                    if let a=rows[left.owner].flatMap({auditRect($0,"readableBoundsOutputPixels")}),
                       let b=rows[right.owner].flatMap({auditRect($0,"readableBoundsOutputPixels")}) {
                        pair["achievedReadableClearancePixels"]=NativeAdaptiveTextGutter.clearance(a,b).map { $0 as Any } ?? NSNull()
                    }
                    pairs.append(pair)
                }
            }
            var annotated=result
            let diagnostic:[String:Any]=["enabled":true,"proposalCount":proposals.count,
                "admittedProposalCount":admittedProposals,"rejectionCounts":rejections,"adjacentPairs":pairs,
                "pairDiagnosticsTruncated":groups.values.reduce(0,{$0+max(0,$1.count-1)})>pairs.count]
            annotated.audit[0]["retainedPeerGutterReplay"]=diagnostic
            if trace,let data=try? JSONSerialization.data(withJSONObject:diagnostic,options:[.sortedKeys]),
               let message=String(data:data,encoding:.utf8) {fputs("retained-peer-gutter \(message)\n",stderr)}
            return annotated
        }
        guard !proposals.isEmpty else{return diagnosed(input)}
        var current=input,origins:[String:CGPoint]=[:],modified=Set<String>()
        for proposal in proposals {
            var trialOrigins=origins;trialOrigins.merge(proposal.origins){_,new in new}
            let allowed=modified.union(proposal.origins.keys)
            var fixed:[String:CGPoint]=[:]
            for i in current.fills.indices {
                guard let owner=current.fills[i].ownerID,
                      let bounds=auditRect(current.audit[i],"finalFootprintOutputPixels")else{continue}
                fixed[owner]=trialOrigins[owner] ?? bounds.origin
            }
            var retainedAnchors:[String:CGFloat]=[:]
            if retainedReplay {
                let fixedPoints=current.fills.compactMap {fill in fill.ownerID.flatMap {fixed[$0]}}
                guard fixedPoints.count==current.fills.count,
                      let anchors=NativeReadablePeerGutter.retainedAnchors(
                        packets:current.fills.map(\.sourceClusterAlignment),origins:fixedPoints)else{
                    rejected("inconsistent-retained-anchors");continue
                }
                retainedAnchors=anchors
            }
            // This is a fixed-geometry polish. Re-solving unrelated paragraphs
            // can undo their contour placement and reject an otherwise valid
            // gutter adjustment, even though every proposed origin is known.
            guard fixed.count==current.fills.count,
                  let candidate=try? place(current.fills,page:page,fixedOrigins:fixed,retainedClusterAnchors:retainedAnchors),
                  candidate.audit.count==current.audit.count else{
                rejected("placement-admission")
                if trace {fputs("gutter-rejected placement \(proposal.origins)\n",stderr)}
                continue
            }
            var before:[String:CGRect]=[:],after:[String:CGRect]=[:],oldReadable:[CGRect]=[],newReadable:[CGRect]=[]
            var valid=true
            for i in current.fills.indices {
                guard let owner=current.fills[i].ownerID,let a=auditRect(current.audit[i],"finalFootprintOutputPixels"),
                      let b=auditRect(candidate.audit[i],"finalFootprintOutputPixels"),
                      let A=auditRect(current.audit[i],"readableBoundsOutputPixels"),
                      let B=auditRect(candidate.audit[i],"readableBoundsOutputPixels")else{valid=false;break}
                guard a.size==b.size,current.fills[i].fontOutputPixels==candidate.fills[i].fontOutputPixels,
                      (current.audit[i]["paintedPixels"]as?Int)==(candidate.audit[i]["paintedPixels"]as?Int),
                      allowed.contains(owner) || a==b else{valid=false;break}
                before[owner]=a;after[owner]=b;oldReadable.append(A);newReadable.append(B)
            }
            guard valid else{
                rejected("geometry-or-unrelated-motion")
                if trace {fputs("gutter-rejected geometry-or-motion \(proposal.origins)\n",stderr)}
                continue
            }
            for group in groups.values where group.contains(where:{allowed.contains($0.owner)}) {
                guard NativeAdaptiveTextGutter.allowsMotion(group,before:before,after:after)else{valid=false;break}
            }
            guard valid else{
                rejected("source-motion")
                if trace {fputs("gutter-rejected geometry-or-motion \(proposal.origins)\n",stderr)}
                continue
            }
            for i in current.fills.indices {
                for j in current.fills.indices where j>i {
                    let desired=min(current.fills[i].fontOutputPixels,current.fills[j].fontOutputPixels)*0.35
                    let old=NativeAdaptiveTextGutter.clearance(oldReadable[i],oldReadable[j]) ?? desired
                    if let new=NativeAdaptiveTextGutter.clearance(newReadable[i],newReadable[j]),new+0.01<min(old,desired) {
                        valid=false;break
                    }
                }
                if !valid {break}
            }
            guard valid else{rejected("all-peer-clearance-regression");continue}
            guard proposal.origins.keys.contains(where:{before[$0] != after[$0]})else{rejected("unchanged");continue}
            if let risk = retainedSourceRiskGate {
                for i in current.fills.indices where current.fills[i].frame != candidate.fills[i].frame {
                    guard let old = try? self.proposal(current.fills[i]),
                          let new = try? self.proposal(candidate.fills[i]),
                          risk.evaluate(old, new) == true else { valid = false; break }
                }
                guard valid else { rejected("retained-source-risk-increased-or-unknown"); continue }
            }
            if trace {fputs("gutter-admitted \(proposal.origins)\n",stderr)}
            current=candidate;origins=trialOrigins;modified=allowed
            admittedProposals+=1
        }
        for i in current.fills.indices {
            guard let owner=current.fills[i].ownerID,modified.contains(owner),let member=byOwner[owner]else{continue}
            current.audit[i]["adaptiveGutterRefined"]=true
            current.audit[i]["adaptiveGutterSourceGroup"]=member.group
            let cohort=groups[member.group]!
            let old=Dictionary(uniqueKeysWithValues:cohort.map {($0.owner,$0.painted)})
            let new=Dictionary(uniqueKeysWithValues:current.audit.compactMap {row -> (String,CGRect)? in
                guard let id=row["owner"]as?String,let r=auditRect(row,"finalFootprintOutputPixels")else{return nil}
                return (id,r)
            })
            if let a=NativeAdaptiveTextGutter.metrics(cohort,bounds:old),let b=NativeAdaptiveTextGutter.metrics(cohort,bounds:new) {
                current.audit[i]["adaptiveGutterSourceDistanceAndSquaredCostNonIncreasing"]=b.distance<=a.distance+1e-9 && b.squared<=a.squared+1e-9
            }
            current.audit[i]["adaptiveGutterBoundedReadabilityMotionAllowed"]=true
        }
        return diagnosed(current)
    }

    /// Preserve exact glyph geometry while resolving row-level paragraph
    /// fusion inside a relaxed body. Every candidate remains source-near and
    /// passes the same assigned-mask/page/peer alpha admission as normal paint.
    private static func refineBodyInkSeparation(_ input:(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]),
                                               page:CGRect)->(fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],audit:[[String:Any]]) {
        guard input.fills.count==input.audit.count else{return input}
        let bodies=Dictionary(grouping:input.fills.indices.filter {input.fills[$0].balloonTargetRelaxed &&
            input.fills[$0].textExpansionPolicy?.insideBalloon==true && input.fills[$0].balloonPlacement != nil},
            by:{input.fills[$0].balloonPlacement!.bodyID})
        var current=input
        for body in bodies.keys.sorted() {
            let members=bodies[body]!
            guard members.count>1 else{continue}
            let horizontal=input.fills[members[0]].balloonPlacement!.flow == .row
            let alignment=input.fills[members[0]].balloonPlacement!.crossAlignment ?? .start
            let fraction:CGFloat=alignment == .center ? 0.5:(alignment == .end ? 1:0)
            let sourceCross=members.compactMap {j -> CGFloat? in
                guard let guide=input.fills[j].textPlacementGuide else{return nil}
                let r=guide.rect(in:page)
                return horizontal ? r.minY+r.height*fraction:r.minX+r.width*fraction
            }
            guard sourceCross.count==members.count else{continue}
            let commonCross=sourceCross.max()!-sourceCross.min()!<=members.map {input.fills[$0].fontOutputPixels}.min()!*0.5
            for i in members {
                let fill=current.fills[i]
                guard let owner=fill.ownerID,let policy=fill.textExpansionPolicy,let guide=fill.textPlacementGuide,
                      let ink=try? proposal(fill),let bounds=auditRect(current.audit[i],"finalFootprintOutputPixels"),ink.bounds==bounds else{continue}
                let rows=NativeInkContourClearance.envelope(ink.runs.map {.init(y:$0.y,left:$0.left,right:$0.right)})
                let peers=members.filter {$0 != i}.compactMap {j -> (Int,[NativeInkContourClearance.Row])? in
                    guard let p=try? proposal(current.fills[j])else{return nil}
                    return (j,NativeInkContourClearance.envelope(p.runs.map {.init(y:$0.y,left:$0.left,right:$0.right)}))
                }
                guard peers.count==members.count-1 else{continue}
                let target=min(128,max(2,Int(ceil(members.map {current.fills[$0].fontOutputPixels}.min()!*0.35))))
                let old=peers.map {NativeInkContourClearance.peerMargin(rows:rows,peer:$0.1,limit:target)}
                guard old.min()!<CGFloat(target) else{continue}
                let source=guide.rect(in:page),font=CGFloat(policy.sourceFontPixels),radius=min(256,Int(floor(font*0.75)))
                guard radius>0 else{continue}
                func cost(_ dx:Int,_ dy:Int)->CGFloat {
                    let x=(bounds.midX+CGFloat(dx)-source.midX)/font,y=(bounds.midY+CGFloat(dy)-source.midY)/font
                    return x*x+y*y
                }
                let before=cost(0,0),step=max(1,Int(ceil(Double(radius)/16)))
                var plans:[(dx:Int,dy:Int,cost:CGFloat,margin:CGFloat)]=[]
                let ys=Set(stride(from:-radius,through:radius,by:step)).union([0])
                for dy in ys.sorted() {
                    if commonCross && horizontal && dy != 0 {continue}
                    guard let interval=NativeInkContourClearance.interval(rows:rows,bounds:bounds,dy:dy,margin:0,policy:policy,page:page)else{continue}
                    let reach=Int(sqrt(Double(radius*radius-dy*dy)))
                    let lower=max(-reach,interval.lowerBound),upper=min(reach,interval.upperBound)
                    guard lower<=upper else{continue}
                    let xs=Set(stride(from:lower,through:upper,by:step)).union([min(upper,max(lower,0))])
                    for dx in xs.sorted() where dx != 0 || dy != 0 {
                        if commonCross && !horizontal && dx != 0 {continue}
                        let proposed=bounds.offsetBy(dx:CGFloat(dx),dy:CGFloat(dy))
                        let order=fill.balloonPlacement!.order
                        guard peers.allSatisfy({j,_ in
                            guard let peer=auditRect(current.audit[j],"finalFootprintOutputPixels")else{return false}
                            let earlier=current.fills[j].balloonPlacement!.order<order
                            return horizontal ? (earlier ? peer.midX<proposed.midX:peer.midX>proposed.midX):
                                (earlier ? peer.midY<proposed.midY:peer.midY>proposed.midY)
                        })else{continue}
                        let value=cost(dx,dy)
                        // Readability improves without adding source-centre
                        // drift, so policy comparison cannot roll it back later.
                        guard value<=before+1e-9 else{continue}
                        let margins=peers.map {NativeInkContourClearance.peerMargin(rows:rows,peer:$0.1,dx:dx,dy:dy,limit:target)}
                        guard margins.min()!>=CGFloat(target) else{continue}
                        plans.append((dx,dy,value,margins.min()!))
                    }
                }
                plans.sort {a,b in a.cost==b.cost ? (a.dx*a.dx+a.dy*a.dy==b.dx*b.dx+b.dy*b.dy ?
                    (a.dy==b.dy ? a.dx<b.dx:a.dy<b.dy):a.dx*a.dx+a.dy*a.dy<b.dx*b.dx+b.dy*b.dy):a.cost<b.cost}
                for plan in plans.prefix(8) {
                    var fixed:[String:CGPoint]=[:]
                    for j in current.fills.indices {
                        guard let id=current.fills[j].ownerID,let b=auditRect(current.audit[j],"finalFootprintOutputPixels")else{continue}
                        fixed[id]=b.origin
                    }
                    fixed[owner]=bounds.origin.applying(CGAffineTransform(translationX:CGFloat(plan.dx),y:CGFloat(plan.dy)))
                    guard fixed.count==current.fills.count,var candidate=try? place(current.fills,page:page,fixedOrigins:fixed)else{continue}
                    var valid=true
                    for j in current.fills.indices {
                        guard let a=auditRect(current.audit[j],"finalFootprintOutputPixels"),
                              let b=auditRect(candidate.audit[j],"finalFootprintOutputPixels"),a.size==b.size,
                              b.origin==fixed[current.fills[j].ownerID!],
                              current.audit[j]["paintedPixels"]as?Int==candidate.audit[j]["paintedPixels"]as?Int else{valid=false;break}
                        if j != i,let peer=auditRect(current.audit[j],"readableBoundsOutputPixels"),
                           let A=auditRect(current.audit[i],"readableBoundsOutputPixels"),
                           let B=auditRect(candidate.audit[i],"readableBoundsOutputPixels") {
                            let desired=min(fill.fontOutputPixels,current.fills[j].fontOutputPixels)*0.35
                            let prior=NativeAdaptiveTextGutter.clearance(A,peer) ?? desired
                            if let next=NativeAdaptiveTextGutter.clearance(B,peer),next+0.01<min(prior,desired) {valid=false;break}
                        }
                    }
                    guard valid else{continue}
                    for j in candidate.audit.indices {
                        var row=current.audit[j];row.merge(candidate.audit[j]){_,new in new};candidate.audit[j]=row
                    }
                    candidate.audit[i]["bodyInkSeparationRefined"]=true
                    candidate.audit[i]["bodyInkSeparationBeforePixels"]=old.min()!
                    candidate.audit[i]["bodyInkSeparationAfterPixels"]=plan.margin
                    candidate.audit[i]["bodyInkSourceSquaredCostBefore"]=before
                    candidate.audit[i]["bodyInkSourceSquaredCostAfter"]=plan.cost
                    candidate.audit[i]["bodyInkTranslationPixels"]=[plan.dx,plan.dy]
                    current=candidate;break
                }
            }
        }
        return current
    }

    /// Interior reflow retains its prior anchor; exterior edge rescue requires
    /// its own complete translation proof. Both bind every member to actual paint.
    static func verifiedRetainedClusterAnchors(
        _ fills: [NativeAOTTranslationPageComposer.TranslatedFillPrimitive],
        footprints: [Footprint], audit: [[String: Any]], page: CGRect) throws -> [String: CGFloat] {
        guard fills.count == footprints.count else { throw Failure.invalidGeometry }
        let balanced: [String: CGFloat]
        if audit.contains(where: { $0[NativeSourceCohortCenterBalance.auditKey] != nil }) {
            balanced = try NativeSourceCohortCenterBalance.verifiedRetainedAnchors(fills,
                footprints: footprints, audit: audit, page: page)
        } else { balanced = [:] }
        let marked = audit.indices.filter { audit[$0]["retainedSourceClusterAnchorApplied"] as? Bool == true }
        guard !marked.isEmpty else { return balanced }
        guard audit.count == fills.count else { throw Failure.invalidGeometry }
        func number(_ value: Any?) -> CGFloat? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite else { return nil }
            return CGFloat(value.doubleValue)
        }
        var owners = Set<String>()
        for i in fills.indices {
            guard let owner = fills[i].ownerID, !owner.isEmpty, owners.insert(owner).inserted,
                  audit[i]["owner"] as? String == owner else { throw Failure.invalidGeometry }
        }
        // Edge recovery retains a NEW coherent exterior anchor, unlike interior
        // reflow, which retains its OLD anchor. Never manufacture interior proof
        // or trust the edge receipt without binding it to the actual paint.
        func numbers(_ value: Any?, count: Int) -> [CGFloat]? {
            guard let values = value as? [Any], values.count == count else { return nil }
            let result = values.compactMap { number($0) }
            return result.count == count ? result : nil
        }
        func rect(_ value: Any?) -> CGRect? {
            guard let v = numbers(value, count: 4), v[2] > 0, v[3] > 0 else { return nil }
            let r = CGRect(x:v[0], y:v[1], width:v[2], height:v[3])
            return r == r.integral ? r : nil
        }
        func sameSupport(_ a: Footprint, _ b: Footprint) -> Bool {
            a.bounds == b.bounds && a.pixels == b.pixels && a.readableBounds == b.readableBounds &&
                a.runs.count == b.runs.count && zip(a.runs,b.runs).allSatisfy {
                    $0.0.y == $0.1.y && $0.0.left == $0.1.left && $0.0.right == $0.1.right
                }
        }
        var anchors = balanced
        var edgeGroups = Set<String>()
        for i in marked where audit[i]["retainedPageEdgeRecovery"] != nil {
            guard let packet = fills[i].sourceClusterAlignment else { throw Failure.invalidGeometry }
            // Current center-balance and current edge receipts must never both
            // authorize a cohort. Earlier edge evidence belongs in history.
            guard balanced[packet.groupID] == nil else { throw Failure.invalidGeometry }
            if edgeGroups.contains(packet.groupID) { continue }
            guard page == page.integral, page.minX == 0, page.minY == 0,
                  page.width > 2, page.height > 2, page.width <= 16_384, page.height <= 16_384,
                  let receipt = audit[i]["retainedPageEdgeRecovery"] as? [String:Any],
                  let shift = numbers(receipt["shiftPixels"], count:2),
                  shift.allSatisfy({ $0 == $0.rounded() && abs($0) <= 1 }),
                  shift[0] != 0 || shift[1] != 0 else { throw Failure.invalidGeometry }
            let delta = CGPoint(x:shift[0],y:shift[1]), norm = hypot(delta.x,delta.y)
            let members = fills.indices.filter { fills[$0].sourceClusterAlignment?.groupID == packet.groupID }
            let cohort = members.compactMap { fills[$0].ownerID }.sorted()
            guard members.count >= 2, cohort.count == members.count else { throw Failure.invalidGeometry }
            let inset = page.insetBy(dx:1,dy:1)
            guard footprints.allSatisfy({ inset.contains($0.bounds) }) else { throw Failure.invalidGeometry }
            var oldUnion = CGRect.null
            var oldAnchor: CGFloat?, newAnchor: CGFloat?
            for j in members {
                let fill = fills[j], row = audit[j], actual = footprints[j]
                guard row["retainedSourceClusterAnchorApplied"] as? Bool == true,
                      let proof = row["retainedPageEdgeRecovery"] as? [String:Any],
                      proof["version"] as? String == "retained-page-edge-inset1-v1",
                      proof["cohortOwners"] as? [String] == cohort,
                      numbers(proof["shiftPixels"],count:2) == shift,
                      numbers(proof["minimalGroupShift"],count:2) == shift,
                      number(proof["insetPixels"]) == 1,
                      number(proof["exceptionBoundPixels"]) == norm,
                      proof["exceptionAuthority"] as? String == "minimal-required-page-inset-and-coherent-cohort-only",
                      fill.balloonPlacement == nil, !fill.balloonTargetRelaxed,
                      let policy = fill.textExpansionPolicy, policy.valid, !policy.insideBalloon,
                      fill.placementDomain != nil, let guide = fill.textPlacementGuide, guide.valid,
                      fill.frame == fill.frame.integral, page.contains(fill.frame),
                      fill.frame.width == CGFloat(fill.image.width), fill.frame.height == CGFloat(fill.image.height),
                      fill.fontOutputPixels.isFinite, fill.fontOutputPixels > 0,
                      norm <= floor(fill.fontOutputPixels*0.5),
                      let member = fill.sourceClusterAlignment, member.valid,
                      member.axis == packet.axis, member.anchorPolicy == "source-near-final-alpha",
                      abs(member.anchorNormalized-packet.anchorNormalized) <= 1e-9,
                      row["sourceClusterID"] as? String == packet.groupID,
                      row["sourceClusterAxis"] as? String == packet.axis.rawValue,
                      row["effectsIncluded"] as? Bool == true,
                      number(row["paintedPixels"]) == CGFloat(actual.pixels),
                      rect(row["finalFootprintOutputPixels"]) == actual.bounds,
                      rect(proof["afterBounds"]) == actual.bounds,
                      let before = rect(proof["beforeBounds"]), page.contains(before),
                      before.offsetBy(dx:delta.x,dy:delta.y) == actual.bounds,
                      let previous = number(proof["cohortOldAnchor"]),
                      let certified = number(proof["cohortNewAnchor"]),
                      number(row["sourceClusterAnchorOutputPixels"]) == certified else { throw Failure.invalidGeometry }
                let oldAxis = packet.axis == .top ? before.minY : before.minX
                let newAxis = packet.axis == .top ? actual.bounds.minY : actual.bounds.minX
                guard previous == oldAxis, certified == newAxis,
                      oldAnchor == nil || oldAnchor == previous,
                      newAnchor == nil || newAnchor == certified else { throw Failure.invalidGeometry }
                oldAnchor = previous; newAnchor = certified
                // Reconstruct the incumbent from the SAME retained raster/style.
                // Compare every nonzero alpha run, not just its box or count.
                var oldFill = fill
                oldFill.frame = fill.frame.offsetBy(dx:-delta.x,dy:-delta.y)
                guard page.contains(oldFill.frame) else { throw Failure.invalidGeometry }
                let oldSupport = try retainedFootprint(oldFill)
                let newSupport = try retainedFootprint(fill)
                guard oldSupport.bounds == before,
                      sameSupport(oldSupport.translated(delta),actual),
                      sameSupport(newSupport,actual) else { throw Failure.invalidGeometry }
                let source = guide.rect(in:page)
                let oldPreferred = guide.preferredShift(bounds:before,page:page)
                let newPreferred = guide.preferredShift(bounds:actual.bounds,page:page)
                let oldCenter = hypot(before.midX-source.midX,before.midY-source.midY)
                let newCenter = hypot(actual.bounds.midX-source.midX,actual.bounds.midY-source.midY)
                let oldCost = hypot(oldPreferred.x,oldPreferred.y), newCost = hypot(newPreferred.x,newPreferred.y)
                guard number(proof["centerBeforePixels"]) == oldCenter,
                      number(proof["centerAfterPixels"]) == newCenter,
                      number(proof["guideBeforePixels"]) == oldCost,
                      number(proof["guideAfterPixels"]) == newCost,
                      newCenter <= oldCenter+norm+1e-7, newCost <= oldCost+norm+1e-7 else { throw Failure.invalidGeometry }
                oldUnion = oldUnion.union(before)
            }
            // Recompute the unique nearest integral correction for the COMPLETE
            // old cohort. Margin-only or oversized translations are not rescue.
            func nearest(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat? {
                let lower = ceil(lo), upper = floor(hi)
                return lower <= upper ? min(upper,max(lower,0)) : nil
            }
            guard !inset.contains(oldUnion),
                  nearest(inset.minX-oldUnion.minX,inset.maxX-oldUnion.maxX) == delta.x,
                  nearest(inset.minY-oldUnion.minY,inset.maxY-oldUnion.maxY) == delta.y,
                  let anchor = newAnchor else { throw Failure.invalidGeometry }
            for j in members {
                guard let proof = audit[j]["retainedPageEdgeRecovery"] as? [String:Any],
                      rect(proof["minimalGroupBeforeBounds"]) == oldUnion else { throw Failure.invalidGeometry }
            }
            anchors[packet.groupID] = anchor
            edgeGroups.insert(packet.groupID)
        }
        for i in marked {
            if let group = fills[i].sourceClusterAlignment?.groupID, balanced[group] != nil { continue }
            if let group = fills[i].sourceClusterAlignment?.groupID, edgeGroups.contains(group) { continue }
            guard let packet = fills[i].sourceClusterAlignment,
                  audit[i]["interiorWordReflow"] as? Bool == true,
                  let prior = audit[i]["preInteriorWordReflowPlacement"] as? [String: Any],
                  prior["owner"] as? String == fills[i].ownerID,
                  prior["sourceClusterID"] as? String == packet.groupID,
                  prior["sourceClusterAxis"] as? String == packet.axis.rawValue,
                  let anchor = number(audit[i]["sourceClusterAnchorOutputPixels"]),
                  let previous = number(prior["sourceClusterAnchorOutputPixels"]),
                  abs(anchor - previous) < 0.01 else { throw Failure.invalidGeometry }
            if let previous = anchors[packet.groupID], abs(previous - anchor) >= 0.01 {
                throw Failure.invalidGeometry
            }
            anchors[packet.groupID] = anchor
        }
        for (group, anchor) in anchors where !edgeGroups.contains(group) && balanced[group] == nil {
            let members = fills.indices.filter { fills[$0].sourceClusterAlignment?.groupID == group }
            guard members.count >= 2, let first = members.first,
                  let packet = fills[first].sourceClusterAlignment else { throw Failure.invalidGeometry }
            for i in members {
                let row = audit[i], actual = footprints[i]
                guard let member = fills[i].sourceClusterAlignment, member.valid,
                      member.axis == packet.axis, member.anchorPolicy == "source-near-final-alpha",
                      abs(member.anchorNormalized - packet.anchorNormalized) <= 1e-9,
                      let policy = fills[i].textExpansionPolicy, policy.valid, policy.insideBalloon,
                      row["sourceClusterID"] as? String == group,
                      row["sourceClusterAxis"] as? String == packet.axis.rawValue,
                      let certified = number(row["sourceClusterAnchorOutputPixels"]), abs(certified - anchor) < 0.01,
                      row["effectsIncluded"] as? Bool == true,
                      let pixels = number(row["paintedPixels"]), pixels == CGFloat(actual.pixels),
                      let values = row["finalFootprintOutputPixels"] as? [Any], values.count == 4 else {
                    throw Failure.invalidGeometry
                }
                let bounds = values.compactMap { number($0) }
                guard bounds.count == 4, bounds[2] > 0, bounds[3] > 0,
                      CGRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3]) == actual.bounds,
                      abs((packet.axis == .top ? actual.bounds.minY : actual.bounds.minX) - anchor) < 0.01 else {
                    throw Failure.invalidGeometry
                }
            }
        }
        return anchors
    }

    /// Only missing nonzero support is a loss. Extra actual pixels still pass
    /// the ordinary page/domain/peer gates below; they are not clipping.
    private static func retainsSupport(_ expected: Footprint, actual: Footprint) -> Bool {
        var index = 0
        for run in expected.runs {
            while index < actual.runs.count && (actual.runs[index].y < run.y ||
                (actual.runs[index].y == run.y && actual.runs[index].right <= run.left)) {
                index += 1
            }
            guard index < actual.runs.count else { return false }
            let retained = actual.runs[index]
            guard retained.y == run.y, retained.left <= run.left, retained.right >= run.right else { return false }
        }
        return true
    }

    static func verify(_ fills: [NativeAOTTranslationPageComposer.TranslatedFillPrimitive],
                       layers: [NativeMandatoryDisplayStroke.Prepared], page: CGRect,
                       admissionAudit: [[String: Any]] = [],
                       sourceStyleMemo: NativeSourceStylePaint.PlaneMemo? = nil,
                       observeVerifiedSupport: ([Footprint]) -> Void = { _ in }) throws -> Int {
        guard fills.count == layers.count else { throw Failure.invalidGeometry }
        var retained: [Footprint] = []
        for i in fills.indices {
            try fills[i].validateSourceContourOnly()
            guard fills[i].sourceContourOnly == layers[i].sourceContourOnly else { throw Failure.invalidGeometry }
            // Independently prepare support away from the page boundary. The
            // supplied layer may already be truncated by prepare(restored:).
            let expected = try proposal(fills[i])
            let actual = try footprint(layer: layers[i], style: fills[i].sourceStyle, fontPixels: fills[i].fontOutputPixels,
                                       sourceStyleMemo: sourceStyleMemo)
            guard admitted(expected, page: page, domain: fills[i].placementDomain),
                  retainsSupport(expected, actual: actual) else { throw Failure.clippedEffects }
            guard admitted(actual, page: page, domain: fills[i].placementDomain) else { throw Failure.clippedEffects }
            let spacing = PeerSpacing(fills[i], page: page)
            for j in retained.indices where intersects(retained[j],actual) ||
                blockConflict(retained[j],actual,rule:spacingRule(PeerSpacing(fills[j], page: page), spacing)) {
                throw Failure.finalCollision(j,i)
            }
            retained.append(actual)
        }
        let anchors = try verifiedRetainedClusterAnchors(fills, footprints: retained, audit: admissionAudit, page: page)
        try verifyRetainedPlacement(fills, footprints:retained, page:page, retainedClusterAnchors:anchors)
        observeVerifiedSupport(retained)
        return retained.reduce(0) { $0 + $1.pixels }
    }

    /// Shared by final paint and terminal shape selection. Fixed origins do
    /// not waive source-cluster or body-relative placement invariants.
    static func verifyRetainedPlacement(_ fills:[NativeAOTTranslationPageComposer.TranslatedFillPrimitive],
        footprints retained:[Footprint],page:CGRect,retainedClusterAnchors:[String:CGFloat]=[:])throws {
        guard fills.count==retained.count else {throw Failure.invalidGeometry}
        let targets = try NativeSourceClusterAlignment.targets(fills.map(\.sourceClusterAlignment),
            bounds: retained.map(\.bounds), page: page, guides: fills.map(\.textPlacementGuide),
            capacities:fills.map(\.textExpansionPolicy),retainedAnchors:retainedClusterAnchors)
        for i in fills.indices {
            if let target = targets[i], let packet = fills[i].sourceClusterAlignment {
                let actual = packet.axis == .top ? retained[i].bounds.minY : retained[i].bounds.minX
                guard abs(actual - target) < 0.01 else {
                    throw Failure.finalInvariant("source-cluster:\(i):actual=\(actual):target=\(target)")
                }
            }
        }
        let bodyTargets = try NativeBalloonPlacement.targets(fills.map(\.balloonPlacement),
            bounds: retained.map(\.bounds), fonts: fills.map(\.fontOutputPixels), page: page,guides:fills.map(\.textPlacementGuide))
        var bodyResiduals: [String: CGPoint] = [:]
        for i in fills.indices {
            guard let packet = fills[i].balloonPlacement, let residual = bodyTargets[i] else { continue }
            if fills[i].balloonTargetRelaxed {
                // Body targets are proposal-only. Actual retained alpha has
                // already passed the mandatory assigned-mask/page/peer checks.
                guard fills[i].placementDomain != nil,
                      fills.indices.filter({fills[$0].balloonPlacement?.bodyID==packet.bodyID}).allSatisfy({fills[$0].balloonTargetRelaxed})
                else{throw Failure.invalidGeometry}
                continue
            }
            guard packet.rect(in: page).contains(retained[i].bounds) else { throw Failure.clippedEffects }
            if let previous = bodyResiduals[packet.bodyID] {
                guard abs(previous.x - residual.x) < 0.01, abs(previous.y - residual.y) < 0.01 else {
                    throw Failure.finalInvariant("body-residual:\(packet.bodyID):\(i):previous=\(previous):current=\(residual)")
                }
            } else { bodyResiduals[packet.bodyID] = residual }
        }
    }

    static func verifyRaster(_ image: CGImage, expectedPixels: Int) throws {
        let bytes = try NativeMandatoryDisplayStroke.rgba(image)
        let actual = stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + (bytes[$1] == 0 ? 0 : 1) }
        guard actual == expectedPixels else { throw Failure.clippedEffects }
    }
}

extension NativeBalloonPlacement.RetainedState {
        typealias Primitive = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
        typealias Tuple = (fills: [Primitive], audit: [[String:Any]])
        struct Plan {
            let fills: [Primitive]
            let audit: [[String:Any]]
            let states: [String:Snapshot]
            let unknownOwners: Set<String>
            /// ALWAYS complete: a plan is never permission to recenter.
            let fixedOrigins: [String:CGPoint]
        }
        /// Metadata restoration only. Old audit flags are never rewritten here.
        /// Missing legacy state is a candidate, NOT exact historical recovery.
        static func rehydrate(_ incumbent: Tuple, page: CGRect, rawGroup: AuthenticatedRawGroup) throws -> Plan {
            try rehydrate(incumbent,page:page,rawGroups:[rawGroup])
        }
        static func rehydrate(_ incumbent: Tuple, page: CGRect, rawGroups: [AuthenticatedRawGroup] = [],
                              declaredAbsentOwners: Set<String> = [], declaredSourceIdentity: String? = nil) throws -> Plan {
            guard incumbent.fills.count <= 256, incumbent.fills.count == incumbent.audit.count,
                  page == page.integral, page.minX == 0, page.minY == 0, page.width > 0, page.height > 0,
                  page.width <= 16_384, page.height <= 16_384 else { throw Failure.budget }
            let owners = incumbent.fills.compactMap(\.ownerID)
            guard owners.count == incumbent.fills.count, Set(owners).count == owners.count, owners.allSatisfy(validOwner) else { throw Failure.malformed }
            let indices = Dictionary(uniqueKeysWithValues:owners.enumerated().map { ($0.element,$0.offset) })
            guard declaredAbsentOwners.isSubset(of:Set(owners)) else { throw Failure.partialGroup }
            if !declaredAbsentOwners.isEmpty {
                guard let identity = declaredSourceIdentity, !identity.isEmpty, identity.utf8.count <= 4096 else { throw Failure.binding }
            }
            guard rawGroups.count <= 256 else { throw Failure.budget }
            var declaredPackets: [String:NativeBalloonPlacement] = [:], declaredBodies = Set<String>()
            for rawGroup in rawGroups {
                guard declaredBodies.insert(rawGroup.packets.values.first!.bodyID).inserted else { throw Failure.partialGroup }
                for (owner,packet) in rawGroup.packets {
                    guard declaredPackets.updateValue(packet,forKey:owner) == nil else { throw Failure.partialGroup }
                }
                guard Set(rawGroup.packets.keys).isSubset(of:Set(owners)) else { throw Failure.partialGroup }
                let body = rawGroup.packets.values.first!.bodyID
                let knownMembers = incumbent.fills.filter { $0.balloonPlacement?.bodyID == body }.compactMap(\.ownerID)
                guard Set(knownMembers).isSubset(of:Set(rawGroup.packets.keys)) else { throw Failure.partialGroup }
            }
            guard Set(declaredPackets.keys).isDisjoint(with:declaredAbsentOwners) else { throw Failure.binding }
            var fills = incumbent.fills, states: [String:Snapshot] = [:], unknown = Set<String>(), fixed: [String:CGPoint] = [:]
            var pixels = 0
            for i in fills.indices {
                guard incumbent.audit[i]["owner"] as? String == owners[i], page.contains(fills[i].frame),
                      fills[i].frame == fills[i].frame.integral, fills[i].image.height > 0,
                      fills[i].image.width <= 8_000_000/fills[i].image.height else { throw Failure.malformed }
                pixels += fills[i].image.width*fills[i].image.height
                guard pixels <= 16_777_216 else { throw Failure.budget }
                let support = try NativeFinalTextPaintAdmission.retainedFootprint(fills[i])
                fixed[owners[i]] = support.bounds.origin
                let declared: DeclaredRequest? = declaredAbsentOwners.contains(owners[i]) ? .absent :
                    declaredPackets[owners[i]].map { DeclaredRequest.packet($0) }
                switch try read(incumbent.audit[i],owner:owners[i],declaredRequest:declared) {
                case .missing:
                    unknown.insert(owners[i])
                    if declaredAbsentOwners.contains(owners[i]) {
                        guard fills[i].balloonPlacement == nil else { throw Failure.binding }
                        let state = Snapshot(schema:1,owner:owners[i],presence:.absent,inputPacket:nil,effectivePacket:nil,
                            groupOwners:[owners[i]],balloonTargetRelaxed:nil,
                            target:.unknown,fallbackReason:nil,provenance:.authenticatedLegacyCandidate,
                            requiresFixedOriginRevalidation:true,historicalStateExact:false,sourceIdentity:declaredSourceIdentity)
                        try validate(state); states[owners[i]] = state
                    }
                case .state(let s):
                    guard s.groupOwners.allSatisfy({ indices[$0] != nil }) else { throw Failure.partialGroup }
                    states[owners[i]] = s
                    fills[i].balloonPlacement = s.effectivePacket
                    if let flag = s.balloonTargetRelaxed { fills[i].balloonTargetRelaxed = flag }
                    if s.requiresFixedOriginRevalidation { unknown.insert(owners[i]) }
                }
            }
            // Validate over ALL states before considering any raw reconstruction.
            // Same-body singleton partitions cannot evade unique-order checks.
            try validateGroups(states)
            for state in states.values where state.presence == .present {
                let actualMembers = fills.indices.filter { fills[$0].balloonPlacement?.bodyID == state.effectivePacket?.bodyID }.map { owners[$0] }
                guard Set(actualMembers) == Set(state.groupOwners) else { throw Failure.partialGroup }
                for rawGroup in rawGroups where rawGroup.packets.values.first?.bodyID == state.effectivePacket?.bodyID {
                    guard Set(state.groupOwners) == Set(rawGroup.packets.keys) else { throw Failure.partialGroup }
                }
            }
            for rawGroup in rawGroups {
                let members = rawGroup.packets.keys.sorted()
                let missing = members.filter { states[$0] == nil }
                if !missing.isEmpty {
                    guard missing.count == members.count else { throw Failure.partialGroup }
                    let ids = members.map { indices[$0]! }
                    guard ids.allSatisfy({ fills[$0].textPlacementGuide?.valid == true &&
                        fills[$0].fontOutputPixels.isFinite && fills[$0].fontOutputPixels > 0 &&
                        fills[$0].textExpansionPolicy?.valid == true }) else { throw Failure.malformed }
                    let packets = NativeBalloonPlacement.sourceNearPackets(members.map { rawGroup.packets[$0] },
                        guides:ids.map { fills[$0].textPlacementGuide },
                        fonts:ids.map { CGFloat(fills[$0].textExpansionPolicy!.sourceFontPixels) },
                        capacities:ids.map { fills[$0].textExpansionPolicy!.allowedRectNormalized },page:page)
                    for (n,i) in ids.enumerated() {
                        let owner = owners[i]
                        let state = Snapshot(schema:1,owner:owner,presence:.present,inputPacket:rawGroup.packets[owner],
                            effectivePacket:packets[n],groupOwners:members,
                            balloonTargetRelaxed:nil,target:.unknown,
                            fallbackReason:incumbent.audit[i]["balloonTargetFallbackReason"] as? String,
                            provenance:.authenticatedLegacyCandidate,requiresFixedOriginRevalidation:true,historicalStateExact:false,sourceIdentity:rawGroup.sourceIdentity)
                        try validate(state); states[owner] = state; fills[i].balloonPlacement = packets[n]
                        // Do not infer a missing relaxed flag from raw request.
                        if let flag = state.balloonTargetRelaxed { fills[i].balloonTargetRelaxed = flag }
                    }
                }
            }
            try validateGroups(states)
            return Plan(fills:fills,audit:incumbent.audit,states:states,unknownOwners:unknown,fixedOrigins:fixed)
        }
        /// Explicit new admission at ALL incumbent origins. Never claims to
        /// recover legacy historical state; returns a newly validated receipt.
        static func revalidateFixedOrigins(_ plan: Plan, page: CGRect) throws -> Tuple {
            let owners = plan.fills.compactMap(\.ownerID)
            guard plan.fills.count <= 256, plan.fills.count == plan.audit.count,
                  owners.count == plan.fills.count, Set(owners).count == owners.count,
                  Set(plan.fixedOrigins.keys) == Set(owners),
                  plan.unknownOwners.allSatisfy({ plan.states[$0] != nil }) else { throw Failure.unsafeRevalidation }
            let old = try plan.fills.map { try NativeFinalTextPaintAdmission.retainedFootprint($0) }
            guard old.indices.allSatisfy({ plan.fixedOrigins[owners[$0]] == old[$0].bounds.origin }) else { throw Failure.unsafeRevalidation }
            guard let anchors = NativeReadablePeerGutter.retainedAnchors(packets:plan.fills.map(\.sourceClusterAlignment),
                origins:old.map { $0.bounds.origin }) else { throw Failure.unsafeRevalidation }
            var admitted = try NativeFinalTextPaintAdmission.place(plan.fills,page:page,fixedOrigins:plan.fixedOrigins,retainedClusterAnchors:anchors)
            guard admitted.fills.count == plan.fills.count else { throw Failure.unsafeRevalidation }
            let next = try admitted.fills.map { try NativeFinalTextPaintAdmission.retainedFootprint($0) }
            try NativeFinalTextPaintAdmission.verifyRetainedPlacement(admitted.fills,footprints:next,page:page,retainedClusterAnchors:anchors)
            // Retain the ORIGINAL new-admission evidence for unknown owners.
            // Reconciliation intentionally removes fresh state for missing
            // history, while copying every known Snapshot in full.
            let freshAudit = admitted.audit
            let retainedAudit = try preservingKnownSnapshots(priorAudit:plan.audit,admittedAudit:freshAudit,
                unknownPolicy:.preservePriorUncertainty,inputPolicy:.retainedEffectivePacket)
            for i in plan.fills.indices {
                let a = plan.fills[i], b = admitted.fills[i], owner = a.ownerID!
                guard a.ownerID == b.ownerID, a.frame == b.frame, a.fontOutputPixels == b.fontOutputPixels,
                      a.image.width == b.image.width, a.image.height == b.image.height,
                      try NativeMandatoryDisplayStroke.rgba(a.image) == NativeMandatoryDisplayStroke.rgba(b.image),
                      a.balloonPlacement == b.balloonPlacement,
                      plan.unknownOwners.contains(owner) || a.balloonTargetRelaxed == b.balloonTargetRelaxed else { throw Failure.unsafeRevalidation }
                var row = plan.audit[i]; row.merge(retainedAudit[i]) { _,new in new }
                if plan.audit[i]["retainedSourceClusterAnchorApplied"] as? Bool != true {
                    row.removeValue(forKey:"retainedSourceClusterAnchorApplied")
                }
                if plan.unknownOwners.contains(owner) {
                    guard let value = freshAudit[i][auditKey] else { throw Failure.unsafeRevalidation }
                    let captured = try decode(value,owner:owner)
                    let new = Snapshot(schema:captured.schema,owner:owner,presence:captured.presence,
                        inputPacket:captured.inputPacket,effectivePacket:captured.effectivePacket,groupOwners:captured.groupOwners,
                        balloonTargetRelaxed:captured.balloonTargetRelaxed,target:captured.target,fallbackReason:captured.fallbackReason,
                        provenance:.fixedOriginRevalidated,requiresFixedOriginRevalidation:false,historicalStateExact:false,
                        sourceIdentity:plan.states[owner]?.sourceIdentity)
                    row[auditKey] = try encode(new)
                    var prior: [String:Any] = [:]
                    for key in ["balloonBodyID","balloonBodyPlaced","balloonCapacityFallback","balloonTargetRelaxed",
                                "balloonTargetFallbackReason","sourceParagraphOffsetsPreserved","effectiveBalloonRectNormalized"] {
                        let value = plan.audit[i][key]
                        // Only bounded scalar/rectangle evidence, never nested
                        // old audits. Null explicitly distinguishes missing keys.
                        if let flag = value as? Bool { prior[key] = flag }
                        else if let text = value as? String, text.utf8.count <= 512 { prior[key] = text }
                        else if let rect = value as? [Double], rect.count == 4, rect.allSatisfy(\.isFinite) { prior[key] = rect }
                        else { prior[key] = NSNull() }
                    }
                    row["retainedBalloonRevalidation"] = ["status":"new-fixed-origin-admission","historicalStateExact":false,
                        "priorBalloonAudit":prior,"priorPresentKeys":prior.keys.filter {plan.audit[i][$0] != nil}.sorted(),
                        "physicalContainmentMeasured":false]
                }
                admitted.audit[i] = row
            }
            if plan.audit.contains(where: { $0[NativeSourceCohortCenterBalance.auditKey] != nil }) {
                admitted = try NativeSourceCohortCenterBalance.preservingReceipts(
                    prior: (plan.fills, plan.audit), admitted: admitted, page: page)
            }
            return admitted
        }
}
