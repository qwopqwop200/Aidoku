import Foundation

/// The core-model-free source-page seam used by the actual backend and focused
/// activation tests. Inputs already contain real primary/M1 observations; this
/// stage executes five style roles and one whole-page BODY role, never RF/OCR/
/// segmentation/AOT/LLM or accepted appearance/font estimator graphs.
final class NativeM1SourcePageInference {
    static let revision = "actual-m1-p9-page-five-style-single-body-v1"
    static let bundled64DirectoryName = "M1SourceStyle64"
    static let bundled95PresenceDirectoryName = "M1SourcePresence95"
    static let bodyBase4SpecFileName = "BodyBase4MeasurementSpec.json"
    static let bodyBase4SpecSHA256 = "9aad440be0909479d027c26899439876db15e507b4b7d2f21ab235a27d591ff7"
    static let bodyFontInitializerIdentity = "compact-pinned-base4-font-spec-v1"
    static let bodyIntrinsicMetricsExecutionRevision = "base4-intrinsic-metrics-content-lru-v1"
    // Declared implementation limits/validation, not measured hits or RSS.
    // Numeric raw597 ABI and BODY predictions are not memoized.
    static let bodyIntrinsicMetricsCacheDeclaration =
        "enabled;process-local;4096-entry;<=1MiB-metrics-backing-not-RSS;four-readonly-root-snapshot-font-digests;fresh-mutable-file-SHA-and-miss-postSHA;no-bitmap-face-prediction-cache"
    enum Failure: Error { case unavailableModelDirectory, missingStyleDirectory, invalidLocalDirectory, invalidCohort, missingBodyFontSpec }
    struct Result {
        let styles: [[String: Any]]
        let weights: [[String: Any]]
        let audit: [String: Any]
    }
    let styleAssetDirectory: URL
    let checkpointIdentity: String
    private let style: NativeM1SourceStyleInference
    private let body: NativeSingleBodyWeightInference

    static func sourceModelDirectory(bundle: Bundle = .main, override: URL? = nil) throws -> URL {
        if let override {
            guard override.isFileURL else { throw Failure.invalidLocalDirectory }
            return override.standardizedFileURL
        }
        guard let resources = bundle.resourceURL else { throw Failure.unavailableModelDirectory }
        let candidates = [resources.appendingPathComponent("SourceModels"),
            resources.appendingPathComponent("Translation/SourceModels"),
            resources.appendingPathComponent("Resources/Translation/SourceModels"), resources]
        guard let directory = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("registry-index.json").path)
        }) else { throw Failure.unavailableModelDirectory }
        return directory
    }

    static func styleDirectory(modelDirectory: URL, variant: NativeM1SourceStyleInference.Variant,
                               override: URL? = nil) throws -> URL {
        if let override {
            guard override.isFileURL else { throw Failure.invalidLocalDirectory }
            return override.standardizedFileURL
        }
        guard variant == .rounds64 else { throw Failure.missingStyleDirectory }
        // SourceModels is an existing folder reference on both platforms. The
        // host's explicit modelDirectory also avoids stale Models.bundle copies.
        return modelDirectory.appendingPathComponent(bundled64DirectoryName, isDirectory: true)
    }

    static func presenceDirectory(modelDirectory: URL, variant: NativeM1SourceStyleInference.Variant,
                                  presenceABI: NativeM1SourceStyleInference.PresenceABI) throws -> URL? {
        guard presenceABI == .noBackground95 else { return nil }
        guard variant == .rounds64 else { throw Failure.missingStyleDirectory }
        return modelDirectory.appendingPathComponent(bundled95PresenceDirectoryName, isDirectory: true)
    }

    static func resolvedBodyBase4Spec(modelDirectory: URL, fontResources: URL? = nil) throws -> [String: Any] {
        let url = modelDirectory.appendingPathComponent(bodyBase4SpecFileName)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let size, (1...4096).contains(size.intValue) else { throw Failure.missingBodyFontSpec }
        let bytes = try Data(contentsOf: url)
        guard NativeFrozenSourceSHA256.hex(bytes) == bodyBase4SpecSHA256,
              let spec = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.missingBodyFontSpec }
        return try NativeSourceFontResolver.resolveBodyBase4MeasurementSpec(spec, resourceRoot: fontResources)
    }

    init(bundle: Bundle = .main, variant: NativeM1SourceStyleInference.Variant = .rounds64,
         modelDirectory: URL? = nil, fontResources: URL? = nil, styleDirectoryOverride: URL? = nil,
         presenceABI: NativeM1SourceStyleInference.PresenceABI = .legacy151) throws {
        let models = try Self.sourceModelDirectory(bundle: bundle, override: modelDirectory)
        // M1 must fail closed rather than let the generic Registry loader's
        // legacy missing-index fallback parse the complete metadata document.
        guard FileManager.default.fileExists(atPath: models.appendingPathComponent("registry-index.json").path) else {
            throw Failure.unavailableModelDirectory
        }
        let directory = try Self.styleDirectory(modelDirectory: models, variant: variant, override: styleDirectoryOverride)
        styleAssetDirectory = directory
        let presence = try Self.presenceDirectory(modelDirectory: models, variant: variant,
            presenceABI: presenceABI)
        style = try NativeM1SourceStyleInference(directory: directory, variant: variant,
            presenceABI: presenceABI, presenceDirectory: presence)
        // Exact ordered BASE4 projection is packaged and pinned separately.
        // No full registry/font graph metadata or unused 8+4 bank is parsed.
        // The BODY helper still authenticates its real model via compact index.
        let resolved = try Self.resolvedBodyBase4Spec(modelDirectory: models, fontResources: fontResources)
        body = try NativeSingleBodyWeightInference(directory: models, measurementSpec: resolved, measurementABI: .base4)
        let contract: [String: Any] = ["revision": Self.revision, "styleCheckpoint": style.checkpointIdentity,
            "BODYModelSHA256": NativeSingleBodyWeightInference.modelSHA256,
            "BODYBridge": NativeSingleBodyWeightInference.MeasurementABI.base4.rawValue,
            "BODYFontAdmission": "compact pinned BASE4 init+per-crop; no unused12 banks/full metadata",
            "BODYFontInitializer": Self.bodyFontInitializerIdentity,
            "BODYFontSpecSHA256": Self.bodyBase4SpecSHA256,
            "BODYIntrinsicMetricsExecutionRevision": Self.bodyIntrinsicMetricsExecutionRevision,
            "BODYIntrinsicMetricsCacheDeclaration": Self.bodyIntrinsicMetricsCacheDeclaration,
            "actualFontMeasurementSpecSHA256": NativeFrozenSourceSHA256.hex(
                try JSONSerialization.data(withJSONObject: resolved, options: .sortedKeys))]
        checkpointIdentity = NativeFrozenSourceSHA256.hex(try JSONSerialization.data(withJSONObject: contract, options: .sortedKeys))
    }

    func predict(_ inputs: [NativeMinimalSourceStyleInput]) throws -> Result {
        guard inputs.count <= 4096, Set(inputs.map(\.sourceIdentity)).count <= 1 else { throw Failure.invalidCohort }
        for input in inputs { try input.validate() }
        let pairStages = inputs.count > 1 && NativeSourceOwnerMeasurements.allowsIndependentPageStages(
            largestCrop: inputs.map { $0.ownMask.count }.max() ?? 0)
        func estimateStyles(mode: NativeSourceOwnerMeasurements.Mode) throws -> [[String: Any]] {
            try NativeSourceOwnerMeasurements.map(count: inputs.count, pixels: { inputs[$0].ownMask.count }, mode: mode) {
                [style] index in try style.predict(inputs[index])
            }
        }
        let styles: [[String: Any]], weights: [[String: Any]]
        if pairStages {
            (styles, weights) = try NativeSourceOwnerMeasurements.pair(
                { try estimateStyles(mode: .serial) },
                { [body] in try body.estimateBase4(inputs) })
        } else {
            styles = try estimateStyles(mode: .style)
            weights = try body.estimate(inputs, styles: styles)
        }
        guard styles.count == inputs.count, weights.count == inputs.count else { throw Failure.invalidCohort }
        return Result(styles: styles, weights: weights, audit: ["revision": Self.revision,
            "checkpointSHA256": checkpointIdentity, "sourceOnly": true, "GTAtInference": false,
            "actualOwners": inputs.count, "styleRoleCount": 5, "BODYRoleCount": 1,
            "BODYPageBatchForwardCalls": inputs.isEmpty ? 0 : 1,
            "upstreamPrimaryComputedHere": false, "coreModelForwardCalls": 0,
            "rich209Executed": false, "acceptedAppearanceGraphConstructed": false,
            "BODYBridge": NativeSingleBodyWeightInference.MeasurementABI.base4.rawValue,
            "BODYFontInitializer": Self.bodyFontInitializerIdentity,
            "BODYFontSpecSHA256": Self.bodyBase4SpecSHA256,
            "BODYIntrinsicMetricsExecutionRevision": Self.bodyIntrinsicMetricsExecutionRevision,
            "BODYIntrinsicMetricsCacheDeclaration": Self.bodyIntrinsicMetricsCacheDeclaration,
            "pinnedFontDescriptorContract": "compact pinned BASE4 init+per-crop; no unused12 banks/full metadata"])
    }
}
