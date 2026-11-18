import Foundation
import CoreML
import CoreGraphics

#if os(macOS)
/// Explicit host-canary fence. Unconfigured app behavior is unchanged. Once
/// configured, every resident in this process shares a non-resettable budget,
/// including retries and detached/queued work. Cache hits never enter this gate.
final class NativeAOTHostPredictionBudget: @unchecked Sendable {
    enum Failure: Error { case invalidRequest, alreadyConfigured, exhausted }
    struct Snapshot: Sendable {
        let configured: Bool
        let maximumFreshPredictions: Int?
        let actualCalls: Int
        let remaining: Int?
        let budgetEnforcedBeforePrediction: Bool
    }
    private static let shared = NativeAOTHostPredictionBudget()
    private let lock = NSLock()
    private var maximum: Int?
    private var calls = 0
    private var unconfiguredForwardStarted = false
    private init() {}

    static func configure(maximumFreshPredictions: Int = 0) throws {
        guard (0...1).contains(maximumFreshPredictions) else {
            throw Failure.invalidRequest
        }
        let state = shared
        state.lock.lock(); defer { state.lock.unlock() }
        guard state.maximum == nil, !state.unconfiguredForwardStarted else { throw Failure.alreadyConfigured }
        state.maximum = maximumFreshPredictions
    }

    /// Reservations are attempts, not successful outputs: a throwing forward
    /// consumes its slot permanently, so model errors cannot authorize retries.
    static func perform<T>(_ forward: () throws -> T) throws -> T {
        try Task.checkCancellation()
        let state = shared
        state.lock.lock()
        if let maximum = state.maximum {
            guard state.calls < maximum else { state.lock.unlock(); throw Failure.exhausted }
            state.calls += 1
        } else {
            state.unconfiguredForwardStarted = true
        }
        state.lock.unlock()
        return try forward()
    }

    /// A sealed raw bank may satisfy this permanently zero-forward host process.
    /// Missing or exhausted max1 is not equivalent to an explicit max0 policy.
    static func permitsReplayWithoutModel(hasReplay: Bool) -> Bool {
        guard hasReplay else { return false }
        let state = snapshot()
        return state.configured && state.maximumFreshPredictions == 0
    }

    static func snapshot() -> Snapshot {
        let state = shared
        state.lock.lock(); defer { state.lock.unlock() }
        return Snapshot(configured: state.maximum != nil, maximumFreshPredictions: state.maximum,
            actualCalls: state.calls, remaining: state.maximum.map { $0 - state.calls },
            budgetEnforcedBeforePrediction: state.maximum != nil)
    }
}
#endif

struct NativeAOTResult {
    let image: CGImage
    let coordinateAudit: [String: Any]
}

// Platform independent RGB8 buffer boundary: callers own image decode/encode.
// One instance per serial page executor. No page identity or label dependencies.
@available(iOS 16.0, macOS 13.0, *)
final class NativeResidentAOT {
    let side = 1024
    #if os(macOS)
    private let model: MLModel?
    var modelLoaded: Bool { model != nil }
    #else
    let model: MLModel
    #endif
    let image: MLMultiArray
    let mask: MLMultiArray
    let provider: MLDictionaryFeatureProvider
    private let tensorCachePolicy: NativeAOTExactTensorCache.Policy?
    private let tensorCacheModelBindingSeconds: Double
    private var lastActualPredictionCalls = 1
    private var lastTensorPredictionAudit: [String: Any]?
    private let rawCapturePolicy: NativeAOTExactTensorCache.Policy?
    private let rawCaptureProducerSHA256: String?
    private let rawCaptureProducerConfigSHA256: String?
    private let rawPredictionReplay: NativeAOTRawPredictionReplay?
    private let rawReplayPolicy: NativeAOTExactTensorCache.Policy?
    private var lastRawReplayAudit: [String: Any]?
    init(url: URL, captureProducerSHA256: String? = nil, captureProducerConfigSHA256: String? = nil,
         rawPredictionReplay: NativeAOTRawPredictionReplay? = nil) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        if let producer = captureProducerSHA256,
           !NativeAOTRawPredictionSnapshot.validSHA(producer) { throw NativeAOTRawPredictionSnapshot.Failure.producer }
        if captureProducerSHA256 != nil && !(captureProducerConfigSHA256.map(NativeAOTRawPredictionSnapshot.validSHA) ?? false) {
            throw NativeAOTRawPredictionSnapshot.Failure.producer
        }
        if NativeAOTTensorCachePolicy.enabled || captureProducerSHA256 != nil || rawPredictionReplay != nil {
            let began = ProcessInfo.processInfo.systemUptime
            let identity = NativeAOTExactTensorCache.Policy(installedModelSHA256: try NativeAOTCompiledModelIdentity.digest(url),
                computeUnits: "cpuAndGPU", runtime: ProcessInfo.processInfo.operatingSystemVersionString,
                tensorABI: NativeAOTTensorCachePolicy.tensorABI)
            tensorCachePolicy = NativeAOTTensorCachePolicy.enabled ? identity : nil
            rawCapturePolicy = captureProducerSHA256 != nil ? identity : nil
            rawReplayPolicy = rawPredictionReplay != nil ? identity : nil
            tensorCacheModelBindingSeconds = ProcessInfo.processInfo.systemUptime - began
        } else { tensorCachePolicy = nil; rawCapturePolicy = nil; rawReplayPolicy = nil; tensorCacheModelBindingSeconds = 0 }
        rawCaptureProducerSHA256 = captureProducerSHA256
        rawCaptureProducerConfigSHA256 = captureProducerConfigSHA256
        self.rawPredictionReplay = rawPredictionReplay
        #if os(macOS)
        if NativeAOTHostPredictionBudget.permitsReplayWithoutModel(hasReplay: rawPredictionReplay != nil) {
            model = nil
        } else { model = try MLModel(contentsOf: url, configuration: config) }
        #else
        model = try MLModel(contentsOf: url, configuration: config)
        #endif
        image = try MLMultiArray(shape: [1, 3, 1024, 1024], dataType: .float16)
        mask = try MLMultiArray(shape: [1, 1, 1024, 1024], dataType: .float16)
        provider = try MLDictionaryFeatureProvider(dictionary: ["masked_image": image, "mask": mask])
        guard image.strides.map(\.intValue) == [3145728, 1048576, 1024, 1],
              mask.strides.map(\.intValue) == [1048576, 1048576, 1024, 1] else {
            throw NSError(domain: "NativeAOTTensorContract", code: 7)
        }
    }

    func prepare(rgb: [UInt8], finalMask: [UInt8], width: Int, height: Int) throws -> (Int, Int) {
        try Self.prepare(rgb: rgb, finalMask: finalMask, width: width, height: height, image: image, mask: mask)
    }

    /// Pure transport seam for no-model regression checks; tensors remain caller-owned.
    static func prepare(rgb: [UInt8], finalMask: [UInt8], width: Int, height: Int,
                        image: MLMultiArray, mask: MLMultiArray) throws -> (Int, Int) {
        let snapshot = try transportMask(finalMask, width: width, height: height)
        return try prepare(rgb: rgb, validatedMask: snapshot, image: image, mask: mask)
    }

    static func prepare(rgb: [UInt8], validatedMask: NativeAOTValidatedMask,
                        image: MLMultiArray, mask: MLMultiArray) throws -> (Int, Int) {
        try prepareInterleaved(source: rgb, components: 3, validatedMask: validatedMask, image: image, mask: mask)
    }

    /// The admitted RGBA route shares the exact RGB channel arithmetic without
    /// allocating a second full-page RGB raster. Alpha is not a model channel;
    /// admission/alpha-composition policy remains owned by the caller.
    static func prepareRGBA(rgba: [UInt8], finalMask: [UInt8], width: Int, height: Int,
                            image: MLMultiArray, mask: MLMultiArray) throws -> (Int, Int) {
        let snapshot = try transportMask(finalMask, width: width, height: height)
        return try prepareRGBA(rgba: rgba, validatedMask: snapshot, image: image, mask: mask)
    }

    static func prepareRGBA(rgba: [UInt8], validatedMask: NativeAOTValidatedMask,
                            image: MLMultiArray, mask: MLMultiArray) throws -> (Int, Int) {
        try prepareInterleaved(source: rgba, components: 4, validatedMask: validatedMask, image: image, mask: mask)
    }

    private static func transportMask(_ bytes: [UInt8], width: Int, height: Int) throws -> NativeAOTValidatedMask {
        do { return try NativeAOTValidatedMask(validating: bytes, width: width, height: height, domain: .logical01Or255) }
        catch { throw NSError(domain: "NativeAOTTransportContract", code: 7) }
    }

    private static func prepareInterleaved(source: [UInt8], components: Int, validatedMask: NativeAOTValidatedMask,
                                   image: MLMultiArray, mask: MLMultiArray) throws -> (Int, Int) {
        let side = 1024
        let width = validatedMask.width, height = validatedMask.height, finalMask = validatedMask.bytes
        guard (components == 3 || components == 4), source.count == width * height * components,
              image.shape.map(\.intValue) == [1, 3, side, side], image.dataType == .float16,
              mask.shape.map(\.intValue) == [1, 1, side, side], mask.dataType == .float16,
              image.strides.map(\.intValue) == [3145728, 1048576, 1024, 1],
              mask.strides.map(\.intValue) == [1048576, 1048576, 1024, 1] else {
            throw NSError(domain: "NativeAOTTransportContract", code: 7)
        }
        // The dimension and count checks above establish the bounds of every
        // integer area below. Borrow both arrays for the complete transport.
        return try source.withUnsafeBufferPointer { pixels in
            try finalMask.withUnsafeBufferPointer { binaryMask in
                try fillInputTensors(pixels: pixels.baseAddress!, binaryMask: binaryMask.baseAddress!,
                    components: components, width: width, height: height, side: side,
                    image: image, mask: mask)
            }
        }
    }

    private static func fillInputTensors(pixels: UnsafePointer<UInt8>, binaryMask: UnsafePointer<UInt8>,
                                         components: Int, width: Int, height: Int, side: Int,
                                         image: MLMultiArray, mask: MLMultiArray) throws -> (Int, Int) {
        let plane = side * side
        let scale = min(1, Double(side) / Double(max(width, height)))
        let sw = min(side, max(1, Int(ceil(Double(width) * scale))))
        let sh = min(side, max(1, Int(ceil(Double(height) * scale))))
        let ip = image.dataPointer.assumingMemoryBound(to: Float16.self)
        let mp = mask.dataPointer.assumingMemoryBound(to: Float16.self)
        let horizontalSupport = (0..<sw).map { x in
            (x * width / sw, min(width, ((x + 1) * width + sw - 1) / sw))
        }
        // Padding uses unmasked edge RGB even if the last content row/column
        // takes a mask hit. Keep just that row in half precision.
        var bottom = [Float16](repeating: 0, count: sh < side ? sw * 3 : 0)
        // Fallible operations stay on the caller's task. Each GCD worker writes
        // disjoint output rows. Only the final content row writes bottom's scratch.
        try bottom.withUnsafeMutableBufferPointer { bottomBuffer in
            nonisolated(unsafe) let bottomAddress = bottomBuffer.baseAddress
            nonisolated(unsafe) let pixels = pixels
            nonisolated(unsafe) let binaryMask = binaryMask
            nonisolated(unsafe) let ip = ip
            nonisolated(unsafe) let mp = mp
            @Sendable func fillRows(_ first: Int, _ last: Int) {
                for y in first..<last {
                    let y0 = y * height / sh, y1 = min(height, ((y + 1) * height + sh - 1) / sh)
                    let rowOffset = y * side
                    let saveBottom = y == sh - 1 && sh < side
                    var edge: (Float16, Float16, Float16) = (0, 0, 0)
                    for x in 0..<sw {
                        let (x0, x1) = horizontalSupport[x]
                        var sums = (0, 0, 0)
                        var maskUnion: UInt8 = 0
                        for yy in y0..<y1 {
                            for xx in x0..<x1 {
                                let p = yy * width + xx
                                let color = pixels + p * components
                                // At most 32M source pixels can contribute to a 64-bit sum.
                                sums.0 &+= Int(color[0])
                                sums.1 &+= Int(color[1])
                                sums.2 &+= Int(color[2])
                                maskUnion |= binaryMask[p]
                            }
                        }
                        let hit = maskUnion != 0
                        let count = Float((y1 - y0) * (x1 - x0)), p = rowOffset + x
                        let n0 = (Float(sums.0) / count) / Float(127.5) - Float(1)
                        let n1 = (Float(sums.1) / count) / Float(127.5) - Float(1)
                        let n2 = (Float(sums.2) / count) / Float(127.5) - Float(1)
                        mp[p] = hit ? 1 : 0
                        // Keep multiplication in Float so a negative normalized value
                        // masked to zero retains the previous negative-zero bit.
                        ip[p] = Float16(n0 * (hit ? 0 : 1))
                        ip[plane + p] = Float16(n1 * (hit ? 0 : 1))
                        ip[2 * plane + p] = Float16(n2 * (hit ? 0 : 1))
                        if saveBottom {
                            bottomAddress![x] = Float16(n0); bottomAddress![sw + x] = Float16(n1); bottomAddress![2 * sw + x] = Float16(n2)
                        }
                        if x == sw - 1 { edge = (Float16(n0), Float16(n1), Float16(n2)) }
                    }
                    for x in sw..<side {
                        let p = rowOffset + x
                        mp[p] = 0
                        ip[p] = edge.0; ip[plane + p] = edge.1; ip[2 * plane + p] = edge.2
                    }
                }
            }
            if width * height < 65_536 {
                for y in 0..<sh {
                    try Task.checkCancellation()
                    fillRows(y, y + 1)
                }
                return
            }
            let lanes = 4
            let rowsPerPass = 64
            for first in stride(from: 0, to: sh, by: rowsPerPass) {
                try Task.checkCancellation()
                let last = min(first + rowsPerPass, sh)
                DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                    let lower = first + (last - first) * lane / lanes
                    let upper = first + (last - first) * (lane + 1) / lanes
                    fillRows(lower, upper)
                }
            }
        }
        for y in sh..<side {
            try Task.checkCancellation()
            let rowOffset = y * side
            for x in 0..<side {
                let p = rowOffset + x, tx = min(x, sw - 1)
                mp[p] = 0
                ip[p] = bottom[tx]; ip[plane + p] = bottom[sw + tx]; ip[2 * plane + p] = bottom[2 * sw + tx]
            }
        }
        try Task.checkCancellation()
        return (sw, sh)
    }

    func predict() throws -> MLMultiArray {
        try Task.checkCancellation()
        lastActualPredictionCalls = 0
        lastTensorPredictionAudit = nil
        lastRawReplayAudit = nil
        if let replay = rawPredictionReplay, let policy = rawReplayPolicy {
            let lookup = try replay.lookup(image: image, mask: mask, policy: policy)
            lastRawReplayAudit = ["configured": true, "hit": lookup.raw != nil, "exactTensorKey": lookup.key,
                "indexSHA256": replay.indexSHA256, "producerSHA256": replay.producerSHA256,
                "producerConfigSHA256": replay.producerConfigSHA256, "compiledModelSHA256": replay.compiledModelSHA256,
                "metadataSHA256": lookup.metadataSHA256 as Any? ?? NSNull(), "lookupSeconds": lookup.seconds,
                "actualPredictionCallsOnHit": 0, "currentOriginalMaskStillComposed": true]
            if let raw = lookup.raw { return raw }
        }
        func directPrediction() throws -> MLMultiArray {
            #if os(macOS)
            guard let model else {
                try Task.checkCancellation()
                throw NativeAOTHostPredictionBudget.Failure.exhausted
            }
            #endif
            func forward() throws -> MLMultiArray {
                lastActualPredictionCalls = 1
                guard let raw = try model.prediction(from: provider).featureValue(for: "raw_rgb")?.multiArrayValue,
                      raw.shape.map(\.intValue) == [1, 3, side, side], raw.dataType == .float16 else {
                    throw NSError(domain: "NativeAOT", code: 1)
                }
                return raw
            }
            #if os(macOS)
            return try NativeAOTHostPredictionBudget.perform(forward)
            #else
            return try forward()
            #endif
        }
        let raw: MLMultiArray
        if let policy = tensorCachePolicy {
            var kernelSeconds: Double = 0
            let lookup = try NativeAOTExactTensorCache.shared.predict(image: image, mask: mask, policy: policy) {
                let began = ProcessInfo.processInfo.systemUptime
                defer { kernelSeconds = ProcessInfo.processInfo.systemUptime - began }
                return try directPrediction()
            }
            raw = lookup.raw
            lastTensorPredictionAudit = ["enabled": true, "hit": lookup.hit, "inputSHA256": lookup.key,
                "installedModelSHA256": policy.installedModelSHA256, "computeUnits": policy.computeUnits,
                "runtime": policy.runtime, "tensorABI": policy.tensorABI,
                "actualPredictionCalls": lastActualPredictionCalls, "kernelSeconds": kernelSeconds,
                "modelBindingSecondsAtResidentInit": tensorCacheModelBindingSeconds,
                "inputHashBytes": NativeAOTExactTensorCache.imageBytes + NativeAOTExactTensorCache.maskBytes,
                "outputSnapshotBytes": NativeAOTExactTensorCache.outputBytes, "metrics": lookup.metrics,
                "cache": NativeAOTExactTensorCache.shared.statistics()]
        } else {
            raw = try directPrediction()
        }
        try Task.checkCancellation()
        return raw
    }

    // Source and binary mask are top-left raster coordinates at identical resolution.
    // Serial use only: model and input tensors stay resident across calls.
    func restore(source: CGImage, originalMask: [UInt8], maskWidth: Int, maskHeight: Int,
                 calibrateBoundaryBias: Bool = false,
                 boundaryMeanClamp: Int? = nil,
                 rawPredictionSink: ((NativeAOTRawPredictionSnapshot) throws -> Void)? = nil,
                 auditSink: ((MLMultiArray, MLMultiArray, MLMultiArray) throws -> Void)? = nil) throws -> NativeAOTResult {
        let w = source.width, h = source.height
        try Task.checkCancellation()
        if rawPredictionSink != nil && rawCapturePolicy == nil { throw NativeAOTRawPredictionSnapshot.Failure.producer }
        guard w == maskWidth, h == maskHeight else {
            throw NSError(domain: "NativeAOTMaskDimensionsOrBinary", code: 3)
        }
        let snapshot: NativeAOTValidatedMask
        do { snapshot = try NativeAOTValidatedMask(validating: originalMask, width: w, height: h, domain: .logical01Or255) }
        catch { throw NSError(domain: "NativeAOTMaskDimensionsOrBinary", code: 3) }
        return try restore(source: source, validatedMask: snapshot, calibrateBoundaryBias: calibrateBoundaryBias,
            boundaryMeanClamp: boundaryMeanClamp, rawPredictionSink: rawPredictionSink, auditSink: auditSink)
    }

    func restore(source: CGImage, validatedMask: NativeAOTValidatedMask,
                 calibrateBoundaryBias: Bool = false, boundaryMeanClamp: Int? = nil,
                 rejectNewBoundarySaturation: Bool = false,
                 rawPredictionSink: ((NativeAOTRawPredictionSnapshot) throws -> Void)? = nil,
                 auditSink: ((MLMultiArray, MLMultiArray, MLMultiArray) throws -> Void)? = nil) throws -> NativeAOTResult {
        let w = source.width, h = source.height, originalMask = validatedMask.bytes
        try Task.checkCancellation()
        if rawPredictionSink != nil && rawCapturePolicy == nil { throw NativeAOTRawPredictionSnapshot.Failure.producer }
        guard w == validatedMask.width, h == validatedMask.height else {
            throw NSError(domain: "NativeAOTMaskDimensionsOrBinary", code: 3)
        }
        let sourceDecodeStart = Date()
        let alphaSource = try NativeAOTAlphaComposition.prepare(source: source)
        let rgb = alphaSource.inferenceRGB
        let sourceDecodeSeconds = Date().timeIntervalSince(sourceDecodeStart)
        let start = Date()
        let content = try Self.prepare(rgb: rgb, validatedMask: validatedMask, image: image, mask: mask)
        let prep = Date().timeIntervalSince(start), t = Date()
        let raw = try predict()
        let inference = Date().timeIntervalSince(t)
        // Explicit capture observes the actual raw before downstream composition
        // can fail. Capture-off performs no snapshot, mask retention or I/O.
        if let rawPredictionSink {
            guard let policy = rawCapturePolicy, let producer = rawCaptureProducerSHA256,
                  let producerConfig = rawCaptureProducerConfigSHA256 else {
                throw NativeAOTRawPredictionSnapshot.Failure.producer
            }
            try rawPredictionSink(NativeAOTRawPredictionSnapshot.capture(source: source, originalMask: originalMask,
                image: self.image, mask: mask, raw: raw, policy: policy, producerSHA256: producer,
                producerConfigSHA256: producerConfig))
        }
        let composed = try Self.composeRestoration(source: alphaSource, validatedMask: validatedMask,
            raw: raw, content: content, calibrateBoundaryBias: calibrateBoundaryBias, boundaryMeanClamp: boundaryMeanClamp,
            rejectNewBoundarySaturation: rejectNewBoundarySaturation)
        try auditSink?(self.image, mask, raw)
        var coordinateAudit = composed.coordinateAudit
        coordinateAudit["preprocessingSeconds"] = prep
        coordinateAudit["inferenceSeconds"] = inference
        coordinateAudit["sourceDecodeAndMattingSeconds"] = sourceDecodeSeconds
        coordinateAudit["inferenceCalls"] = lastActualPredictionCalls
        #if os(macOS)
        coordinateAudit["modelLoaded"] = modelLoaded
        #endif
        coordinateAudit["tensorPredictionCacheEnabled"] = tensorCachePolicy != nil
        if let lastTensorPredictionAudit { coordinateAudit["tensorPredictionCache"] = lastTensorPredictionAudit }
        if let lastRawReplayAudit { coordinateAudit["rawPredictionDiskReplay"] = lastRawReplayAudit }
        return NativeAOTResult(image: composed.image, coordinateAudit: coordinateAudit)
    }

    /// One shared production/offline composition kernel. Both boundary variants
    /// consume the SAME actual raw tensor; this function cannot load a model.
    static func composeRestoration(source alphaSource: NativeAOTAlphaComposition.Source,
                                   originalMask: [UInt8], raw: MLMultiArray, content: (Int, Int),
                                   calibrateBoundaryBias: Bool, boundaryMeanClamp: Int? = nil) throws -> NativeAOTResult {
        guard boundaryMeanClamp == nil || (calibrateBoundaryBias && (boundaryMeanClamp == 8 || boundaryMeanClamp == 16)) else {
            throw NSError(domain: "NativeAOTBoundaryMeanContract", code: 9)
        }
        let snapshot = try compositionMask(originalMask, width: alphaSource.width, height: alphaSource.height)
        return try composeRestoration(source: alphaSource, validatedMask: snapshot, raw: raw, content: content,
            calibrateBoundaryBias: calibrateBoundaryBias, boundaryMeanClamp: boundaryMeanClamp)
    }

    static func composeRestoration(source alphaSource: NativeAOTAlphaComposition.Source,
                                   validatedMask: NativeAOTValidatedMask, raw: MLMultiArray, content: (Int, Int),
                                   calibrateBoundaryBias: Bool, boundaryMeanClamp: Int? = nil,
                                   rejectNewBoundarySaturation: Bool = false) throws -> NativeAOTResult {
        guard NativeAOTBoundaryBias.validConfiguration(enabled: calibrateBoundaryBias, meanClamp: boundaryMeanClamp,
                                                      rejectNewSaturation: rejectNewBoundarySaturation) else {
            throw NSError(domain: "NativeAOTBoundaryMeanContract", code: 9)
        }
        guard validatedMask.width == alphaSource.width, validatedMask.height == alphaSource.height else {
            throw NSError(domain: "NativeAOTCompositionContract", code: 7)
        }
        let originalMask = validatedMask.bytes
        let w = alphaSource.width, h = alphaSource.height, rgb = alphaSource.inferenceRGB
        let c = Date()
        var boundaryAudit: [String: Any]?
        let image: CGImage
        var composition: TimeInterval = 0
        var alphaCompositionStart = c
        var outside = 0
        if !calibrateBoundaryBias && !alphaSource.hasTransparency {
            try validateScatter(byteCount: rgb.count, components: 3, validatedMask: validatedMask, raw: raw, content: content)
            image = try NativeAOTAlphaComposition.opaqueImage(source: alphaSource, validatedMask: validatedMask) { pixels in
                if validatedMask.hasForeground {
                    try scatter(into: pixels, components: 3, validatedMask: validatedMask, raw: raw, content: content)
                }
                try Task.checkCancellation()
                alphaCompositionStart = Date()
                composition = alphaCompositionStart.timeIntervalSince(c)
            }
        } else {
            let plan = calibrateBoundaryBias && !alphaSource.hasTransparency
                ? NativeAOTBoundaryBias.prepare(source: rgb, validatedMask: validatedMask) : nil
            // An independently constructed sampling mask is a NEW snapshot; its
            // bytes must pass the same real constructor, never inherit a flag.
            let samplingMask = try plan.map { try compositionMask($0.samplingMask, width: w, height: h) } ?? validatedMask
            var restored = try composePixels(source: rgb, validatedMask: samplingMask, raw: raw, content: content)
            if let plan {
                if let cap = boundaryMeanClamp {
                    boundaryAudit = NativeAOTBoundaryBias.applyMeanInPlace(source: rgb, predicted: &restored, mask: originalMask, plan: plan, maximumBias: cap)
                } else {
                    boundaryAudit = NativeAOTBoundaryBias.applyInPlace(source: rgb, predicted: &restored, mask: originalMask,
                        plan: plan, rejectNewSaturation: rejectNewBoundarySaturation)
                }
            } else if calibrateBoundaryBias {
                boundaryAudit = ["status": alphaSource.hasTransparency ? "nonopaque-source-preserved" : "invalid-empty-or-large-mask-preserved",
                                 "correctionMeasured": false]
            }
            try Task.checkCancellation()
            composition = Date().timeIntervalSince(c)
            if alphaSource.hasTransparency {
                for p in 0..<(w * h) where originalMask[p] == 0 {
                    if (0..<3).contains(where: { restored[p * 3 + $0] != rgb[p * 3 + $0] }) { outside += 1 }
                }
            }
            alphaCompositionStart = Date()
            image = try NativeAOTAlphaComposition.makeImage(source: alphaSource,
                restoredRGB: restored, validatedMask: validatedMask)
        }
        // Both opaque image paths independently compare every actual exterior
        // RGB byte and throws on mismatch. A second identical pre-scan cannot
        // change acceptance/output. Transparent RGB+actual RGBA checks remain.
        var outsideRGBA = outside, insideNonopaque = 0
        if alphaSource.hasTransparency {
            let actual = try NativeAOTAlphaComposition.prepare(source: image)
            outsideRGBA = 0
            for p in 0..<(w * h) {
                if originalMask[p] == 0 {
                    if (0..<4).contains(where: { actual.canonicalRGBA[p * 4 + $0] != alphaSource.canonicalRGBA[p * 4 + $0] }) {
                        outsideRGBA += 1
                    }
                } else if actual.canonicalRGBA[p * 4 + 3] != 255 { insideNonopaque += 1 }
            }
            guard outsideRGBA == 0, insideNonopaque == 0 else {
                throw NSError(domain: "NativeAOTAlphaCompositionContract", code: 8)
            }
        }
        var coordinateAudit: [String: Any] = ["originalSize": [w, h], "maskSize": [w, h],
            "content": [content.0, content.1], "modelSize": [1024, 1024], "padding": "top-left content; RGB edge extension; mask zero",
            "forwardSupport": "floor start / ceil end integer area; any-hit binary mask", "restore": "clamped half-pixel bilinear; float32 coordinates; double weights",
            "outsideOriginalMaskChangedPixels": outsideRGBA, "outsideInferenceMatteChangedPixels": outside,
            "outsideCanonicalRGBAChangedPixels": outsideRGBA, "insideMaskNonopaquePixels": insideNonopaque,
            "alphaCompositionAndVerificationSeconds": Date().timeIntervalSince(alphaCompositionStart),
            "compositionSeconds": composition, "inferenceCalls": 0, "opaqueSourceRequired": false,
            "sourceWasOpaque": !alphaSource.hasTransparency,
            "alphaPolicy": NativeAOTAlphaComposition.policyVersion,
            "colorContract": "sRGB white-matted model input; original canonical RGBA outside mask; opaque restoration inside"]
        if let boundaryAudit {
            coordinateAudit["boundaryBias"] = boundaryAudit
            coordinateAudit["boundaryBiasRequested"] = true
            coordinateAudit["boundaryBiasPolicy"] = NativeAOTBoundaryBias.policy(meanClamp: boundaryMeanClamp,
                rejectNewSaturation: rejectNewBoundarySaturation)
        }
        return NativeAOTResult(image: image, coordinateAudit: coordinateAudit)
    }

    func compose(source: [UInt8], finalMask: [UInt8], width: Int, height: Int,
                 raw: MLMultiArray, content: (Int, Int)) throws -> [UInt8] {
        try Self.composePixels(source: source, finalMask: finalMask, width: width, height: height, raw: raw, content: content)
    }

    /// No inference; only final original-mask pixels may change.
    static func composePixels(source: [UInt8], finalMask: [UInt8], width: Int, height: Int,
                              raw: MLMultiArray, content: (Int, Int)) throws -> [UInt8] {
        let snapshot = try compositionMask(finalMask, width: width, height: height)
        return try composePixels(source: source, validatedMask: snapshot, raw: raw, content: content)
    }

    static func composePixels(source: [UInt8], validatedMask: NativeAOTValidatedMask,
                              raw: MLMultiArray, content: (Int, Int)) throws -> [UInt8] {
        try composeInterleaved(source: source, components: 3, validatedMask: validatedMask, raw: raw, content: content)
    }

    /// Legacy admitted-page output keeps its RGBA descriptor and alpha bytes.
    /// Only the original binary-mask RGB channels are replaced. Main-route alpha
    /// matting/opaque-inside policy continues through NativeAOTAlphaComposition.
    static func composeRGBA(source: [UInt8], finalMask: [UInt8], width: Int, height: Int,
                            raw: MLMultiArray, content: (Int, Int)) throws -> [UInt8] {
        let snapshot = try compositionMask(finalMask, width: width, height: height)
        return try composeRGBA(source: source, validatedMask: snapshot, raw: raw, content: content)
    }

    static func composeRGBA(source: [UInt8], validatedMask: NativeAOTValidatedMask,
                            raw: MLMultiArray, content: (Int, Int)) throws -> [UInt8] {
        try composeInterleaved(source: source, components: 4, validatedMask: validatedMask, raw: raw, content: content)
    }

    private static func compositionMask(_ bytes: [UInt8], width: Int, height: Int) throws -> NativeAOTValidatedMask {
        do { return try NativeAOTValidatedMask(validating: bytes, width: width, height: height, domain: .logical01Or255) }
        catch { throw NSError(domain: "NativeAOTCompositionContract", code: 7) }
    }

    private static func composeInterleaved(source: [UInt8], components: Int, validatedMask: NativeAOTValidatedMask,
                                          raw: MLMultiArray, content: (Int, Int)) throws -> [UInt8] {
        try validateScatter(byteCount: source.count, components: components, validatedMask: validatedMask, raw: raw, content: content)
        guard validatedMask.hasForeground else { return source }
        var restored = source
        try restored.withUnsafeMutableBufferPointer {
            try scatter(into: $0, components: components, validatedMask: validatedMask, raw: raw, content: content)
        }
        return restored
    }

    private static func validateScatter(byteCount: Int, components: Int, validatedMask: NativeAOTValidatedMask,
                                        raw: MLMultiArray, content: (Int, Int)) throws {
        guard (components==3 || components==4),byteCount==validatedMask.bytes.count*components,
              (1...1024).contains(content.0),(1...1024).contains(content.1),
              raw.shape.map(\.intValue)==[1,3,1024,1024],raw.dataType == .float16,
              raw.strides.map(\.intValue)==[3145728,1048576,1024,1] else {
            throw NSError(domain:"NativeAOTCompositionContract",code:7)
        }
        try Task.checkCancellation()
    }

    private static func scatter(into restored: UnsafeMutableBufferPointer<UInt8>, components: Int, validatedMask: NativeAOTValidatedMask,
                                raw: MLMultiArray, content: (Int, Int)) throws {
        let (sw,sh)=content,w=validatedMask.width,h=validatedMask.height,mask=validatedMask.bytes
        let strides=raw.strides.map(\.intValue),values=raw.dataPointer.assumingMemoryBound(to:Float16.self)
        var a=[Double](repeating:0,count:sw*3),b=a
        var validA=[UInt8](repeating:0,count:sw),validB=validA
        var rowA = -1,rowB = -1
        for y in 0..<h {
            try Task.checkCancellation()
            let row=y*w
            var first=0
            while first<w && mask[row+first]==0 {first += 1}
            if first==w {continue}
            let sy=min(Float(sh-1),max(0,(Float(y)+0.5)*Float(sh)/Float(h)-0.5))
            let y0=Int(floor(sy)),y1=min(sh-1,y0+1),dy=Double(sy)-Double(y0)
            if rowA != y0 {
                if rowB==y0 {swap(&a,&b);swap(&validA,&validB);swap(&rowA,&rowB)}
                else {rowA=y0;validA.withUnsafeMutableBufferPointer{$0.initialize(repeating:0)}}
            }
            if y1 != y0 && rowB != y1 {rowB=y1;validB.withUnsafeMutableBufferPointer{$0.initialize(repeating:0)}}
            try a.withUnsafeMutableBufferPointer { aa in
                try b.withUnsafeMutableBufferPointer { bb in
                    try validA.withUnsafeMutableBufferPointer { va in
                        try validB.withUnsafeMutableBufferPointer { vb in
                            func ensure(_ x:Int,_ yy:Int,_ target:UnsafeMutableBufferPointer<Double>,_ valid:UnsafeMutableBufferPointer<UInt8>) {
                                if valid[x] != 0 {return}
                                for c in 0..<3 {
                                    // Same Float32 normalization BEFORE Double widening.
                                    target[c*sw+x]=Double((Float(values[c*strides[1]+yy*strides[2]+x*strides[3]])+1)/2)
                                }
                                valid[x]=1
                            }
                            for x in first..<w where mask[row+x] != 0 {
                                let sx=min(Float(sw-1),max(0,(Float(x)+0.5)*Float(sw)/Float(w)-0.5))
                                let x0=Int(floor(sx)),x1=min(sw-1,x0+1),dx=Double(sx)-Double(x0)
                                ensure(x0,y0,aa,va);ensure(x1,y0,aa,va)
                                if y1 != y0 {ensure(x0,y1,bb,vb);ensure(x1,y1,bb,vb)}
                                for c in 0..<3 {
                                    let top=aa[c*sw+x0]*(1-dx)+aa[c*sw+x1]*dx
                                    let bottom=y1==y0 ? top : bb[c*sw+x0]*(1-dx)+bb[c*sw+x1]*dx
                                    let selected=top*(1-dy)+bottom*dy
                                    guard selected.isFinite else {throw NSError(domain:"NonfiniteAOT",code:2)}
                                    restored[(row+x)*components+c]=UInt8(floor(min(1,max(0,selected))*255+0.5))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
