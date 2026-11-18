import CoreGraphics
import Foundation

/// Actual native erasure producer when no complete source-mask transaction was
/// supplied by the pre-shaping constructor. Uses fresh original RGB and AUX RF.
@available(iOS 18.0, macOS 15.0, *)
final class NativeSelectedSourceSegmentationPageProducer: @unchecked Sendable {
    static let shared = NativeSelectedSourceSegmentationPageProducer()
    struct Owner { let polygon: [CGPoint]; let fontPixels: Double }
    enum Failure: Error { case invalidSource, workBudget, incompleteNativeMasks }
    private let lock = NSLock()
    private let detector: NativeRFDETRLayoutDetector
    private var producer: NativeSourceSegmentationExecution?

    private init() {
        detector = NativeRFDETRLayoutDetector(cacheByteLimit: 0, retainAllQueryMasks: true,
            expectedWeightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
            expectedSourceRevision: NativeRFDETRLayoutResource.highresSourceRevision,
            resolveModelURL: {
                var bundles = [Bundle.main]
                if let path = ProcessInfo.processInfo.environment["AIDOKU_HOST_MODEL_BUNDLE"], let host = Bundle(path: path) {
                    bundles.insert(host, at: 0)
                }
                for bundle in bundles {
                    if let url = bundle.url(forResource: "KoharuHighres648FP16", withExtension: "mlmodelc") {
#if os(iOS)
                        return try NativeCoreMLModelStore.shared.modelURL(for: url)
#else
                        return url
#endif
                    }
                }
                throw NativeRFDETRLayoutError.modelUnavailable
            })
    }
    private final class Pending: @unchecked Sendable {
        private let condition = NSCondition()
        private var result: Result<NativeRFDETRLayoutResult, Error>?
        func complete(_ value: Result<NativeRFDETRLayoutResult, Error>) {
            condition.lock(); result = value; condition.broadcast(); condition.unlock()
        }
        func wait() throws -> NativeRFDETRLayoutResult {
            condition.lock(); defer { condition.unlock() }
            while result == nil { condition.wait() }
            return try result!.get()
        }
    }
    func build(original: CGImage, decodedSource: NativeRFDETRSourceImage,
               owners: [Owner], sourceWitnessRequest: NativeSourceBackedRFProtection.Request? = nil)
        throws -> (masks: NativeSelectedSourceSegmentationMasks, audit: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        guard !owners.isEmpty, owners.count <= 256, original.width == decodedSource.width, original.height == decodedSource.height else {
            throw Failure.invalidSource
        }
        let selected: NativeSourceSegmentationExecution
        if let producer { selected = producer }
        else { selected = try NativeSourceSegmentationExecution(purpose: .erasure); producer = selected }
        let source = decodedSource.withPreparedIdentity()
        let pending = Pending(), detector = detector
        let task = Task.detached(priority: .userInitiated) {
            do { pending.complete(.success(try await detector.detect(source: source))) }
            catch { pending.complete(.failure(error)) }
        }
        defer { if Task.isCancelled { task.cancel() } }
        let rf = try pending.wait()
        guard rf.imageIdentity == source.identity,
              rf.semanticGrid?.modelWeightsSHA256 == NativeRFDETRLayoutResource.highresSourceWeightsSHA256 else {
            throw Failure.invalidSource
        }
        let evidence = try NativePixelRFEvidence(result: rf)
        var entries: [NativeSelectedSourceSegmentationMasks.Entry] = [], audits: [[String: Any]] = [], work = 0
        var sourceWitnessWork = 0
        for (index, owner) in owners.enumerated() {
            try Task.checkCancellation()
            guard (3...16).contains(owner.polygon.count), owner.polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  owner.fontPixels.isFinite, owner.fontPixels > 0 else { throw Failure.invalidSource }
            let xs = owner.polygon.map(\.x), ys = owner.polygon.map(\.y)
            let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            let crop = bounds.insetBy(dx: -bounds.width * 0.15, dy: -bounds.height * 0.15).integral
                .intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
            guard crop.width > 0, crop.height > 0, crop.width <= 1_500_000 / crop.height else { throw Failure.workBudget }
            let w = Int(crop.width), h = Int(crop.height), count = w * h
            guard work <= 24_000_000 - count else { throw Failure.workBudget }
            work += count
            let support = try evidence.support(crop: crop, polygons: [owner.polygon], sourceIdentity: source.identity)
            let local = owner.polygon.map { CGPoint(x: $0.x - crop.minX, y: $0.y - crop.minY) }
            var rgb = [UInt8](repeating: 0, count: count * 3)
            source.rgb.withUnsafeBytes { bytes in
                let input = bytes.bindMemory(to: UInt8.self)
                for y in 0..<h {
                    let first = ((Int(crop.minY) + y) * source.width + Int(crop.minX)) * 3
                    for x in 0..<(w * 3) { rgb[y * w * 3 + x] = input[first + x] }
                }
            }
            let mask: [UInt8], nativeSeed: [UInt8]?, segmentationAudit: [String: Any]
            if selected.isMinimal {
                let result = try selected.predictMinimal(.init(width: w, height: h, rgb: rgb,
                    fullRF: support.full, coarseRF: support.coarse, memberPolygons: [local],
                    fontPixels: owner.fontPixels, rfModelWeightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256))
                mask = result.mask; nativeSeed = result.nativeSeed; segmentationAudit = result.audit
            } else {
                let result = try selected.predict(rgb: rgb, width: w, height: h, polygons: [local], fontPixels: owner.fontPixels,
                    coarseRF: support.coarse, fullRF: support.full, affinity: support.affinityScores,
                    rfModelWeightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256)
                mask = result.mask; nativeSeed = result.rawNative; segmentationAudit = result.audit
            }
            let witness = nativeSeed.flatMap { seed in
                NativeSourceBackedRFProtection.pack(rawNative: seed, selected: mask, crop: crop,
                    sourceIdentity: source.identity, original: original, request: sourceWitnessRequest, work: &sourceWitnessWork)
            }
            entries.append(.init(ownerPolygon: owner.polygon, crop: crop, mask: mask, positiveSourceSeed: witness))
            audits.append(["owner": index, "cropPixels": count, "segmentation": segmentationAudit,
                "sourceWitnessAvailable": nativeSeed != nil])
        }
        return (NativeSelectedSourceSegmentationMasks(original: original, entries: entries),
            ["engine": "native-selected-source-page", "sourceIdentity": source.identity,
             "rfModelWeightsSHA256": NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
             "owners": audits, "GTRead": false, "storedMaskRead": false, "legacyFallback": false])
    }
}
