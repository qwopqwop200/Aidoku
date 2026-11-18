import CoreGraphics
import Foundation

/// Invoke on the selected pre-physical tuple only,
/// after outer capacity/initial-word arbitration has committed the plain winner.
/// Never calls place(), reflow, tight(), or any fallback/search/refinement API.
enum NativeTerminalRoundedSourcePaint {
    typealias P = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
    typealias Tuple = (fills: [P], audit: [[String: Any]])
    enum Failure: Error { case malformedBaseline, unsupportedCohort, preexistingCohortReceipt, newSupportUnobserved, boundaryVeto, paintDrift, glyphWitness(String) }

    static func refine(layer: NativeAOTTranslationPageComposer.TextLayer, baseline: Tuple,
                       declaredStyleCohorts: [String: Set<String>], restored: CGImage,
                       enabled: Bool) throws -> (layer: NativeAOTTranslationPageComposer.TextLayer, baseline: Tuple) {
        guard enabled else { return (layer, baseline) }
        try Task.checkCancellation()
        let page = CGRect(x: 0, y: 0, width: restored.width, height: restored.height)
        let ids = baseline.fills.compactMap(\.ownerID)
        guard layer.complete, layer.expectedItems == ids.count, layer.paintedItems == ids.count,
              ids.count == baseline.fills.count, ids.count == baseline.audit.count,
              ids.count <= 256, Set(ids).count == ids.count,
              baseline.audit.indices.allSatisfy({ baseline.audit[$0]["owner"] as? String == ids[$0] }) else {
            throw Failure.malformedBaseline
        }
        let byID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        let oldSupports = try baseline.fills.map { try NativeFinalTextPaintAdmission.retainedFootprint($0) }
        let anchors = try NativeFinalTextPaintAdmission.verifiedRetainedClusterAnchors(baseline.fills,
            footprints: oldSupports, audit: baseline.audit, page: page)
        var assigned = Set<String>(), cohorts: [Set<String>] = []
        for key in declaredStyleCohorts.keys.sorted() {
            let members = declaredStyleCohorts[key]!
            guard !members.isEmpty, members.isSubset(of: Set(ids)), assigned.isDisjoint(with: members) else {
                throw Failure.malformedBaseline
            }
            assigned.formUnion(members); cohorts.append(members)
        }
        for id in ids where !assigned.contains(id) { cohorts.append([id]) }
        var current = baseline, currentLayer = layer
        var outcomes: [[String: Any]] = []
        for members in cohorts {
            try Task.checkCancellation()
            let indices = members.compactMap { byID[$0] }.sorted()
            guard indices.contains(where: { current.fills[$0].sourceStyle?.pendingRoundedContour != nil }) else { continue }
            var stage = "authenticated-shape-plan"
            var measurements: [[String:Any]] = []
            do {
                // Historical center receipts bind active style and exact alpha.
                // Never rebind/remove/recapture them to authorize changed paint.
                guard indices.allSatisfy({ current.audit[$0][NativeSourceCohortCenterBalance.auditKey] == nil }) else {
                    throw Failure.preexistingCohortReceipt
                }
                // Copy complete tuple; only the style's derived paint evidence changes.
                var trial = current
                for i in indices {
                    let old = current.fills[i]
                    guard old.sourceContourOnly, !old.hasFinalEffects, let plain = old.sourceStyle,
                          let active = try NativeSourceStylePaint.activatingDeferredContour(plain,
                              fill: old.image, fontPixels: old.fontOutputPixels) else { throw Failure.unsupportedCohort }
                    trial.fills[i].sourceStyle = active
                }
                let supports = try trial.fills.map { try NativeFinalTextPaintAdmission.retainedFootprint($0) }
                for i in indices {
                    // Bbox shrink is expected. Real native body/retained-anchor,
                    // domain/page, alpha and peer gates below decide admission.
                    let isSubset = subset(supports[i], of: oldSupports[i])
                    var boundary: [String: Any] = ["required": false, "reason": "global-alpha-subset"]
                    if !isSubset {
                        stage = "original-source-boundary"
                        guard let source = NativeSourceCohortCenterBalance.currentBoundaryContext else {
                            throw Failure.newSupportUnobserved
                        }
                        let proof = source.paintBoundaryClearance(incumbent:current.fills[i],
                            before:oldSupports[i],after:supports[i],page:page)
                        boundary = proof.audit
                        measurements.append(["owner": ids[i], "sourceBoundary": boundary])
                        guard let allowed = proof.allowed else { throw Failure.newSupportUnobserved }
                        guard allowed else { throw Failure.boundaryVeto }
                        if let risk = NativeFinalTextPaintAdmission.retainedSourceRiskGate,
                           risk.evaluate(oldSupports[i], supports[i]) != true { throw Failure.boundaryVeto }
                    }
                    measurements.append(["owner": ids[i], "beforeEffectBounds": rect(oldSupports[i].bounds),
                        "afterEffectBounds": rect(supports[i].bounds), "globalAlphaSubset": isSubset,
                        "nativeAnchorRepositioningRequested": false])
                    trial.audit[i]["paintedPixels"] = supports[i].pixels
                    trial.audit[i]["finalFootprintOutputPixels"] = rect(supports[i].bounds)
                    trial.audit[i]["readableBoundsOutputPixels"] = rect(supports[i].readableBounds ?? supports[i].bounds)
                    trial.audit[i]["terminalRoundedSourcePaint"] = ["enabled": true,
                        "fixedCanvasAndFillRGBA": true, "globalSupportSubset": isSubset,
                        "originalSourceBoundary": boundary, "bboxEqualityRequired": false,
                        "nativeRetainedAnchorVerificationRequired": true]
                }
                stage = "native-retained-placement-body-and-anchor"
                try NativeFinalTextPaintAdmission.verifyRetainedPlacement(trial.fills,
                    footprints: supports, page: page, retainedClusterAnchors: anchors)
                let oldPalettes = try current.fills.map { try NativeBalloonReadabilityReflow.exteriorPaletteReceipt($0, restored: restored) }
                let newPalettes = try trial.fills.map { try NativeBalloonReadabilityReflow.exteriorPaletteReceipt($0, restored: restored) }
                for i in trial.fills.indices {
                    guard let old = oldPalettes[i], let new = newPalettes[i],
                          NSDictionary(dictionary: old).isEqual(to: new) else { throw Failure.paintDrift }
                }
                // Existing forced paint path verifies actual prepared effects,
                // clipping, alpha/peer collisions, block gaps, native retained
                // anchors, body state and actual final composite raster.
                stage = "native-final-paint-domain-page-alpha-peer"
                let painted = try NativeAOTTranslationPageComposer.refineFinalReadability(layer: currentLayer,
                    fills: current.fills, restored: restored, admittedOverride: trial, forceRepaint: true)
                guard let decisions = painted.audit["endpointDecisions"] as? [[String: Any]],
                      decisions.count == ids.count else { throw Failure.paintDrift }
                for i in decisions.indices {
                    guard NativeBalloonReadabilityReflow.paintDecisionMatches(decisions[i], palette: newPalettes[i]!) else {
                        throw Failure.paintDrift
                    }
                }
                // Trial is assembled by copying every original carrier. No new
                // admission receipt or Snapshot is fabricated; full prior state
                // remains bound to the unchanged packets/origins/font/glyph image.
                current = trial; currentLayer = painted
                outcomes.append(["owners": members.sorted(), "status": "selected-fixed-geometry",
                                 "nativeStage": stage, "measurements": measurements])
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                outcomes.append(["owners": members.sorted(), "status": "whole-cohort-incumbent-retained",
                                 "reason": String(reflecting: error), "nativeStage": stage, "measurements": measurements])
            }
        }
        var audit = currentLayer.audit
        audit["terminalRoundedSourcePaint"] = ["cohorts": outcomes,
            "selectionShapeUnchanged": true, "originsUnchanged": true,
            "scope": "post-layout paint only; no reflow/admission search/anchor relaxation"]
        return (.init(image: currentLayer.image, expectedItems: currentLayer.expectedItems,
            paintedItems: currentLayer.paintedItems, complete: currentLayer.complete, audit: audit), current)
    }

    /// Native center receipts for plain and rounded transactions may differ.
    /// Validate each through the ordinary painter; compare all SELECTION metrics
    /// and immutable carrier semantics rather than rewriting either receipt.
    static func verifyCompletedSelection(plain: NativeAOTTranslationPageComposer.TextLayer, plainTuple: Tuple,
        candidate: NativeAOTTranslationPageComposer.TextLayer, candidateTuple: Tuple, restored: CGImage) throws {
        guard plain.complete, candidate.complete, plain.expectedItems == candidate.expectedItems,
              plain.paintedItems == candidate.paintedItems, plainTuple.fills.count == candidateTuple.fills.count,
              plainTuple.audit.count == candidateTuple.audit.count,
              plainTuple.fills.count == plainTuple.audit.count else { throw Failure.paintDrift }
        for i in plainTuple.fills.indices {
            let old = plainTuple.fills[i], new = candidateTuple.fills[i]
            guard old.ownerID == new.ownerID, old.frame == new.frame,
                  old.image.width == new.image.width, old.image.height == new.image.height,
                  old.fontOutputPixels == new.fontOutputPixels,
                  try NativeMandatoryDisplayStroke.rgba(old.image) == NativeMandatoryDisplayStroke.rgba(new.image),
                  try logicalCarrier(old) == logicalCarrier(new),
                  try sameJSON(plainTuple.audit[i][NativeBalloonPlacement.RetainedState.auditKey],
                               candidateTuple.audit[i][NativeBalloonPlacement.RetainedState.auditKey]) else { throw Failure.paintDrift }
        }
        guard let oldRows = plain.audit["rawNativeItems"] as? [[String: Any]],
              let newRows = candidate.audit["rawNativeItems"] as? [[String: Any]],
              oldRows.count == newRows.count, oldRows.count == plainTuple.fills.count else { throw Failure.paintDrift }
        if ProcessInfo.processInfo.environment["AIDOKU_CAPTURE_FINAL_GLYPH_WITNESSES"] == "1" {
            try verifyGlyphWitnesses(plain,candidate)
        }
        // Outer layout selection is already COMPLETE before this transaction.
        // Actual styled bboxes may shrink; glyph frames/rows never change.
        let keys = ["id", "sourceUTF16", "visibleUTF16", "lineRangesUTF16", "actualCoreTextLineStrings",
            "fontSize", "retainedLinePitchOutputPixels", "softWordCuts", "shortSoftTails",
            "oneCharacterRowsProxy", "frameOutputTopLeft", "retainedFillBoundsOutput",
            "appliedTrackingPixels", "discretionaryHyphenUTF16Offsets"]
        for i in oldRows.indices {
            for key in keys { guard try sameJSON(oldRows[i][key], newRows[i][key]) else { throw Failure.paintDrift } }
        }
    }

    /// Render-local bounded typed handoff. Records a completed plain attempt
    /// and its exact pre-physical closure; no JSON can create this capability.
    /// Outer actual/legacy/mixed/word selection ALWAYS sees plain effects.
    final class SelectionScope: @unchecked Sendable {
        private struct Entry {
            let image: CGImage
            let projection: Data
            let pixels: Int
            let apply: (NativeAOTTranslationPageComposer.TextLayer) throws -> NativeAOTTranslationPageComposer.TextLayer
        }
        private struct PaintEntry {
            let image: CGImage
            let tuple: Tuple
            let admission: Data
            let pixels: Int
        }
        private let restored:CGImage?
        private let cohorts:[String:Set<String>]
        private var paints:[ObjectIdentifier:PaintEntry] = [:]
        private var paintOrder:[ObjectIdentifier] = []
        private var paintPixels = 0
        init(restored:CGImage? = nil,cohorts:[String:Set<String>] = [:]) {
            self.restored=restored;self.cohorts=cohorts
        }
        private let lock = NSLock()
        private var entries: [ObjectIdentifier: Entry] = [:]
        private var pixels = 0
        func record(_ plain: NativeAOTTranslationPageComposer.TextLayer, carrierPixels: Int,
                    apply: @escaping (NativeAOTTranslationPageComposer.TextLayer) throws -> NativeAOTTranslationPageComposer.TextLayer) {
            guard let projection = try? selectionProjection(plain), carrierPixels >= 0 else { return }
            let cost = carrierPixels + plain.image.width * plain.image.height
            lock.lock(); defer { lock.unlock() }
            let key = ObjectIdentifier(plain.image)
            let previous = entries[key]?.pixels ?? 0
            guard entries[key] != nil || entries.count < 16,
                  cost <= 64_000_000, pixels - previous <= 64_000_000 - cost else { return }
            pixels = pixels - previous + cost
            entries[key] = Entry(image:plain.image,projection:projection,pixels:cost,apply:apply)
        }
        func observe(image:CGImage,fills:[P],audit:[[String:Any]]) {
            guard fills.count == audit.count, fills.count <= 256,
                  let proof=try? JSONSerialization.data(withJSONObject:audit,options:.sortedKeys) else {return}
            let cost=image.width*image.height+fills.reduce(0){$0+$1.image.width*$1.image.height}
            guard cost <= 64_000_000 else {return}
            let key=ObjectIdentifier(image)
            lock.lock();defer{lock.unlock()}
            if let old=paints.removeValue(forKey:key) {paintPixels-=old.pixels;paintOrder.removeAll{$0==key}}
            while !paintOrder.isEmpty && (paints.count>=16 || paintPixels>64_000_000-cost) {
                let oldest=paintOrder.removeFirst()
                if let old=paints.removeValue(forKey:oldest) {paintPixels-=old.pixels}
            }
            paintPixels+=cost;paintOrder.append(key)
            paints[key]=PaintEntry(image:image,tuple:(fills,audit),admission:proof,pixels:cost)
        }
        func finish(_ winner: NativeAOTTranslationPageComposer.TextLayer) throws -> NativeAOTTranslationPageComposer.TextLayer {
            let key=ObjectIdentifier(winner.image)
            lock.lock();let entry=entries[key],observed=paints[key];lock.unlock()
            try Task.checkCancellation()
            if let entry,entry.image === winner.image,
               let projection=try? selectionProjection(winner),entry.projection==projection {
                return try entry.apply(winner)
            }
            // Generic completed-paint fallback for routes that skip optional
            // physical refinement. Exact image identity AND actual native audit
            // are required; no width/frame reconstruction or Snapshot recapture.
            guard let observed,observed.image === winner.image,let restored,
                  let rows=winner.audit["finalPaintAdmission"] as? [[String:Any]],
                  let proof=try? JSONSerialization.data(withJSONObject:rows,options:.sortedKeys),
                  proof==observed.admission else {
                return annotating(winner,status:"incumbent-retained-no-exact-selected-attempt",
                    details:["prePhysicalRecord":entry != nil,"actualPaintRecord":observed != nil,
                             "actualAdmissionMatches":false])
            }
            return try applyPinned(winner: winner,baseline:observed.tuple,declaredStyleCohorts:cohorts,
                restored:restored,provenance:"actual-final-paint-observer")
        }
    }
    @TaskLocal static var selectionScope: SelectionScope?
    static func afterOuterSelection(enabled:Bool,restored:CGImage? = nil,
        declaredStyleCohorts:[String:Set<String>] = [:],_ build:() throws -> NativeAOTTranslationPageComposer.TextLayer) throws -> NativeAOTTranslationPageComposer.TextLayer {
        guard enabled else { return try build() }
        let scope = SelectionScope(restored:restored,cohorts:declaredStyleCohorts)
        // Preserve an outer required final-paint listener while collecting local
        // rounding counterfactuals. The listener binds only its selected image.
        let outerObserver=NativeAOTTranslationPageComposer.completedPaintObserver
        let observer=NativeAOTTranslationPageComposer.CompletedPaintObserver {image,fills,audit in
            outerObserver?.observe(image,fills,audit)
            scope.observe(image:image,fills:fills,audit:audit)
        }
        let plain = try NativeAOTTranslationPageComposer.$completedPaintObserver.withValue(observer) {
            try $selectionScope.withValue(scope,operation:build)
        }
        return try scope.finish(plain)
    }
    /// Fixed-font recovery deliberately skips optional translations. Register
    /// its ALREADY admitted full tuple at the same outer-winner handoff, with
    /// paint-only substitution and every owner origin pinned. No re-placement.
    static func recordPinnedAttempt(layer:NativeAOTTranslationPageComposer.TextLayer,baseline:Tuple,
        declaredStyleCohorts:[String:Set<String>],restored:CGImage) {
        guard let scope = selectionScope, baseline.fills.contains(where:{$0.sourceStyle?.pendingRoundedContour != nil}) else { return }
        let pixels = baseline.fills.reduce(0) { $0 + $1.image.width * $1.image.height }
        scope.record(layer,carrierPixels:pixels) { winner in
            try applyPinned(winner:winner,baseline:baseline,declaredStyleCohorts:declaredStyleCohorts,
                restored:restored,provenance:"explicit-pinned-attempt")
        }
    }
    private static func applyPinned(winner:NativeAOTTranslationPageComposer.TextLayer,baseline:Tuple,
        declaredStyleCohorts:[String:Set<String>],restored:CGImage,provenance:String) throws -> NativeAOTTranslationPageComposer.TextLayer {
        do {
            let applied=try refine(layer:winner,baseline:baseline,declaredStyleCohorts:declaredStyleCohorts,
                restored:restored,enabled:true)
            try verifyCompletedSelection(plain:winner,plainTuple:baseline,candidate:applied.layer,
                candidateTuple:applied.baseline,restored:restored)
            return annotating(applied.layer,status:applied.baseline.fills.contains(where:{$0.sourceStyle?.roundedContour != nil})
                ? "selected-pinned-recovery-paint-only":"incumbent-retained-no-eligible-cohort",
                details:["handoff":provenance,"cohorts":(applied.layer.audit["terminalRoundedSourcePaint"] as? [String:Any])?["cohorts"] ?? []])
        } catch {
            if error is CancellationError {throw error}
            try Task.checkCancellation()
            return annotating(winner,status:"pinned-recovery-incumbent-retained",
                details:["handoff":provenance,"error":String(reflecting:error)])
        }
    }
    static func styleCohorts(_ rows:[[String:Any]]) -> [String:Set<String>] {
        var result:[String:Set<String>]=[:]
        for row in rows {
            if let id=row["id"] as? String,let group=row["sourceStyleGroupID"] as? String {
                result[group,default:[]].insert(id)
            }
        }
        return result
    }

    private static func selectionProjection(_ layer:NativeAOTTranslationPageComposer.TextLayer) throws -> Data {
        guard let rows = layer.audit["rawNativeItems"] as? [[String:Any]],
              let admission = layer.audit["finalPaintAdmission"] as? [[String:Any]],
              layer.complete, rows.count == layer.expectedItems, admission.count == rows.count else {
            throw Failure.malformedBaseline
        }
        let keys = ["id","sourceUTF16","visibleUTF16","lineRangesUTF16","actualCoreTextLineStrings",
                    "fontSize","retainedLinePitchOutputPixels","frameOutputTopLeft","retainedFillBoundsOutput"]
        let sealedRows = rows.map { row in Dictionary(uniqueKeysWithValues:keys.map { ($0,row[$0] ?? NSNull()) }) }
        return try JSONSerialization.data(withJSONObject:["rows":sealedRows,"admission":admission],options:.sortedKeys)
    }
    static func preservingPlainSelectionHistory(_ candidate:NativeAOTTranslationPageComposer.TextLayer,
        selected:NativeAOTTranslationPageComposer.TextLayer) -> NativeAOTTranslationPageComposer.TextLayer {
        var audit = selected.audit
        audit.merge(candidate.audit) { _, fresh in fresh }
        audit["roundLayoutSelectionUsesPlainEffects"] = true
        return .init(image:candidate.image,expectedItems:candidate.expectedItems,paintedItems:candidate.paintedItems,
            complete:candidate.complete,audit:audit)
    }

    /// Independent actual Prepared.fill receipts, including every antialias byte.
    static func verifyGlyphWitnesses(_ before:NativeAOTTranslationPageComposer.TextLayer,
        _ after:NativeAOTTranslationPageComposer.TextLayer) throws {
        guard let a=before.audit["finalGlyphWitnesses"] as? [String:Any],
              let b=after.audit["finalGlyphWitnesses"] as? [String:Any],
              a["captureComplete"] as? Bool == true,b["captureComplete"] as? Bool == true,
              a["glyphProofComplete"] as? Bool == true,b["glyphProofComplete"] as? Bool == true,
              let old=a["owners"] as? [[String:Any]],let new=b["owners"] as? [[String:Any]],
              old.count==new.count,old.count==before.expectedItems else {throw Failure.glyphWitness("missing-or-incomplete")}
        let keys=["ownerID","width","height","frameOutputPixels","fontOutputPixels","canvasWidth","canvasHeight",
                  "sourceContourOnly","hasFinalEffects","glyphOnly","status","producer",
                  "premultipliedRGBASHA256","pngSHA256"]
        var seen=Set<String>()
        for (a,b) in zip(old,new) {
            guard let id=a["ownerID"] as? String,seen.insert(id).inserted else {throw Failure.glyphWitness("duplicate-owner")}
            for key in keys {guard try sameJSON(a[key],b[key]) else {throw Failure.glyphWitness(id+":"+key)}}
            guard let png=a["pngBase64"] as? String,!png.isEmpty,png==b["pngBase64"] as? String else {
                throw Failure.glyphWitness(id+":PNG-bytes")
            }
        }
    }

    private static func logicalCarrier(_ f: P) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var objects: [String: Any] = ["owner": f.ownerID as Any? ?? NSNull(), "font": Double(f.fontOutputPixels),
            "finalEffects": f.hasFinalEffects, "endpoint": f.displayStrokeEndpoint.map { Int($0) } as Any? ?? NSNull(),
            "ratio": f.displayStrokeRatio.map { Double($0) } as Any? ?? NSNull(), "recheck": f.recheckFinalEndpoint,
            "contrast": f.minimumFillStrokeContrast, "gain": f.minimumCoverageGain,
            "appearance": f.sourceAppearance as Any? ?? NSNull(), "sourceOnly": f.sourceContourOnly,
            "relaxed": f.balloonTargetRelaxed]
        if let style = f.sourceStyle {
            objects["style"] = ["font": style.sourceFontPixels, "bands": style.bands.map { ["rgb": $0.rgb, "width": $0.width] },
                "shadowRGB": style.shadow.map { $0.rgb as Any } ?? NSNull(),
                "shadowOffset": style.shadow.map { $0.offset as Any } ?? NSNull()]
        }
        objects["cluster"] = try encoder.encode(f.sourceClusterAlignment).base64EncodedString()
        objects["body"] = try encoder.encode(f.balloonPlacement).base64EncodedString()
        objects["guide"] = try encoder.encode(f.textPlacementGuide).base64EncodedString()
        objects["policy"] = try encoder.encode(f.textExpansionPolicy).base64EncodedString()
        return try JSONSerialization.data(withJSONObject: objects, options: .sortedKeys)
    }
    private static func sameJSON(_ a: Any?, _ b: Any?) throws -> Bool {
        try JSONSerialization.data(withJSONObject: ["value": a ?? NSNull()], options: .sortedKeys) ==
            JSONSerialization.data(withJSONObject: ["value": b ?? NSNull()], options: .sortedKeys)
    }
    static func annotating(_ layer: NativeAOTTranslationPageComposer.TextLayer, status: String,
                           details: Any? = nil) -> NativeAOTTranslationPageComposer.TextLayer {
        var audit = layer.audit
        audit["terminalRoundedSourcePaintSelection"] = ["status": status, "details": details ?? NSNull(),
            "noLayoutOrPeerOriginChanges": true, "historicalCenterReceiptRewritten": false,
            "layoutSelectionAuthority": "outer-completed-plain-winner-before-paint",
            "effectBBoxEqualityRequired": false]
        if var rows = audit["rawNativeItems"] as? [[String: Any]],
           let paints = audit["sourceStylePaint"] as? [[String: Any]], rows.count == paints.count {
            for i in rows.indices where paints[i]["roundedSourceContourBinding"] is String {
                rows[i]["roundedSourceJoins"] = ["enabled": true, "binding": paints[i]["roundedSourceContourBinding"]!,
                    "scope": "deferred exact native shape; before new source-center receipts",
                    "originalFillRGBAReproduced": true, "completeSourceStyleCohort": true]
            }
            audit["rawNativeItems"] = rows
        }
        return .init(image: layer.image, expectedItems: layer.expectedItems, paintedItems: layer.paintedItems,
                     complete: layer.complete, audit: audit)
    }

    private static func rect(_ r: CGRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height] }
    private static func subset(_ a: NativeFinalTextPaintAdmission.Footprint,
                               of b: NativeFinalTextPaintAdmission.Footprint) -> Bool {
        var cursor = 0
        for run in a.runs {
            while cursor < b.runs.count && (b.runs[cursor].y < run.y ||
                (b.runs[cursor].y == run.y && b.runs[cursor].right <= run.left)) { cursor += 1 }
            guard cursor < b.runs.count, b.runs[cursor].y == run.y,
                  b.runs[cursor].left <= run.left, b.runs[cursor].right >= run.right else { return false }
        }
        return true
    }
}
