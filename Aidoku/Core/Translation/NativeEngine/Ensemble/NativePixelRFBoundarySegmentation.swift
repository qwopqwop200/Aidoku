import CoreGraphics
import Foundation

/// A contextual boundary classifier refines the frozen primary prediction.
/// Dilation requires corroboration from global source classifiers.
enum NativePixelRFBoundarySegmentation {
    static func refine(rgb: [UInt8], primary: [Float], nativeMask: [UInt8], coarseRF: [Float], fullRF: [Float],
                       width: Int, height: Int, fontPixels: Double, model: NativePixelRFForest,
                       constrainExpansion: Bool = true,
                       captureBoundary: (([Float]) throws -> Void)? = nil) throws -> NativePixelRFSegmentation.Result {
        let features: NativePixelRFFeatures.Matrix
        if model.featureCount == 60 {
            features = try NativePixelRFBoundaryFeatures.extractEdgeContext(rgb: rgb, probabilities: primary,
                nativeMask: nativeMask, coarseRF: coarseRF, fullRF: fullRF, width: width, height: height, fontPixels: fontPixels)
        } else {
            features = try NativePixelRFBoundaryFeatures.extract(rgb: rgb, probabilities: primary,
                nativeMask: nativeMask, coarseRF: coarseRF, fullRF: fullRF, width: width, height: height, fontPixels: fontPixels)
        }
        let probabilities = try model.probabilities(features)
        try captureBoundary?(probabilities)
        return try complete(rgb: rgb, primary: primary, probabilities: probabilities, nativeMask: nativeMask,
            width: width, height: height, fontPixels: fontPixels, model: model, constrainExpansion: constrainExpansion)
    }

    /// The same policy path consumes authenticated native classifier observations
    /// when only global completion thresholds change. It never consumes GT masks.
    static func complete(rgb: [UInt8], primary: [Float], probabilities: [Float], nativeMask: [UInt8],
                         width: Int, height: Int, fontPixels: Double, model: NativePixelRFForest,
                         constrainExpansion: Bool = true) throws -> NativePixelRFSegmentation.Result {
        guard width > 0, height > 0, width <= 1_500_000 / height,
              rgb.count == width * height * 3, primary.count == width * height,
              primary.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw NativePixelRFBoundaryFeatures.Failure.invalidInput
        }
        let completed = try NativePixelRFSegmentation.complete(probabilities: probabilities,
            nativeMask: nativeMask, width: width, height: height, fontPixels: fontPixels, model: model)
        var mask = completed.mask, removed = 0, colorSupported = 0
        if constrainExpansion {
            for i in mask.indices where mask[i] != 0 {
                var unsupported: Bool
                if let gate = model.boundaryEvidenceGate {
                    let primaryFloor: Float, boundaryFloor: Float, includeNative: Bool
                    let colorPolicy: NativePixelRFForest.ColorCorroboration?
                    let offset = i * 3
                    let chroma = Int(max(rgb[offset], rgb[offset + 1], rgb[offset + 2])) -
                        Int(min(rgb[offset], rgb[offset + 1], rgb[offset + 2]))
                    if let alternate = gate.chromaticOverride, chroma >= alternate.minimumChroma {
                        primaryFloor = alternate.primaryThreshold
                        boundaryFloor = alternate.boundaryThreshold
                        includeNative = alternate.includeNativeSupport
                        colorPolicy = alternate.colorCorroboration
                    } else {
                        primaryFloor = gate.primaryThreshold
                        boundaryFloor = gate.boundaryThreshold
                        includeNative = gate.includeNativeSupport
                        colorPolicy = gate.colorCorroboration
                    }
                    unsupported = primary[i] < primaryFloor && probabilities[i] < boundaryFloor &&
                        !(includeNative && nativeMask[i] != 0)
                    if unsupported, let color = colorPolicy,
                       colorSupport(index: i, rgb: rgb, primary: primary, boundary: probabilities,
                                    width: width, height: height, policy: color) {
                        unsupported = false
                        colorSupported += 1
                    }
                } else {
                    // Backwards compatible policy for previously validated models.
                    unsupported = primary[i] == 0 && probabilities[i] == 0
                }
                if unsupported {
                    mask[i] = 0
                    removed += 1
                }
            }
        }
        let recoveryBase: [UInt8]? = constrainExpansion && model.boundaryEvidenceGate?.recoveryGate != nil ? mask : nil
        var uniformRemoved = 0, uniformMinimumDistance = 0
        if constrainExpansion, let uniform = model.boundaryEvidenceGate?.uniformityGate {
            let distance = try uniformDistances(rgb: rgb, width: width, height: height, contrastThreshold: uniform.contrastThreshold)
            uniformMinimumDistance = max(uniform.minimumDistancePixels,
                Int(min(65535, (fontPixels * uniform.distanceFontScale).rounded(.up))))
            for i in mask.indices where mask[i] != 0 && distance[i] >= uniformMinimumDistance &&
                primary[i] < uniform.maximumPrimaryProbability && probabilities[i] < uniform.maximumBoundaryProbability {
                if uniform.preserveConsensusNeighbors && consensusSupport(index: i, primary: primary, boundary: probabilities,
                    width: width, height: height, policy: uniform) { continue }
                mask[i] = 0
                uniformRemoved += 1
            }
        }
        var recoveryAdded = 0
        if let base = recoveryBase, let recovery = model.boundaryEvidenceGate?.recoveryGate {
            var seeds = [UInt8](repeating: 0, count: base.count)
            for i in seeds.indices where base[i] != 0 && primary[i] >= recovery.primarySeedThreshold &&
                probabilities[i] >= recovery.boundarySeedThreshold { seeds[i] = 255 }
            let nearby = NativePixelRFSegmentation.expand(seeds, width: width, height: height, radius: recovery.radius, kernel: "square")
            let distance = recovery.maximumEdgeDistancePixels >= 0 ?
                try uniformDistances(rgb: rgb, width: width, height: height, contrastThreshold: recovery.edgeContrastThreshold) : nil
            for i in mask.indices where base[i] == 0 && nearby[i] != 0 &&
                (!recovery.requireNativeSupport || nativeMask[i] != 0) {
                if let distance, distance[i] > recovery.maximumEdgeDistancePixels { continue }
                if matchingSeed(index: i, rgb: rgb, seeds: seeds, width: width, height: height,
                    radius: recovery.radius, tolerance: recovery.colorTolerance) {
                    mask[i] = 255
                    recoveryAdded += 1
                }
            }
        }
        var audit = completed.audit
        audit["boundaryExpansionEvidenceGate"] = constrainExpansion
        audit["unsupportedExpansionPixelsRemoved"] = removed
        audit["colorCorroboratedPixelsRetained"] = colorSupported
        audit["uniformInteriorPixelsRemoved"] = uniformRemoved
        audit["uniformityMinimumEdgeDistance"] = uniformMinimumDistance
        audit["sourceRecoveryPixelsAdded"] = recoveryAdded
        if let gate = model.boundaryEvidenceGate {
            audit["boundaryPrimaryProbabilityFloor"] = Double(gate.primaryThreshold)
            audit["boundaryRefinerProbabilityFloor"] = Double(gate.boundaryThreshold)
            audit["boundaryIncludesNativeSupport"] = gate.includeNativeSupport
            audit["boundaryUsesChromaPolicy"] = gate.chromaticOverride != nil
        }
        audit["maskPixels"] = mask.filter { $0 != 0 }.count
        audit["primaryObservationRead"] = true
        audit["GTRead"] = false
        return .init(bounds: completed.bounds, mask: mask, audit: audit)
    }

    private static func matchingSeed(index: Int, rgb: [UInt8], seeds: [UInt8], width: Int, height: Int,
                                     radius: Int, tolerance: Int) -> Bool {
        let x = index % width, y = index / width, offset = index * 3
        for sy in max(0, y - radius)...min(height - 1, y + radius) {
            for sx in max(0, x - radius)...min(width - 1, x + radius) {
                let seed = sy * width + sx
                guard seeds[seed] != 0 else { continue }
                let source = seed * 3
                if (0..<3).allSatisfy({ abs(Int(rgb[offset + $0]) - Int(rgb[source + $0])) <= tolerance }) { return true }
            }
        }
        return false
    }

    /// RGB contrast edges use replicated crop borders, followed by an exact
    /// bounded L1 transform. A flat crop has no invented boundary evidence.
    static func uniformDistances(rgb: [UInt8], width: Int, height: Int, contrastThreshold: Int) throws -> [Int] {
        guard width > 0, height > 0, width <= 1_500_000 / height,
              rgb.count == width * height * 3, (1...255).contains(contrastThreshold) else {
            throw NativePixelRFBoundaryFeatures.Failure.invalidInput
        }
        var low = [UInt8](repeating: 0, count: rgb.count), high = low
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 3
                let left = (y * width + max(0, x - 1)) * 3
                let right = (y * width + min(width - 1, x + 1)) * 3
                for c in 0..<3 {
                    low[i + c] = min(rgb[left + c], rgb[i + c], rgb[right + c])
                    high[i + c] = max(rgb[left + c], rgb[i + c], rgb[right + c])
                }
            }
        }
        var edges = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let above = (max(0, y - 1) * width + x) * 3
                let below = (min(height - 1, y + 1) * width + x) * 3
                for c in 0..<3 {
                    let minimum = min(low[above + c], low[i * 3 + c], low[below + c])
                    let maximum = max(high[above + c], high[i * 3 + c], high[below + c])
                    if Int(maximum) - Int(minimum) >= contrastThreshold {
                        edges[i] = 255
                        break
                    }
                }
            }
        }
        return NativePixelRFFeatures.distance(toNonzero: edges, width: width, height: height)
    }

    private static func consensusSupport(index: Int, primary: [Float], boundary: [Float], width: Int, height: Int,
                                         policy: NativePixelRFForest.UniformityGate) -> Bool {
        let x = index % width, y = index / width
        for sy in max(0, y - policy.consensusRadius)...min(height - 1, y + policy.consensusRadius) {
            for sx in max(0, x - policy.consensusRadius)...min(width - 1, x + policy.consensusRadius) {
                let seed = sy * width + sx
                if primary[seed] >= policy.primarySeedThreshold && boundary[seed] >= policy.boundarySeedThreshold { return true }
            }
        }
        return false
    }

    /// A weak fringe may match a nearby source-classifier seed in all RGB
    /// channels. This is bounded by crop context, never a localization polygon.
    private static func colorSupport(index: Int, rgb: [UInt8], primary: [Float], boundary: [Float],
                                     width: Int, height: Int,
                                     policy: NativePixelRFForest.ColorCorroboration) -> Bool {
        let x = index % width, y = index / width, offset = index * 3
        for sy in max(0, y - policy.radius)...min(height - 1, y + policy.radius) {
            for sx in max(0, x - policy.radius)...min(width - 1, x + policy.radius) {
                let seed = sy * width + sx
                guard primary[seed] >= policy.primarySeedThreshold || boundary[seed] >= policy.boundarySeedThreshold else { continue }
                let source = seed * 3
                if (0..<3).allSatisfy({ abs(Int(rgb[offset + $0]) - Int(rgb[source + $0])) <= policy.tolerance }) {
                    return true
                }
            }
        }
        return false
    }

    static func segmentCrop(rgb: [UInt8], width: Int, height: Int, polygons: [[CGPoint]], fontPixels: Double,
                            coarseRF: [Float], fullRF: [Float], primaryModel: NativePixelRFForest,
                            boundaryModel: NativePixelRFForest) throws -> NativePixelRFSegmentation.Result {
        guard primaryModel.sourceModelSHA256 == boundaryModel.primarySourceModelSHA256 else {
            throw NativePixelRFBoundaryFeatures.Failure.invalidInput
        }
        var primary: [Float] = [], nativeMask: [UInt8] = []
        _ = try NativePixelRFSegmentation.segmentCrop(rgb: rgb, width: width, height: height, polygons: polygons,
            fontPixels: fontPixels, coarseRF: coarseRF, fullRF: fullRF, model: primaryModel,
            captureClassifier: { probabilities, base in primary = probabilities; nativeMask = base })
        return try refine(rgb: rgb, primary: primary, nativeMask: nativeMask, coarseRF: coarseRF, fullRF: fullRF,
            width: width, height: height, fontPixels: fontPixels, model: boundaryModel)
    }
}
