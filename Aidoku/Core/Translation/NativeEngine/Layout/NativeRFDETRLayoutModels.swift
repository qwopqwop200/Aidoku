import Accelerate
import CoreGraphics
import CryptoKit
import Foundation

/// Auxiliary evidence only. Never replaces OCR, erases source glyphs, or shrinks
/// an OCR owner solely because a predicted mask excludes part of its source.
enum NativeRFDETRLayoutClass: Int, Codable, Sendable {
    case text = 0
    case soundEffect = 1
    case balloon = 2
    case frame = 3

    /// Shared primitive taxonomy: frame0, text1, balloon2, SFX3.
    var canonicalClassID: Int {
        switch self {
        case .text: 1
        case .soundEffect: 3
        case .balloon: 2
        case .frame: 0
        }
    }
}

enum NativeRFDETRLayoutError: Error, Sendable {
    case modelUnavailable
    case unsupportedModelContract(String)
    case invalidImage
    case sourceImageTooLarge
    case busy
    case nonfiniteOutput
    case maskRasterTooLarge
}

/// Parent's model acquisition layer supplies a verified, durable compiled URL.
/// The upstream repository provides SafeTensors, NOT an installable Core ML
/// resource. Publish the converted648 asset with its own package/archive hash
/// before adding a remote resource to the shared model manager.
enum NativeRFDETRLayoutResource {
    static let resourceName = "KoharuHighres648FP16"
    static let sourceRepository = "mayocream/koharu-layout-highres"
    static let sourceRevision = "53fef6f1301f4cbd8324ddc24f554b3767fc9e45"
    static let sourceWeightsSHA256 = "03de2f77281974f5084cdd8652ace2b55dc15ac0378aed66654e62537cdda255"
    static let highresSourceRevision = "53fef6f1301f4cbd8324ddc24f554b3767fc9e45"
    static let highresSourceWeightsSHA256 = "03de2f77281974f5084cdd8652ace2b55dc15ac0378aed66654e62537cdda255"
    static let rawCanonicalResourceName = "KoharuHighres648FP16"
    static let inputSide = 648
    static let maskSide = 162
    static let queryCount = 300
    static let logitClassCount = 5
    static let selectedCount = 160
    static let strictStockDeviceParityPassed = false
    static let licenseIdentifier = "Apache-2.0"
    static let licenseNotice = "Model and RF-DETR software Apache-2.0; Manga109 training images retain their separate terms."

    struct OCRProducer: Equatable, Sendable {
        let resourceName: String
        let weightsSHA256: String
        let revision: String
        var maximumMaskQueries = 160
        var retainAllQueryMasks = false

        func modelURL(bundle: Bundle = .main) throws -> URL {
            guard let url = bundle.url(forResource: resourceName, withExtension: "mlmodelc") else {
                throw NativeRFDETRLayoutError.modelUnavailable
            }
            return url
        }
    }
    static let auxiliaryOCR = OCRProducer(resourceName: resourceName, weightsSHA256: sourceWeightsSHA256, revision: sourceRevision)
    static let rawCanonicalOCR = OCRProducer(resourceName: rawCanonicalResourceName,
        weightsSHA256: highresSourceWeightsSHA256, revision: highresSourceRevision)

    static func bundledModelURL(bundle: Bundle = .main) throws -> URL { try auxiliaryOCR.modelURL(bundle: bundle) }
    static func rawCanonicalModelURL(bundle: Bundle = .main) throws -> URL { try rawCanonicalOCR.modelURL(bundle: bundle) }
}

/// Upright, original-resolution, tightly packed RGB8 in source top-left order.
/// The caller must use the same upright canvas passed to OCR/rendering. A page
/// name/URL alone is not a cache identity; all original RGB bytes are hashed.
struct NativeRFDETRSourceImage: Sendable {
    let width: Int
    let height: Int
    let rgb: Data
    private let preparedIdentity: String?

    init(width: Int, height: Int, rgb: Data) throws {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= 16_777_216 / height else {
            throw NativeRFDETRLayoutError.sourceImageTooLarge
        }
        guard rgb.count == width * height * 3 else { throw NativeRFDETRLayoutError.invalidImage }
        self.width = width
        self.height = height
        self.rgb = rgb
        self.preparedIdentity = nil
    }

    private init(copying source: Self, identity: String) {
        width = source.width
        height = source.height
        rgb = source.rgb
        preparedIdentity = identity
    }

    /// Bind one computed digest to the immutable pixels for a detector or render transaction.
    func withPreparedIdentity() -> Self {
        if preparedIdentity != nil { return self }
        return Self(copying: self, identity: identity)
    }

    var identity: String {
        if let preparedIdentity { return preparedIdentity }
        return rgb.withUnsafeBytes { Self.identity(width: width, height: height, packedRGB: $0) }
    }

    fileprivate static func identity(width: Int, height: Int, packedRGB: UnsafeRawBufferPointer) -> String {
        var hash = SHA256()
        hash.update(data: Data("rf648-rgb8-v1:\(width)x\(height):".utf8))
        hash.update(bufferPointer: packedRGB)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// No resize here. Decode onto an opaque sRGB source canvas; alpha is
    /// composited on white. RGB8 callers can avoid a second color conversion.
    fileprivate static func withCanonicalRGBA<T>(_ image: CGImage, _ body: (UnsafeRawBufferPointer) throws -> T) throws -> T {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= 16_777_216 / height,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw NativeRFDETRLayoutError.sourceImageTooLarge
        }
        var rgba = Data(count: width * height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw NativeRFDETRLayoutError.invalidImage
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Match NativeOCRCGImageAdapter's original CGImage row order.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try rgba.withUnsafeBytes(body)
    }

    static func decode(_ image: CGImage) throws -> Self {
        let width = image.width, height = image.height
        return try withCanonicalRGBA(image) { source in
            var rgb = Data(count: width * height * 3)
            rgb.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                for i in 0..<(width * height) {
                    target[i * 3] = source[i * 4]
                    target[i * 3 + 1] = source[i * 4 + 1]
                    target[i * 3 + 2] = source[i * 4 + 2]
                }
            }
            return try Self(width: width, height: height, rgb: rgb)
        }
    }
}

/// Only inference needs these three read-only operations. Renderer callers retain packed Data.
protocol NativeRFDETRInferenceSource: Sendable {
    var width: Int { get }
    var height: Int { get }
    var identity: String { get }
    func withPackedRGB<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T
}

extension NativeRFDETRSourceImage: NativeRFDETRInferenceSource {
    func withPackedRGB<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try rgb.withUnsafeBytes(body)
    }
}

/// The fourth byte per pixel has address space reserved but is left uninitialized
/// through RF inference. Array copy-on-write protects any outstanding RF reader.
struct NativeRFOCRPackedSource: NativeRFDETRInferenceSource {
    let width: Int
    let height: Int
    let identity: String
    private var bytes: [UInt8]

    init(_ image: CGImage, verified: NativeRFOCRSourceReuse.VerifiedIdentity? = nil) throws {
        width = image.width
        height = image.height
        bytes = try NativeRFDETRSourceImage.withCanonicalRGBA(image) { input in
            let count = image.width * image.height
            return try [UInt8](unsafeUninitializedCapacity: count * 4) { output, initialized in
                var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: input.baseAddress!),
                    height: vImagePixelCount(image.height), width: vImagePixelCount(image.width),
                    rowBytes: image.width * 4)
                var destination = vImage_Buffer(data: output.baseAddress!, height: source.height,
                    width: source.width, rowBytes: image.width * 3)
                guard vImageConvert_RGBA8888toRGB888(&source, &destination, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                    throw NativeRFDETRLayoutError.invalidImage
                }
                initialized = count * 3
            }
        }
        identity = verified?.value(for: image) ?? bytes.withUnsafeBytes {
            NativeRFDETRSourceImage.identity(width: image.width, height: image.height, packedRGB: $0)
        }
    }

    func withPackedRGB<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try bytes.withUnsafeBytes(body)
    }

    /// The packed snapshot stays immutable to other owners even if another task still holds it.
    consuming func rgbaBytes() throws -> [UInt8] {
        let count = width * height
        bytes.append(contentsOf: repeatElement(255, count: count))
        try bytes.withUnsafeMutableBytes { (pixels: UnsafeMutableRawBufferPointer) in
            var end = count
            while end >= 4 {
                // Read [3*start,3*end) and write [4*start,4*end). The two intervals are disjoint.
                let start = (3 * end + 3) / 4
                let length = end - start
                var source = vImage_Buffer(data: pixels.baseAddress! + 3 * start,
                    height: 1, width: vImagePixelCount(length), rowBytes: 3 * length)
                var destination = vImage_Buffer(data: pixels.baseAddress! + 4 * start,
                    height: 1, width: source.width, rowBytes: 4 * length)
                guard vImageConvert_RGB888toRGBA8888(&source, nil, 255, &destination, false,
                    vImage_Flags(kvImageDoNotTile)) == kvImageNoError else {
                    throw NativeRFDETRLayoutError.invalidImage
                }
                end = start
            }
            while end > 0 {
                end -= 1
                let r = pixels[3 * end], g = pixels[3 * end + 1], b = pixels[3 * end + 2]
                pixels[4 * end] = r
                pixels[4 * end + 1] = g
                pixels[4 * end + 2] = b
                pixels[4 * end + 3] = 255
            }
        }
        return bytes
    }
}

/// Share the canonical RF pixels and digest only within ONE serial Reader OCR
/// call. The detector actor explicitly captures this scope before detaching.
/// No model outputs are shared across the two independent RF model contracts.
final class NativeRFOCRSourceReuse: @unchecked Sendable {
    /// The initial evidence lease attests to the exact upright CGImage without retaining its pixels.
    struct VerifiedIdentity: Sendable {
        private weak var original: CGImage?
        let digest: String

        init(original: CGImage) throws {
            self.init(original: original, digest: try NativeRFDETRSourceImage.decode(original).identity)
        }

        fileprivate init(original: CGImage, digest: String) {
            self.original = original
            self.digest = digest
        }

        func value(for image: CGImage) -> String? { original === image ? digest : nil }
    }

    @TaskLocal static var leasedIdentity: VerifiedIdentity?
    @TaskLocal static var active: NativeRFOCRSourceReuse?
    private let lock = NSLock()
    private weak var original: CGImage?
    private var prepared: NativeRFOCRPackedSource?
    private var preparedIdentity: VerifiedIdentity?
    private var mayPreparePixels = true

    init(original: CGImage) {
        self.original = original
        if let lease = Self.leasedIdentity, lease.value(for: original) != nil { preparedIdentity = lease }
    }

    func source(for image: CGImage, consume: Bool = false) throws -> NativeRFOCRPackedSource {
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        guard mayPreparePixels, original === image else { return try NativeRFOCRPackedSource(image) }
        let canonical = try prepared ?? NativeRFOCRPackedSource(image, verified: preparedIdentity)
        if preparedIdentity == nil { preparedIdentity = VerifiedIdentity(original: image, digest: canonical.identity) }
        if consume {
            mayPreparePixels = false
            prepared = nil
        } else {
            prepared = canonical
        }
        return canonical
    }

    /// OCR has finished consuming pixels. Evidence publication still needs their canonical digest.
    func releasePixels() {
        lock.lock()
        defer { lock.unlock() }
        mayPreparePixels = false
        prepared = nil
    }

    func identity(for image: CGImage) -> String? { verifiedIdentity(for: image)?.digest }

    func verifiedIdentity(for image: CGImage) -> VerifiedIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return original === image ? preparedIdentity : nil
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        original = nil
        prepared = nil
        preparedIdentity = nil
    }
}

/// Compact raw mask logits, not a bbox crop, contour, glyph mask or pixel gold.
/// A sampled value is equivalent to align_corners=False bilinear expansion to
/// the original source dimensions followed by logit>0. All semantic classes
/// retain these arrays; absent masks indicate a documented budget cap.
struct NativeRFDETRLayoutMask: Sendable {
    let queryID: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let logits: [Float]

    var storageBytes: Int { logits.count * MemoryLayout<Float>.size }

    func contains(sourceX: Int, sourceY: Int) -> Bool {
        contains(sourceX: sourceX, sourceY: sourceY, decisionLogitThreshold: 0)
    }

    func contains(sourceX: Int, sourceY: Int, decisionLogitThreshold: Float) -> Bool {
        guard sourceX >= 0, sourceY >= 0, sourceX < sourceWidth, sourceY < sourceHeight,
              logits.count == NativeRFDETRLayoutResource.maskSide * NativeRFDETRLayoutResource.maskSide else { return false }
        let side = NativeRFDETRLayoutResource.maskSide
        let x = max(0, (Float(sourceX) + 0.5) * Float(side) / Float(sourceWidth) - 0.5)
        let y = max(0, (Float(sourceY) + 0.5) * Float(side) / Float(sourceHeight) - 0.5)
        let x0 = min(side - 1, Int(x)), y0 = min(side - 1, Int(y))
        let x1 = min(side - 1, x0 + 1), y1 = min(side - 1, y0 + 1)
        let dx = x - Float(x0), dy = y - Float(y0)
        let top = logits[y0 * side + x0] * (1 - dx) + logits[y0 * side + x1] * dx
        let bottom = logits[y1 * side + x0] * (1 - dx) + logits[y1 * side + x1] * dx
        return top * (1 - dy) + bottom * dy > decisionLogitThreshold
    }

    /// An OUTER bound of possible bilinearly positive source-pixel centres.
    /// Not a contour, ownership certificate, detector-box clip or glyph mask.
    /// Nil means no useful bound: callers must execute the unchanged sampler.
    func conservativePositivePixelBounds() -> CGRect? {
        let side = NativeRFDETRLayoutResource.maskSide
        guard sourceWidth > 0, sourceHeight > 0, sourceWidth <= 16_384, sourceHeight <= 16_384,
              logits.count == side * side else { return nil }
        // Two positive opposite corners already imply a full-page outer bound.
        // Returning nil is safe even if other cells are invalid: no skip occurs.
        if logits[0] > 0 && logits[side * side - 1] > 0 { return nil }
        var left = side, top = side, right = -1, bottom = -1
        for index in logits.indices {
            let value = logits[index]
            guard value.isFinite else { return nil }
            if value > 0 {
                let x = index % side, y = index / side
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
                if left == 0 && top == 0 && right == side - 1 && bottom == side - 1 {
                    return nil // Whole-page bound cannot skip a query.
                }
            }
        }
        guard right >= left else { return .zero }
        // Same Float32 operation order as contains(sourceX:sourceY:).
        func indices(_ source: Int, dimension: Int) -> (Int, Int) {
            let value = max(0, (Float(source) + 0.5) * Float(side) / Float(dimension) - 0.5)
            let first = min(side - 1, Int(value))
            return (first, min(side - 1, first + 1))
        }
        func lowerBound(_ dimension: Int, predicate: (Int) -> Bool) -> Int {
            var lo = 0, hi = dimension
            while lo < hi {
                let middle = lo + (hi - lo) / 2
                if predicate(middle) { hi = middle } else { lo = middle + 1 }
            }
            return lo
        }
        // A positive interpolant requires a positive corner. Including zero-
        // weight corners is conservative and avoids a floating-point epsilon.
        let x0 = lowerBound(sourceWidth) { indices($0, dimension: sourceWidth).1 >= left }
        let x1 = lowerBound(sourceWidth) { indices($0, dimension: sourceWidth).0 > right }
        let y0 = lowerBound(sourceHeight) { indices($0, dimension: sourceHeight).1 >= top }
        let y1 = lowerBound(sourceHeight) { indices($0, dimension: sourceHeight).0 > bottom }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Explicit bounded source-pixel ROI; no full-page mask allocation.
    func rasterize(sourceBounds: CGRect, maximumPixels: Int = 1_048_576) throws -> NativeRFDETRMaskRaster {
        guard !sourceBounds.isNull, !sourceBounds.isInfinite,
              [sourceBounds.minX, sourceBounds.minY, sourceBounds.maxX, sourceBounds.maxY].allSatisfy({ $0.isFinite }) else {
            throw NativeRFDETRLayoutError.invalidImage
        }
        let bounded = sourceBounds.intersection(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        guard !bounded.isNull, !bounded.isEmpty else {
            return NativeRFDETRMaskRaster(sourceBounds: .zero, width: 0, height: 0, bytes: Data())
        }
        let left = max(0, Int(floor(bounded.minX))), top = max(0, Int(floor(bounded.minY)))
        let right = min(sourceWidth, Int(ceil(bounded.maxX))), bottom = min(sourceHeight, Int(ceil(bounded.maxY)))
        let width = right - left, height = bottom - top
        guard maximumPixels > 0, width <= maximumPixels / height else { throw NativeRFDETRLayoutError.maskRasterTooLarge }
        var bytes = Data(count: width * height)
        bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for y in 0..<height {
                for x in 0..<width { buffer[y * width + x] = contains(sourceX: left + x, sourceY: top + y) ? 1 : 0 }
            }
        }
        return NativeRFDETRMaskRaster(sourceBounds: CGRect(x: left, y: top, width: width, height: height),
                                     width: width, height: height, bytes: bytes)
    }
}

struct NativeRFDETRMaskRaster: Sendable {
    let sourceBounds: CGRect
    let width: Int
    let height: Int
    let bytes: Data
}

struct NativeRFDETRLayoutPrimitive: Sendable {
    let queryID: Int
    let semanticClass: NativeRFDETRLayoutClass
    let confidence: Float
    /// Unclipped top-left normalized rectangle, NOT Vision bottom-left space.
    let normalizedBounds: CGRect
    /// Original upright source pixels. Retaining boxes never alters OCR owners.
    let sourceBounds: CGRect
    let mask: NativeRFDETRLayoutMask?
    /// Exact support after a local-coordinate transform; sourceBounds is only its envelope.
    var supportPolygon: [CGPoint]? = nil
}

/// All query hypotheses before stock class acceptance. A mask is shared with
/// retained queries when available; weak unretained hypotheses remain box-only.
final class NativeRFImmutableMaskBank: Sendable {
    let bytes: Data
    let width: Int
    let height: Int
    static let cells = 162 * 162

    init(bytes: Data, width: Int, height: Int) {
        precondition(bytes.count == 300 * Self.cells * MemoryLayout<Float>.size)
        self.bytes = bytes
        self.width = width
        self.height = height
    }

    func withPlane<T>(queryID: Int, _ body: (UnsafeBufferPointer<Float>) -> T) -> T {
        bytes.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: Float.self)
            let start = input.baseAddress! + queryID * Self.cells
            return body(UnsafeBufferPointer(start: start, count: Self.cells))
        }
    }
}

struct NativeRFDETRClassEvidence: Sendable {
    let queryID: Int
    let logits: [Float]
    let probabilities: [Float]
    let normalizedBounds: CGRect
    let sourceBounds: CGRect
    let mask: NativeRFDETRLayoutMask?
}

/// A raw query returned through the regular API owns its mask array. Only the
/// page-wide segmentation reader takes a shared bank, as part of its inventory.
private final class NativeRFDeferredQueryInventory: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [NativeRFDETRClassEvidence]
    private var bank: NativeRFImmutableMaskBank?

    init(_ queries: [NativeRFDETRClassEvidence], bank: NativeRFImmutableMaskBank) {
        self.queries = queries
        self.bank = bank
    }

    func read(detaching: Bool) -> (queries: [NativeRFDETRClassEvidence], bank: NativeRFImmutableMaskBank?) {
        lock.lock()
        defer { lock.unlock() }
        if detaching, let bank {
            queries = queries.map { query in
                guard query.mask == nil else { return query }
                let mask = NativeRFDETRLayoutMask(queryID: query.queryID, sourceWidth: bank.width,
                    sourceHeight: bank.height, logits: bank.withPlane(queryID: query.queryID) { Array($0) })
                return NativeRFDETRClassEvidence(queryID: query.queryID, logits: query.logits,
                    probabilities: query.probabilities, normalizedBounds: query.normalizedBounds,
                    sourceBounds: query.sourceBounds, mask: mask)
            }
            self.bank = nil
        }
        return (queries, bank)
    }
}

struct NativeRFDETRLayoutResult: Sendable {
    let imageIdentity: String
    let sourceWidth: Int
    let sourceHeight: Int
    let primitives: [NativeRFDETRLayoutPrimitive]
    let maskQueriesOmittedByBudget: Int
    let preprocessingMilliseconds: Double
    let modelMilliseconds: Double
    let decodeMilliseconds: Double
    let computeUnits: String
    let fromCache: Bool
    private var ordinaryQueries: [NativeRFDETRClassEvidence]
    private var deferredQueries: NativeRFDeferredQueryInventory?
    var classEvidence: [NativeRFDETRClassEvidence] {
        get { deferredQueries?.read(detaching: true).queries ?? ordinaryQueries }
        set { ordinaryQueries = newValue; deferredQueries = nil }
    }

    var pixelInventory: (queries: [NativeRFDETRClassEvidence], bank: NativeRFImmutableMaskBank?) {
        deferredQueries?.read(detaching: false) ?? (ordinaryQueries, nil)
    }

    init(imageIdentity: String, sourceWidth: Int, sourceHeight: Int,
         primitives: [NativeRFDETRLayoutPrimitive], maskQueriesOmittedByBudget: Int,
         preprocessingMilliseconds: Double, modelMilliseconds: Double, decodeMilliseconds: Double,
         computeUnits: String, fromCache: Bool, classEvidence: [NativeRFDETRClassEvidence] = [],
         semanticGrid: NativeRFDETRSemanticGrid? = nil, sourceSupportGrid: NativeRFDETRSourceSupportGrid? = nil,
         maskBank: NativeRFImmutableMaskBank? = nil) {
        self.imageIdentity = imageIdentity
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.primitives = primitives
        self.maskQueriesOmittedByBudget = maskQueriesOmittedByBudget
        self.preprocessingMilliseconds = preprocessingMilliseconds
        self.modelMilliseconds = modelMilliseconds
        self.decodeMilliseconds = decodeMilliseconds
        self.computeUnits = computeUnits
        self.fromCache = fromCache
        self.semanticGrid = semanticGrid
        self.sourceSupportGrid = sourceSupportGrid
        if let maskBank {
            ordinaryQueries = []
            deferredQueries = NativeRFDeferredQueryInventory(classEvidence, bank: maskBank)
        } else {
            ordinaryQueries = classEvidence
        }
    }
    var semanticGrid: NativeRFDETRSemanticGrid? = nil
    var sourceSupportGrid: NativeRFDETRSourceSupportGrid? = nil
    var strictStockDeviceParityPassed: Bool { NativeRFDETRLayoutResource.strictStockDeviceParityPassed }
    var isAuxiliaryEvidence: Bool { true }
    var maskStorageBytes: Int {
        // Conservative accounting when a query supplies more than one class.
        primitives.reduce(0) { $0 + ($1.mask?.storageBytes ?? 0) }
    }

    /// All-query segmentation evidence can exceed the accepted-layout masks.
    /// Count shared query storage once so cache admission cannot hide it.
    var evidenceStorageBytes: Int {
        var bytes: [Int: Int] = [:]
        for primitive in primitives {
            if let mask = primitive.mask { bytes[mask.queryID] = mask.storageBytes }
        }
        let inventory = pixelInventory
        for evidence in inventory.queries {
            if let mask = evidence.mask { bytes[mask.queryID] = mask.storageBytes }
        }
        return (inventory.bank?.bytes.count ?? 0) + bytes.values.reduce(0, +) + ((semanticGrid?.probabilities.count ?? 0)
            + (semanticGrid?.weightedMeanProbabilities?.count ?? 0)
            + (sourceSupportGrid?.native17Fields.count ?? 0)) * MemoryLayout<Float>.size
    }
}

struct NativeRFDETRBalloonOwner: Sendable {
    let sourceBounds: CGRect
    let queryID: Int?
    let fullyOutsideQueries: Set<Int>
}

struct NativeRFDETROwnerResolution: Sendable {
    /// exact, ieeePixelEdge, compositeEnvelope, unresolved, identityMismatch.
    let kind: String
    let queryID: Int?
    let memberIndices: [Int]
    let fullyOutsideQueries: Set<Int>
    let reason: String
}

struct NativeRFDETRMergeDecision: Sendable {
    let veto: Bool
    let first: NativeRFDETROwnerResolution
    let second: NativeRFDETROwnerResolution
    /// veto, sameOwner, unresolvedOwner, outsideNotProven, identityMismatch.
    let outcome: String
}

/// All inconclusive/budget-limited cases leave the existing merge policy alone.
/// Same predicted ownership never forces a merge. Distinct owners veto only
/// when each expanded OCR rectangle is wholly outside the other's mask.
struct NativeRFDETRBalloonOwnership: Sendable {
    let imageIdentity: String
    let owners: [NativeRFDETRBalloonOwner]
    let verifiedPixelTests: Int

    func vetoesMerge(first: CGRect, second: CGRect) -> Bool {
        mergeDecision(first: first, second: second, imageIdentity: imageIdentity).veto
    }

    /// Parent logs outcomes and resolution kinds from ACTUAL callbacks. These
    /// counters cannot be inferred from a ledger or a synthetic replay.
    func mergeDecision(first: CGRect, second: CGRect, imageIdentity expectedIdentity: String) -> NativeRFDETRMergeDecision {
        let a = resolve(sourceBounds: first, imageIdentity: expectedIdentity)
        let b = resolve(sourceBounds: second, imageIdentity: expectedIdentity)
        let outcome: String
        if expectedIdentity != imageIdentity { outcome = "identityMismatch" }
        else if let aq = a.queryID, let bq = b.queryID {
            if aq == bq { outcome = "sameOwner" }
            else if a.fullyOutsideQueries.contains(bq) && b.fullyOutsideQueries.contains(aq) { outcome = "veto" }
            else { outcome = "outsideNotProven" }
        } else { outcome = "unresolvedOwner" }
        return .init(veto: outcome == "veto", first: a, second: b, outcome: outcome)
    }

    /// NO IoU, centre-distance, nearest-owner or arbitrary pixel epsilon.
    /// Only integer pixel edges within8 IEEE ULPs may canonicalize a normalized
    /// coordinate's multiply/divide round trip. Noninteger edges remain exact.
    /// Aggregate rectangles must be EXACT envelopes of ledger members, all in
    /// one unambiguous balloon. Partial foreign intersections always abstain.
    func resolve(sourceBounds: CGRect, imageIdentity expectedIdentity: String) -> NativeRFDETROwnerResolution {
        func unresolved(_ reason: String, kind: String = "unresolved") -> NativeRFDETROwnerResolution {
            .init(kind: kind, queryID: nil, memberIndices: [], fullyOutsideQueries: [], reason: reason)
        }
        guard expectedIdentity == imageIdentity else { return unresolved("stalePageIdentity", kind: "identityMismatch") }
        guard owners.count <= 256, let request = canonical(sourceBounds) else { return unresolved("invalidGeometry") }
        let keys = owners.map { canonical($0.sourceBounds) }
        guard keys.allSatisfy({ $0 != nil }) else { return unresolved("invalidLedgerGeometry") }
        let direct = owners.indices.filter { keys[$0] == request }
        var members = direct
        var kind = direct.contains(where: { owners[$0].sourceBounds == sourceBounds }) ? "exact" : "ieeePixelEdge"
        if members.isEmpty {
            kind = "compositeEnvelope"
            for i in owners.indices {
                let member = keys[i]!
                if request.contains(member) { members.append(i) }
                else if request.intersects(member) { return unresolved("partialLedgerMemberIntersection") }
            }
            guard members.count >= 2, members.reduce(CGRect.null, { $0.union(keys[$1]!) }) == request else {
                return unresolved("notExactLedgerEnvelope")
            }
        }
        guard let first = members.first, let query = owners[first].queryID,
              members.allSatisfy({ owners[$0].queryID == query }) else { return unresolved("missingOrMixedBalloonOwnership") }
        // A coincident direct rectangle must not conceal an intersecting
        // foreign/inconclusive ledger member, including duplicate-box classes.
        for i in owners.indices where !members.contains(i) && request.intersects(keys[i]!) {
            guard owners[i].queryID == query, request.contains(keys[i]!) else {
                return unresolved("foreignOrPartialLedgerMember")
            }
            members.append(i)
        }
        let outside = members.reduce(owners[first].fullyOutsideQueries) { $0.intersection(owners[$1].fullyOutsideQueries) }
        return .init(kind: kind, queryID: query, memberIndices: members.sorted(), fullyOutsideQueries: outside,
                     reason: "exactSourceLedgerMembership")
    }

    private func canonical(_ rect: CGRect) -> CGRect? {
        guard !rect.isNull, !rect.isEmpty, !rect.isInfinite,
              [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 16_384 }) else { return nil }
        func edge(_ value: CGFloat) -> CGFloat {
            let integer = value.rounded()
            return abs(value - integer) <= 8 * max(value.ulp, integer.ulp) ? integer : value
        }
        let x = edge(rect.minX), y = edge(rect.minY), right = edge(rect.maxX), bottom = edge(rect.maxY)
        guard right > x, bottom > y else { return nil }
        return CGRect(x: x, y: y, width: right - x, height: bottom - y)
    }
}

struct NativeRFDETRBalloonEligibility: Sendable {
    let imageIdentity: String
    let primitive: NativeRFDETRLayoutPrimitive
    let originalSourceBounds: [CGRect]
    /// Model-mask coverage is NOT physical source contour verification.
    var requiresNativeSourceContourVerification: Bool { true }
}

struct NativeRFDETRVerifiedContourHint: Sendable {
    let imageIdentity: String
    let queryID: Int
    let sourcePolygon: [CGPoint]
    let normalizedPolygon: [CGPoint]
    let originalSourceBounds: [CGRect]
    /// Actual source verification is supplied by parent, never inferred from
    /// confidence, parity, rectangle coverage or this helper's polygon test.
    let nativeSourceContourVerified: Bool
}

/// Experimental placement evidence, not an erasure domain or source contour.
/// Parent must preserve every original OCR owner and apply native placement /
/// protected-artwork checks before using the extra room for translated text.
struct NativeRFDETRPlacementHint: Sendable {
    let imageIdentity: String
    let balloonQueryID: Int
    let textQueryIDs: [Int]
    let frameQueryID: Int?
    let originalSourceBounds: [CGRect]
    let sourcePlacementBounds: CGRect
    let normalizedPlacementBounds: CGRect
    let verifiedPixelTests: Int
    var sourceSurfaceEvidence: NativeRFDETRSurfaceEvidence?
    var nativeSourceContourVerified: Bool { false }
}

struct NativeRFDETRSurfaceEvidence: Sendable {
    let representativeRGB: [UInt8]
    let ringSamples: Int
    let matchingRingFraction: Double
    let testedPixels: Int
    /// Uniform observed source pixels are not a complete balloon contour.
    var isCompleteSourceContour: Bool { false }
}

/// Pairwise evidence only; never a transitive grouping or OCR replacement.
struct NativeRFDETRGroupingHint: Sendable {
    let firstIndex: Int
    let secondIndex: Int
    let balloonQueryID: Int
    let textQueryID: Int
}

enum NativeRFDETRLayoutApplication {
    struct BalloonContour: Sendable {
        let queryID: Int
        let confidence: Float
        let rect: CGRect
        let center: CGPoint
        let spans: [Double]
    }

    /// Layout evidence from the segmentation mask itself. A detector rectangle
    /// is insufficient, and this estimate never authorizes source erasure.
    static func balloonContour(sourceBounds: [CGRect], result: NativeRFDETRLayoutResult) -> BalloonContour? {
        guard !sourceBounds.isEmpty, result.sourceWidth > 0, result.sourceHeight > 0 else { return nil }
        let page = CGRect(x: 0, y: 0, width: result.sourceWidth, height: result.sourceHeight)
        guard sourceBounds.allSatisfy({ !$0.isEmpty && !$0.isNull && page.contains($0) }) else { return nil }
        let union = sourceBounds.reduce(CGRect.null) { $0.union($1) }
        var matches: [(NativeRFDETRLayoutPrimitive, Double)] = []
        for body in result.primitives where body.semanticClass == .balloon && body.confidence >= 0.5 {
            guard let mask = body.mask, mask.sourceWidth == result.sourceWidth,
                  mask.sourceHeight == result.sourceHeight,
                  mask.contains(sourceX: Int(union.midX), sourceY: Int(union.midY)) else { continue }
            var covered = 0
            for source in sourceBounds {
                for y in 0..<5 { for x in 0..<5 {
                    if mask.contains(sourceX: Int(source.minX + (CGFloat(x) + 0.5) * source.width / 5),
                                     sourceY: Int(source.minY + (CGFloat(y) + 0.5) * source.height / 5)) { covered += 1 }
                } }
            }
            let coverage = Double(covered) / Double(sourceBounds.count * 25)
            if coverage >= 0.8 { matches.append((body, coverage)) }
        }
        matches.sort { $0.1 == $1.1 ? $0.0.confidence > $1.0.confidence : $0.1 > $1.1 }
        guard let selected = matches.first, let mask = selected.0.mask else { return nil }
        // Overlapping competing predictions are ambiguous; preserve the native fallback.
        if matches.count > 1, matches[1].1 >= selected.1 - 0.04,
           matches[1].0.confidence >= selected.0.confidence - 0.05 { return nil }
        let side = NativeRFDETRLayoutResource.maskSide
        var bands: [(Double, Double)?] = Array(repeating: nil, count: side)
        let ownerX = Double(union.midX) / Double(result.sourceWidth)
        for y in 0..<side {
            var runs: [(Double, Double)] = [], start: Int?
            let sourceY = min(result.sourceHeight - 1, Int((Double(y) + 0.5) * Double(result.sourceHeight) / Double(side)))
            for x in 0...side {
                let sourceX = min(result.sourceWidth - 1, Int((Double(x) + 0.5) * Double(result.sourceWidth) / Double(side)))
                let inside = x < side && mask.contains(sourceX: sourceX, sourceY: sourceY)
                if inside, start == nil { start = x }
                if !inside, let begin = start {
                    // One cell of inset absorbs interpolation and low-resolution boundary uncertainty.
                    if x - begin > 2 { runs.append((Double(begin + 1) / Double(side), Double(x - 1) / Double(side))) }
                    start = nil
                }
            }
            bands[y] = runs.first(where: { $0.0 <= ownerX && ownerX <= $0.1 }) ?? runs.max(by: { $0.1 - $0.0 < $1.1 - $1.0 })
        }
        let seed = min(side - 1, max(0, Int(Double(union.midY) / Double(result.sourceHeight) * Double(side))))
        guard bands[seed] != nil else { return nil }
        func connected(_ a: Int, _ b: Int) -> Bool {
            guard let first = bands[a], let second = bands[b] else { return false }
            return min(first.1, second.1) > max(first.0, second.0)
        }
        var top = seed, bottom = seed
        while top > 0 && connected(top, top - 1) { top -= 1 }
        while bottom + 1 < side && connected(bottom, bottom + 1) { bottom += 1 }
        guard bottom - top >= 3 else { return nil }
        let rows = (top...bottom).compactMap { bands[$0] }
        let left = rows.map(\.0).min()!, right = rows.map(\.1).max()!
        let rect = CGRect(x: left, y: Double(top) / Double(side), width: right - left,
                          height: Double(bottom - top + 1) / Double(side))
        let maximumWidth = rows.map { $0.1 - $0.0 }.max()!
        var mass = 0.0, weightedY = 0.0
        for (offset, row) in rows.enumerated() where row.1 - row.0 >= maximumWidth * 0.65 {
            let width = row.1 - row.0
            mass += width; weightedY += (Double(top + offset) + 0.5) / Double(side) * width
        }
        return BalloonContour(queryID: selected.0.queryID, confidence: selected.0.confidence, rect: rect,
            center: CGPoint(x: ownerX, y: weightedY / mass), spans: rows.flatMap { [$0.0, $0.1] })
    }

    /// Refine a saved mask-verified proposal WITHOUT another model inference.
    /// Uses original RGB only, never silver labels or rendered/composite pixels.
    /// The source ring must have one strongly supported color; new strips must
    /// agree with that observed color and avoid sharp local source edges.
    /// Still experimental: parent native protection/containment gates remain.
    static func sourceSupportedPlacementHint(_ proposal: NativeRFDETRPlacementHint, source: NativeRFDETRSourceImage,
                                             maximumPixelTests: Int = 1_048_576) -> NativeRFDETRPlacementHint? {
        guard proposal.imageIdentity == source.identity, !proposal.originalSourceBounds.isEmpty,
              maximumPixelTests >= 32 else { return nil }
        let union = proposal.originalSourceBounds.reduce(CGRect.null) { $0.union($1) }
        let base = union.insetBy(dx: -2, dy: -2).integral
        let target = proposal.sourcePlacementBounds
        let imageBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        guard imageBounds.contains(base), imageBounds.contains(target), target.contains(base),
              [target.minX, target.minY, target.maxX, target.maxY].allSatisfy(\.isFinite) else { return nil }
        return source.rgb.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func rgb(_ x: Int, _ y: Int) -> [UInt8] {
                let i = (y * source.width + x) * 3
                return [bytes[i], bytes[i + 1], bytes[i + 2]]
            }
            let left = Int(base.minX), right = Int(base.maxX), top = Int(base.minY), bottom = Int(base.maxY)
            let perimeter = 2 * (right - left) + 2 * max(0, bottom - top - 2)
            guard perimeter >= 32, perimeter <= maximumPixelTests / 2 else { return nil }
            var ring: [[UInt8]] = []
            for x in left..<right { ring.append(rgb(x, top)); ring.append(rgb(x, bottom - 1)) }
            if bottom - top > 2 {
                for y in (top + 1)..<(bottom - 1) { ring.append(rgb(left, y)); ring.append(rgb(right - 1, y)) }
            }
            func key(_ pixel: [UInt8]) -> Int { Int(pixel[0] / 32) * 64 + Int(pixel[1] / 32) * 8 + Int(pixel[2] / 32) }
            var bins: [Int: Int] = [:]
            for pixel in ring { bins[key(pixel), default: 0] += 1 }
            guard let mode = bins.keys.sorted().max(by: { bins[$0]! < bins[$1]! }),
                  Double(bins[mode]!) / Double(ring.count) >= 0.70 else { return nil }
            let modal = ring.filter { key($0) == mode }
            let color = (0..<3).map { c in modal.map { $0[c] }.sorted()[modal.count / 2] }
            func agrees(_ pixel: [UInt8]) -> Bool {
                (0..<3).allSatisfy { abs(Int(pixel[$0]) - Int(color[$0])) <= 24 }
            }
            let fraction = Double(ring.filter(agrees).count) / Double(ring.count)
            guard fraction >= 0.90 else { return nil }
            var rect = base, tested = ring.count, active = [true, true, true, true]
            func supported(_ strip: CGRect) -> Bool {
                let count = Int(strip.width * strip.height)
                guard target.contains(strip), count <= maximumPixelTests - tested else { return false }
                tested += count
                for y in Int(strip.minY)..<Int(strip.maxY) {
                    for x in Int(strip.minX)..<Int(strip.maxX) {
                        let value = rgb(x, y)
                        if !agrees(value) { return false }
                        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                            where nx >= 0 && ny >= 0 && nx < source.width && ny < source.height {
                            let neighbor = rgb(nx, ny)
                            if (0..<3).contains(where: { abs(Int(value[$0]) - Int(neighbor[$0])) > 48 }) { return false }
                        }
                    }
                }
                return true
            }
            // Never grow beyond the already mask-verified bounded rectangle.
            for _ in 0..<128 {
                for edge in 0..<4 where active[edge] {
                    let strip: CGRect
                    switch edge {
                    case 0: strip = CGRect(x: rect.minX - 1, y: rect.minY, width: 1, height: rect.height)
                    case 1: strip = CGRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height)
                    case 2: strip = CGRect(x: rect.minX, y: rect.minY - 1, width: rect.width, height: 1)
                    default: strip = CGRect(x: rect.minX, y: rect.maxY, width: rect.width, height: 1)
                    }
                    if supported(strip) { rect = rect.union(strip) } else { active[edge] = false }
                }
                if !active.contains(true) { break }
            }
            guard rect.width > base.width || rect.height > base.height else { return nil }
            var hint = NativeRFDETRPlacementHint(imageIdentity: proposal.imageIdentity, balloonQueryID: proposal.balloonQueryID,
                textQueryIDs: proposal.textQueryIDs, frameQueryID: proposal.frameQueryID,
                originalSourceBounds: proposal.originalSourceBounds, sourcePlacementBounds: rect,
                normalizedPlacementBounds: CGRect(x: rect.minX / CGFloat(source.width), y: rect.minY / CGFloat(source.height),
                    width: rect.width / CGFloat(source.width), height: rect.height / CGFloat(source.height)),
                verifiedPixelTests: proposal.verifiedPixelTests)
            hint.sourceSurfaceEvidence = NativeRFDETRSurfaceEvidence(representativeRGB: color, ringSamples: ring.count,
                matchingRingFraction: fraction, testedPixels: tested)
            return hint
        }
    }

    /// Call after grouping/interior extraction with original source bounds.
    /// Growth is bounded, all newly admitted pixels must be in the predicted
    /// balloon, and no extra pixel may enter another OCR/protection rectangle.
    /// A native verified contour, if available, remains the parent's authority.
    static func placementHint(sourceBounds: [CGRect], otherSourceBounds: [CGRect], result: NativeRFDETRLayoutResult,
                              maximumExpansionPixels: Int = 32, maximumPixelTests: Int = 1_048_576) -> NativeRFDETRPlacementHint? {
        guard maximumPixelTests > 1, maximumExpansionPixels > 0, maximumExpansionPixels <= 128,
              otherSourceBounds.count <= 512,
              let eligibility = eligibleBalloon(sourceBounds: sourceBounds, result: result,
                                                maximumPixelTests: maximumPixelTests / 2),
              let mask = eligibility.primitive.mask else { return nil }
        let union = sourceBounds.reduce(CGRect.null) { $0.union($1) }
        guard let initial = pixelBounds(union.insetBy(dx: -2, dy: -2), result: result) else { return nil }
        let blockers = otherSourceBounds.map { $0.insetBy(dx: -2, dy: -2) }
        guard blockers.allSatisfy({ pixelBounds($0, result: result) != nil }) else { return nil }
        var rect = CGRect(x: initial.left, y: initial.top, width: initial.width, height: initial.height)
        guard !blockers.contains(where: { $0.intersects(rect) }) else { return nil }
        // OCR may span multiple model-text boxes; these are evidence, never
        // replacement source bounds. Only explicit text (raw0), not SFX.
        let texts = result.primitives.filter {
            $0.semanticClass == .text && $0.confidence >= 0.75
        }
        let textIDs = texts.filter { text in sourceBounds.contains { text.sourceBounds.intersects($0) } }.map(\.queryID)
        let frames = result.primitives.filter {
            $0.semanticClass == .frame && $0.confidence >= 0.90 && $0.sourceBounds.contains(rect)
        }
        // Nested/duplicate frame boxes are not unambiguous frame ownership.
        guard frames.count <= 1 else { return nil }
        let frame = frames.first
        var remaining = maximumPixelTests / 2
        var tested = 0
        func admitted(_ candidate: CGRect) -> Bool {
            guard let bounds = pixelBounds(candidate, result: result), bounds.width <= remaining / bounds.height,
                  frame == nil || frame!.sourceBounds.contains(candidate) else { return false }
            remaining -= bounds.width * bounds.height
            tested += bounds.width * bounds.height
            for y in bounds.top..<(bounds.top + bounds.height) {
                for x in bounds.left..<(bounds.left + bounds.width) {
                    if !mask.contains(sourceX: x, sourceY: y) { return false }
                    if let frameMask = frame?.mask, !frameMask.contains(sourceX: x, sourceY: y) { return false }
                }
            }
            return true
        }
        guard admitted(rect) else { return nil }
        var active = [true, true, true, true]
        for _ in 0..<maximumExpansionPixels {
            for edge in 0..<4 where active[edge] {
                let strip: CGRect
                switch edge {
                case 0: strip = CGRect(x: rect.minX - 1, y: rect.minY, width: 1, height: rect.height)
                case 1: strip = CGRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height)
                case 2: strip = CGRect(x: rect.minX, y: rect.minY - 1, width: rect.width, height: 1)
                default: strip = CGRect(x: rect.minX, y: rect.maxY, width: rect.width, height: 1)
                }
                if blockers.contains(where: { $0.intersects(strip) }) || !admitted(strip) { active[edge] = false }
                else { rect = rect.union(strip) }
            }
            if !active.contains(true) { break }
        }
        guard rect.width > CGFloat(initial.width) || rect.height > CGFloat(initial.height) else { return nil }
        return NativeRFDETRPlacementHint(imageIdentity: result.imageIdentity, balloonQueryID: eligibility.primitive.queryID,
            textQueryIDs: Array(Set(textIDs)).sorted(), frameQueryID: frame?.queryID, originalSourceBounds: sourceBounds,
            sourcePlacementBounds: rect, normalizedPlacementBounds: CGRect(x: rect.minX / CGFloat(result.sourceWidth),
                y: rect.minY / CGFloat(result.sourceHeight), width: rect.width / CGFloat(result.sourceWidth),
                height: rect.height / CGFloat(result.sourceHeight)), verifiedPixelTests: tested)
    }

    /// Native semantic/orientation/speaker checks are mandatory AND gates.
    /// Same model balloon alone cannot promote a merge. Each proposal requires
    /// one unique raw0 text envelope covering BOTH complete OCR rectangles.
    static func groupingHints(sourceBounds: [CGRect], result: NativeRFDETRLayoutResult,
                              maximumPixelTests: Int = 1_048_576,
                              nativeAllowsPair: (Int, Int) -> Bool) -> [NativeRFDETRGroupingHint] {
        let ownership = independentBalloonOwnership(sourceBounds: sourceBounds, result: result,
                                                    maximumPixelTests: maximumPixelTests)
        guard ownership.owners.count == sourceBounds.count else { return [] }
        var remaining = maximumPixelTests - ownership.verifiedPixelTests
        var hints: [NativeRFDETRGroupingHint] = []
        for i in sourceBounds.indices {
            guard let balloon = ownership.owners[i].queryID else { continue }
            for j in sourceBounds.indices where j > i {
                guard ownership.owners[j].queryID == balloon, nativeAllowsPair(i, j) else { continue }
                let a = sourceBounds[i], b = sourceBounds[j]
                let gapX = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
                let gapY = max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))
                guard hypot(gapX, gapY) <= 1.5 * min(max(a.width, a.height), max(b.width, b.height)) else { continue }
                let union = a.union(b).insetBy(dx: -2, dy: -2)
                let texts = result.primitives.filter {
                    $0.semanticClass == .text && $0.confidence >= 0.75 && $0.sourceBounds.contains(union)
                }
                guard texts.count == 1 else { continue }
                guard let mask = result.primitives.first(where: { $0.semanticClass == .balloon && $0.queryID == balloon })?.mask,
                      let bounds = pixelBounds(union, result: result), bounds.width <= remaining / bounds.height else { continue }
                remaining -= bounds.width * bounds.height
                var corridorCovered = true
                for y in bounds.top..<(bounds.top + bounds.height) {
                    for x in bounds.left..<(bounds.left + bounds.width) where !mask.contains(sourceX: x, sourceY: y) {
                        corridorCovered = false
                    }
                }
                guard corridorCovered else { continue }
                // Reject a frame boundary crossing. This is supporting bbox
                // evidence, not a claim of native frame-contour verification.
                let frames = result.primitives.filter { $0.semanticClass == .frame && $0.confidence >= 0.90 }
                if frames.contains(where: { $0.sourceBounds.contains(a) != $0.sourceBounds.contains(b) }) { continue }
                hints.append(NativeRFDETRGroupingHint(firstIndex: i, secondIndex: j,
                    balloonQueryID: balloon, textQueryID: texts[0].queryID))
            }
        }
        return hints
    }

    /// Use the original OCR source rectangles in upright source pixels, before
    /// grouping. Precompute once; the existing `separated` closure ORs in veto.
    static func independentBalloonOwnership(sourceBounds: [CGRect], result: NativeRFDETRLayoutResult,
                                            minimumConfidence: Float = 0.90,
                                            maximumPixelTests: Int = 1_048_576) -> NativeRFDETRBalloonOwnership {
        guard sourceBounds.count <= 256, result.maskQueriesOmittedByBudget == 0,
              minimumConfidence.isFinite, minimumConfidence >= 0.90, maximumPixelTests > 0 else {
            return NativeRFDETRBalloonOwnership(imageIdentity: result.imageIdentity, owners: [], verifiedPixelTests: 0)
        }
        let candidates = balloons(result, minimumConfidence: minimumConfidence)
        var supportBounds: [Int: CGRect] = [:]
        var supportChecked = Set<Int>()
        var remaining = maximumPixelTests
        var owners: [NativeRFDETRBalloonOwner] = []
        for rect in sourceBounds {
            guard let bounds = pixelBounds(rect.insetBy(dx: -2, dy: -2), result: result) else {
                owners.append(NativeRFDETRBalloonOwner(sourceBounds: rect, queryID: nil, fullyOutsideQueries: []))
                continue
            }
            var inside: [Int] = [], outside = Set<Int>(), complete = true
            for (ordinal, candidate) in candidates.enumerated() {
                guard let mask = candidate.mask, bounds.width <= remaining / bounds.height else { complete = false; break }
                remaining -= bounds.width * bounds.height
                // Charge exactly as before, including skipped pixel proofs.
                // Never promote ownership that the caller's budget could not verify.
                if maximumPixelTests >= NativeRFDETRLayoutResource.maskSide * NativeRFDETRLayoutResource.maskSide {
                    let tested = CGRect(x: bounds.left, y: bounds.top, width: bounds.width, height: bounds.height)
                    if supportChecked.insert(ordinal).inserted {
                        supportBounds[ordinal] = mask.conservativePositivePixelBounds()
                    }
                    if let outer = supportBounds[ordinal], !outer.intersects(tested) {
                        outside.insert(candidate.queryID)
                        continue
                    }
                }
                var count = 0
                for y in bounds.top..<(bounds.top + bounds.height) {
                    for x in bounds.left..<(bounds.left + bounds.width) {
                        if mask.contains(sourceX: x, sourceY: y) { count += 1 }
                    }
                }
                if count == bounds.width * bounds.height { inside.append(candidate.queryID) }
                if count == 0 { outside.insert(candidate.queryID) }
            }
            owners.append(NativeRFDETRBalloonOwner(sourceBounds: rect,
                queryID: complete && inside.count == 1 ? inside[0] : nil,
                fullyOutsideQueries: complete ? outside : []))
        }
        return NativeRFDETRBalloonOwnership(imageIdentity: result.imageIdentity, owners: owners,
                                           verifiedPixelTests: maximumPixelTests - remaining)
    }

    /// Eligibility for a native source-derived contour, after existing native
    /// interiors. All member rectangles must share one unambiguous high-score
    /// mask, including2 source-pixel margin. No OCR rect/polygon is changed.
    static func eligibleBalloon(sourceBounds: [CGRect], result: NativeRFDETRLayoutResult,
                                maximumPixelTests: Int = 1_048_576) -> NativeRFDETRBalloonEligibility? {
        guard !sourceBounds.isEmpty else { return nil }
        let ownership = independentBalloonOwnership(sourceBounds: sourceBounds, result: result,
                                                    maximumPixelTests: maximumPixelTests)
        guard ownership.owners.count == sourceBounds.count,
              let query = ownership.owners.first?.queryID,
              ownership.owners.allSatisfy({ $0.queryID == query }),
              let primitive = balloons(result, minimumConfidence: 0.90).first(where: { $0.queryID == query }) else { return nil }
        return NativeRFDETRBalloonEligibility(imageIdentity: result.imageIdentity, primitive: primitive,
                                             originalSourceBounds: sourceBounds)
    }

    /// Parent supplies a CLOSED contour derived/verified from actual source
    /// pixels. Model contours must not masquerade as source-verified contours.
    /// Verify every covered source-rectangle pixel, not only corners/centres.
    static func verifiedContourHint(sourcePolygon: [CGPoint], eligibility: NativeRFDETRBalloonEligibility,
                                    result: NativeRFDETRLayoutResult, maximumPixelTests: Int = 1_048_576,
                                    verifyNativeSourceContour: ([CGPoint]) -> Bool) -> NativeRFDETRVerifiedContourHint? {
        guard eligibility.imageIdentity == result.imageIdentity, sourcePolygon.count >= 3, sourcePolygon.count <= 512,
              sourcePolygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 &&
                  $0.x <= CGFloat(result.sourceWidth) && $0.y <= CGFloat(result.sourceHeight) }),
              maximumPixelTests > 0, verifyNativeSourceContour(sourcePolygon) else { return nil }
        let path = CGMutablePath()
        path.addLines(between: sourcePolygon)
        path.closeSubpath()
        var remaining = maximumPixelTests
        for rect in eligibility.originalSourceBounds {
            guard let bounds = pixelBounds(rect.insetBy(dx: -2, dy: -2), result: result),
                  bounds.width <= remaining / bounds.height else { return nil }
            remaining -= bounds.width * bounds.height
            for y in bounds.top..<(bounds.top + bounds.height) {
                for x in bounds.left..<(bounds.left + bounds.width) {
                    guard path.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) else { return nil }
                }
            }
        }
        return NativeRFDETRVerifiedContourHint(imageIdentity: result.imageIdentity, queryID: eligibility.primitive.queryID,
            sourcePolygon: sourcePolygon, normalizedPolygon: sourcePolygon.map {
                CGPoint(x: $0.x / CGFloat(result.sourceWidth), y: $0.y / CGFloat(result.sourceHeight))
            }, originalSourceBounds: eligibility.originalSourceBounds, nativeSourceContourVerified: true)
    }

    private static func balloons(_ result: NativeRFDETRLayoutResult, minimumConfidence: Float) -> [NativeRFDETRLayoutPrimitive] {
        var queries = Set<Int>()
        return result.primitives.filter {
            $0.semanticClass == .balloon && $0.confidence >= minimumConfidence && $0.mask != nil && queries.insert($0.queryID).inserted
        }
    }

    private static func pixelBounds(_ rect: CGRect, result: NativeRFDETRLayoutResult) -> (left: Int, top: Int, width: Int, height: Int)? {
        guard result.sourceWidth > 0, result.sourceHeight > 0, !rect.isNull, !rect.isEmpty,
              [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy({ $0.isFinite }),
              rect.minX >= 0, rect.minY >= 0, rect.maxX <= CGFloat(result.sourceWidth), rect.maxY <= CGFloat(result.sourceHeight) else { return nil }
        let left = Int(floor(rect.minX)), top = Int(floor(rect.minY))
        return (left, top, Int(ceil(rect.maxX)) - left, Int(ceil(rect.maxY)) - top)
    }
}

/// Optional two-global-threshold RF balloon geometry. It never certifies
/// original RGB, changes RF weights/inputs, or supplies source erasure truth.
struct NativeRFDETRBalloonDomainPolicy: Sendable, Equatable {
    let queryLogit: Float
    let maskLogit: Float
    static var requested: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_SIMPLE_RF_BALLOON_DOMAIN"] == "1"
    }
    static func configured() throws -> Self? {
        guard requested else { return nil }
        let env = ProcessInfo.processInfo.environment
        guard let query = Float(env["AIDOKU_SIMPLE_RF_BALLOON_QUERY_LOGIT"] ?? "0"),
              let mask = Float(env["AIDOKU_SIMPLE_RF_BALLOON_MASK_LOGIT"] ?? "0"),
              query.isFinite, mask.isFinite, (-10...10).contains(query), (-10...10).contains(mask) else {
            throw NativeRFDETRLayoutError.unsupportedModelContract("invalid global balloon policy")
        }
        return Self(queryLogit: query, maskLogit: mask)
    }
    var minimumConfidence: Float {
        queryLogit >= 0 ? 1 / (1 + exp(-queryLogit)) : exp(queryLogit) / (1 + exp(queryLogit))
    }
    var cacheIdentity: String {
        "raw-rf-balloon-v1:q\(queryLogit.bitPattern):m\(maskLogit.bitPattern)"
    }
    func balloons(_ result: NativeRFDETRLayoutResult) throws -> [NativeRFDETRLayoutPrimitive] {
        guard result.classEvidence.count == 300 else {
            throw NativeRFDETRLayoutError.unsupportedModelContract("simple balloon policy requires ALL300 evidence")
        }
        return try result.classEvidence.compactMap { evidence in
            guard evidence.logits.count == 5, evidence.probabilities.count == 5,
                  evidence.logits.allSatisfy(\.isFinite) else {
                throw NativeRFDETRLayoutError.nonfiniteOutput
            }
            guard evidence.logits[2] >= queryLogit else { return nil }
            guard let mask = evidence.mask, mask.queryID == evidence.queryID,
                  mask.sourceWidth == result.sourceWidth, mask.sourceHeight == result.sourceHeight else {
                throw NativeRFDETRLayoutError.unsupportedModelContract("selected balloon mask not retained")
            }
            return NativeRFDETRLayoutPrimitive(queryID: evidence.queryID, semanticClass: .balloon,
                confidence: evidence.probabilities[2], normalizedBounds: evidence.normalizedBounds,
                sourceBounds: evidence.sourceBounds, mask: mask)
        }
    }
}
