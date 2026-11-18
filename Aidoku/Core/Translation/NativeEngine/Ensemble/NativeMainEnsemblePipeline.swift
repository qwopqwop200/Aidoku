import CoreGraphics
import Foundation

/// In-memory main entrypoint. Caller supplies one upright page-local viewport,
/// identity-bound RF/OCR evidence and translated raw items. No file or model lookup
/// belongs here; the serial resident backend owns restoration and its resources.
/// promptVersion: technical-review-v1 + main-integration-v1.
@available(iOS 16.0, macOS 13.0, *)
enum NativeMainEnsemblePipeline {
    typealias Parameters = [String: [String: Double]]
    static let stageOrder = ["01", "02", "03", "05", "04", "06", "07", "08"]

    /// Deployment activation is explicit here, not inherited from experiment env.
    /// Missing override keys retain these values; enabled=0 disables one stage.
    /// pipeline.enabled=0 throws so the adapter can use its existing renderer;
    /// it never returns an untranslated source page as a successful translation.
    static let defaultParameters: Parameters = {
        var p: Parameters = ["01": EnsembleCandidate01.defaults, "02": EnsembleCandidate02Next.defaults,
            "03": EnsembleCandidate03.defaults, "04": EnsembleCandidate04Next.defaults,
            "05": EnsembleCandidate05.defaults, "06": EnsembleCandidate06Next.defaults,
            "07": EnsembleCandidate07Next.defaults, "08": EnsembleCandidate08.defaults,
            "maskDense": ["enabled": 0],
            "maskFlat": ["enabled": 0],
            "maskTopology": ["enabled": 0],
            "03Texture": ["enabled": 0],
            "04Unknown": ["enabled": 0],
            "04EnvelopeRefit": ["enabled": 0],
            "04ParagraphJoint": ["enabled": 0],
            // Strict opaque/flat-context correction only; nonflat and uncertain
            // regions keep the unchanged resident AOT prediction.
            "aotBoundaryBias": ["enabled": 0],
            "04Flow": ["enabled": 1, "maximumOverlapFraction": 0.25,
                "useOriginalBoundaryWitness": 1, "explicitPixelSampling": 1, "minimumRetainedFontRatio": 0.75],
            // Full836 source-bound apply proof plus actual affected-page renders:
            // reject backing masquerading as dominant ink; retain source predictions.
            "07Dominance": ["enabled": 1, "minimumBridgeFraction": 0.4, "useObservedHaloEndpoint": 1],
            "07Final": ["enabled": 1, "minimumCoverageGain": 0.05],
            "pipeline": ["enabled": 1, "maxPixels": 32_000_000, "spacingPolicyVersion": Double(NativeTextSpacing.version),
                "rebindSourceNearAfterReadOrder": 1,
                // Combined836 replay: independent display duplicate removal,
                // incumbent-preserving original chromatic contour recovery.
                "recoverChromaticShellPalette": 1,
                "recoverOwnConnectedBoundary": 1]]
        for key in stageOrder { p[key]?["enabled"] = 1 }
        let tuned: Parameters = [
            "02": ["requireSingleColumn": 1, "reachXEm": 1.5, "neighborGapEm": 0.6],
            "04": ["minFontScale": 0.65, "fontSteps": 4, "widthSteps": 3, "leadingSteps": 1,
                "lineWeight": 3, "shrinkWeight": 24, "emergencyMinFontScale": 0.45, "useSourceInkAnchor": 1],
            "06": ["terminalReach": 0.75, "supportCoverage": 0.9, "surfaceTolerance": 36,
                "stemSeedFraction": 0.1, "streamingOwners": 1, "minimumOutsidePointContrast": 8,
                "neutralForeignOwnerProtection": 1],
            "07": ["fillWeight": 0.7, "backgroundMeanWeight": 0.4, "backgroundTailWeight": 0.25,
                "sourceToneWeight": 1.7, "sourceContrastWeight": 0.5, "minimumFillStrokeContrast": 3,
                "strokeRatio": 0.20, "extraWidth1": 0, "extraWidth2": 0]
        ]
        for (key, values) in tuned { p[key] = p[key, default: [:]].merging(values) { _, new in new } }
        return p
    }()

    enum Failure: Error {
        case disabled, invalidViewport, sourceBudget, imageDimensions, allocation, invalidMask
        case conflictingMaskPolicies
        case duplicateOwner(String), invalidItem(Int, String), unsupportedMaskItemMutation
        case incompleteTranslation(expected: Int, painted: Int)
        case paragraphOwnershipMutation, invalidAOTPostprocessConfiguration, invalidAOTInferenceAudit
    }

    static func render(original: CGImage, rawItems: [[String: Any]], viewport: CGSize,
                       rfRegions: [Ensemble100RFRegion], restored: CGImage? = nil,
                       baseRemovalMask: CGImage? = nil, savedEvidence: [String: Any] = [:],
                       sourceProbability: NativeMainAOTRemovalMaskBuilder.SourceProbability? = nil,
                       unownedMasks: [NativeCausalUnownedInkLiveRecovery.AffiliatedMask] = [],
                       erasureMode: NativeAOTRemovalReadiness.ErasureMode = .retainedText,
                       cohortFitPolicy: NativeCohortFitPlanner.Policy? = .onFailure,
                       simplePlacement: NativeSimpleRFBalloonPlacement? = nil,
                       parameters: Parameters = defaultParameters, collectAudit: Bool = true) throws -> NativeAOTTranslationPageComposer.Result {
        try Task.checkCancellation()
        try simplePlacement?.validate(original: original, viewport: viewport)
        let started = Date(), p = resolved(parameters)
        let calibrateBoundaryBias = enabled("aotBoundaryBias", p)
        let saturationGuard = p["aotBoundaryBias"]?["rejectNewSaturation"] ?? 0
        guard saturationGuard == 0 || saturationGuard == 1 else { throw Failure.invalidAOTPostprocessConfiguration }
        let rejectNewBoundarySaturation = saturationGuard == 1
        let boundaryMeanClamp: Int?
        if let value = p["aotBoundaryBias"]?["meanResidualClamp"] {
            guard value == 8 || value == 16 else {
                throw Failure.invalidAOTPostprocessConfiguration
            }
            boundaryMeanClamp = Int(value)
        } else { boundaryMeanClamp = nil }
        guard NativeAOTBoundaryBias.validConfiguration(enabled: calibrateBoundaryBias, meanClamp: boundaryMeanClamp,
                                                      rejectNewSaturation: rejectNewBoundarySaturation) else {
            throw Failure.invalidAOTPostprocessConfiguration
        }
        guard p["pipeline"]?["enabled"] != 0 else { throw Failure.disabled }
        guard ["maskDense", "maskFlat", "maskTopology"].filter({ enabled($0, p) }).count <= 1 else {
            throw Failure.conflictingMaskPolicies
        }
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0 else {
            throw Failure.invalidViewport
        }
        let limit = min(32_000_000, max(1, p["pipeline"]?["maxPixels"] ?? 32_000_000))
        guard original.width > 0, original.height > 0, Double(original.width) <= limit / Double(original.height),
              rawItems.count <= 4096 else { throw Failure.sourceBudget }
        // Direct callers may carry a historical serialized keptLettering=false.
        // Actual nonempty source text equality is required; absent proof stays unchanged.
        let rawItems = NativeSourceTextPreservation.normalized(rawItems)
        if let restored { try dimensions(restored, original) }
        var evidence = savedEvidence
        // Typed live masks are consumed here, never serialized as saved page evidence.
        let selectedSourceMasks = evidence.removeValue(forKey: "sourceSegmentationMasks") as? NativeSelectedSourceSegmentationMasks
        let retainedSourceRF = evidence.removeValue(forKey: "retainedSourceRF") as? NativeLiveSourceAppearance.RFEvidence
        let removalItems = evidence["sourceRevisionRemovalItems"] as? [[String: Any]] ?? rawItems
        if evidence["originalItems"] == nil {
            evidence["originalItems"] = rawItems
        } else if evidence["sourceRevisionRemovalItems"] == nil,
                  let originals = evidence["originalItems"] as? [[String: Any]] {
            evidence["originalItems"] = NativeSourceTextPreservation.normalized(originals)
        }
        // Empty identity deliberately leaves cached-text recovery unbound. A
        // decoded-image hash is NOT interchangeable with an encoded-file hash.
        let identity = evidence["sourceSHA256"] as? String ?? ""
        let targetOwners = NativeSourceOwnerRecovery.partitionDisplayTargets(rawItems)
        // Display consolidation never retires non-contained source polygons:
        // base-mask construction,06 originalItems and readiness retain rawItems.
        var current = targetOwners.displayItems.map { item -> [String: Any] in
            var value = item; value["enableVerticalDisplayTitles"] = true; return value
        }
        if p["pipeline"]?["recoverChromaticShellPalette"] == 1 {
            for index in current.indices { current[index]["sourceChromaticShellPaletteRecovery"] = true }
        }
        if p["pipeline"]?["recoverOwnConnectedBoundary"] == 1 {
            for index in current.indices {current[index]["sourceOwnConnectedBoundaryRecovery"]=true}
        }
        let placement = try simplePlacement?.rebinding(items: current, viewport: viewport)
        let contours = NativeMainBalloonContours.annotate(current, original: original, regions: rfRegions,
            viewport: viewport, parameters: p["03"] ?? [:], texturedParameters: p["03Texture"] ?? [:],
            sourceIdentity: identity.isEmpty ? nil : identity,
            regionsSourceIdentity: evidence["rfSourceSHA256"] as? String, simplePlacement: placement)
        current = contours.items
        if NativeEnsembleLayoutContour.supportedEstimatedContourEnabled {
            current = try NativeOperationalRenderExpansion.reannotateGenerated(items: current,
                viewport: viewport, source: original, regions: rfRegions, simplePlacement: placement)
        }
        let joins: [[String: Any]] = []
        try validateOwners(current)
        let baseMask: CGImage
        let baseBytes: [UInt8]
        let baseSummary: NativeMainAOTRemovalMaskBuilder.MaskSummary?
        let sourceMaskAudit: [String: Any]
        let sourceOwnership: NativeEnsembleRemovalDenseSupport.Ownership?
        if let baseRemovalMask {
            baseBytes = try maskBytes(baseRemovalMask, original: original)
            baseMask = try maskImage(baseBytes, original: original)
            sourceMaskAudit = ["status": "caller-source-bound-base-mask"]
            sourceOwnership = nil; baseSummary = nil
        } else {
            // Erasure owns original source polygons, not merged display geometry.
            let built = try NativeMainAOTRemovalMaskBuilder.buildWithAudit(original: original,
                items: removalItems, rfRegions: rfRegions, parameters: p["06"] ?? [:], probability: sourceProbability,
                unownedMasks: unownedMasks, sourceDisplayItems: rawItems,
                selectedSegmentation: selectedSourceMasks, collectAudit: collectAudit)
            baseMask = built.mask; baseBytes = built.canonicalMaskBytes; baseSummary = built.summary
            sourceMaskAudit = built.audit; sourceOwnership = built.ownership
        }
        evidence["removalMaskAvailable"] = true
        let initialPage = Ensemble100Page(sourceSHA256: identity, original: original, restored: restored ?? original,
            removalMask: baseMask, viewport: viewport, items: current, rfRegions: rfRegions, savedEvidence: evidence)
        var cacheConfiguration = NativeMainEnsembleCacheContext.Configuration.numeric(p["08"] ?? [:])
        cacheConfiguration.enabled = enabled("08", p)
        return try NativeMainEnsembleCacheContext.withPage(initialPage, configuration: cacheConfiguration) { _, cache in
            var records: [[String: Any]] = [], changedMask: CGImage?
            var stage05Evidence: [String: Any]?
            func record(_ entry: @autoclosure () -> [String: Any]) {
                if collectAudit { records.append(entry()) }
            }
            var background = restored ?? original
            func page(_ items: [[String: Any]], maskWitness: Bool = false) -> Ensemble100Page {
                cache.attaching(to: Ensemble100Page(sourceSHA256: identity, original: original,
                    restored: maskWitness ? (restored ?? original) : background, removalMask: baseMask,
                    viewport: viewport, items: items, rfRegions: rfRegions, savedEvidence: evidence))
            }
            func stage(_ key: String, input: [[String: Any]]) throws -> Ensemble100Proposal {
                let snapshot = page(input, maskWitness: key == "06")
                switch key {
                case "01": return try EnsembleCandidate01.apply(snapshot, parameters: p[key] ?? [:])
                case "02": return try EnsembleCandidate02Next.apply(snapshot, parameters: p[key] ?? [:])
                case "03": return try EnsembleCandidate03.apply(snapshot, parameters: p[key] ?? [:])
                case "05":
                    var proposal = try EnsembleCandidate05.apply(snapshot, parameters: p[key] ?? [:])
                    if p["pipeline"]?["rebindSourceNearAfterReadOrder"] == 1 {
                        let rebound = NativeSourceNearOwnerRebinding.apply(before: input, after: proposal.items)
                        proposal.items = rebound.items
                        proposal.audit["sourceNearOwnerRebinding"] = rebound.audit
                    }
                    return proposal
                case "04":
                    let verifier: (([String: Any]) -> Bool)?
                    if enabled("03Texture", p), p["03Texture"]?["recheckBoundaryForLayout"] == 1 {
                        verifier = { raw in
                            (try? NativeEnsembleTexturedContours.rechecks(raw, original: original, viewport: viewport,
                                regions: rfRegions, parameters: p["03Texture"] ?? [:])) == true
                        }
                    } else { verifier = nil }
                    return try EnsembleCandidate04Next.apply(snapshot, parameters: p[key] ?? [:],
                        originalBoundaryVerifier: verifier)
                case "06": return try EnsembleCandidate06Next.apply(snapshot, parameters: p[key] ?? [:])
                case "07":
                    let annotated = Ensemble100PaletteBridge.annotate(input, original: original, cache: cache)
                    let baseline = try EnsembleCandidate07Next.apply(page(annotated), parameters: p[key] ?? [:])
                    guard enabled("07Dominance", p) else { return baseline }
                    var revised = try NativeEnsembleDominantColorEvidenceV2.apply(page(baseline.items),
                        parameters: p["07Dominance"] ?? [:], strokeParameters: p[key] ?? [:])
                    revised.audit["baseline07"] = baseline.audit
                    return revised
                default: return try EnsembleCandidate08.apply(snapshot, parameters: p[key] ?? [:])
                }
            }
            func accept(_ proposal: Ensemble100Proposal, key: String) throws {
                try validateOwners(proposal.items)
                guard preservesParagraphOwnership(targetOwners.displayItems, proposal.items) else { throw Failure.paragraphOwnershipMutation }
                if proposal.requiresRestoration {
                    guard let mask = proposal.replacementMask else { throw Failure.invalidMask }
                    try dimensions(mask, original); changedMask = mask
                }
                current = proposal.items
                if key == "04" {
                    for row in (proposal.audit["agent04"] ?? proposal.audit["agent04Next"]) as? [[String: Any]] ?? [] {
                        guard ["proposed-glyph-and-stroke-checked", "proposed-minimum-objective"].contains(row["status"] as? String ?? ""),
                              let index = row["index"] as? Int, current.indices.contains(index) else { continue }
                        current[index]["ensembleLockLayout"] = true
                        current[index]["ensembleStrokeRatio"] = max(0.20, p["04"]?["strokeFraction"] ?? 0.20)
                    }
                }
            }
            func apply(_ key: String) throws {
                let start = Date()
                guard enabled(key, p) else { record(["candidate": key, "status": "disabled"]); return }
                do {
                    let proposal = try stage(key, input: current)
                    try accept(proposal, key: key)
                    if key == "05" { stage05Evidence = proposal.audit }
                    record(["candidate": key, "seconds": Date().timeIntervalSince(start),
                        "parameters": p[key] ?? [:], "evidence": proposal.audit])
                } catch {
                    try Task.checkCancellation()
                    record(["candidate": key, "seconds": Date().timeIntervalSince(start),
                        "status": "failed-preserved-incumbents", "error": String(reflecting: error),
                        "itemCount": current.count, "qualitySuccess": false])
                }
            }
            for key in ["01", "02"] { try apply(key) }
            // No renderer-side graph, RF-text or tilted-axis paragraph unions.
            if let ids = evidence["sourceRevisionOwnCapacityOwnerIDs"] as? [String], !ids.isEmpty {
                let proposal = try NativeSourceRevisionCapacity.constrain(page(current), ownerIDs: Set(ids))
                try accept(proposal, key: "02SourceRevisionCapacity")
                record(["candidate": "02SourceRevisionCapacity", "evidence": proposal.audit])
            }
            for key in ["03", "05"] { try apply(key) }

            var unknownSpaceAudit: [String: Any] = ["status": "disabled"]
            if enabled("04Unknown", p) {
                // Preserve relations05 actually applied, even when it does not tag raw items.
                let relations = stage05Evidence
                let protectedKeys = (relations?["relations"] as? [[String: Any]] ?? []).filter {
                    $0["status"] as? String == "applied"
                }.flatMap { $0["members"] as? [String] ?? [] }
                var supporting = evidence
                supporting["unknownSpaceProtectedOwnerKeys"] = protectedKeys
                let input = cache.attaching(to: Ensemble100Page(sourceSHA256: identity, original: original,
                    restored: background, removalMask: baseMask, viewport: viewport, items: current,
                    rfRegions: rfRegions, savedEvidence: supporting))
                var options = p["04Unknown"] ?? [:]
                options["assumed04MaximumWidthGrowth"] = min(3, max(1, p["04"]?["maximumWidthGrowth"] ?? 2))
                do {
                    let proposal = try NativeEnsembleUnknownSpaceLayout.apply(input, parameters: options)
                    try accept(proposal, key: "04Unknown")
                    unknownSpaceAudit = proposal.audit
                } catch {
                    try Task.checkCancellation()
                    unknownSpaceAudit = ["status": "failed-preserved-incumbents",
                        "error": String(reflecting: error), "qualitySuccess": false]
                }
            }

            // Frozen06 uses original pixels, source geometry/font, originalItems,
            // OCR/RF and BASE mask, never 04's display frame/font or restoration.
            // Prepare that same proposal now, so first-use main does ONE final-
            // mask restoration BEFORE 04's restored-pixel containment checks.
            // Its logical application/audit remains after04. Revisit this boundary
            // if a future06 starts changing items or consuming display geometry.
            let maskStart = Date()
            var prepared06: Ensemble100Proposal?, maskFailure: String?
            var prepared06Bytes: [UInt8]?
            if enabled("06", p) {
                do {
                    let proposal = try stage("06", input: current)
                    guard sameItems(proposal.items, current) else { throw Failure.unsupportedMaskItemMutation }
                    if proposal.requiresRestoration {
                        guard let mask = proposal.replacementMask else { throw Failure.invalidMask }
                        prepared06Bytes = try maskBytes(mask, original: original)
                        changedMask = mask
                    }
                    prepared06 = proposal
                } catch {
                    try Task.checkCancellation(); maskFailure = String(reflecting: error)
                }
            }
            var effectiveBytes = try prepared06Bytes ?? changedMask.map { try maskBytes($0, original: original) } ?? baseBytes
            prepared06Bytes = nil
            var effectiveMask = changedMask == nil ? baseMask : try maskImage(effectiveBytes, original: original)
            var denseAudit: [String: Any] = ["status": "disabled"]
            var flatAudit: [String: Any] = ["status": "disabled"]
            var topologyAudit: [String: Any] = ["status": "disabled"]
            if enabled("maskDense", p) {
                if let sourceOwnership {
                    let result = try NativeEnsembleRemovalDenseSupport.apply(original: original,
                        mask: effectiveMask, ownership: sourceOwnership, probability: sourceProbability,
                        parameters: p["maskDense"] ?? [:])
                    denseAudit = result.audit
                    if let replacement = result.replacementMask {
                        effectiveBytes = try maskBytes(replacement, original: original)
                        effectiveMask = try maskImage(effectiveBytes, original: original)
                    }
                } else {
                    denseAudit = ["status": "unchanged", "reason": "caller-mask-original-owner-inventory-unavailable"]
                }
            }
            if enabled("maskFlat", p) {
                if let sourceOwnership {
                    let inventory = NativeEnsembleRemovalFlatBacking.Ownership(original: original,
                        owners: sourceOwnership.owners.map {
                            .init(polygon: $0.polygon, fontPixels: $0.fontPixels, preserved: $0.preserved)
                        })
                    let result = try NativeEnsembleRemovalFlatBacking.apply(original: original,
                        mask: effectiveMask, ownership: inventory, probability: sourceProbability,
                        parameters: p["maskFlat"] ?? [:])
                    flatAudit = result.audit
                    if let replacement = result.replacementMask {
                        effectiveBytes = try maskBytes(replacement, original: original)
                        effectiveMask = try maskImage(effectiveBytes, original: original)
                    }
                } else {
                    flatAudit = ["status": "unchanged", "reason": "caller-mask-original-owner-inventory-unavailable"]
                }
            }
            if enabled("maskTopology", p) {
                if let sourceOwnership {
                    let inventory = NativeEnsembleRemovalFlatTopology.Ownership(original: original,
                        owners: sourceOwnership.owners.map {
                            .init(polygon: $0.polygon, fontPixels: $0.fontPixels, preserved: $0.preserved)
                        })
                    let result = try NativeEnsembleRemovalFlatTopology.apply(original: original,
                        mask: effectiveMask, ownership: inventory, probability: sourceProbability,
                        parameters: p["maskTopology"] ?? [:])
                    topologyAudit = result.audit
                    if let replacement = result.replacementMask {
                        effectiveBytes = try maskBytes(replacement, original: original)
                        effectiveMask = try maskImage(effectiveBytes, original: original)
                    }
                } else {
                    topologyAudit = ["status": "unchanged", "reason": "caller-mask-original-owner-inventory-unavailable"]
                }
            }
            // Count actual paint-eligible targets, not all original removal
            // fragments or duplicate-display carriers. Match paintItems exactly.
            let retainedBeforeRestoration = Set(current.filter {
                !held($0) && ($0["text"] as? String)?.isEmpty == false
            }.compactMap { $0["id"] as? String })
            var maskChanged = effectiveBytes != baseBytes
            let matchingBase = maskChanged ? nil : baseSummary
            let proposedHasRemovalPixels = matchingBase.map { $0.foregroundCount != 0 } ?? effectiveBytes.contains(255)
            let restorationPlan = try NativeAOTRemovalReadiness.restorationPlan(
                retainedOwners: retainedBeforeRestoration.count,
                hasRemovalPixels: proposedHasRemovalPixels, mode: erasureMode)
            // Only source-preservation needs a second proposed/applied identity;
            // ordinary retained-owner runs keep their existing single mask hash.
            var knownDigest = matchingBase?.sha256
            if collectAudit, restorationPlan.preserveOriginal, knownDigest == nil {
                knownDigest = NativeMainAOTRemovalMaskBuilder.canonicalMaskSHA256(effectiveBytes)
            }
            let proposedMaskSHA256 = restorationPlan.preserveOriginal ? knownDigest : nil
            if restorationPlan.preserveOriginal && proposedHasRemovalPixels {
                effectiveBytes = [UInt8](repeating: 0, count: baseBytes.count)
                effectiveMask = try maskImage(effectiveBytes, original: original)
                maskChanged = baseSummary.map { $0.foregroundCount != 0 } ?? baseBytes.contains(255)
                knownDigest = maskChanged ? nil : baseSummary?.sha256
            }
            let observedOCR = (evidence["originalOCR"] as? [String: Any])?["regions"] as? [[String: Any]]
            var removalReadiness = try NativeAOTRemovalReadiness.audit(activeOwners: retainedBeforeRestoration.count,
                inputOwners: rawItems.count, observedOCR: observedOCR?.count,
                hasRemovalPixels: proposedHasRemovalPixels)
            removalReadiness.merge(restorationPlan.audit) { _, actual in actual }
            removalReadiness["proposedMaskSHA256"] = proposedMaskSHA256
            let restorationStart = Date()
            let sourceSelection: (image: CGImage, audit: [String: Any], calls: Int) =
                (original, ["status": "source-pass-through-no-retained-text", "inferenceCalls": 0,
                    "bindingAuthority": "original upright source; no active retained target and no applied erasure"], 0)
            let selection = try NativeAOTRemovalReadiness.resolve(restorationPlan, original: sourceSelection) {
                if let restored, baseRemovalMask != nil, !maskChanged, !calibrateBoundaryBias {
                    return (image: restored, audit: ["status": "caller-restoration-reused", "inferenceCalls": 0,
                        "bindingAuthority": "caller supplied matching base mask and same upright source; not pixel-proven"], calls: 0)
                }
                let result = try NativeMainAOTBackend.shared.restore(source: original, canonicalMaskBytes: effectiveBytes,
                    calibrateBoundaryBias: calibrateBoundaryBias, boundaryMeanClamp: boundaryMeanClamp,
                    rejectNewBoundarySaturation: rejectNewBoundarySaturation)
                try dimensions(result.image, original)
                guard let actualCalls = result.coordinateAudit["inferenceCalls"] as? Int, (0...1).contains(actualCalls) else {
                    throw Failure.invalidAOTInferenceAudit
                }
                return (image: result.image, audit: result.coordinateAudit, calls: actualCalls)
            }
            background = selection.image
            var restorationAudit = selection.audit
            let restorationCalls = selection.calls
            if collectAudit {
                restorationAudit.merge(restorationPlan.audit) { _, actual in actual }
                restorationAudit["proposedMaskSHA256"] = proposedMaskSHA256
                if restorationPlan.preserveOriginal { restorationAudit["appliedMaskPixels"] = 0 }
                restorationAudit["secondsIncludingBackendAdmission"] = Date().timeIntervalSince(restorationStart)
                restorationAudit["backendRequests"] = restorationCalls
                restorationAudit["baseMaskBuiltHere"] = baseRemovalMask == nil
                restorationAudit["changedInferenceMask"] = maskChanged
                restorationAudit["inferenceMaskSHA256"] =
                    knownDigest ?? NativeMainAOTRemovalMaskBuilder.canonicalMaskSHA256(effectiveBytes)
            }
            try apply("04")
            if let prepared06 {
                record(["candidate": "06", "parameters": p["06"] ?? [:], "evidence": prepared06.audit,
                    "preparedBeforeLayout": true, "preparationSeconds": Date().timeIntervalSince(maskStart)
                        - Date().timeIntervalSince(restorationStart)])
            } else {
                record(["candidate": "06", "status": enabled("06", p) ? "failed-preserved-base-mask" : "disabled",
                    "error": maskFailure as Any? ?? NSNull(), "qualitySuccess": false])
            }
            try apply("07")
            if enabled("04Flow", p) {
                let start = Date()
                let relations = stage05Evidence
                var supporting = evidence
                supporting["jointFlowProtectedOwnerKeys"] = (relations?["relations"] as? [[String: Any]] ?? []).filter {
                    $0["status"] as? String == "applied"
                }.flatMap { $0["members"] as? [String] ?? [] }
                let input = page(current)
                let flowPage = Ensemble100Page(sourceSHA256:input.sourceSHA256,original:input.original,
                    restored:input.restored,removalMask:input.removalMask,viewport:input.viewport,
                    items:input.items,rfRegions:input.rfRegions,savedEvidence:supporting)
                let proposal = try EnsembleCandidate04Next.sharedBalloonFlow(flowPage,parameters:p["04Flow"] ?? [:],
                    layoutParameters:p["04"] ?? [:],sourceDriftEm:p["02"]?["centerDriftEm"] ?? 0.75)
                try accept(proposal,key:"04Flow")
                record(["candidate":"04Flow","seconds":Date().timeIntervalSince(start),
                    "parameters":p["04Flow"] ?? [:],"evidence":proposal.audit])
            }
            let alignedStart = Date()
            let aligned = EnsembleCandidate04Next.sourceAlignedColumns(page(current))
            try accept(aligned, key: "04SourceAligned")
            record(["candidate": "04SourceAligned", "seconds": Date().timeIntervalSince(alignedStart),
                "evidence": aligned.audit])
            if enabled("04EnvelopeRefit", p) {
                let start=Date()
                do {
                    let proposal=try EnsembleCandidate04Next.sourceEnvelopeRefit(page(current),parameters:p["04EnvelopeRefit"] ?? [:])
                    try accept(proposal,key:"04EnvelopeRefit")
                    record(["candidate":"04EnvelopeRefit","seconds":Date().timeIntervalSince(start),
                        "parameters":p["04EnvelopeRefit"] ?? [:],"evidence":proposal.audit])
                } catch {
                    try Task.checkCancellation()
                    record(["candidate":"04EnvelopeRefit","status":"failed-preserved-incumbents",
                        "error":String(reflecting:error),"qualitySuccess":false])
                }
            }
            if enabled("04ParagraphJoint",p) {
                let jointStart=Date()
                do {
                    let proposal=try NativeCausalParagraphJointLayout.apply(page(current),parameters:p["04ParagraphJoint"] ?? [:])
                    try accept(proposal,key:"04ParagraphJoint")
                    record(["candidate":"04ParagraphJoint","seconds":Date().timeIntervalSince(jointStart),"evidence":proposal.audit])
                } catch {
                    try Task.checkCancellation()
                    record(["candidate":"04ParagraphJoint","status":"failed-preserved-incumbents",
                        "error":String(reflecting:error),"qualitySuccess":false])
                }
            }
            try apply("08")
            if enabled("07Final",p) {
                current=current.map { raw in
                    var value=raw
                    value["ensembleFinalStrokeRecheck"]=true
                    value["ensembleFinalStrokeContrastFloor"]=p["07"]?["minimumFillStrokeContrast"] ?? 3
                    value["ensembleFinalStrokeMinimumGain"]=p["07Final"]?["minimumCoverageGain"] ?? 0.05
                    return value
                }
            }
            let collisionRepair = EnsembleCandidate04Next.resolveInfeasibleSourceNearCollisions(page(current))
            try accept(collisionRepair, key: "04ConflictRepair")
            record(["candidate": "04ConflictRepair", "evidence": collisionRepair.audit])
            let paintStart = Date()
            guard preservesParagraphOwnership(targetOwners.displayItems, current) else { throw Failure.paragraphOwnershipMutation }
            // Source font inference is authoritative. Re-shape at that size rather than
            // consuming certificates produced by bbox-constrained layout candidates.
            let requestedByID = Dictionary(uniqueKeysWithValues: NativeSourceStyleConsistency.harmonized(NativeTypographyConsistency.harmonized(targetOwners.displayItems)).compactMap { raw -> (String, [String: Any])? in
                (raw["id"] as? String).map { ($0, raw) }
            })
            current = current.map { raw in
                guard let id = raw["id"] as? String, let input = requestedByID[id],
                      let requested = (input["sourceRequestedDisplayFontSize"] as? NSNumber)
                        ?? (input["fontSize"] as? NSNumber), requested.doubleValue.isFinite,
                      requested.doubleValue > 0 else { return raw }
                var value = raw
                value["sourceClusterAlignment"] = input["sourceClusterAlignment"]
                value["balloonPlacement"] = input["balloonPlacement"]
                for key in ["supportedEstimatedContourReceipt", "renderExpansionPolicyOrigin", "balloonLayoutRectNormalized", "typographyGroupID", "lineHeightEm", "trackingEm", "textAlignment", "textPlacementGuide", "textExpansionPolicy", "sourceAppearance", "sourceAppearanceBinding", "sourceContourPaintBinding", "sourceFontSize",
                    "sourceStyleGroupID", "sourceColourGroupID", "sourceFontFitGroupID", "sourceFontFitGroupAuthority",
                    "renderSourceFillRGB", "renderSourceOutlineRGB", "renderSourceOutlineWidthPx", "renderSourceDisplayStrokeRGB"] { value[key] = input[key] }
                if let stroke=input["renderSourceDisplayStrokeRGB"] {
                    value["ensembleDisplayStroke"]=stroke
                    value["ensembleFinalStrokeRecheck"]=false
                }
                if let fill=input["renderSourceFillRGB"] { value["ensembleDisplayFill"]=fill }
                if input["renderSourceOutlineRGB"] != nil { value["ensembleStrokeRatio"]=0.035 }
                if let fill = value["ensembleDisplayFill"] as? [Double],
                   let incumbent = value["ensembleStrokeRatio"] as? NSNumber {
                    value["ensembleStrokeRatio"] = Double(NativeExplicitDisplayStrokePolicy.sourceAwareGuardRatio(
                        chosenFillRGB:fill,sourceAppearance:input["sourceAppearance"] as? [String:Any],
                        incumbentRatio:CGFloat(incumbent.doubleValue)))
                }
                value["bboxConstrainedFontSizeBeforeReshape"] = raw["fontSize"]
                value["fontSize"] = requested
                // Earlier candidates inserted wraps for their smaller font. Reflow the
                // original translation, preserving only its intentional line breaks.
                value["text"] = input["text"]
                let inputFont = (input["fontSize"] as? NSNumber)?.doubleValue ?? requested.doubleValue
                let inputPitch = (input["lineHeight"] as? NSNumber)?.doubleValue ?? inputFont * 1.12
                value["lineHeight"] = max(requested.doubleValue, inputPitch * requested.doubleValue / max(0.001, inputFont))
                value["ensembleLockLayout"] = false
                value["renderPreserveRequestedFontSize"] = true
                value["renderFontPolicy"] = "preserve-source-estimate; bounded-source-line-shape; targeted-fit-retries"
                return value
            }
            let converted = try paintItems(current, original: original, cache: cache)
            guard Set(converted.items.map(\.id)) == retainedBeforeRestoration else {
                throw Failure.paragraphOwnershipMutation
            }
            var paintSource = NativeRetainedSourceRisk.OriginalObservation(original)
            let risk = NativeRetainedSourceRisk.make(original: &paintSource, erased: effectiveBytes, evidence: retainedSourceRF)
            record(["candidate": "retainedSourceRisk", "status": risk.status])
            let wantsPhysical = ProcessInfo.processInfo.environment["AIDOKU_SOURCE_PHYSICAL_INTERIOR"] != "0" &&
                current.contains { ($0["textExpansionPolicy"] as? [String:Any])?["kind"] as? String == "inside-balloon-mask" }
            let contextRequest = try NativeSourceCohortCenterBalance.sourceContextRequest(physicalRequested:wantsPhysical,
                rawItems:current,renderedOwnerIDs:Set(converted.items.map(\.id)))
            let sourceContext: NativeSourcePhysicalInteriorContext?
            if contextRequest.needed, let source = try? paintSource.pixels() {
                sourceContext = NativeSourcePhysicalInteriorContext(rgb:source.rgb,width:source.identity.width,
                    height:source.identity.height,erased:effectiveBytes,sourceIdentity:source.identity.source,
                    sourceOpaque:NativeSourcePhysicalInteriorContext.opaqueSourceProof(original))
            } else { sourceContext = nil }
            paintSource.finish()
            // Preserve the old physical TaskLocal activation EXACTLY. A source
            // decode can be shared without sharing the consumers' permissions.
            let physicalContext = wantsPhysical ? sourceContext : nil
            let cohortContext = contextRequest.cohortBoundary ? sourceContext : nil
            let qualityContext = ProcessInfo.processInfo.environment["AIDOKU_SOURCE_OBSTRUCTION_QUALITY"] == "0" ? nil : sourceContext
            record(["candidate":"sourcePhysicalInteriorContext", "physicalRequested":wantsPhysical,
                "cohortBoundaryRequested":contextRequest.cohortBoundary,
                "physicalContextAvailable":physicalContext != nil,"cohortBoundaryContextAvailable":cohortContext != nil,
                "sourceObstructionQualityContextAvailable":qualityContext != nil,
                "status":sourceContext == nil ? "unavailable; incumbent retained" : "source-bound; per-owner evidence still required"])
            // Original caller declarations precede ALL injected renderer preserve flags.
            // Full current membership retains held/empty groups; it is not only paintItems.
            var cohortFitAudit: [String:Any]?
            let paintPlacement = try placement?.rebinding(items: current, viewport: viewport)
            let layer = try NativeSourcePhysicalInteriorContext.$current.withValue(physicalContext) {
                try NativeSourcePhysicalInteriorContext.$cohortBoundaryContext.withValue(cohortContext) {
                    try NativeSourceObstructionRecovery.$sourceContext.withValue(qualityContext) {
                        try NativeFinalTextPaintAdmission.$retainedSourceRiskGate.withValue(risk.gate) {
                            do {
                                let renderRequest: ([NativeAOTRawTextPainter.Item]) throws -> NativeAOTTranslationPageComposer.TextLayer = { request in
                                    try NativeAOTRawTextPainter.renderCentered(items: request, rawItems: current,
                                        viewport: viewport, restored: background, allowShrink: false,
                                        simplePlacement: paintPlacement)
                                }
                                guard let cohortFitPolicy, !converted.items.isEmpty else {
                                    return try renderRequest(converted.items)
                                }
                                return try NativeCohortFitPlanner.run(items: converted.items,
                                    authenticatedOptions: current, declaredRaw: rawItems, membershipRaw: current,
                                    policy: cohortFitPolicy, outputScale: CGFloat(background.width)/viewport.width,
                                    record: { cohortFitAudit = $0 }, render: renderRequest).layer
                            } catch {
                                try Task.checkCancellation()
                                // Never turn a planner policy/identity/style proof error into
                                // a partial-owner success. Only exhausted genuine capacity
                                // failures may retain the pre-existing original-font fallback.
                                let completePageFailure=error
                                let fallback = {
                                    do {
                                        return try individualFallback(converted.items, rawItems: current, viewport: viewport,
                                            restored: background, initialFailure: completePageFailure,
                                            simplePlacement: paintPlacement)
                                    } catch var failure as NativeAOTRawTextPainter.FixedFontRecoveryFailure {
                                        failure.diagnostics["completePageInitialFailure"]=String(reflecting:completePageFailure)
                                        failure.diagnostics["completePageCohortFitPlanning"]=cohortFitAudit as Any? ?? NSNull()
                                        throw failure
                                    }
                                }
                                if let cohortFitPolicy, !converted.items.isEmpty {
                                    do {
                                        return try NativeCohortFitPlanner.exhaustedCapacityFallback(after: error, perform: fallback)
                                    } catch let terminal where NativeCohortFitPlanner.retryable(terminal) {
                                        // Reached only when the page is otherwise refused: the full planner ladder
                                        // and the individual fallback both failed on capacity.
                                        try Task.checkCancellation()
                                        guard case NativeCohortFitPlanner.Failure.boundedPlanningUnresolved = completePageFailure,
                                              let lowered = try NativeCohortFitPlanner.belowMinimumScaleFallback(items: converted.items,
                                                authenticatedOptions: current, declaredRaw: rawItems, membershipRaw: current,
                                                policy: cohortFitPolicy, outputScale: CGFloat(background.width)/viewport.width,
                                                after: terminal, record: { receipt in
                                                    var audit = cohortFitAudit ?? [:]
                                                    audit["belowMinimumScaleFallback"] = receipt
                                                    audit["fallbackScale"] = receipt["fallbackScale"] ?? NSNull()
                                                    cohortFitAudit = audit
                                                }, render: { request in
                                                    try NativeAOTRawTextPainter.renderCentered(items: request, rawItems: current,
                                                        viewport: viewport, restored: background, allowShrink: false,
                                                        simplePlacement: paintPlacement)
                                                }) else {
                                            if var failure = terminal as? NativeAOTRawTextPainter.FixedFontRecoveryFailure,
                                               let attempted = cohortFitAudit?["belowMinimumScaleFallback"] {
                                                failure.diagnostics["belowMinimumScaleFallback"] = attempted
                                                throw failure
                                            }
                                            throw terminal
                                        }
                                        return lowered.layer
                                    }
                                }
                                // Strict opt-out retains its pre-existing fallback route.
                                return try fallback()
                            }
                        }
                    }
                }
            }
            guard layer.complete, layer.expectedItems == converted.items.count,
                  layer.paintedItems == converted.items.count else {
                throw Failure.incompleteTranslation(expected: converted.items.count, painted: layer.paintedItems)
            }
            try dimensions(layer.image, original)
            let image: CGImage
            if restorationPlan.preserveOriginal {
                guard converted.items.isEmpty, layer.expectedItems == 0, layer.paintedItems == 0 else {
                    throw Failure.paragraphOwnershipMutation
                }
                // Preserve the original image, not a color-space/canvas roundtrip.
                image = original
                restorationAudit["sourceImageReturnedDirectly"] = true
            } else {
                let context = try canvas(original)
                let bounds = CGRect(x: 0, y: 0, width: original.width, height: original.height)
                context.draw(background, in: bounds); context.draw(layer.image, in: bounds)
                guard let composed = context.makeImage() else { throw Failure.allocation }
                image = composed
            }
            guard collectAudit else {
                return .init(image: image, restored: background, text: layer.image, paintedItemCount: layer.paintedItems,
                             audit: [:], removalMask: effectiveMask)
            }
            let itemAccounting = current.enumerated().map { index, raw -> [String: Any] in
                ["index": index, "id": raw["id"] as? String ?? "", "status": held(raw) ? "preserved-source-lettering"
                    : ((raw["text"] as? String)?.isEmpty ?? true) ? "untranslated-or-empty-retained" : "painted"]
            }
            return .init(image: image, restored: background, text: layer.image, paintedItemCount: layer.paintedItems, audit: [
                "renderItems": current, "itemAccounting": itemAccounting, "inputItemCount": rawItems.count,
                "targetOwnerRecovery": targetOwners.audit,
                "candidateItemCount": current.count, "expectedTranslationItems": converted.items.count,
                "paintedTranslationItems": layer.paintedItems, "complete": layer.complete,
                "sourceFragmentJoins": joins, "paragraphOwnershipPolicy": "upstream-only-no-render-merges-v2171",
                "paragraphOwnershipPreserved": true, "rfBalloonContours": contours.audit, "candidates": records,
                "candidateStageOrder": stageOrder, "maskPreparedBefore04": true,
                "restoration": restorationAudit, "removalReadiness": removalReadiness,
                "sourceMask": sourceMaskAudit, "denseSourceSupport": denseAudit,
                "flatBackingSupport": flatAudit,
                "flatTopologySupport": topologyAudit,
                "unknownSpaceLayout": unknownSpaceAudit,
                "text": layer.audit, "freshOriginalPalette": converted.audit,
                "cohortFitPlanning": cohortFitAudit ?? ["status":"strict-original-request-path"],
                "cache": cache.statistics, "parameters": p, "mainPipelineApplied": true,
                "qualityAccepted": false, "localRenderSeconds": Date().timeIntervalSince(started),
                "layoutStrokeCompositeSeconds": Date().timeIntervalSince(paintStart),
                "timingScope": "memory inputs through masks, candidate stages, backend admission and final composite; excludes OCR/RF/LLM",
                "measurementAuthority": "runtime accounting and raster/completeness checks; not image-quality acceptance"
            ], removalMask: effectiveMask)
        }
    }

    private static func resolved(_ input: Parameters) -> Parameters {
        var result = defaultParameters
        for (stage, values) in input {
            result[stage] = result[stage, default: [:]].merging(values.filter { $0.value.isFinite }) { _, new in new }
        }
        return result
    }
    private static func enabled(_ key: String, _ p: Parameters) -> Bool { (p[key]?["enabled"] ?? 0) > 0 }
    private static func held(_ item: [String: Any]) -> Bool {
        item["keptLettering"] as? Bool == true || item["sourceTextOnly"] as? Bool == true
    }
    private static func dimensions(_ image: CGImage, _ source: CGImage) throws {
        guard image.width == source.width, image.height == source.height else { throw Failure.imageDimensions }
    }
    private static func sameItems(_ a: [[String: Any]], _ b: [[String: Any]]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { NSDictionary(dictionary: $0).isEqual(to: $1) }
    }
    private static func validateOwners(_ items: [[String: Any]]) throws {
        var owners = Set<String>()
        for (index, item) in items.enumerated() where !held(item) && (item["text"] as? String)?.isEmpty == false {
            guard let id = item["id"] as? String, !id.isEmpty else { throw Failure.invalidItem(index, "missing-owner-id") }
            guard owners.insert(id).inserted else { throw Failure.duplicateOwner(id) }
        }
    }
    /// A renderer can reflow whitespace, never concatenate/drop/reassign IDs or text.
    static func preservesParagraphOwnership(_ input: [[String: Any]], _ output: [[String: Any]]) -> Bool {
        func owners(_ items: [[String: Any]]) -> [String: String]? {
            var result: [String: String] = [:]
            for item in items {
                guard let id = item["id"] as? String, !id.isEmpty, result[id] == nil else { return nil }
                result[id] = (item["text"] as? String ?? "").components(separatedBy: .whitespacesAndNewlines).joined()
            }
            return result
        }
        guard input.count == output.count, let a = owners(input), let b = owners(output) else { return false }
        return a == b
    }
    private static func paintItems(_ rawItems: [[String: Any]], original: CGImage,
                                   cache: NativeMainEnsembleCacheContext)
        throws -> (items: [NativeAOTRawTextPainter.Item], audit: [[String: Any]]) {
        let palette = NativeOriginalSourcePalette(original: original)
        var items: [NativeAOTRawTextPainter.Item] = [], records: [[String: Any]] = []
        for (index, raw) in rawItems.enumerated() where !held(raw) {
            guard let text = raw["text"] as? String, !text.isEmpty else { continue }
            guard let id = raw["id"] as? String else { throw Failure.invalidItem(index, "missing-owner-id") }
            func number(_ key: String) throws -> CGFloat {
                guard let n = raw[key] as? NSNumber, n.doubleValue.isFinite else { throw Failure.invalidItem(index, key) }
                return CGFloat(n.doubleValue)
            }
            let sourceBounds = raw["sourceBounds"] as? [Double] ?? []
            let polygon = raw["sourcePolygon"] as? [[Double]]
            let baselineObservation = palette.observeCached(context: cache, originalGeometry: raw)
            let observation = baselineObservation.selected.color == nil
                ? NativeCausalParagraphPaletteCompatibility.observePolicyDescriptor(original:original,
                    geometry:raw,sourceBounds:sourceBounds) ?? baselineObservation : baselineObservation
            let selected = observation.selected
            let recovered = selected.color == nil ? NativeMainEnsembleCacheContext.neutralShell(context: cache,
                original: original, bounds: sourceBounds, polygon: polygon) {
                    NativeNeutralShellObserver.observe(original: original, bounds: sourceBounds, geometry: raw)
                } : nil
            let sourceColor = recovered?.fill ?? selected.color
            let rgb = (raw["ensembleDisplayFill"] as? [Double]) ?? sourceColor ?? [0, 0, 0]
            guard rgb.count == 3, rgb.allSatisfy({ $0.isFinite && (0...255).contains($0) }),
                  let fill = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    components: rgb.map { CGFloat($0 / 255) } + [1]) else { throw Failure.invalidItem(index, "invalid-fill") }
            let frame = try CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
            let font = try number("fontSize"), pitch = try number("lineHeight")
            guard frame.width > 0, frame.height > 0, font > 0, pitch > 0 else { throw Failure.invalidItem(index, "nonpositive-geometry") }
            let dominance = raw["ensembleDominantColorEvidenceV2Audit"] as? [String: Any]
            let correctedDominance = dominance?["action"] as? String == "rejectSurfaceDominance"
            items.append(.init(id: id, text: text, frame: frame, fontSize: font, lineHeight: pitch, chosenFill: fill,
                colorAuthority: correctedDominance ? "source fill selected after independent original exterior contradiction; original predictions retained"
                    : sourceColor == nil ? "unknown source; explicit black fallback, not successful prediction"
                    : "fresh original pixels independent endpoints and owned evidence;" + selected.role))
            records.append(["id": id, "originalFill": (recovered?.fill ?? observation.originalFill) as Any? ?? NSNull(),
                "originalStroke": (recovered?.stroke ?? observation.originalStroke) as Any? ?? NSNull(),
                "selectedOriginalInk": sourceColor as Any? ?? NSNull(), "displayFill": rgb,
                "displayFallback": sourceColor == nil, "selectedRole": selected.role,
                "displayInkSelectionRole": correctedDominance ? "source-fill-after-surface-contradiction" : selected.role,
                "displayDominanceCorrection": dominance as Any? ?? NSNull(),
                "uncertainty": observation.unknownReason as Any? ?? NSNull(),
                "previousOriginalEvidence": observation.rawPrediction as Any? ?? NSNull(),
                "neutralShellEvidence": recovered?.evidence as Any? ?? NSNull()])
        }
        return (items, records)
    }
    private static func individualFallback(_ items: [NativeAOTRawTextPainter.Item], rawItems: [[String: Any]],
                                           viewport: CGSize, restored: CGImage, initialFailure: Error,
                                           simplePlacement: NativeSimpleRFBalloonPlacement? = nil)
        throws -> NativeAOTTranslationPageComposer.TextLayer {
        let context = try canvas(restored)
        let bounds = CGRect(x: 0, y: 0, width: restored.width, height: restored.height)
        var records: [[String: Any]] = [], painted = 0
        var retained: [NativeAOTTranslationPageComposer.TranslatedFillPrimitive] = []
        let scale = CGFloat(restored.width) / viewport.width
        let protected = NativeAOTRawTextPainter.protectedRects(rawItems: rawItems, viewport: viewport, scale: scale)
        for item in items {
            let raw = rawItems.filter { $0["id"] as? String == item.id }
            let layer = try NativeAOTRawTextPainter.renderCentered(items: [item], rawItems: raw,
                viewport: viewport, restored: restored, allowShrink: false, completePeerContext: false,
                simplePlacement: simplePlacement)
            guard layer.complete, layer.expectedItems == 1, layer.paintedItems == 1 else {
                throw Failure.incompleteTranslation(expected: items.count, painted: painted)
            }
            // These rasters already contain every effect. The shared final pass
            // must validate/reposition their union instead of blindly stacking them.
            var primitive = NativeAOTTranslationPageComposer.TranslatedFillPrimitive(image: layer.image,
                frame: bounds, fontOutputPixels: item.fontSize * scale)
            primitive.ownerID = item.id
            primitive.hasFinalEffects = true
            primitive.sourceClusterAlignment = try NativeSourceClusterAlignment.decode(raw.first?["sourceClusterAlignment"])
            primitive.balloonPlacement = try NativeBalloonPlacement.decode(raw.first?["balloonPlacement"])
            primitive.textPlacementGuide = try NativeTextPlacementGuide.decode(raw.first?["textPlacementGuide"])
            primitive.placementDomain = NativeAOTRawTextPainter.placementDomain(raw: raw.first ?? [:],
                viewport: viewport, scale: scale, protected: protected, simplePlacement: simplePlacement,
                outputScaleY: CGFloat(restored.height) / viewport.height)
            if let expansion = try NativeTextExpansionPolicy.decode(raw.first?["textExpansionPolicy"]) {
                primitive.textExpansionPolicy=expansion
                let renderPage=CGRect(x:0,y:0,width:restored.width,height:restored.height)
                let previous=primitive.placementDomain
                primitive.placementDomain={ expansion.allows($0,page:renderPage) && (previous?($0) ?? true) }
            }
            primitive.certifyNativeDomainSubrects()
            retained.append(primitive); painted += 1
            records.append(["id": item.id, "evidence": layer.audit])
        }
        let admitted = try NativeFinalTextPaintAdmission.place(retained, page: bounds)
        for primitive in admitted.fills {
            context.draw(primitive.image, in: CGRect(x: primitive.frame.minX,
                y: CGFloat(restored.height) - primitive.frame.maxY, width: primitive.frame.width, height: primitive.frame.height))
        }
        guard let image = context.makeImage() else { throw Failure.allocation }
        let expectedPixels = admitted.audit.reduce(0) { $0 + ($1["paintedPixels"] as? Int ?? 0) }
        try NativeFinalTextPaintAdmission.verifyRaster(image, expectedPixels: expectedPixels)
        return .init(image: image, expectedItems: items.count, paintedItems: painted, complete: painted == items.count,
            audit: ["perItemRecovery": records, "initialFailure": String(reflecting: initialFailure),
                "wholePageFontReset": false, "peerSafetyUnverifiedAfterRecovery": false,
                "finalPaintAdmission": admitted.audit, "finalPaintBoundsChecked": true,
                "finalPaintCollisionAuthority": "actual retained effect alpha; shared recovery placement", "qualityAccepted": false])
    }
    private static func canvas(_ image: CGImage) throws -> CGContext {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.allocation }
        return context
    }
    private static func maskBytes(_ image: CGImage, original: CGImage) throws -> [UInt8] {
        try dimensions(image, original)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height)
        try bytes.withUnsafeMutableBytes { raw in
            guard let c = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { throw Failure.allocation }
            c.setBlendMode(.copy); c.interpolationQuality = .none
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        try canonicalizeMaskBytes(&bytes)
        return bytes
    }
    static func canonicalizeMaskBytes(_ bytes: inout [UInt8]) throws {
        var needsNormalization = false
        for byte in bytes {
            switch byte {
            case 0, 255: break
            case 1: needsNormalization = true
            default: throw Failure.invalidMask
            }
        }
        if needsNormalization {
            for i in bytes.indices where bytes[i] == 1 { bytes[i] = 255 }
        }
    }

    private static func maskImage(_ bytes: [UInt8], original: CGImage) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: original.width, height: original.height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: original.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.allocation }
        return image
    }
}
