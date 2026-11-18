import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// The ordinary host renderer installs this executable backend. It always
/// reconstructs source observations, masks, styles and same-page font packets.
/// No saved appearance records or corpus inventories enter the request.
final class HostOperationalAppearance: NativeLiveSourceAppearance.Backend, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var backend: HostOperationalAppearance?
    }
    private static let registry = Registry()
    private let root: URL
    private let detector: NativeRFDETRLayoutDetector
    private let lock = NSLock()
    private let selection: String
    private let verificationOutput: URL?
    private let verificationSourceSHA256: String?
    private var native: NativeOperationalSourceInference?

    /// macOS and iOS use the same frozen source graph by default. The old host
    /// adapter remains an explicit diagnostic comparison, never an implicit fallback.
    static var selectedBackend: String {
        ProcessInfo.processInfo.environment["AIDOKU_OPERATIONAL_APPEARANCE_BACKEND"] ?? "shared-native"
    }

    static func install(root: URL) {
        registry.lock.lock(); defer { registry.lock.unlock() }
        let selection = selectedBackend
        if registry.backend?.root != root || registry.backend?.selection != selection {
            registry.backend = HostOperationalAppearance(root: root, selection: selection)
        }
        NativeLiveSourceAppearance.shared.install(registry.backend!)
    }

    private init(root: URL, selection: String = "shared-native", verificationOutput: URL? = nil,
                 verificationSourceSHA256: String? = nil) {
        self.root = root
        self.selection = selection
        self.verificationOutput = verificationOutput
        self.verificationSourceSHA256 = verificationSourceSHA256
        detector = NativeRFDETRLayoutDetector(retainAllQueryMasks: true,
            expectedWeightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
            expectedSourceRevision: NativeRFDETRLayoutResource.highresSourceRevision,
            resolveModelURL: {
                guard let url = HostResources.bundle.url(forResource: "KoharuHighres648FP16", withExtension: "mlmodelc") else {
                    throw NativeRFDETRLayoutError.modelUnavailable
                }
                return url
            })
    }

    /// These are the app's packaged assets, not research estimators or host-only
    /// fonts. The shared initializer validates RF tensor/checkpoint metadata;
    /// native model/font loaders authenticate the selected artifact bytes.
    private func sharedNative() throws -> NativeOperationalSourceInference {
        try NativeSourceInferencePolicy.validate()
        let staged = try NativeSourceInferencePolicy.stagedM1StyleDirectory()
        if let native, native.inferencePolicy == NativeSourceInferencePolicy.selected,
           native.m1StyleAssetDirectory == staged { return native }
        let resources = root.appendingPathComponent("Aidoku/Resources/Translation")
        let backend = try NativeOperationalSourceInference(bundle: HostResources.bundle,
            modelDirectory: resources.appendingPathComponent("SourceModels"),
            fontResources: resources.appendingPathComponent("SourceReferenceFonts.bundle"), m1StyleDirectory: staged)
        native = backend
        return backend
    }

    /// Module-bank collection, not a renderer/E2E route. Keep the real source
    /// text eligible without inventing a translation or changing preservation
    /// selection in the ordinary pipeline. The caller supplies the CURRENT OCR
    /// packet; no resident evidence-store lookup or evidence enrichment occurs.
    static func collectObservedSourceBank(root: URL, source: CGImage,
        regions: [ReaderTranslationRegion], packet: NativeMainEnsembleOCREvidence.Packet,
        segmentationObserver: NativeSelectedSourceSegmentationProducer.SourceReplayObserver? = nil,
        diagnostics: NativeSourceFeatureObserver? = nil,
        constructorObserver: (([NativeSourceInputFactory.Owner], NativeRFDETRSourceImage) throws -> Void)? = nil) throws -> NativeLiveSourceAppearance.Output {
        // The frozen rich-observation bank cannot be silently repurposed as a
        // minimal candidate bank with absent boundary/OCR/font observations.
        try NativeSourceInferencePolicy.validate()
        guard NativeSourceInferencePolicy.selected == .accepted else {
            throw HostError.message("Frozen source-bank collection requires accepted source policy")
        }
        let binding = try HostEnsembleEvidence.sourceStageBinding(original: source,
            sourceURL: HostDump.context?.sourceURL,
            fallbackURL: HostDump.context?.directory.appendingPathComponent("input.png"))
        guard packet.binding.contentIdentity == binding.contentIdentity,
              packet.binding.width == source.width, packet.binding.height == source.height,
              packet.binding.verifiedEncodedSourceSHA256.map({ $0 == binding.verifiedEncodedSourceSHA256 }) ?? true else {
            throw HostError.message("Source-bank current OCR packet differs from this page")
        }
        let items = observedSourceBankItems(regions)
        let evidence = try packet.savedEvidence(currentOriginalItems: items, removalMaskAvailable: false)
        let backend = observedSourceBackend(root: root)
        backend.lock.lock(); defer { backend.lock.unlock() }
        try Task.checkCancellation()
        let featureExport = try backend.sourceFeatureObserver(source: source)
        let observer: NativeSourceFeatureObserver?
        if featureExport == nil && diagnostics == nil {
            observer = nil
        } else {
            observer = { (index: Int, stage: String, payload: [String: Any]) throws -> Void in
                try featureExport?(index, stage, payload)
                try diagnostics?(index, stage, payload)
            }
        }
        let output = try backend.sharedNative().annotate(source: source, items: items, sourceEvidence: evidence,
            segmentationObserver: segmentationObserver, diagnostics: observer, constructorObserver: constructorObserver)
        HostDump.capture("source-bank-cohort", ["schema": "aidoku-observed-source-bank-cohort-v1",
            "cohort": "all-actual-observed-grouped-owners-preLLM", "E2E": false,
            "sourceOnly": true, "GTAtInference": false, "providerInvoked": false,
            "AOTInvoked": false, "renderInvoked": false,
            "sourceIdentity": binding.contentIdentity,
            "sourceEncodedSHA256": binding.verifiedEncodedSourceSHA256 as Any? ?? NSNull(),
            "observedGroupedOwners": regions.count,
            "nonemptySourceOwners": regions.filter { !$0.source.isEmpty }.count,
            "modelBinding": try backend.modelBinding(),
            "owners": regions.enumerated().map { index, region -> [String: Any] in
                ["itemIndex": index, "regionID": region.id,
                 "sourceTextSHA256": NativeFrozenSourceSHA256.hex(Data(region.source.utf8)),
                 "sourceBounds": [Double(region.rect.minX), Double(region.rect.minY), Double(region.rect.width), Double(region.rect.height)],
                 "emptySource": region.source.isEmpty]
            }])
        return output
    }

    private static func observedSourceBackend(root: URL) -> HostOperationalAppearance {
        registry.lock.lock(); defer { registry.lock.unlock() }
        if let existing = registry.backend, existing.root == root { return existing }
        let backend = HostOperationalAppearance(root: root)
        registry.backend = backend
        return backend
    }

    /// Actual source-model assets selected by this same host-only producer.
    static func observedSourceModelBinding(root: URL) throws -> [String: Any] {
        let backend = observedSourceBackend(root: root)
        backend.lock.lock(); defer { backend.lock.unlock() }
        return try backend.modelBinding()
    }

    /// Projection of actual Reader observations only: no target layout/font,
    /// role answer, inferred translation, DET/REC augmentation or GT metadata.
    static func observedSourceBankItems(_ regions: [ReaderTranslationRegion]) -> [[String: Any]] {
        regions.map { region in
            var item: [String: Any] = ["text": region.source, "sourceOriginalText": region.source,
                "sourceBounds": [Double(region.rect.minX), Double(region.rect.minY), Double(region.rect.width), Double(region.rect.height)],
                "sourcePolygon": region.polygon.map { [Double($0.x), Double($0.y)] },
                "sourceConfidence": region.confidence]
            if !region.sourceMemberPolygons.isEmpty {
                item["sourceMemberPolygons"] = region.sourceMemberPolygons.map { $0.map { [Double($0.x), Double($0.y)] } }
            }
            if !region.unitMemberRects.isEmpty {
                item["unitMemberRects"] = region.unitMemberRects.map {
                    [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)]
                }
            }
            return item
        }
    }

    private func modelBinding() throws -> [String: Any] {
        try NativeSourceInferencePolicy.validate()
        if NativeSourceInferencePolicy.selected.usesMinimalObservations && !NativeSourceInferencePolicy.selected.usesMinimalM1Style {
            return ["sourcePolicy": NativeSourceInferencePolicy.cacheProjection,
                "sourceArtifacts": [String: String](), "sourceModelsHeadRoles": 0,
                "sourceFontEstimator": NativeSimpleSourceFont.identity,
                "sourceFontHeadCount": 0, "appearanceHeadCount": 0, "weightHeadCount": 0,
                "segmentationPolicySHA256": NativeSourceSegmentationExecution.policySHA256,
                "segmentationPolicyRevision": NativeSourceSegmentationExecution.policyRevision,
                "erasureSegmentationPolicySHA256": NativeSourceSegmentationExecution.erasurePolicySHA256,
                "erasureSegmentationPolicyRevision": NativeSourceSegmentationExecution.erasurePolicyRevision,
                "primaryModelSHA256": NativeSourceInferencePolicy.selected == .minimalPrimary ?
                    NativeMinimalSourceSegmentation.primaryArtifactSHA256 : "not-loaded",
                "registryLoaded": false, "fontResourcesLoaded": false,
                "RFWeightsSHA256": NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
                "RFSourceRevision": NativeRFDETRLayoutResource.highresSourceRevision,
                "sourceArtifactAuthority": "minimal actual constructor; no SourceModels registry or font resource lookup"]
        }
        let resources = root.appendingPathComponent("Aidoku/Resources/Translation")
        let path = resources.appendingPathComponent("SourceModels/registry-index.json")
        let bytes = try Data(contentsOf: path)
        guard let index = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw HostError.message("Native source registry index is not an object")
        }
        if let variant = NativeSourceInferencePolicy.selected.m1StyleVariant {
            let staged = try NativeSourceInferencePolicy.stagedM1StyleDirectory()
            let presenceABI = NativeSourceInferencePolicy.selected.m1PresenceABI
            let presence = try NativeM1SourcePageInference.presenceDirectory(
                modelDirectory: resources.appendingPathComponent("SourceModels"), variant: variant,
                presenceABI: presenceABI)
            return ["sourcePolicy": NativeSourceInferencePolicy.cacheProjection,
                "registryIndexSHA256": NativeFrozenSourceSHA256.hex(bytes),
                "sourceArtifacts": ["primary62": NativeMinimalSourceSegmentation.primaryArtifactSHA256,
                    "BODY180": NativeSingleBodyWeightInference.modelSHA256],
                "expectedPinnedStyleSHA256": NativeM1SourceStyleInference.roleSHA256(for: variant, presenceABI: presenceABI),
                "externalStyleAssetDirectory": staged?.path ?? "not-used; bundled64",
                "styleAssetDirectory": staged?.path ?? resources.appendingPathComponent("SourceModels/M1SourceStyle64").path,
                "styleAssetStorage": staged == nil ? "packaged64" : "verified-local-override",
                "presenceABI": presenceABI.rawValue,
                "presenceAssetDirectory": presence?.path ?? "not-used; legacy151 in style directory",
                "presenceAssetStorage": presenceABI == .legacy151 ? "legacy-style-directory" : "pinned95-from-selected-model-directory",
                "styleRoleAssetBytes": NativeM1SourceStyleInference.roleAssetBytes(for: variant, presenceABI: presenceABI),
                "BODYLoader": "compact-registry-direct-role; no accepted-appearance policy asset loader",
                "BODYFontValidation": "compact pinned BASE4 init+per-crop; no unused12 banks/full BODY metadata",
                "BODYFontInitializer": NativeM1SourcePageInference.bodyFontInitializerIdentity,
                "BODYFontSpecSHA256": NativeM1SourcePageInference.bodyBase4SpecSHA256,
                "BODYMeasurementABI": NativeSingleBodyWeightInference.MeasurementABI.base4.rawValue,
                "BODYIntrinsicMetricsExecutionRevision": NativeM1SourcePageInference.bodyIntrinsicMetricsExecutionRevision,
                "BODYIntrinsicMetricsCacheDeclaration": NativeM1SourcePageInference.bodyIntrinsicMetricsCacheDeclaration,
                "sourceM1StyleCandidate": variant.candidateID,
                "sourceM1StyleIdentity": NativeM1SourceStyleInference.cacheIdentity(for: variant, presenceABI: presenceABI),
                "sourceFontEstimator": NativeSimpleSourceFont.identity, "sourceFontHeadCount": 0,
                "appearanceHeadCount": 5, "weightHeadCount": 1, "segmentationHeadCount": 1,
                "learnedSourceAuxiliaryHeadCount": 7, "compactRegistryHeadRoles": 1, "styleHeadRoles": 5,
                "headAccountingScope": "1primary62+5pinned-style-roles+1packaged-BODY180; upstream RF-DETR retained",
                "appearanceGraph": "actual-M1-physical35-primary9;no-accepted-appearance-graph",
                "rich209Executed": false, "boundaryOCRContextFeatureHeadsExecuted": false,
                "registryLoaded": true, "fontResourcesLoaded": true,
                "fullFontMetadataParsedForBodyDescriptors": false,
                "physicalGlyphMetricFontDescriptorsRetained": true,
                "pinnedFontDescriptorValidationPerCrop": true,
                "bodyBridgeDescriptorContract": "compact pinned BASE4 initializer+glyphMetricsRaster/raw597 per-crop; direct7Fill71NotComputed",
                "bodyBridgeAdmissionContract": "actualRGBBBoxOriginalPriorNFCText;only4BaseFontsAdmittedReadAndHashedPerCrop;noStyleOwnershipSourceEmBridgeInputs",
                "PCAPrototypeAndFullFontTemplateGraphRetainedForWeight": false,
                "singleBodyHeadRole": NativeSingleBodyWeightInference.modelIdentity,
                "singleBodyHeadSHA256": NativeSingleBodyWeightInference.modelSHA256,
                "singleBodyThreshold": NativeSingleBodyWeightInference.threshold,
                "segmentationPolicySHA256": NativeSourceSegmentationExecution.policySHA256,
                "segmentationPolicyRevision": NativeSourceSegmentationExecution.policyRevision,
                "erasureSegmentationPolicySHA256": NativeSourceSegmentationExecution.erasurePolicySHA256,
                "erasureSegmentationPolicyRevision": NativeSourceSegmentationExecution.erasurePolicyRevision,
                "styleAndErasureShareActualM1Mask": NativeSourceSegmentationExecution.erasurePolicySHA256 ==
                    NativeSourceSegmentationExecution.policySHA256,
                "RFWeightsSHA256": NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
                "sourceArtifactAuthority": "declared pinned closure; external bytes authenticated by shared native initializer; counts are not measured execution timings"]
        }
        if NativeSourceInferencePolicy.selected.usesSimpleFont {
            let retainsWeight = NativeSourceInferencePolicy.selected.usesAcceptedWeight
            let singleBody = NativeSourceInferencePolicy.selected.usesSingleBodyWeight
            let entries = index["heads"] as? [String: Any] ?? [:]
            return ["registryIndexSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                "sourcePolicy": NativeSourceInferencePolicy.cacheProjection,
                "sourceFontEstimator": NativeSimpleSourceFont.identity,
                "appearanceGraph": "actual-accepted-source-graph;actual-rich-segmentation-and-OCR-inputs",
                "availableAppearanceHeadRoles": entries.keys.filter { $0.hasPrefix("appearance/") }.count,
                "availableSegmentationRefinementHeadRoles": entries.keys.filter { $0.hasPrefix("segmentation/") }.count,
                "fontHeadsRetainedForWeight": retainsWeight,
                "availableRetainedFontHeadRoles": retainsWeight ? entries.keys.filter { $0.hasPrefix("font198/") }.count : 0,
                "availableRetainedWeightHeadRoles": retainsWeight ? entries.keys.filter { $0.hasPrefix("font-weight/") }.count : (singleBody ? 1 : 0),
                "originalMembersFontMeasurementExecuted": false, "bboxOnlyFontMeasurementExecuted": retainsWeight,
                "PCAPrototypeAndFullFontTemplateGraphRetainedForWeight": retainsWeight,
                "physicalGlyphMetricFontDescriptorsRetained": retainsWeight || singleBody,
                "registryLoaded": true, "fontResourcesLoaded": retainsWeight || singleBody,
                "fullFontMetadataParsedForBodyDescriptors": singleBody,
                "bodyBridgeDescriptorContract": singleBody ? "pinned4/8/4;glyphMetricsRasterUsesBase4;dedicatedRaw597Only;direct7Fill71NotComputed" : "not-used",
                "bodyBridgeAdmissionContract": singleBody ? "actualStyleOwnershipSourceEmAndPinnedDescriptorsValidated;raw597UsesRGBBboxOriginalPriorTextBaseFonts" : "not-used",
                "singleBodyHeadRole": singleBody ? NativeSingleBodyWeightInference.modelIdentity : "not-used",
                "singleBodyHeadSHA256": singleBody ? NativeSingleBodyWeightInference.modelSHA256 : "not-used",
                "singleBodyThreshold": singleBody ? NativeSingleBodyWeightInference.threshold : 0,
                "segmentationPolicySHA256": NativeSourceSegmentationExecution.policySHA256,
                "segmentationPolicyRevision": NativeSourceSegmentationExecution.policyRevision,
                "erasureSegmentationPolicySHA256": NativeSourceSegmentationExecution.erasurePolicySHA256,
                "erasureSegmentationPolicyRevision": NativeSourceSegmentationExecution.erasurePolicyRevision,
                "erasureConsumesAlreadyComputedPrimary": NativeSourceInferencePolicy.erasureSegmentationConfiguration != nil,
                "RFWeightsSHA256": NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
                "RFSourceRevision": NativeRFDETRLayoutResource.highresSourceRevision,
                "sourceArtifactAuthority": "actual hybrid constructor; available roles are not eager-load counters",
                "sourceArtifacts": index["sourceArtifacts"] ?? [:]]
        }
        return ["registryIndexSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "sourceArtifacts": index["sourceArtifacts"] ?? [:],
            "sourceFontEstimator": NativeAcceptedSourceFontInference.selectedEstimatorIdentity,
            "sourceFontEstimatorCachePolicy": NativeAcceptedSourceFontInference.cachePolicy as Any? ?? NSNull(),
            "sourceArtifactAuthority": "packaged asset inventory; selected estimator records actual font-size role separately",
            "segmentationPolicySHA256": NativeSourceSegmentationExecution.policySHA256,
            "segmentationPolicyRevision": NativeSourceSegmentationExecution.policyRevision,
            "erasureSegmentationPolicySHA256": NativeSourceSegmentationExecution.erasurePolicySHA256,
            "erasureSegmentationPolicyRevision": NativeSourceSegmentationExecution.erasurePolicyRevision,
            "frozenSegmentationPolicySHA256": NativeSegmentationFinalPolicy.frozenBaselinePolicySHA256,
            "fontResources": resources.appendingPathComponent("SourceReferenceFonts.bundle").path,
            "RFWeightsSHA256": NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
            "RFSourceRevision": NativeRFDETRLayoutResource.highresSourceRevision,
            "systemFontResolution": "shared NativeSourceFontResolver; actual CoreText face files; no platform font substitution"]
    }

    /// Bounded source-only A/B route. The caller supplies actual source pixels,
    /// original OCR evidence and layout items, never saved appearance answers.
    /// PipelineMain dispatch is supplied separately as a reviewable patch.
    static func runVerification(_ arguments: [String]) throws -> Int32 {
        guard arguments.count == 3,
              let rootPath = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"],
              let bundlePath = ProcessInfo.processInfo.environment["AIDOKU_HOST_MODEL_BUNDLE"],
              Bundle(path: bundlePath) != nil else {
            throw HostError.message("Usage: --native-source-appearance-verify REQUEST.json TRACE.json; existing AIDOKU_HOST_MODEL_BUNDLE required")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["schema"] as? String == "native-source-appearance-verify-v1",
              let descriptor = request["source"] as? [String: String],
              let path = descriptor["path"], let expected = descriptor["SHA256"],
              let items = request["items"] as? [[String: Any]], !items.isEmpty, items.count <= 16,
              items.contains(where: { $0["keptLettering"] as? Bool != true &&
                  $0["sourceTextOnly"] as? Bool != true && !($0["text"] as? String ?? "").isEmpty }),
              let evidence = request["sourceEvidence"] as? [String: Any] else {
            throw HostError.message("Invalid bounded source appearance verification request")
        }
        let pixels = try Data(contentsOf: URL(fileURLWithPath: path))
        guard SHA256.hash(data: pixels).map({ String(format: "%02x", $0) }).joined() == expected,
              let decoder = CGImageSourceCreateWithData(pixels as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(decoder, 0, nil) else {
            throw HostError.message("Source appearance verification source identity/decode differs")
        }
        let backend = HostOperationalAppearance(root: URL(fileURLWithPath: rootPath), selection: "legacy-python",
            verificationOutput: URL(fileURLWithPath: arguments[2]), verificationSourceSHA256: expected)
        _ = try backend.annotate(source: image, items: items, sourceEvidence: evidence)
        return 0
    }

    /// Python canonical() sorts these ASCII artifact filenames by code point.
    /// Foundation .sortedKeys uses a different mixed-case ordering, so serialize
    /// each string scalar and assemble the object in explicit lexical order.
    static func checkpointBinding(_ artifacts:[String:String]) throws -> String {
        func quoted(_ value:String) throws -> String {
            let data=try JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.withoutEscapingSlashes])
            return String(decoding:data,as:UTF8.self)
        }
        let fields=try artifacts.keys.sorted().map {key in try quoted(key)+":"+quoted(artifacts[key]!)}
        let data=Data(("{"+fields.joined(separator:",")+"}").utf8)
        return SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
    }

    private final class RFResult: @unchecked Sendable {
        let condition = NSCondition()
        var result: Result<NativeRFDETRLayoutResult, Error>?
        func complete(_ result: Result<NativeRFDETRLayoutResult, Error>) {
            condition.lock(); self.result = result; condition.broadcast(); condition.unlock()
        }
        func wait() throws -> NativeRFDETRLayoutResult {
            condition.lock(); defer { condition.unlock() }
            while result == nil { condition.wait() }
            return try result!.get()
        }
    }

    private func sourceRF(_ source: NativeRFDETRSourceImage) throws -> NativeRFDETRLayoutResult {
        let box = RFResult(), detector = detector
        let task = Task.detached(priority: .userInitiated) {
            do { box.complete(.success(try await detector.detect(source: source))) }
            catch { box.complete(.failure(error)) }
        }
        defer { if Task.isCancelled { task.cancel() } }
        return try box.wait()
    }

    func annotate(source: CGImage, items: [[String: Any]], sourceEvidence: [String: Any]) throws -> NativeLiveSourceAppearance.Output {
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        try NativeSourceInferencePolicy.validate()
        guard NativeSourceInferencePolicy.selected == .accepted || selection == "shared-native" else {
            throw HostError.message("Minimal source policy requires shared-native backend; legacy comparison cannot load its graph")
        }
        if selection == "shared-native" {
            let started = ProcessInfo.processInfo.systemUptime
            let stageDirectory: URL? = !NativeSourceInferencePolicy.selected.usesMinimalObservations &&
                ProcessInfo.processInfo.environment["AIDOKU_SOURCE_STAGE_EXPORT"] == "1" &&
                ProcessInfo.processInfo.environment["AIDOKU_SOURCE_FINAL_MASK_EXPORT"] == "1" ?
                HostDump.context?.directory.appendingPathComponent("analysis/source-stage-cache") : nil
            let output = try sharedNative().annotate(source: source, items: items, sourceEvidence: sourceEvidence,
                segmentationObserver: sourceStageObserver(source: source, directory: stageDirectory),
                diagnostics: try sourceFeatureObserver(source: source))
            if NativeRFRawCachePolicy.enabled, let rf = output.sourceRF {
                HostDump.capture("rf-raw-cache-source", NativeRFRawCacheDiagnostics.snapshot(sourceIdentity: rf.sourceIdentity))
                if HostRFRawReplay.enabled {
                    HostDump.capture("rf-raw-archive-v2", HostRFRawReplay.diagnostics(sourceIdentity: rf.sourceIdentity))
                }
            }
            // Optional audit of ALREADY GENERATED own masks; no inference/GT lookup.
            let maskDirectory: URL? = ProcessInfo.processInfo.environment["AIDOKU_SOURCE_FINAL_MASK_EXPORT"] == "1" ?
                HostDump.context?.directory.appendingPathComponent("analysis/source-final-masks") : nil
            try exportSourceFinalMasks(output, source: source, directory: maskDirectory)
            HostDump.capture("live-source-appearance", ["backend": "shared-native",
                "sourceWidth": source.width, "sourceHeight": source.height,
                "modelBinding": try modelBinding(), "seconds": ProcessInfo.processInfo.systemUptime - started,
                "freshInference": true, "GTAtInference": false, "cachedPredictionsRead": false,
                "authority": "NativeOperationalSourceInference; shared iOS/macOS source pipeline",
                "items": output.items] as [String: Any])
            return output
        }
        guard selection == "legacy-python" else {
            throw HostError.message("Unknown AIDOKU_OPERATIONAL_APPEARANCE_BACKEND: " + selection)
        }
        let indices = items.indices.filter { items[$0]["keptLettering"] as? Bool != true &&
            items[$0]["sourceTextOnly"] as? Bool != true && !(items[$0]["text"] as? String ?? "").isEmpty }
        guard !indices.isEmpty else { return .init(items: items) }
        let decoded = try NativeRFDETRSourceImage.decode(source)
        let rf = try sourceRF(decoded)
        if NativeRFRawCachePolicy.enabled {
            HostDump.capture("rf-raw-cache-source", NativeRFRawCacheDiagnostics.snapshot(sourceIdentity: decoded.identity))
            if HostRFRawReplay.enabled {
                HostDump.capture("rf-raw-archive-v2", HostRFRawReplay.diagnostics(sourceIdentity: decoded.identity))
            }
        }
        guard rf.imageIdentity == decoded.identity,
              rf.semanticGrid?.modelWeightsSHA256 == NativeRFDETRLayoutResource.highresSourceWeightsSHA256 else {
            throw HostError.message("Operational appearance requires current source RF648 checkpoint")
        }
        let sourceRegions = try NativeMainRFRegionAdapter.regions(from: rf, source: decoded)
        HostDump.capture("live-source-rf", ["sourceIdentity": decoded.identity,
            "modelWeightsSHA256": NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
            "sourceWidth": source.width, "sourceHeight": source.height,
            "regions": sourceRegions.map { region -> [String: Any] in
                ["query": region.queryID, "classID": region.classID, "confidence": region.confidence,
                 "bounds": [region.bounds.minX, region.bounds.minY, region.bounds.width, region.bounds.height],
                 "exterior": region.exterior.map { [$0.x, $0.y] },
                 "holes": region.holes.map { $0.map { [$0.x, $0.y] } }]
            }] as [String: Any])
        let evidence = try NativePixelRFEvidence(result: rf)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aidoku-source-style-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func write(_ values: [Float], _ name: String) throws {
            try values.withUnsafeBytes { bytes in
                let data = bytes.baseAddress.map {
                    Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: $0), count: bytes.count, deallocator: .none)
                } ?? Data()
                try data.write(to: folder.appendingPathComponent(name))
            }
        }
        var requests: [[String: Any]] = [], geometries: [[String: Any]] = []
        var sourceHashes: [[String: String]] = [], crops: [CGRect] = [], ownerPolygons: [[CGPoint]] = []
        var originalMembers:[[[CGPoint]]]=[],clippingAudits:[[String:Any]]=[]
        var verificationInputs: [SourceNativeInput] = []
        for (ordinal, index) in indices.enumerated() {
            let item = items[index]
            guard let bounds = item["sourceBounds"] as? [Double], bounds.count == 4, bounds.allSatisfy(\.isFinite),
                  bounds[2] > 0, bounds[3] > 0 else {
                throw HostError.message("Live source appearance requires original source geometry/text/font prior")
            }
            let sourceRows=(sourceEvidence["originalOCR"] as? [String:Any])?["regions"] as? [[String:Any]] ?? []
            let matching=sourceRows.filter { row in
                guard let b=row["sourceBounds"] as? [Double],b.count==4 else {return false}
                return zip(b,bounds).allSatisfy {abs($0-$1)<=1e-8}
            }
            let matched=matching.count == 1 ? matching[0] : [:]
            guard let text=(item["sourceOriginalText"] as? String) ?? (matched["source"] as? String),!text.isEmpty else {
                throw HostError.message("Source-bound OCR text required; translated text is not a font observation")
            }
            let box = CGRect(x: bounds[0]*Double(source.width), y: bounds[1]*Double(source.height),
                width: bounds[2]*Double(source.width), height: bounds[3]*Double(source.height))
            let sourcePrior=(item["sourceFontSize"] as? NSNumber)?.doubleValue
            let prior=sourcePrior.flatMap {$0.isFinite && $0>0 ? $0 : nil} ??
                max(8,min(Double(min(box.width,box.height)),sqrt(Double(box.width*box.height)/Double(max(1,text.count)))))
            let crop = box.insetBy(dx: -box.width*0.15, dy: -box.height*0.15).integral
                .intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
            guard crop.width > 0, crop.height > 0, crop.width*crop.height <= 1_500_000 else {
                throw HostError.message("Live source appearance crop budget exceeded")
            }
            let rawOwner = item["sourcePolygon"] as? [[Double]] ?? []
            guard rawOwner.count<=16,rawOwner.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else {
                throw HostError.message("Invalid original source polygon")
            }
            let owner = rawOwner.map {
                CGPoint(x: $0[0]*Double(source.width), y: $0[1]*Double(source.height))
            }
            let ownerPolygon = owner.count >= 3 ? owner : [CGPoint(x: box.minX,y: box.minY),
                CGPoint(x: box.maxX,y: box.minY),CGPoint(x: box.maxX,y: box.maxY),CGPoint(x: box.minX,y: box.maxY)]
            let recognized=(sourceEvidence["originalRecognizer"] as? [String:Any])?["regions"] as? [[String:Any]] ?? []
            let polygons=try NativeSourceInputFactory.memberPolygons(item:item,originalRows:sourceRows,
                recognizedRows:recognized,pageSize:CGSize(width:source.width,height:source.height),fallback:ownerPolygon)
            let features=try NativeSourceInputFactory.featureGeometry(members:polygons,merged:ownerPolygon,crop:crop)
            let support = try evidence.support(crop: crop, polygons: features.polygons, sourceIdentity: decoded.identity)
            let w=Int(crop.width), h=Int(crop.height)
            var rgb=Data(); rgb.reserveCapacity(w*h*3)
            decoded.rgb.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for y in 0..<h {
                    let offset=((Int(crop.minY)+y)*source.width+Int(crop.minX))*3
                    rgb.append(bytes.bindMemory(to: UInt8.self).baseAddress!+offset, count:w*3)
                }
            }
            let prefix=String(ordinal)
            let rgbPath=folder.appendingPathComponent(prefix+".rgb")
            try rgb.write(to:rgbPath)
            try write(support.full,prefix+"-rf.f32")
            try write(support.coarse,prefix+"-coarse.f32")
            func local(_ polygon:[CGPoint])->[[Double]] {
                polygon.map {[Double($0.x-crop.minX),Double($0.y-crop.minY)]}
            }
            let geometry:[String:Any]=["polygons":features.polygons.map(local),"mergedPolygon":local(features.merged),"fontPixels":prior]
            let words=try NativeSourceInputFactory.wordEvidence(recognizedRows:recognized,members:polygons,crop:crop)
            if verificationOutput != nil {
                // Exactly the legacy constructor's observed arrays and clipped
                // geometry: RF inference runs once for BOTH implementations.
                var input = SourceNativeInput(width: w, height: h, rgb: Array(rgb), rf: support.full,
                    coarseRF: support.coarse, affinityScores: support.affinityScores,
                    rfModelWeightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
                    memberPolygons: features.polygons.map { polygon in polygon.map {
                        CGPoint(x: $0.x - crop.minX, y: $0.y - crop.minY)
                    } }, mergedPolygon: features.merged.map { CGPoint(x: $0.x - crop.minX, y: $0.y - crop.minY) },
                    bbox: box.offsetBy(dx: -crop.minX, dy: -crop.minY), fontPriorSourcePixels: prior,
                    crop: crop, pageSize: CGSize(width: source.width, height: source.height),
                    sourceIdentity: decoded.identity, sourceText: text,
                    confidence: ((item["sourceConfidence"] ?? matched["confidence"]) as? NSNumber)?.doubleValue,
                    role: (item["sourceRole"] ?? matched["textRole"]) as? String)
                input.wordEvidence = words
                try input.validate(requirePredictions: false)
                verificationInputs.append(input)
            }
            requests.append(["width":w,"height":h,"rgb":rgbPath.path,
                "rf":folder.appendingPathComponent(prefix+"-rf.f32").path,
                "coarseRF":folder.appendingPathComponent(prefix+"-coarse.f32").path,
                "affinity":support.affinityScores.map(Double.init),"geometry":geometry,
                "cropOrigin":[Int(crop.minX),Int(crop.minY)],"bbox":[box.minX-crop.minX,box.minY-crop.minY,box.width,box.height],
                "sourceText":text,"confidence":item["sourceConfidence"] ?? matched["confidence"] ?? NSNull(),
                "wordMembers":words.map {word -> [String:Any] in
                    ["text":word.text,"sourceIndex":word.sourceIndex,
                     "bbox":[Double(word.bbox.minX),Double(word.bbox.minY),Double(word.bbox.width),Double(word.bbox.height)],
                     "polygon":word.polygon.map {[Double($0.x),Double($0.y)]}]
                },
                "role":item["sourceRole"] ?? matched["textRole"] ?? NSNull(),
                "rfModelWeightsSHA256":NativeRFDETRLayoutResource.highresSourceWeightsSHA256])
            geometries.append(geometry); sourceHashes.append(["rgbSHA256":sha(rgb),"rfSHA256":support.full.withUnsafeBytes(HostRFRawReplay.digest)])
            crops.append(crop);ownerPolygons.append(ownerPolygon)
            originalMembers.append(polygons);clippingAudits.append(features.audit)
        }
        let request:[String:Any]=["schema":"aidoku-live-source-page-v1","pageSize":[source.width,source.height],
            "sourceIdentity":decoded.identity,"sourceEvidence":sourceEvidence,"items":requests,
            "nativeHost":CommandLine.arguments[0]]
        let input=folder.appendingPathComponent("request.json"), output=folder.appendingPathComponent("result.json")
        try JSONSerialization.data(withJSONObject:request,options:[.sortedKeys]).write(to:input)
        let workspace=root.deletingLastPathComponent()
        let python=ProcessInfo.processInfo.environment["AIDOKU_OPERATIONAL_APPEARANCE_PYTHON"] ??
            root.appendingPathComponent(".venv-source-inference/bin/python").path
        let process=Process();process.executableURL=URL(fileURLWithPath:python)
        process.arguments=["-B",root.appendingPathComponent("Scripts/appearance_estimation/source_style_runtime.py").path,
            "--request",input.path,"--workspace",workspace.path,"--out",output.path]
        var environment=ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"]="1"
        environment["PYTHONPATH"]=root.appendingPathComponent("Scripts/style_gt").path
        process.environment=environment
        let log=folder.appendingPathComponent("process.log")
        FileManager.default.createFile(atPath:log.path,contents:nil)
        let handle=try FileHandle(forWritingTo:log);defer {try? handle.close()}
        process.standardError=handle;process.standardOutput=handle
        let pythonStarted = ProcessInfo.processInfo.systemUptime
        try process.run();process.waitUntilExit();try Task.checkCancellation()
        let pythonSeconds = ProcessInfo.processInfo.systemUptime - pythonStarted
        guard process.terminationStatus == 0,
              let response=try JSONSerialization.jsonObject(with:Data(contentsOf:output)) as? [String:Any],
              response["schema"] as? String == "aidoku-live-source-page-result-v1",
              let packets=response["items"] as? [[String:Any]],packets.count == indices.count else {
            let diagnostic=String(data:(try? Data(contentsOf:log)) ?? Data(),encoding:.utf8) ?? ""
            throw HostError.message("Live source style constructor failed: "+String(diagnostic.suffix(3000)))
        }
        var result=items
        var masks:[NativeSelectedSourceSegmentationMasks.Entry]=[]
        let artifacts=root.appendingPathComponent("Scripts/appearance_estimation/assets/accepted")
        let artifactNames=["model.pkl","pixel-role-model.pkl","width-model.pkl","source-fill-palette-model.pkl",
            "background-palette.pkl","final-background-model.pkl","SHADOW-OBSERVATION-POLICY.json",
            "FINAL-BACKGROUND-POLICY.json","NATIVE-GRADIENT-CONTOUR-POLICY.json","NATIVE-OUTER-SHELL-POLICY.json"]
        let expectedArtifacts=try Dictionary(uniqueKeysWithValues:artifactNames.map { name in
            (name,sha(try Data(contentsOf:artifacts.appendingPathComponent(name))))
        })
        let checkpoint=try Self.checkpointBinding(expectedArtifacts)
        for (ordinal,index) in indices.enumerated() {
            let packet=packets[ordinal]
            guard let geometry=packet["geometry"] as? NSDictionary, geometry.isEqual(to:geometries[ordinal]),
                  var binding=packet["binding"] as? [String:String],
                  let font=packet["sourceFontSize"] as? Double,font.isFinite,font>0 else {
                throw HostError.message("Live source style producer geometry/font mismatch")
            }
            // Rehash original request arrays and actual fresh producer outputs;
            // expected binding is not copied wholesale from a saved receipt.
            for (key,value) in sourceHashes[ordinal] { binding[key]=value }
            for name in ["mask","context","segPrimary","segBoundary","ocr"] {
                binding[name+"SHA256"]=sha(try Data(contentsOf:folder.appendingPathComponent(String(ordinal)+"-"+name+".raw")))
            }
            binding["geometrySHA256"]=sha(try Data(contentsOf:folder.appendingPathComponent(String(ordinal)+"-geometry.json")))
            binding["checkpointSHA256"]=checkpoint
            binding["rfModelWeightsSHA256"]=NativeRFDETRLayoutResource.highresSourceWeightsSHA256
            let emitted=packet["binding"] as? [String:String] ?? [:]
            let differing=Set(binding.keys).union(emitted.keys).filter {binding[$0] != emitted[$0]}.sorted()
            guard differing.isEmpty else {
                throw HostError.message("Live source appearance binding mismatch owner=\(ordinal) keys=\(differing.joined(separator:","))")
            }
            var revised=try NativeOperationalAppearance.apply(packet:JSONSerialization.data(withJSONObject:packet),
                expectedBinding:binding,to:items[index])
            revised["sourceFontSize"]=font
            revised["sourceAppearanceUnits"]="original-source-pixels; native page viewport already localized"
            revised["sourceFontAuthority"]=packet["sourceFontAuthority"]
            revised["sourcePredictedStyle"]=packet["prediction"]
            revised["sourceMemberPolygons"]=originalMembers[ordinal].map {$0.map {[Double($0.x),Double($0.y)]}}
            revised["sourceFeatureGeometryClipping"]=clippingAudits[ordinal]
            revised["sourceMemberPolygonsCrop"]=packet["sourceMemberPolygonsCrop"]
            if let weight=packet["sourceFontWeight"] as? String {
                let selected=root.appendingPathComponent("Scripts/font_weight_estimation/ACTIVE-ESTIMATOR.json")
                guard let selection=try JSONSerialization.jsonObject(with:Data(contentsOf:selected)) as? [String:Any],
                      let expectedModel=selection["modelSHA256"] as? String,
                      let evidence=packet["sourceWeightBinding"] as? [String:String],
                      let bold=packet["renderBold"] as? Bool,["regular","bold","mixed"].contains(weight),bold==(weight=="bold"),
                      evidence["sourceIdentity"]==decoded.identity,evidence["modelSHA256"]==expectedModel,
                      evidence["rgbSHA256"]==sourceHashes[ordinal]["rgbSHA256"],
                      evidence["rfSHA256"]==sourceHashes[ordinal]["rfSHA256"] else {
                    throw HostError.message("Live source weight identity/render binding differs")
                }
                for name in ["segPrimary","segBoundary","segNative","segValid"] {
                    guard evidence[name+"SHA256"]==sha(try Data(contentsOf:folder.appendingPathComponent(String(ordinal)+"-"+name+".raw"))) else {
                        throw HostError.message("Live source weight observation binding differs: "+name)
                    }
                }
                revised["sourceFontWeight"]=weight;revised["renderBold"]=bold
                revised["sourceWeightEvidence"]=packet["sourceWeightEvidence"]
                revised["sourceWeightAuthority"]="accepted-frozen-weight;source-seg-rf-font-style"
                revised.removeValue(forKey:"sourceWeightRuns")
            }
            let oldFont=items[index]["fontSize"] as? Double ?? font
            let leading=items[index]["lineHeight"] as? Double ?? oldFont
            let oldSource=items[index]["sourceFontSize"] as? Double ?? oldFont
            let displayRequest=font*oldFont/max(1,oldSource)
            revised["sourceRequestedDisplayFontSize"]=displayRequest
            revised["fontSize"]=displayRequest;revised["lineHeight"]=displayRequest*max(1,leading/max(1,oldFont))
            result[index]=revised
            let raw=try Data(contentsOf:folder.appendingPathComponent(String(ordinal)+"-mask.raw"))
            let owner=ownerPolygons[ordinal]
            let removalOwner=(items[index]["sourcePolygon"] as? [[Double]] ?? []).isEmpty ? owner :
                NativeIndependentPanelGutter.clip(owner,to:CGRect(x:0,y:0,width:source.width-1,height:source.height-1))
            masks.append(.init(ownerPolygon:removalOwner,crop:crops[ordinal],mask:Array(raw).map {$0 == 0 ? 0 : 255}))
        }
        result = NativeSourceFontFitGroups.annotate(result)
        if let verificationOutput {
            let observationTransferStarted = ProcessInfo.processInfo.systemUptime
            // The legacy producer has constructed the source-only OCR raster
            // from the same original recognizer evidence. Its binding was
            // authenticated above; share this observation, never a prediction.
            for ordinal in verificationInputs.indices {
                let bytes = try Data(contentsOf: folder.appendingPathComponent(String(ordinal) + "-ocr.raw"))
                let input = verificationInputs[ordinal]
                let count = input.width * input.height * 8
                guard bytes.count == count * MemoryLayout<Float>.size,
                      (packets[ordinal]["binding"] as? [String: String])?["ocrSHA256"] == sha(bytes) else {
                    throw HostError.message("A/B source OCR raster dimensions/hash differ")
                }
                let observations: [Float] = bytes.withUnsafeBytes { raw in
                    (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
                }
                guard observations.allSatisfy({ $0.isFinite && (0...1.001).contains($0) }) else {
                    throw HostError.message("A/B source OCR raster values are invalid")
                }
                verificationInputs[ordinal].ocr = observations
            }
            let observationTransferSeconds = ProcessInfo.processInfo.systemUptime - observationTransferStarted
            let diagnosticsDirectory = verificationOutput.appendingPathExtension("diagnostics")
            try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
            let nativeStarted = ProcessInfo.processInfo.systemUptime
            let inference = try sharedNative().predict(verificationInputs, returnFontStages: true,
                diagnostics: { sourceIndex, stage, payload in
                    guard !stage.isEmpty, stage.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                        throw HostError.message("Invalid native diagnostic stage")
                    }
                    let document: [String: Any] = ["sourceIndex": sourceIndex, "stage": stage, "payload": payload,
                        "evaluationIdentityIsNotModelFeature": true]
                    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
                        .write(to: diagnosticsDirectory.appendingPathComponent("\(sourceIndex)-\(stage).json"), options: .atomic)
                })
            let nativeSeconds = ProcessInfo.processInfo.systemUptime - nativeStarted
            var comparisons: [[String: Any]] = []
            for ordinal in verificationInputs.indices {
                let observed = verificationInputs[ordinal], predicted = inference.inputs[ordinal]
                let pythonMask = try Data(contentsOf: folder.appendingPathComponent(String(ordinal) + "-mask.raw"))
                let expectedMask = pythonMask.map { $0 == 0 ? UInt8(0) : 1 }
                let nativeMask = predicted.ownMask.map { $0 == 0 ? UInt8(0) : 1 }
                guard expectedMask.count == nativeMask.count,
                      predicted.rgb == observed.rgb, predicted.rf == observed.rf,
                      predicted.coarseRF == observed.coarseRF,
                      let pythonFont = packets[ordinal]["sourceFontSize"] as? Double else {
                    throw HostError.message("A/B source packet dimensions/binding differs")
                }
                comparisons.append(["sourceIndex": ordinal, "itemID": items[indices[ordinal]]["id"] ?? ordinal,
                    "sourceImageSHA256": verificationSourceSHA256 ?? "",
                    "regionID": items[indices[ordinal]]["id"] ?? ordinal,
                    "identityAuthority": "evaluation-only original request ID; never a native model feature",
                    "width": observed.width, "height": observed.height,
                    "crop": [observed.crop.minX, observed.crop.minY, observed.crop.width, observed.crop.height],
                    "cropBounds": [observed.crop.minX, observed.crop.minY, observed.crop.maxX, observed.crop.maxY],
                    "bbox": [observed.bbox.minX, observed.bbox.minY, observed.bbox.width, observed.bbox.height],
                    "rgbSHA256": observed.rgb.withUnsafeBytes(HostRFRawReplay.digest),
                    "rfSHA256": observed.rf.withUnsafeBytes(HostRFRawReplay.digest),
                    "coarseRFSHA256": observed.coarseRF.withUnsafeBytes(HostRFRawReplay.digest),
                    "ocrSHA256": observed.ocr.withUnsafeBytes(HostRFRawReplay.digest),
                    "ocrObservationCount": observed.ocr.count,
                    "geometry": geometries[ordinal], "sourceText": observed.sourceText,
                    "wordEvidenceCount": observed.wordEvidence.count,
                    "sameObservedSourceArrays": true,
                    "python": ["fontPixels": pythonFont, "prediction": packets[ordinal]["prediction"] ?? [:],
                        "weight": packets[ordinal]["sourceFontWeight"] ?? NSNull(),
                        "weightEvidence": packets[ordinal]["sourceWeightEvidence"] ?? [:],
                        "maskSHA256": expectedMask.withUnsafeBytes(HostRFRawReplay.digest)],
                    "native": ["fontPixels": inference.font.values[ordinal], "prediction": inference.styles[ordinal],
                        "weightDecision": inference.weights?[ordinal] ?? [:],
                        "fontStages": inference.font.stages.mapValues { $0[ordinal] },
                        "maskSHA256": nativeMask.withUnsafeBytes(HostRFRawReplay.digest)],
                    "maskDifferentPixels": zip(expectedMask, nativeMask).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) },
                    "fontAbsoluteDifferencePixels": abs(pythonFont - inference.font.values[ordinal])])
            }
            let trace: [String: Any] = ["schema": "native-source-appearance-verification-v1",
                "sourceIdentity": decoded.identity, "pageSize": [source.width, source.height],
                "sourceImageSHA256": verificationSourceSHA256 ?? "",
                "diagnosticsDirectory": diagnosticsDirectory.path,
                "modelBinding": try modelBinding(), "PythonAppearanceArtifactBinding": expectedArtifacts,
                "pythonSeconds": pythonSeconds, "nativeSeconds": nativeSeconds,
                "sourceOCRObservationTransferSeconds": observationTransferSeconds,
                "timingScope": "Python process including graph load vs native first-use predict including graph load and diagnostics; shared RF and source OCR raster transfer excluded",
                "sharedRFInferenceCount": 1, "sameRFAndFrame": true,
                "GTAtInference": false, "cachedPredictionsRead": false, "freshInference": true,
                "OCRCalls": 0, "providerCalls": 0, "AOTCalls": 0, "renderCalls": 0,
                "scope": "source component parity; no native annotate/item application or end-to-end renderer parity claim",
                "items": comparisons]
            try FileManager.default.createDirectory(at: verificationOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: trace, options: [.prettyPrinted, .sortedKeys])
                .write(to: verificationOutput, options: .atomic)
        }
        let checkpointKeys = ["id", "sourceBounds", "sourceOriginalText", "sourceFontSize", "fontSize", "lineHeight",
            "sourceRequestedDisplayFontSize", "sourceFontWeight", "renderBold", "sourceAppearance",
            "sourceAppearanceBinding", "sourceAppearanceUnits", "sourceFontAuthority", "sourceMemberPolygons",
            "sourceFeatureGeometryClipping", "sourceFontFitGroupID", "sourceFontFitGroupAuthority"]
        HostDump.capture("live-source-appearance", ["sourceIdentity": decoded.identity,
            "sourceWidth": source.width, "sourceHeight": source.height,
            "rfModelWeightsSHA256": NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
            "rfRegionCount": sourceRegions.count, "selectedSourceMaskCount": masks.count,
            "authority": "executed source constructor before shaping; not a successful render receipt",
            "items": result.map { item in
                Dictionary(uniqueKeysWithValues: checkpointKeys.compactMap { key in item[key].map { (key, $0) } })
            }] as [String: Any])
        return .init(items:result,sourceSegmentationMasks:.init(original:source,entries:masks),
            sourceRF:.init(sourceIdentity:decoded.identity,
                modelWeightsSHA256:NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
                regions:sourceRegions))
    }
    /// No cost or files with default nil; writes full inference crops unmodified.
    private func exportSourceFinalMasks(_ output: NativeLiveSourceAppearance.Output, source: CGImage,
                                        directory: URL? = nil) throws {
        guard let directory else { return }
        // The production backend legitimately performs no inference for a page
        // containing only preserved/empty lettering. Do not turn audit into a failure.
        if output.sourceSegmentationMasks == nil && output.items.allSatisfy({
            $0["keptLettering"] as? Bool == true || $0["sourceTextOnly"] as? Bool == true ||
                ($0["text"] as? String ?? "").isEmpty
        }) { return }
        guard let masks = output.sourceSegmentationMasks, masks.original === source,
              let evidence = output.sourceRF else {
            throw HostError.message("Source-final mask export requires bound fresh shared-native masks")
        }
        // New transaction subfolder prevents stale owners after repeat renders.
        let transaction = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        var entries: [[String: Any]] = []
        for (index, entry) in masks.entries.enumerated() {
            try Task.checkCancellation()
            let crop = entry.crop, width = Int(crop.width), height = Int(crop.height)
            guard crop == crop.integral, width > 0, height > 0,
                  crop.minX >= 0, crop.minY >= 0, crop.maxX <= CGFloat(source.width), crop.maxY <= CGFloat(source.height),
                  entry.mask.count == width * height, entry.mask.allSatisfy({ $0 == 0 || $0 == 255 }) else {
                throw HostError.message("Source-final full-crop mask dimensions differ")
            }
            let name = String(format: "%03d.u8", index), bytes = Data(entry.mask)
            try bytes.write(to: transaction.appendingPathComponent(name), options: .atomic)
            entries.append(["sourceIndex": index, "mask": name, "width": width, "height": height,
                "maskSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                "foregroundPixels": entry.mask.reduce(0) { $0 + ($1 == 0 ? 0 : 1) },
                "cropBounds": [crop.minX, crop.minY, crop.maxX, crop.maxY].map(Double.init),
                "ownerPolygonPage": entry.ownerPolygon.map { [Double($0.x), Double($0.y)] }])
        }
        let minimal = NativeSourceInferencePolicy.selected.usesMinimalObservations
        let context83Executed = !minimal && !NativeSourceSegmentationExecution.completedOnlyEnabled
        let style78Executed = context83Executed && !NativeSelectedSourceSegmentationProducer.connectedWeakEnabled
        let document: [String: Any] = ["schema": "aidoku-source-final-mask-export-v1",
            "modelBinding": try modelBinding(),
            "sourceIdentity": evidence.sourceIdentity, "sourceIdentityConvention": "sha256(rf648-rgb8-v1:WIDTHxHEIGHT: + opaque-sRGB-RGB8)",
            "pageSize": [source.width, source.height], "entries": entries,
            "policySHA256": masks.policySHA256, "RFWeightsSHA256": evidence.modelWeightsSHA256,
            "featureSegmentationPolicySHA256": NativeSourceSegmentationExecution.policySHA256,
            "erasureSegmentationPolicySHA256": NativeSourceSegmentationExecution.erasurePolicySHA256,
            "erasurePolicyRevision": NativeSourceSegmentationExecution.erasurePolicyRevision,
            "refinementHeadsExecution": context83Executed ? (style78Executed ? "executed" : "context83-only") : "not-executed",
            "refinementHeadsExecutionScope": "actual rich feature-mask producers; erasure policy is separately declared",
            "erasureFromAlreadyComputedPrimary": NativeSourceInferencePolicy.erasureSegmentationConfiguration != nil,
            "context83Executed": context83Executed, "style78Executed": style78Executed,
            "primaryModelSHA256": NativeSourceInferencePolicy.selected == .minimalRF ? "not-executed" :
                "8f5dba949b25c2cf54359bd8e4066c6423970980a0355887c83e150d82a0e617",
            "boundaryModelSHA256": minimal ? "not-executed" :
                "3df521613d2981c412c3c9a38878128d1450bb1016e7baaaddad5f3a0d3a36ea",
            "jointModelSHA256": context83Executed ? NativeSegmentationFinalPolicy.jointModelSHA256 : "not-executed",
            "auxiliaryModelSHA256": style78Executed ? NativeSegmentationFinalPolicy.auxiliaryModelSHA256 : "not-executed",
            "encoding": "row-major uint8; 0 background;255 owned; top-left original-page pixels; crop max exclusive",
            "stage": "source-erasure-masks-before-final-protection",
            "bboxMaskClipping": false, "GTAtInference": false, "additionalInference": false]
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            .write(to: transaction.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private final class StageExportBudget: @unchecked Sendable {
        let lock = NSLock()
        private var remaining = 190_000_000
        func fits(_ bytes: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return bytes <= remaining }
        func reserve(_ bytes: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard bytes <= remaining else { return false }
            remaining -= bytes
            return true
        }
    }
    private static let stageExportBudget = StageExportBudget()

    /// Default nil is zero IO/allocation/hash and does not retain source arrays.
    /// A process-wide exact byte reservation bounds concurrent selected-page exports.
    /// Request-scoped, opt-in numeric export. No source RGB/masks are written.
    /// Default nil creates no buffers, hashes or retained observer.
    private func sourceFeatureObserver(source: CGImage) throws -> NativeSourceFeatureObserver? {
        let env = ProcessInfo.processInfo.environment
        guard env["AIDOKU_SOURCE_FEATURE_EXPORT"] == "1" else { return nil }
        guard let destination = env["AIDOKU_SOURCE_FEATURE_DIRECTORY"],
              let fingerprint = env["AIDOKU_PIPELINE_FINGERPRINT"], fingerprint.count == 64,
              let policy = env["AIDOKU_SOURCE_FEATURE_POLICY_SHA256"], policy.count == 64 else {
            throw HostError.message("Feature export requires destination, compiled and policy fingerprints")
        }
        let binding = try HostEnsembleEvidence.sourceStageBinding(original: source,
            sourceURL: HostDump.context?.sourceURL,
            fallbackURL: HostDump.context?.directory.appendingPathComponent("input.png"))
        guard let encodedSHA = binding.verifiedEncodedSourceSHA256 else {
            throw HostError.message("Feature export requires verified per-page encoded source binding")
        }
        let sourceIdentity = binding.contentIdentity
        let bindingData = try JSONSerialization.data(withJSONObject: modelBinding(), options: [.sortedKeys])
        let directory = URL(fileURLWithPath: destination)
        // A private UUID request directory prevents replacing an earlier collection.
        let requestDirectory = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: requestDirectory, withIntermediateDirectories: true)
        let budget = FeatureExportBudget()
        let schemas: [String: FeatureExportSchema] = [
            "owner-binding": .init(features: [], timing: [], diagnostic: [], metadata: ["schema", "sourceIdentity", "sourceOnly", "GTAtInference", "itemIndex", "ownerIndex"]),
            "source-binding": .init(features: [], timing: [], diagnostic: [], metadata: ["schema", "sourceIdentity", "sourceOnly", "GTAtInference", "width", "height", "rgbSHA256", "predictedMaskSHA256", "rfModelWeightsSHA256", "cropBounds", "bbox", "pageSize", "fontPriorSourcePixels", "memberPolygonsLocal", "mergedPolygonLocal", "sourceTextSHA256", "fullRFSHA256", "coarseRFSHA256", "primarySHA256", "boundarySHA256", "ocrSHA256", "contextMaskSHA256"]),
            "appearance-features": .init(features: ["colors", "features", "pair", "fontPixels", "maskFraction"], timing: ["extractionMicroseconds"], diagnostic: [], metadata: ["schema", "sourceIdentity", "sourceOnly", "GTAtInference", "checkpointSHA256", "rfModelWeightsSHA256", "version"]),
            "width-features": .init(features: ["sourcePrior", "selectedFillIndex", "selectedOutlineIndex", "selectedBackgroundIndex", "selectedFill", "selectedOutline", "source662", "native50"], timing: [], diagnostic: ["sortedAdaptiveTreeOutputs", "baseRawWidth", "unroundedConsensusWidth", "outputResolutionPx", "projectedWidth", "referenceWidth"], metadata: ["schema", "sourceIdentity", "sourceOnly", "GTAtInference", "modelWeightsChanged"]),
            "font-features": .init(features: ["style187", "angle131", "originalPrior", "finalSourceEM"], timing: [], diagnostic: ["stages"], metadata: ["schema", "sourceIdentity", "sourceOnly", "GTAtInference"]),
            "weight-font-features": .init(features: ["style187", "angle131", "originalPrior", "finalSourceEM"], timing: [], diagnostic: [], metadata: ["schema", "sourceIdentity", "sourceOnly", "GTAtInference"]),
            "weight-features": .init(features: ["raw866", "fill71", "paired48", "bands112", "angle131", "sourceEM", "mixed", "physicalReferenceAvailable", "originalPrior"], timing: ["batchMeasurementMicroseconds", "batchOwners"], diagnostic: ["residualReused"], metadata: ["schema", "sourceIdentity", "sourceOnly", "GTAtInference", "registrySHA256", "rfModelWeightsSHA256"]),
            "page-stage-timings": .init(features: [], timing: ["owners", "segmentationMS", "contextsMS", "appearanceMS", "firstFontMS", "bboxOnlyFontMS", "weightMS", "predictTotalMS", "includesOptInObserverCost", "modelInput"], diagnostic: [], metadata: ["schema", "sourceIdentity", "sourceOnly", "GTAtInference", "scope"]),
        ]
        return { index, stage, payload in
            guard let schema = schemas[stage] else { return }
            guard payload["sourceIdentity"] as? String == sourceIdentity else {
                throw HostError.message("Borrowed features differ from encoded source identity")
            }
            let permitted = Set(schema.features + schema.timing + schema.diagnostic + schema.metadata)
            guard Set(payload.keys).isSubset(of: permitted) else {
                throw HostError.message("Unreviewed source feature callback fields: " + stage)
            }
            func numeric(_ value: Any) throws -> Any {
                if let number = value as? NSNumber {
                    guard number.doubleValue.isFinite else { throw HostError.message("Nonfinite feature") }
                    return number
                }
                if value is NSNull { throw HostError.message("Null value in closed source feature schema") }
                if let array = value as? [Any] { return try array.map { try numeric($0) } }
                if let object = value as? [String: Any] {
                    var result: [String: Any] = [:]
                    for (key, value) in object { result[key] = try numeric(value) }
                    return result
                }
                throw HostError.message("Nonnumeric value in closed source feature schema")
            }
            func selected(_ keys: [String]) throws -> [String: Any] {
                var result: [String: Any] = [:]
                for key in keys {
                    guard let value = payload[key] else { throw HostError.message("Missing closed feature field: " + key) }
                    result[key] = try numeric(value)
                }
                return result
            }
            let features = try selected(schema.features)
            let numericData = try JSONSerialization.data(withJSONObject: features, options: [.sortedKeys, .withoutEscapingSlashes])
            var document: [String: Any] = ["schema": "aidoku-source-feature-collection-v1",
                "ownerIndex": index, "stage": stage, "sourceEncodedSHA256": encodedSHA,
                "sourceIdentity": sourceIdentity, "sourceOnly": true, "GTAtInference": false,
                "additionalInference": false, "features": features,
                "featuresJSON": String(decoding: numericData, as: UTF8.self),
                "featuresJSONSHA256": NativeFrozenSourceSHA256.hex(numericData),
                "numericABI": "Foundation sortedKeys numeric JSON; no Float32/64 raw-bit parity claim",
                "compiledSourceFingerprint": fingerprint, "collectorPolicySHA256": policy,
                "modelBinding": try JSONSerialization.jsonObject(with: bindingData)]
            if !schema.timing.isEmpty { document["timingMetadata"] = try selected(schema.timing) }
            if !schema.diagnostic.isEmpty { document["diagnosticMetadata"] = try selected(schema.diagnostic) }
            var observationMetadata: [String: Any] = [:]
            for key in schema.metadata { if let value = payload[key] { observationMetadata[key] = value } }
            document["observationMetadata"] = observationMetadata
            // Only these two closed schemas carry string hashes/identities.
            if stage == "source-binding" || stage == "owner-binding" { document["binding"] = payload }
            if stage == "page-stage-timings" {
                document["scope"] = "page-metadata-not-model-features"
            }
            if schema.features.isEmpty {
                document.removeValue(forKey: "features")
                document.removeValue(forKey: "featuresJSON")
                document.removeValue(forKey: "featuresJSONSHA256")
            }
            let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
            guard budget.reserve(bytes.count) else { throw HostError.message("Feature export exceeds 32MiB request budget") }
            try bytes.write(to: requestDirectory.appendingPathComponent(String(index) + "-" + stage + ".json"), options: [.withoutOverwriting])
        }
    }
    private struct FeatureExportSchema: Sendable {
        let features: [String]
        let timing: [String]
        let diagnostic: [String]
        let metadata: [String]
    }
    private final class FeatureExportBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0
        func reserve(_ count: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard count <= 2_097_152, bytes <= 33_554_432 - count else { return false }
            bytes += count; return true
        }
    }

    private func sourceStageObserver(source: CGImage, directory: URL? = nil) -> NativeSelectedSourceSegmentationProducer.SourceReplayObserver? {
        guard let directory else { return nil }
        // A source URL is a location, never proof that those bytes belong to
        // the image being annotated. Reuse the typed OCR pixel binding check.
        guard let binding = try? HostEnsembleEvidence.sourceStageBinding(original: source,
            sourceURL: HostDump.context?.sourceURL,
            fallbackURL: HostDump.context?.directory.appendingPathComponent("input.png")),
            let encodedSHA = binding.verifiedEncodedSourceSHA256 else {
            HostDump.capture("source-stage-cache", ["status": "missing-or-mismatched-encoded-source-binding", "complete": false])
            return nil
        }
        return { input, stage in
            let n = input.width * input.height, rawBytes = n * 18 + 316
            func skipped(_ reason: String) {
                HostDump.capture("source-stage-cache", ["status": reason, "complete": false,
                    "sourceIdentity": input.sourceIdentity,
                    "cropBounds": [input.crop.minX,input.crop.minY,input.crop.maxX,input.crop.maxY],
                    "requestedRawBytes": rawBytes, "processBudgetBytes": 190_000_000])
            }
            guard input.sourceIdentity == binding.contentIdentity else { skipped("source-identity-mismatch"); return }
            guard Self.stageExportBudget.fits(rawBytes) else { skipped("budget-exhausted"); return }
            try Task.checkCancellation()
            // <=9MB new scratch at the existing1.5M crop-pixel bound.
            var auxiliary = [UInt16](repeating: 65535, count: n)
            for (row, pixel) in stage.weakPositions.enumerated() { auxiliary[pixel] = stage.auxiliaryCodes[row] }
            var rfText = [Float](repeating: 0, count: n)
            for pixel in 0..<n { rfText[pixel] = input.rf[pixel * 27] }
            func hash<T>(_ values: [T]) -> String {
                values.withUnsafeBytes { buffer in
                    guard let address = buffer.baseAddress else {
                        return SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
                    }
                    let bytes = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: address), count: buffer.count, deallocator: .none)
                    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                }
            }
            func file<T>(_ name: String, _ values: [T], _ scalar: String) -> [String: Any] {
                ["path": name, "scalar": scalar, "count": values.count,
                 "bytes": values.count * MemoryLayout<T>.stride, "SHA256": hash(values)]
            }
            let files: [String: Any] = ["primary": file("primary.f32",stage.primary,"f32le"),
                "boundary": file("boundary.f32",stage.boundary,"f32le"),
                "rawNative": file("native.u8",stage.rawNative,"u8"),
                "completed": file("completed.u8",stage.completed,"u8"),
                "jointCodes": file("joint.u16",stage.jointCodes,"u16le-original-policy-code"),
                "auxiliaryCodes": file("auxiliary.u16",auxiliary,"u16le-original-policy-code"),
                "rfMaximumText": file("rf-max-text.f32",rfText,"f32le"),
                "sourceStyle18": file("source-style.f64",stage.sourceStyle18,"f64le"),
                "auxiliaryStyle18": file("auxiliary-style.f64",stage.auxiliaryStyle18,"f64le"),
                "affinityScores": file("affinity.f32",input.affinityScores,"f32le"),
                "fontPixels": file("font.f64",[stage.fontPixels],"f64le")]
            let document: [String: Any] = ["schema": "aidoku-source-stage-cache-v1", "files": files,
                "implementationFingerprint": ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_FINGERPRINT"] ?? "unmeasured",
                "sourceIdentity": input.sourceIdentity, "sourceEncodedSHA256": encodedSHA,
                "width": input.width, "height": input.height,
                "cropBounds": [input.crop.minX,input.crop.minY,input.crop.maxX,input.crop.maxY].map(Double.init),
                "pageSize": [Double(input.pageSize.width),Double(input.pageSize.height)],
                "bboxLocal": [input.bbox.minX,input.bbox.minY,input.bbox.width,input.bbox.height].map(Double.init),
                "memberPolygonsLocal": input.memberPolygons.map { $0.map { [Double($0.x),Double($0.y)] } },
                "mergedPolygonLocal": input.mergedPolygon.map { [Double($0.x),Double($0.y)] },
                "rgbSHA256": hash(input.rgb), "fullRFSHA256": hash(input.rf), "coarseRFSHA256": hash(input.coarseRF),
                "filledBaseSHA256": hash(stage.filledBase), "finalMaskSHA256": hash(stage.finalMask),
                "modelBinding": try self.modelBinding(), "RFWeightsSHA256": input.rfModelWeightsSHA256,
                "primaryModelSHA256": "8f5dba949b25c2cf54359bd8e4066c6423970980a0355887c83e150d82a0e617",
                "boundaryModelSHA256": "3df521613d2981c412c3c9a38878128d1450bb1016e7baaaddad5f3a0d3a36ea",
                "policySHA256": NativeSegmentationFinalPolicy.policySHA256,
                "jointModelSHA256": NativeSegmentationFinalPolicy.jointModelSHA256,
                "auxiliaryModelSHA256": NativeSegmentationFinalPolicy.auxiliaryModelSHA256,
                "probabilityABI": "primary/boundary/RF raw Float32 bit patterns; no cache quantization",
                "decisionABI": "ORIGINAL consumed joint/aux uint16 codes0..8191;65535 UNCOMPUTED,notzero",
                "jointComputationRadius": stage.jointComputationRadius,
                "jointDomainABI": "full-fields-policy-radius-v1; base OR Chebyshev<=radius;65535 elsewhere",
                "rfPlaneABI": "input.rf pixel-interleaved27 channel0=all-queryclass0 maximum mask probability",
                "baseABI": "fill external contours of completed exactly; verify filledBaseSHA256",
                "finalMaskABI": "join existing source-final export by sourceIdentity+cropBounds+finalMaskSHA256",
                "styleABI": "source/aux style18 and font original Float64 RAWBITS; affinity original Float32 RAWBITS; JSON is not numeric authority",
                "rawBytes": rawBytes, "complete": true, "GTAtInference": false,
                "additionalInference": false, "bboxMaskClipping": false]
            let metadata = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            guard Self.stageExportBudget.reserve(rawBytes + metadata.count) else { skipped("budget-exhausted"); return }
            let packet = directory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: packet, withIntermediateDirectories: true)
                func write<T>(_ values: [T], _ name: String) throws {
                    try values.withUnsafeBytes { buffer in
                        guard let address = buffer.baseAddress else { return }
                        let bytes = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: address), count: buffer.count, deallocator: .none)
                        try bytes.write(to: packet.appendingPathComponent(name), options: .atomic)
                    }
                }
                try write(stage.primary,"primary.f32"); try write(stage.boundary,"boundary.f32")
                try write(stage.rawNative,"native.u8"); try write(stage.completed,"completed.u8")
                try write(stage.jointCodes,"joint.u16"); try write(auxiliary,"auxiliary.u16")
                try write(rfText,"rf-max-text.f32")
                try write(stage.sourceStyle18,"source-style.f64"); try write(stage.auxiliaryStyle18,"auxiliary-style.f64")
                try write(input.affinityScores,"affinity.f32"); try write([stage.fontPixels],"font.f64")
                // Commit manifest last; partial directories are never valid replay packets.
                try metadata.write(to: packet.appendingPathComponent("manifest.json"), options: .atomic)
                HostDump.capture("source-stage-cache", ["status": "captured", "complete": true,
                    "manifest": packet.appendingPathComponent("manifest.json").path,
                    "bytes": rawBytes + metadata.count, "processBudgetBytes": 190_000_000])
            } catch is CancellationError { throw CancellationError() }
            catch { skipped("IO-failed-reservation-not-reused: \(error)") }
        }
    }

}
