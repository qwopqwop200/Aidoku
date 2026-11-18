import Accelerate
import CoreGraphics
import CryptoKit
import Foundation

/// A separate typed graph: absent learned observations are nil, never fake
/// boundary/style/joint arrays made to satisfy the legacy full-source ABI.
final class NativeMinimalSourceSegmentation {
    enum Failure: Error { case invalidConfiguration, invalidInput, missingPrimary, primaryArtifactMismatch }
    enum Mode: String, Sendable { case primaryOnly, rfTextOnly, rfCoarseTextSFX }
    struct WeakRecovery: Sendable, Equatable {
        let minimumPrimaryProbability: Float
        let radius: Int
        init(minimumPrimaryProbability: Float, radius: Int) {
            self.minimumPrimaryProbability = minimumPrimaryProbability; self.radius = radius
        }
    }
    struct Configuration: Sendable, Equatable {
        let mode: Mode
        let threshold: Float
        let closingRadius: Int
        let weakRecovery: WeakRecovery?
        init(mode: Mode, threshold: Float = 0.5, closingRadius: Int = 0, weakRecovery: WeakRecovery? = nil) {
            self.mode = mode; self.threshold = threshold; self.closingRadius = closingRadius
            self.weakRecovery = weakRecovery
        }
        var policyRevision: String { "minimal-source-mask-v1/" + mode.rawValue }
        var policySHA256: String {
            var contract = "minimal-source-mask-v1;mode=\(mode.rawValue);threshold-f32=\(threshold.bitPattern);square-close-radius=\(closingRadius);zero-exterior;native-rf-text0-sfx1;primary62-preseed-preserved;postcompletion=none"
            if let recovery = weakRecovery {
                contract += ";weak-primary-f32=\(recovery.minimumPrimaryProbability.bitPattern);weak-radius=\(recovery.radius);weak-support=none;single-original-core-neighborhood;before-square-close"
            }
            return SHA256.hash(data: Data(contract.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
    struct Input: Sendable {
        let width: Int
        let height: Int
        let rgb: [UInt8]
        let fullRF: [Float]
        let coarseRF: [Float]
        let memberPolygons: [[CGPoint]] // Actual owner seeds, crop-local; never output clipping.
        let fontPixels: Double // Actual constructor prior, not a manufactured font observation.
        let rfModelWeightsSHA256: String
    }
    struct Output {
        let mask: [UInt8]
        let primary: [Float]?
        let nativeSeed: [UInt8]?
        let audit: [String: Any]
    }
    static let primaryArtifactSHA256 = NativePixelRFForest.primarySourceFileSHA256
    let configuration: Configuration
    private let primary: NativePixelRFForest?

    convenience init(configuration: Configuration, bundle: Bundle = .main, sourceDirectory: URL? = nil) throws {
        try self.init(configuration: configuration, loadPrimary: {
            let url = try Self.primaryURL(bundle: bundle, sourceDirectory: sourceDirectory)
            if url.pathExtension == "pr62" {
                guard let model = try NativePixelRFForest.readPackedPrimary(at: url) else { throw Failure.primaryArtifactMismatch }
                return model
            }
            let data = try Data(contentsOf: url)
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard sha == Self.primaryArtifactSHA256 else { throw Failure.primaryArtifactMismatch }
            // Automatically resolved development resources can contain both files. Verify
            // the existing JSON before using its derivative. Explicit directories retain
            // their original JSON-only contract.
            if sourceDirectory == nil,
               let model = try? NativePixelRFForest.readPackedPrimary(at: url.deletingPathExtension().appendingPathExtension("pr62")) {
                return model
            }
            let model = try NativePixelRFForest(data: data)
            guard model.featureCount == 62 else { throw Failure.primaryArtifactMismatch }
            return model
        })
    }

    /// Injection point for focused graph tests. RF modes MUST NOT call loader.
    init(configuration: Configuration, loadPrimary: () throws -> NativePixelRFForest) throws {
        guard configuration.threshold.isFinite, (0...1).contains(configuration.threshold),
              (0...3).contains(configuration.closingRadius) else { throw Failure.invalidConfiguration }
        if let recovery = configuration.weakRecovery {
            guard configuration.mode == .primaryOnly, recovery.minimumPrimaryProbability.isFinite,
                  recovery.minimumPrimaryProbability >= 0, recovery.minimumPrimaryProbability <= configuration.threshold,
                  (1...3).contains(recovery.radius) else { throw Failure.invalidConfiguration }
        }
        self.configuration = configuration
        primary = configuration.mode == .primaryOnly ? try loadPrimary() : nil
    }

    func predict(_ input: Input) throws -> Output {
        let w = input.width, h = input.height
        guard w > 0, h > 0, w <= 1_500_000 / h, input.rgb.count == w * h * 3,
              input.rfModelWeightsSHA256 == NativeRFDETRLayoutResource.highresSourceWeightsSHA256 else { throw Failure.invalidInput }
        try Task.checkCancellation()
        let n = w * h
        let probabilities: [Float]?
        let nativeSeed: [UInt8]?
        var mask: [UInt8]
        var weakPixelsAdded = 0
        switch configuration.mode {
        case .primaryOnly:
            guard let primary, input.fullRF.count == n * 27, input.coarseRF.count == n * 4,
                  input.fontPixels.isFinite, input.fontPixels > 0,
                  !input.memberPolygons.isEmpty, input.memberPolygons.count <= 256,
                  input.memberPolygons.allSatisfy({ (3...16).contains($0.count) && $0.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) }) else {
                throw Failure.invalidInput
            }
            // Preserve the EXACT pre-primary learned feature closure. The
            // post-primary `complete` call is deliberately absent, not merely
            // bypassed by returning from a captureClassifier callback.
            typealias Factory = NativeMainRemovalSourceFactory
            let source = Factory.NativeCurrentMaskCaller.Source(width: w, height: h, rgb: input.rgb, revision: "fresh-source-crop")
            let owners = input.memberPolygons.enumerated().map { index, polygon in
                Factory.NativeCurrentMaskCaller.Owner(id: String(index), polygon: polygon,
                    fontPixels: input.fontPixels, translated: true, balloon: false)
            }
            let base = try Factory.NativeSourceBaseMask.extract(source: source, owners: owners)
            let chroma = try Factory.NativeChromaticMaskCompletion.complete(rgb: input.rgb, width: w, height: h,
                base: base.mask, protection: [UInt8](repeating: 0, count: n),
                owners: owners.map { .init(id: $0.id, polygon: $0.polygon, fontPixels: $0.fontPixels) })
            let p = try primary.cropProbabilities(.init(width: w, height: h, rgb: input.rgb,
                nativeMask: chroma.mask, polygons: input.memberPolygons, fontPixels: input.fontPixels,
                coarseRF: input.coarseRF, fullRF: input.fullRF))
            guard p.count == n, p.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  chroma.mask.count == n else { throw Failure.invalidInput }
            probabilities = p; nativeSeed = chroma.mask
            if let recovery = configuration.weakRecovery {
                mask = try Self.recoverWeak(primary: p, width: w, height: h,
                    strongThreshold: configuration.threshold, recovery: recovery)
                weakPixelsAdded = mask.indices.reduce(0) { $0 + (mask[$1] != 0 && p[$1] < configuration.threshold ? 1 : 0) }
            } else {
                mask = p.map { $0 >= configuration.threshold ? 255 : 0 }
            }
        case .rfTextOnly:
            guard input.fullRF.count == n * 27 else { throw Failure.invalidInput }
            mask = [UInt8](repeating: 0, count: n)
            for i in 0..<n {
                if i % 16384 == 0 { try Task.checkCancellation() }
                let value = input.fullRF[i * 27] // Source-native TEXT plane0, not Host canonical class1.
                guard value.isFinite, (0...1).contains(value) else { throw Failure.invalidInput }
                mask[i] = value >= configuration.threshold ? 255 : 0
            }
            probabilities = nil; nativeSeed = nil
        case .rfCoarseTextSFX:
            guard input.coarseRF.count == n * 4 else { throw Failure.invalidInput }
            mask = [UInt8](repeating: 0, count: n)
            for i in 0..<n {
                if i % 16384 == 0 { try Task.checkCancellation() }
                let text = input.coarseRF[i * 4], sfx = input.coarseRF[i * 4 + 1]
                guard text.isFinite, sfx.isFinite, (0...1).contains(text), (0...1).contains(sfx) else { throw Failure.invalidInput }
                mask[i] = max(text, sfx) >= configuration.threshold ? 255 : 0
            }
            probabilities = nil; nativeSeed = nil
        }
        mask = try Self.close(mask, width: w, height: h, radius: configuration.closingRadius)
        var audit: [String: Any] = ["policySHA256": configuration.policySHA256, "policyRevision": configuration.policyRevision,
                "maskStage": configuration.mode.rawValue, "thresholdFloat32Bits": configuration.threshold.bitPattern,
                "squareClosingRadius": configuration.closingRadius, "primaryExecuted": probabilities != nil,
                "primaryPreseedRetained": nativeSeed != nil, "boundaryExecuted": false,
                "postPrimaryCompletionExecuted": false, "context83Executed": false, "style78Executed": false,
                "jointExecuted": false, "fullLegacySourceOutputManufactured": false,
                "weakRecoveryExecuted": configuration.weakRecovery != nil, "weakPixelsAddedBeforeClosing": weakPixelsAdded,
                "GTRead": false, "storedMaskRead": false, "bboxMaskClipping": false, "legacyFallback": false]
        if let recovery = configuration.weakRecovery {
            audit["weakRecovery"] = ["minimumPrimaryFloat32Bits": recovery.minimumPrimaryProbability.bitPattern,
                "radius": recovery.radius, "support": "none", "anchorThresholdFloat32Bits": configuration.threshold.bitPattern,
                "onlyOriginalStrongPixelsAnchor": true, "singlePass": true, "additionalLearnedHeads": 0]
        }
        return Output(mask: mask, primary: probabilities, nativeSeed: nativeSeed, audit: audit)
    }

    /// Cheap erasure-policy replay from an ACTUAL already computed primary
    /// observation. Does not construct/load/invoke a forest or manufacture a
    /// rich SourceNativeInput. A legacy feature consumer can keep its original
    /// ownMask while this independent selected mask is used only for erasure.
    static func postprocessPrimary(_ primary: [Float], width: Int, height: Int,
                                   configuration: Configuration) throws -> [UInt8] {
        guard configuration.mode == .primaryOnly else { throw Failure.invalidConfiguration }
        guard width > 0, height > 0, width <= 1_500_000 / height, primary.count == width * height,
              configuration.threshold.isFinite, (0...1).contains(configuration.threshold),
              (0...3).contains(configuration.closingRadius),
              primary.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Failure.invalidInput }
        let mask: [UInt8]
        if let recovery = configuration.weakRecovery {
            mask = try recoverWeak(primary: primary, width: width, height: height,
                strongThreshold: configuration.threshold, recovery: recovery)
        } else {
            mask = primary.map { $0 >= configuration.threshold ? 255 : 0 }
        }
        return try close(mask, width: width, height: height, radius: configuration.closingRadius)
    }

    /// One bounded expansion from ORIGINAL strong probabilities. Recovered
    /// fringe pixels never become anchors; no iterative connected-component
    /// spread, extra classifier, RF calibration, GT or page-specific rule.
    static func recoverWeak(primary: [Float], width: Int, height: Int, strongThreshold: Float,
                            recovery: WeakRecovery) throws -> [UInt8] {
        guard width > 0, height > 0, width <= 1_500_000 / height, primary.count == width * height,
              strongThreshold.isFinite, (0...1).contains(strongThreshold),
              recovery.minimumPrimaryProbability.isFinite, recovery.minimumPrimaryProbability >= 0,
              recovery.minimumPrimaryProbability <= strongThreshold, (1...3).contains(recovery.radius),
              primary.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Failure.invalidInput }
        let radius = recovery.radius
        var mask = [UInt8](repeating: 0, count: primary.count)
        try mask.withUnsafeMutableBufferPointer { out in
            guard let buffer = out.baseAddress else { throw Failure.invalidInput }
            for y in 0..<height {
                if y % 64 == 0 { try Task.checkCancellation() }
                let row = y * width
                var x = 0
                while x < width {
                    guard primary[row + x] >= strongThreshold else { x += 1; continue }
                    let left = max(0, x - radius)
                    repeat { x += 1 } while x < width && primary[row + x] >= strongThreshold
                    let right = min(width, x + radius)
                    // The union of the squares from this original strong run
                    // is a rectangle. Recovered pixels never enter the scan.
                    for yy in max(0, y - radius)...min(height - 1, y + radius) {
                        (buffer + yy * width + left).update(repeating: 255, count: right - left)
                    }
                }
            }
            for i in primary.indices where out[i] != 0 && primary[i] < recovery.minimumPrimaryProbability {
                out[i] = 0
            }
        }
        return mask
    }

    /// Square binary closing with explicit zero exterior, matching the compact
    /// Python baseline. Dilation includes an r-pixel exterior before erosion.
    static func close(_ mask: [UInt8], width: Int, height: Int, radius: Int) throws -> [UInt8] {
        guard width > 0, height > 0, width <= 1_500_000 / height, mask.count == width * height,
              (0...3).contains(radius), mask.allSatisfy({ $0 == 0 || $0 == 255 }) else { throw Failure.invalidInput }
        guard radius > 0 else { return mask }
        let ew = width + radius * 2, eh = height + radius * 2
        let kernel = vImagePixelCount(2 * radius + 1), offset = vImagePixelCount(radius)
        var padded = [UInt8](repeating: 0, count: ew * eh)
        try padded.withUnsafeMutableBufferPointer { dest in
            try mask.withUnsafeBufferPointer { src in
                for y in 0..<height {
                    if y % 64 == 0 { try Task.checkCancellation() }
                    (dest.baseAddress! + (y + radius) * ew + radius)
                        .update(from: src.baseAddress! + y * width, count: width)
                }
            }
        }
        var expanded = [UInt8](repeating: 0, count: ew * eh)
        var result = [UInt8](repeating: 0, count: mask.count)
        try expanded.withUnsafeMutableBytes { dilatedBytes in
            var dilated = vImage_Buffer(data: dilatedBytes.baseAddress!, height: vImagePixelCount(eh),
                width: vImagePixelCount(ew), rowBytes: ew)
            try padded.withUnsafeMutableBytes { paddedBytes in
                var source = vImage_Buffer(data: paddedBytes.baseAddress!, height: dilated.height,
                    width: dilated.width, rowBytes: ew)
                try Task.checkCancellation()
                guard vImageMax_Planar8(&source, &dilated, nil, 0, 0, kernel, kernel, 0) == kvImageNoError
                    else { throw Failure.invalidInput }
            }
            try result.withUnsafeMutableBytes { resultBytes in
                var output = vImage_Buffer(data: resultBytes.baseAddress!, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width)
                try Task.checkCancellation()
                guard vImageMin_Planar8(&dilated, &output, nil, offset, offset, kernel, kernel, 0) == kvImageNoError
                    else { throw Failure.invalidInput }
            }
        }
        try Task.checkCancellation()
        return result
    }

    private static func primaryURL(bundle: Bundle, sourceDirectory: URL?) throws -> URL {
        if let sourceDirectory { return sourceDirectory.appendingPathComponent("primary-forest.json") }
        var candidates: [URL] = []
        if let resources = bundle.resourceURL {
            candidates += [resources.appendingPathComponent("Translation/SegmentationAcceptedFinal"),
                resources.appendingPathComponent("SegmentationAcceptedFinal"),
                resources.appendingPathComponent("Resources/Translation/SegmentationAcceptedFinal"), resources]
        }
        #if os(macOS)
        if let root = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"], !root.isEmpty {
            candidates.append(URL(fileURLWithPath: root).appendingPathComponent("Aidoku/Resources/Translation/SegmentationAcceptedFinal"))
        }
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        candidates.append(repository.appendingPathComponent("Aidoku/Resources/Translation/SegmentationAcceptedFinal"))
        #endif
        for directory in candidates {
            if let url = NativePixelRFForest.primaryResource(in: directory) { return url }
        }
        throw Failure.missingPrimary
    }
}
