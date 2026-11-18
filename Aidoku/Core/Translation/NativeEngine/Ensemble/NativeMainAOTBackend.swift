import CoreGraphics
import CryptoKit
import Foundation

/// The sole resident backend for the new main ensemble route. Lock covers loading,
/// tensor mutation, prediction and composition; no mutable ML object escapes it.
@available(iOS 16.0, macOS 13.0, *)
final class NativeMainAOTBackend: @unchecked Sendable {
    static let shared = NativeMainAOTBackend()

    enum Failure: Error {
        case maskDimensions
        case maskFormat
        case allocation
        case modelResourceMissing
        case restoredDimensions
        case invalidCachePolicy
        case captureAlreadyLoaded
        case captureRequiresActualRaw
    }

    private struct CachedRestoration {
        // Strong ownership prevents object-address recycling while the handoff waits.
        let source: CGImage
        let maskSHA256: SHA256.Digest
        let restored: CGImage
        let normalizationSeconds: Double
        let boundaryBiasPolicy: String?
    }

    private let lock = NSLock()
    private var resident: NativeResidentAOT?
    private var cachedRestoration: CachedRestoration?
    private var rawPredictionSink: ((NativeAOTRawPredictionSnapshot) throws -> Void)?
    private var captureProducerSHA256: String?
    private var captureProducerConfigSHA256: String?
    private var rawPredictionReplay: NativeAOTRawPredictionReplay?

    #if os(iOS)
    private let memoryPressure = DispatchSource.makeMemoryPressureSource(
        eventMask: [.warning, .critical], queue: DispatchQueue(label: "aidoku.translation.aot.memory-pressure"))
    #endif

    private init() {
        #if os(iOS)
        memoryPressure.setEventHandler { [weak self] in
            guard let self else { return }
            // A forward and composition own the model until they finish. Wait
            // on the pressure queue so the reader's main thread stays available.
            self.lock.lock()
            defer { self.lock.unlock() }
            self.resident = nil
            self.cachedRestoration = nil
        }
        memoryPressure.activate()
        #endif
    }

    /// Explicit ROOT-attested raw bank, independent of boundary postprocessing.
    /// Current actual tensors are still generated and fully keyed on every call.
    func configureRawPredictionReplay(_ replay: NativeAOTRawPredictionReplay) throws {
        lock.lock();defer {lock.unlock()}
        guard resident == nil else {throw Failure.captureAlreadyLoaded}
        rawPredictionReplay=replay
    }

    /// Explicit root-selected-bank opt-in BEFORE loading the resident. Default
    /// nil has no capture/hashing/disk cost. Sink errors must stop the page;
    /// quota exhaustion is never silently reported as complete observation.
    func configureRawPredictionCapture(producerSHA256: String, producerConfigSHA256: String,
                                      sink: @escaping (NativeAOTRawPredictionSnapshot) throws -> Void) throws {
        lock.lock();defer {lock.unlock()}
        guard resident == nil else {throw Failure.captureAlreadyLoaded}
        guard NativeAOTRawPredictionSnapshot.validSHA(producerSHA256),
              NativeAOTRawPredictionSnapshot.validSHA(producerConfigSHA256) else {
            throw NativeAOTRawPredictionSnapshot.Failure.producer
        }
        captureProducerSHA256=producerSHA256;captureProducerConfigSHA256=producerConfigSHA256;rawPredictionSink=sink
    }

    /// One-entry, one-use handoff of an ACTUAL main-produced restoration. The caller
    /// validates file/source provenance before registration; this API establishes
    /// in-memory source identity, dimensions, exact binary-mask SHA binding and
    /// actual canonical RGB equality outside the mask. Inside-model/file lineage
    /// remains the caller's responsibility, never inferred from matching pixels.
    /// Empty registration clears the previous entry and does not install a new one.
    func registerCachedRestoration(source: CGImage, mask: CGImage, restored: CGImage,
                                   boundaryBiasPolicy: String? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        cachedRestoration = nil
        guard NativeAOTBoundaryBias.supportedPolicy(boundaryBiasPolicy) else { throw Failure.invalidCachePolicy }
        try Task.checkCancellation()
        let validatedMask = try Self.maskSnapshot(source: source, mask: mask)
        let bytes = validatedMask.bytes
        guard restored.width == source.width, restored.height == source.height else { throw Failure.restoredDimensions }
        guard validatedMask.hasForeground else { return }
        let normalizationStart = Date()
        guard let canonical = try NativeAOTAlphaComposition.legacyRGB24CacheImage(
            source: source, restored: restored, validatedMask: validatedMask) else {
            // RGB24 handoffs cannot preserve transparency or repair changes
            // outside the original mask. Recompute instead of accepting either.
            return
        }
        let normalizationSeconds = Date().timeIntervalSince(normalizationStart)
        try Task.checkCancellation()
        cachedRestoration = CachedRestoration(source: source, maskSHA256: Self.sha256(bytes), restored: canonical,
            normalizationSeconds: normalizationSeconds, boundaryBiasPolicy: boundaryBiasPolicy)
    }

    func restore(source: CGImage, mask: CGImage, calibrateBoundaryBias: Bool = false,
                 boundaryMeanClamp: Int? = nil, rejectNewBoundarySaturation: Bool = false) throws -> NativeAOTResult {
        try restore(source: source, calibrateBoundaryBias: calibrateBoundaryBias, boundaryMeanClamp: boundaryMeanClamp,
                    rejectNewBoundarySaturation: rejectNewBoundarySaturation) {
            try Self.maskSnapshot(source: source, mask: mask)
        }
    }

    /// Internal pipeline already owns canonical original-resolution mask bytes.
    /// Still independently validate dimensions and strict binary inside admission.
    func restore(source: CGImage, canonicalMaskBytes: [UInt8], calibrateBoundaryBias: Bool = false,
                 boundaryMeanClamp: Int? = nil, rejectNewBoundarySaturation: Bool = false) throws -> NativeAOTResult {
        try restore(source: source, calibrateBoundaryBias: calibrateBoundaryBias, boundaryMeanClamp: boundaryMeanClamp,
                    rejectNewBoundarySaturation: rejectNewBoundarySaturation) {
            do {
                return try NativeAOTValidatedMask(validating: canonicalMaskBytes,
                    width: source.width, height: source.height, domain: .strict255)
            } catch NativeAOTValidatedMask.Failure.dimensions {
                throw Failure.maskDimensions
            } catch {
                throw Failure.maskFormat
            }
        }
    }

    private func restore(source: CGImage, calibrateBoundaryBias: Bool, boundaryMeanClamp: Int?, rejectNewBoundarySaturation: Bool,
                         snapshot: () throws -> NativeAOTValidatedMask) throws -> NativeAOTResult {
        lock.lock()
        // Every attempted handoff is consumed, including empty, invalid, cancelled
        // and mismatched calls. No stale entry can survive a fresh/failed attempt.
        defer { cachedRestoration = nil; lock.unlock() }
        try Task.checkCancellation()
        guard NativeAOTBoundaryBias.validConfiguration(enabled: calibrateBoundaryBias, meanClamp: boundaryMeanClamp,
                                                      rejectNewSaturation: rejectNewBoundarySaturation) else {
            throw Failure.invalidCachePolicy
        }
        let validatedMask = try snapshot()
        let bytes = validatedMask.bytes
        let w = source.width, h = source.height
        guard validatedMask.hasForeground else {
            return NativeAOTResult(image: source, coordinateAudit: ["inferenceCalls": 0, "emptyMask": true,
                "outsideOriginalMaskChangedPixels": 0, "originalSize": [w, h], "modelLoadedForCall": false,
                "cacheHit": false, "cacheDisposition": "empty-mask-cleared-handoff"])
        }
        let expectedPolicy = calibrateBoundaryBias ? NativeAOTBoundaryBias.policy(meanClamp: boundaryMeanClamp,
            rejectNewSaturation: rejectNewBoundarySaturation) : nil
        var disposition = "not-registered"
        if let cached = cachedRestoration {
            if cached.boundaryBiasPolicy != expectedPolicy { disposition = "restoration-policy-mismatch" }
            else if cached.source !== source { disposition = "source-identity-mismatch" }
            else if cached.maskSHA256 != Self.sha256(bytes) { disposition = "mask-sha256-mismatch" }
            else {
                // A postprocessed PNG has no raw model lineage. Do not silently
                // issue a second forward merely to satisfy an observer.
                guard rawPredictionSink == nil else {throw Failure.captureRequiresActualRaw}
                return NativeAOTResult(image: cached.restored, coordinateAudit: ["inferenceCalls": 0,
                    "cacheHit": true, "cacheDisposition": "registered-handoff-consumed",
                    "cacheSourceIdentityMatch": true, "cacheMaskSHA256Match": true,
                    "cacheMaskSHA256": cached.maskSHA256.map { String(format: "%02x", $0) }.joined(),
                    "boundaryBiasPolicy": expectedPolicy as Any? ?? NSNull(),
                    "boundaryBiasRequested": calibrateBoundaryBias,
                    "cacheProvenance": "caller-supplied; independent file/source lineage verification not performed here",
                    "cacheRestoredPixelVerificationPerformed": true,
                    "cachePixelVerificationScope": "canonical RGB outside original mask only; inside model lineage remains caller-supplied",
                    "outsideOriginalMaskChangedPixels": 0,
                    "cacheImageFormat": "fresh-equivalent RGB24/sRGB/none; packed rows; interpolation false; default intent",
                    "cacheNormalizationSecondsAtRegistration": cached.normalizationSeconds,
                    "cacheNormalizationRetainedRGBBytes": w * h * 3,
                    "originalSize": [w, h], "maskSize": [w, h], "modelLoadedForCall": false])
            }
        }
        cachedRestoration = nil
        try Task.checkCancellation()
        if resident == nil { resident = try NativeResidentAOT(url: Self.modelURL(), captureProducerSHA256: captureProducerSHA256,
            captureProducerConfigSHA256: captureProducerConfigSHA256, rawPredictionReplay: rawPredictionReplay) }
        // All accesses to resident (including its first construction) are serialized.
        let result = try resident!.restore(source: source, validatedMask: validatedMask,
            calibrateBoundaryBias: calibrateBoundaryBias, boundaryMeanClamp: boundaryMeanClamp,
            rejectNewBoundarySaturation: rejectNewBoundarySaturation, rawPredictionSink: rawPredictionSink)
        var audit = result.coordinateAudit
        audit["cacheHit"] = false
        audit["cacheDisposition"] = disposition
        return NativeAOTResult(image: result.image, coordinateAudit: audit)
    }

    private static func sha256(_ bytes: [UInt8]) -> SHA256.Digest {
        var hasher = SHA256()
        bytes.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return hasher.finalize()
    }

    private static func maskSnapshot(source: CGImage, mask: CGImage) throws -> NativeAOTValidatedMask {
        let w = source.width, h = source.height
        guard w > 0, h > 0, w <= 32_000_000 / h, mask.width == w, mask.height == h else {
            throw Failure.maskDimensions
        }
        guard !mask.isMask, mask.bitsPerComponent == 8, mask.bitsPerPixel == 8,
              mask.colorSpace?.model == .monochrome, mask.alphaInfo == .none else { throw Failure.maskFormat }
        // Draw at exactly 1:1, with no transforms or resampling. Never scale a mask
        // here; candidate masks and cached inference masks are original coordinates.
        var bytes = [UInt8](repeating: 0, count: w * h)
        try bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { throw Failure.allocation }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        do {
            return try NativeAOTValidatedMask(validating: bytes, width: w, height: h, domain: .strict255)
        } catch NativeAOTValidatedMask.Failure.dimensions {
            throw Failure.maskDimensions
        } catch {
            throw Failure.maskFormat
        }
    }

    private static func modelURL() throws -> URL {
        var bundles = [Bundle.main] + Bundle.allBundles
        #if os(macOS)
        // Host launcher owns the bundle location. No experiment/build-path fallback.
        if let path = ProcessInfo.processInfo.environment["AIDOKU_HOST_MODEL_BUNDLE"],
           let hostBundle = Bundle(path: path) { bundles.append(hostBundle) }
        #endif
        var seen = Set<URL>()
        for bundle in bundles where seen.insert(bundle.bundleURL).inserted {
            for subdirectory: String? in [nil, "Translation", "Resources/Translation"] {
                if let url = bundle.url(forResource: "AOT-1024-FP16", withExtension: "mlmodelc", subdirectory: subdirectory),
                   FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        throw Failure.modelResourceMissing
    }
}
