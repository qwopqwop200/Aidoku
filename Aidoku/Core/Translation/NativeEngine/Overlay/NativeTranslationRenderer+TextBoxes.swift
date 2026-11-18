import CoreGraphics
import Foundation
import UIKit

extension NativeTranslationRenderer {

    /// A model-conditional domain certificate is not an ordinary clip measurement.
    static func independentTextDomainAuditMetadata() -> (clipAudit: [String: Any], certificate: [String: Any]) {
        (["status": "allocation-unsupported", "unsupportedReason": "independent-text-paint-domain",
          "ordinaryClipMeasured": false, "serializedPDFMeasured": false],
         ["status": "independent-domain-tiled-certificate",
          "authority": "verified balloon interior model; not artwork GT", "serializedPDFMeasured": false])
    }

    /// Source replacement is solid geometry paint, not glyph segmentation or image repair.
    static func prepareSourceTextBoxesPass(layout: NativeTranslationLayout, image: UIImage?, settings: IPhoneOverlaySettings,
                                 scale: CGFloat, renderBounds: CGRect?, composeSource: Bool, outputPixelSize: CGSize?,
                                 collectDiagnostics: Bool, capturePDF: Bool, pdfDeviceScale: CGFloat,
                                 recordStage: ((String) -> Void)?, auditCardObserver: AuditCardObserver?,
                                 birthsAllowed: Set<String>, proposals: inout [String: NativeSourceBootstrapBirth.Proposal],
                                 sourceReuse: NativeBootstrapSourceReuse, secondPass: Bool,
                                 paragraphGuardEnabled: Bool, paragraphPanelSupport: Bool) throws -> PreparedRender {
        try Task.checkCancellation()
        let prepareStarted = ProcessInfo.processInfo.systemUptime
        guard settings.textBoxGeometryParameters.isValid else { throw RenderError.invalidGeometry }
        var phaseMilliseconds: [String: Double] = [:]
        var sourceStyleMilliseconds = 0.0
        let bounds = renderBounds ?? CGRect(origin: .zero, size: layout.viewport)
        guard valid(bounds), valid(layout.viewport), valid(layout.sourceRect), valid(layout.imageSize),
              layout.sourceRect.maxX.isFinite, layout.sourceRect.maxY.isFinite,
              scale.isFinite, scale > 0, layout.items.count <= 4_096 else { throw RenderError.invalidGeometry }
        try validate(viewport: outputPixelSize ?? bounds.size, scale: outputPixelSize == nil ? scale : 1)
        guard layout.version == NativeTranslationLayout.currentVersion else { throw RenderError.incompatibleLayout }
        let declaredScale = CGSize(width: layout.imageSize.width / layout.sourceRect.width,
                                   height: layout.imageSize.height / layout.sourceRect.height)
        guard declaredScale.width.isFinite, declaredScale.height.isFinite,
              declaredScale.width > 0, declaredScale.height > 0 else { throw RenderError.invalidGeometry }
        let source = try sourceReuse.prepare(image:image,visible:settings.visible)
        if let source {
            let sx = CGFloat(source.width) / layout.sourceRect.width
            let sy = CGFloat(source.height) / layout.sourceRect.height
            guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { throw RenderError.invalidGeometry }
        }
        let reader = sourceReuse.reader
        let excluded = layout.items.flatMap { item in
            ([item.sourceBounds] + item.auxiliaryInkRects).compactMap { b -> CGRect? in
                guard b.count == 4, b.allSatisfy(\.isFinite), b[2] > 0, b[3] > 0 else { return nil }
                return CGRect(x: layout.sourceRect.minX + b[0] * layout.sourceRect.width,
                    y: layout.sourceRect.minY + b[1] * layout.sourceRect.height,
                    width: b[2] * layout.sourceRect.width, height: b[3] * layout.sourceRect.height)
            }
        }
        func ownerBox(_ item: NativeTranslationLayoutItem) -> CGRect {
            var box = CGRect.null
            for b in [item.sourceBounds] + item.auxiliaryInkRects where b.count == 4 && b.allSatisfy(\.isFinite) && b[2] > 0 && b[3] > 0 {
                box = box.union(CGRect(x: layout.sourceRect.minX + b[0] * layout.sourceRect.width,
                    y: layout.sourceRect.minY + b[1] * layout.sourceRect.height,
                    width: b[2] * layout.sourceRect.width, height: b[3] * layout.sourceRect.height))
            }
            return (box.isNull ? item.rect : box).intersection(layout.sourceRect)
        }
        // Original normalized source ownership projects into the restoration raster,
        // before viewport affine construction/subtraction. Aux and kept peers remain owned.
        func originalPixelOwner(_ original: NativeTranslationLayoutItem) -> CGRect? {
            guard let source else { return nil }
            var box = CGRect.null
            for b in [original.sourceBounds] + original.auxiliaryInkRects
                where b.count == 4 && b.allSatisfy(\.isFinite) && b[2] > 0 && b[3] > 0 {
                let rect = CGRect(x: b[0] * Double(source.width), y: b[1] * Double(source.height),
                    width: b[2] * Double(source.width), height: b[3] * Double(source.height))
                guard valid(rect) else { return nil }
                box = box.union(rect)
            }
            guard !box.isNull else { return nil }
            let clipped = box.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
            return valid(clipped) ? clipped : nil
        }
        let originalPixelOwners = layout.items.map(originalPixelOwner)
        let items = layout.items.map(usedLayoutItem)
        let owners = items.map(ownerBox)
        let panels = items.enumerated().map { index, item in
            item.keptLettering ? owners[index] : (item.rotation == 0 ? item.rect
                : rotatedBounds(item.rect, about: item.rect, angle: item.rotation))
                .union(owners[index]).insetBy(dx: -2, dy: -2).intersection(layout.sourceRect)
        }
        let earlySurfaceTrial = ProcessInfo.processInfo.environment["AIDOKU_EXPERIMENT_EARLY_SURFACE_SEPARATION"] == "1"
        let earlySurface = earlySurfaceTrial ? try NativeTextBoxEarlySurfaceTrial.refine(panels: panels, owners: owners,
            items: items, reader: reader, sourceSize: CGSize(width: source?.width ?? 0, height: source?.height ?? 0),
            sourceRect: layout.sourceRect) : (panels: panels, observations: [[String: Any]](), pixels: 0)
        let separated = NativeTextBoxContainment.separated(panels: earlySurface.panels, owners: owners, kept: items.map(\.keptLettering))
        let preserveLateBacking = earlySurfaceTrial
            && ProcessInfo.processInfo.environment["AIDOKU_EXPERIMENT_LATE_BACKING_OBLIGATION"] == "1"
        let preserveEarlyBacking = earlySurfaceTrial
            && ProcessInfo.processInfo.environment["AIDOKU_EXPERIMENT_EARLY_BACKING_OBLIGATION"] == "1"
        let incumbentSeparated = preserveEarlyBacking || preserveLateBacking
            ? NativeTextBoxContainment.separated(panels: panels, owners: owners, kept: items.map(\.keptLettering)) : separated
        var incumbentSourceBackings: [String: CGRect] = [:]
        // Supplied verified contours normally bypass measurement. An invalid one
        // may still fall back to measurement, but need not be memoized.
        let repeatedOwners: Set<NativeTextBoxSurfaceMemo.OwnerKey> = source == nil ? []
            : NativeTextBoxSurfaceMemo.repeatedOwners(owners, eligible: items.map {
                !$0.keptLettering && !$0.text.isEmpty
                    && ($0.balloonInterior ?? $0.balloonUnit?.interior)?.contourVerified != true
            })
        // A memo never crosses source images or render invocations, and unique
        // pages keep the uncached source-query path.
        let surfaceMemo = repeatedOwners.isEmpty ? nil : NativeTextBoxSurfaceMemo()
        var cards: [Card] = []
        let tracePanelStages = collectDiagnostics && ProcessInfo.processInfo.environment["AIDOKU_TRACE_PANEL_STAGES"] == "1"
        var panelStageTrace: [String: [[String: Any]]] = [:]
        func recordPanelStage(_ stage: String) {
            guard tracePanelStages else { return }
            for card in cards {
                guard let index = items.firstIndex(where: { $0.id == card.item.id }) else { continue }
                panelStageTrace[card.item.id, default: []].append([
                    "stage": stage, "panel": diagnosticRect(card.sourcePlateRect),
                    "sourceOwner": diagnosticRect(owners[index]), "textFrame": diagnosticRect(card.item.rect),
                    "fontSize": Double(card.style.fontSize),
                    "panelCoversOwner": card.sourcePlateRect.contains(owners[index])])
            }
        }
        var surfaces: [String: NativeTextBoxContainment.Surface] = [:]
        // Observe original ownership, independently of backing color and the
        // translated layout domain. This does not perform erasure segmentation.
        let sourceStyleSampler = sourceReuse.styleImage(secondPass:secondPass).map { NativeSourceColorSamplingStage(image: $0, enabled: true,
            phase: "translation", budget: .init(remainingSamples: items.filter {
                !$0.keptLettering && !$0.text.isEmpty
            }.count), pixelReader: reader) }
        var sourceStyles: [String: NativeSourceColorSamplingStage.VerifiedSourceStyle] = [:]
        var sourcePaintPredictions: [String: [String: Any]] = [:]
        var sourceScaleRecords: [String: [String: Any]] = [:]
        var panelColorPredictions: [String: [Double]] = [:]
        var panelColorEvidence: [String: String] = [:]
        var panelSurfaceColorEvidence: [String: String] = [:]
        var originalInkPixelBudget = Int.max
        var limitations: [String] = []
        var omittedInputs: [[String: Any]] = []
        func recordOmission(_ index: Int, stage: String, box: CGRect? = nil,
                            wanted: CGRect? = nil, surface: NativeTextBoxContainment.Surface? = nil,
                            proposed: CGRect? = nil) {
            guard collectDiagnostics else { return }
            omittedInputs.append([
                "id": items[index].id, "stage": stage,
                "requestedFrame": diagnosticRect(items[index].rect),
                "sourceOwner": diagnosticRect(owners[index]),
                "separatedPanel": diagnosticRect(separated[index]),
                "surfaceBounds": surface.map { diagnosticRect($0.rect) } ?? [],
                "sourceSurfacePolygon": surface.map { diagnosticPolygon($0.polygon) } ?? NSNull(),
                "candidatePanel": box.map(diagnosticRect) ?? [],
                "requestedIntersection": wanted.map(diagnosticRect) ?? [],
                "proposedTextFrame": proposed.map(diagnosticRect) ?? []
            ])
        }
        var initialBGOverrides: [String: [Double]] = [:]
        var memoInitialBG: [NativeTextBoxSurfaceMemo.Key: NativeOwnerExteriorBGPrediction.CachedObservation] = [:]
        let initialBGBudget = NativeOwnerExteriorBGPrediction.Budget()
        let backgroundOwnerCount = items.lazy.filter { !$0.keptLettering && !$0.text.isEmpty && valid($0.rect) }.count
        initialBGBudget.remaining = NativeOwnerExteriorBGPrediction.primaryWorkLimit(eligibleOwnerCount: backgroundOwnerCount)
        // A separately charged retry cannot consume any baseline observation quota.
        let retryBGBudget = NativeOwnerExteriorBGPrediction.Budget()
        var surfacePixelBudget = Int.max
        for index in settings.visible ? Array(items.indices) : [] where !items[index].keptLettering && !items[index].text.isEmpty {
            try Task.checkCancellation()
            var item = items[index]
            guard valid(item.rect), valid(item.contentRect),
                  [item.fontSize, item.lineHeight, item.rotation].allSatisfy(\.isFinite),
                  item.fontSize >= BrowserOverlayLayoutPlanner.minimumRenderedFontSize else {
                recordOmission(index, stage: "invalid-input-geometry")
                continue
            }
            guard item.fontSize <= 2_048, item.lineHeight <= 4_096, item.text.utf16.count <= 32_768,
                  [item.paddingTop, item.paddingLeft, item.paddingBottom, item.paddingRight]
                    .allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw RenderError.invalidGeometry }
            var box = separated[index]
            var balloonRectangleConstrained = false
            guard valid(box) else {
                recordOmission(index, stage: "independent-space", box: box)
                limitations.append("text-box-no-independent-space:\(item.id)"); continue
            }
            var surface = NativeTextBoxContainment.known(item.balloonInterior ?? item.balloonUnit?.interior, frame: layout.sourceRect)
            let beforePrimary=NativeBootstrapSourceReuse.Stamp(initialBGBudget)
            let beforeRetry=NativeBootstrapSourceReuse.Stamp(retryBGBudget)
            let beforeSurfacePixels=surfacePixelBudget
            if secondPass, let entry=try sourceReuse.replay(index:index,id:item.id,owner:owners[index],panel:box,
                frame:layout.sourceRect,primary:initialBGBudget,retry:retryBGBudget,surfacePixels:&surfacePixelBudget) {
                surface=entry.surface
                if let rgb=entry.override { initialBGOverrides[item.id]=rgb }
                else { initialBGOverrides.removeValue(forKey:item.id) }
            } else {
            if surface == nil, let source, let reader, valid(owners[index]) {
                let owner = owners[index]
                let roi = owner.insetBy(dx: -max(owner.width, owner.height) * 1.2,
                                       dy: -max(owner.width, owner.height) * 1.2).intersection(layout.sourceRect)
                if let projection = NativeTextBoxSourceProjection.project(roi, frame: layout.sourceRect,
                    sourceSize: CGSize(width: source.width, height: source.height)) {
                    let width = Int(min(320, max(8, ceil(projection.width))))
                    let height = Int(min(320, max(8, ceil(projection.height))))
                    if width * height <= surfacePixelBudget {
                        // Keep the original logical admission budget on cache hits:
                        // reuse work, not eligibility or the order of measured surfaces.
                        surfacePixelBudget -= width * height
                        let admitted = surfaceMemo != nil && repeatedOwners.contains(.init(owner))
                        let key = admitted ? NativeTextBoxSurfaceMemo.Key(frame: layout.sourceRect, owner: owner,
                            roi: roi, projection: projection, width: width, height: height) : nil
                        let cached = key.flatMap { surfaceMemo?.lookup($0) } ?? (found: false, surface: nil)
                        if cached.found {
                            let workBefore = initialBGBudget.spent
                            surface = cached.surface
                            if let key, let observation = memoInitialBG[key] {
                                if initialBGBudget.replay(observation.charges) {
                                    if let rgb = observation.rgb { initialBGOverrides[item.id] = rgb }
                                    var evidence = observation.evidence
                                    evidence["id"] = item.id
                                    evidence["memoReused"] = true
                                    evidence["cachedObservationWork"] = observation.work
                                    evidence["work"] = initialBGBudget.spent - workBefore
                                    evidence["remainingPageWork"] = initialBGBudget.remaining
                                    initialBGBudget.observations[item.id] = evidence
                                } else {
                                    var evidence = observation.evidence
                                    evidence["id"] = item.id; evidence["accepted"] = false
                                    evidence["rgb"] = NSNull(); evidence["status"] = "memo-quota-abstention"
                                    evidence["memoReused"] = true
                                    evidence["cachedObservationWork"] = observation.work
                                    evidence["work"] = initialBGBudget.spent - workBefore
                                    evidence["remainingPageWork"] = initialBGBudget.remaining
                                    initialBGBudget.observations[item.id] = evidence
                                }
                            } else {
                                initialBGBudget.observations[item.id] = ["id": item.id, "accepted": false,
                                    "status": "memo-observation-unavailable", "remainingPageWork": initialBGBudget.remaining]
                            }
                            // A surface memo is admitted only for repeated projected owners.
                            // Peer exclusion prevents assigning a unique host role to this shared ownership.
                            retryBGBudget.observations[item.id] = [
                                "accepted": false, "status": "shared-owner-not-exclusive", "work": 0]

                        } else {
                            let rgba = try reader.read(x: Double(projection.minX), y: Double(projection.minY),
                                sourceWidth: Double(projection.width), sourceHeight: Double(projection.height), width: width, height: height)
                            surface = try NativeTextBoxContainment.measured(rgba: rgba, width: width, height: height,
                                roi: roi, owner: owner, excluding: owners.filter { $0 != owner })
                            let workBefore = initialBGBudget.spent
                            initialBGBudget.charges.removeAll(keepingCapacity: true)
                            initialBGBudget.recording = true
                            var rgb = try NativeOwnerExteriorBGPrediction.predict(rgba: rgba, width: width,
                                height: height, roi: roi, owner: owner, peers: owners.filter { $0 != owner },
                                budget: initialBGBudget, id: item.id)
                            let primaryRGB = rgb
                            let primaryEvidence = initialBGBudget.observations[item.id]
                            let primaryCharges = initialBGBudget.charges
                            let primaryWork = initialBGBudget.spent - workBefore
                            initialBGBudget.recording = false
                            let retryBefore = retryBGBudget.spent
                            retryBGBudget.charges.removeAll(keepingCapacity: true)
                            retryBGBudget.recording = true
                            let innerMode = NativeSourceColorSampler.rgb((primaryEvidence?["inner"] as? [String: Any])?["mode"])
                            let outerMode = NativeSourceColorSampler.rgb((primaryEvidence?["outer"] as? [String: Any])?["mode"])
                            let oldSurfaceColor = NativeSourceColorSampler.rgb(surface?.color)
                            let needsAlternative: Bool
                            if let innerMode, let outerMode, let oldSurfaceColor {
                                needsAlternative = (0..<3).allSatisfy { abs(innerMode[$0] - outerMode[$0]) <= 12 }
                                    && (0..<3).contains { abs(innerMode[$0] - oldSurfaceColor[$0]) > 12 }
                            } else { needsAlternative = false }
                            if !repeatedOwners.contains(.init(owner)), needsAlternative, rgb == nil, !initialBGBudget.exhausted, !retryBGBudget.exhausted,
                               let originalOwner = originalPixelOwners[index] {
                                let peerIndices = originalPixelOwners.indices.filter { $0 != index && valid(owners[$0]) }
                                let originalPeers = peerIndices.compactMap { originalPixelOwners[$0] }
                                if originalPeers.count == peerIndices.count {
                                    let originalEvidence = initialBGBudget.observations[item.id]
                                    let bridge: [String: Any]
                                    do {
                                        bridge = try NativeOwnerHostBackgroundPrediction.predict(rgba: rgba, width: width, height: height,
                                            sourceROI: projection, owner: originalOwner, peers: originalPeers, budget: retryBGBudget)
                                    } catch NativeOwnerHostBackgroundPrediction.Quota.exhausted {
                                        bridge = ["accepted": false, "status": "quota", "selected": NSNull()]
                                    }
                                    if bridge["accepted"] as? Bool == true, let color = bridge["selected"] as? [Int] {
                                        rgb = color.map(Double.init)
                                        retryBGBudget.observations[item.id] = ["id": item.id, "accepted": true,
                                            "rgb": rgb!, "method": "initial-source-host-bridge",
                                            "baselineObservation": originalEvidence as Any? ?? NSNull(),
                                            "bridge": bridge, "authority": "source spatial model; not RGBGT"]
                                    } else {
                                        retryBGBudget.observations[item.id] = bridge
                                    }
                                }
                            }
                            retryBGBudget.recording = false
                            initialBGBudget.observations[item.id]?["work"] = primaryWork
                            retryBGBudget.observations[item.id]?["work"] = retryBGBudget.spent - retryBefore
                            retryBGBudget.observations[item.id]?["remainingRetryWork"] = retryBGBudget.remaining
                            if let rgb { initialBGOverrides[item.id] = rgb }
                            if let key {
                                // A newly captured query replaces an evicted prior observation, even when nil.
                                memoInitialBG.removeValue(forKey: key)
                                memoInitialBG[key] = .init(rgb: primaryRGB, work: primaryWork, charges: primaryCharges,
                                    evidence: initialBGBudget.observations[item.id] ?? ["accepted": false, "status": "unmeasured"])
                            }
                            if let key {
                                retryBGBudget.observations[item.id] = [
                                    "accepted": false, "status": "shared-owner-not-exclusive", "work": 0]
                                surfaceMemo?.insert(surface, for: key)
                            }
                        }
                    }
                }
            }
            // Small text owners can truncate a connected/necked balloon in the
            // first ROI. One bounded wider observation can recover its closed face.
            if surface == nil, let source, let reader, valid(owners[index]) {
                let owner = owners[index]
                let extent = max(owner.width, owner.height) * 2.4
                let roi = owner.insetBy(dx: -extent, dy: -extent).intersection(layout.sourceRect)
                if let projection = NativeTextBoxSourceProjection.project(roi, frame: layout.sourceRect,
                    sourceSize: CGSize(width: source.width, height: source.height)) {
                    let width = Int(min(320, max(8, ceil(projection.width))))
                    let height = Int(min(320, max(8, ceil(projection.height))))
                    if width * height <= surfacePixelBudget {
                        surfacePixelBudget -= width * height
                        let rgba = try reader.read(x: Double(projection.minX), y: Double(projection.minY),
                            sourceWidth: Double(projection.width), sourceHeight: Double(projection.height), width: width, height: height)
                        surface = try NativeTextBoxContainment.measured(rgba: rgba, width: width, height: height,
                            roi: roi, owner: owner, excluding: owners.filter { $0 != owner })
                    }
                }
            }
            // A supplied contour used to skip source color sampling altogether.
            // Predict from the same interior face for supplied and measured geometry.
            if let face = surface, let source, let reader,
               let projection = NativeTextBoxSourceProjection.project(face.rect, frame: layout.sourceRect,
                    sourceSize: CGSize(width: source.width, height: source.height)) {
                let width = Int(min(320, max(8, ceil(projection.width))))
                let height = Int(min(320, max(8, ceil(projection.height))))
                if width * height <= surfacePixelBudget {
                    surfacePixelBudget -= width * height
                    let rgba = try reader.read(x: Double(projection.minX), y: Double(projection.minY),
                        sourceWidth: Double(projection.width), sourceHeight: Double(projection.height), width: width, height: height)
                    if let rgb = try NativeTextBoxContainment.faceColor(rgba: rgba, width: width, height: height,
                        roi: face.rect, surface: face, owner: owners[index], excluding: owners.filter { $0 != owners[index] }),
                       face.color.map({ prior in zip(prior, rgb).allSatisfy { abs($0 - $1) <= 32 } }) ?? true {
                        // Measured row envelopes can include artwork islands.
                        // A face sample contradicting independently supported paper
                        // is ambiguous, not permission to overwrite its role.
                        surface = .init(rect: face.rect, spans: face.spans, color: rgb,
                            colorEvidence: "source-face-median-or-gradient-trimmed-mean-excluding-lettering",
                            geometryObserved: face.geometryObserved)
                        initialBGOverrides.removeValue(forKey: item.id)
                    }
                }
            }

                if !secondPass {
                    sourceReuse.record(index:index,id:item.id,owner:owners[index],panel:box,frame:layout.sourceRect,
                        beforePrimary:beforePrimary,beforeRetry:beforeRetry,beforeSurfacePixels:beforeSurfacePixels,
                        primary:initialBGBudget,retry:retryBGBudget,surfacePixels:surfacePixelBudget,
                        surface:surface,override:initialBGOverrides[item.id])
                }
            }
            let preSurfaceIntersectionPanel = box
            let surfaceIntersectionBounds = surface?.rect
            if let surface {
                // Trial only: retaining source ownership must also pass final
                // balloon/peer/pixel checks before becoming the default policy.
                if ProcessInfo.processInfo.environment["AIDOKU_EXPERIMENT_PRESERVE_SOURCE_INTERSECTION"] == "1" {
                    box = NativeTextBoxContainment.sourcePreservingIntersection(panel: box,
                        surfaceBounds: surface.rect, owner: owners[index])
                } else {
                    box = box.intersection(surface.rect)
                }
                // Fit into a complete inscribed rectangle, not the balloon bounding box.
                if let contained = surface.rectangularPanel(covering: owners[index], near: box, within: box) {
                    balloonRectangleConstrained = contained.width < box.width * 0.92
                        || contained.height < box.height * 0.92
                    box = contained
                }
                if preserveEarlyBacking || preserveLateBacking {
                    let incumbentDomain = incumbentSeparated[index].intersection(surface.rect)
                    if let incumbent = surface.rectangularPanel(covering: owners[index],
                        near: incumbentDomain, within: incumbentDomain) {
                        // Retain only an obligation lost by the changed initial
                        // admission. Unchanged paragraphs must not regain all
                        // historical search padding after normal tight trimming.
                        if !box.contains(incumbent) {
                            incumbentSourceBackings[item.id] = incumbent
                        }
                        if preserveEarlyBacking && !preserveLateBacking,
                           let proposal = NativeTextBoxEarlySurfaceTrial.backingUnion(candidate: box,
                        incumbent: incumbent, owner: owners[index],
                        peers: separated.indices.filter { $0 != index }.map { separated[$0] },
                        contains: { surface.contains($0) }) {
                            box = proposal
                        }
                    }
                }
            }
            guard valid(box) else {
                recordOmission(index, stage: "surface-intersection", box: box, surface: surface)
                limitations.append("text-box-invalid-surface:\(item.id)"); continue
            }
            // Build the incumbent first. Recover a clipped requested capacity
            // later, after actual peer glyphs exist for joint admission.
            let requestedTextFrame = item.rect
            let requestedIntersection = requestedTextFrame.intersection(box)
            let wanted = requestedIntersection
            let peerRects = items.indices.filter { $0 != index }.map { owners[$0].union(items[$0].rect) }
            // A later centered() call uses its incoming frame as its baseline;
            // it cannot undo peer intrusion introduced by the initial lobe search.
            var textFrame = surface?.inscribed(near: wanted, within: box, protectedRects: peerRects,
                fullClearance: false) ?? wanted
            if !valid(textFrame), item.sourceBounds.count == 4, item.sourceBounds.allSatisfy(\.isFinite),
               item.sourceBounds[2]>0, item.sourceBounds[3]>0,
               let proposal = NativeSourceBootstrapBirth.propose(owner: owners[index], panel: box,
                    incumbent: preSurfaceIntersectionPanel, sourceRect: layout.sourceRect, surface: surface,
                    peers: peerRects, fixedOtherOwners: items.indices.filter { $0 != index }.map { owners[$0] }, hasText: !item.text.isEmpty) {
                proposals[item.id] = proposal
                if birthsAllowed.contains(item.id) { textFrame = proposal.frame; box = proposal.panel }
            }
            guard valid(textFrame) else {
                recordOmission(index, stage: "text-space", box: box, wanted: wanted,
                    surface: surface, proposed: textFrame)
                limitations.append("text-box-no-text-space:\(item.id)"); continue
            }
            item.x = textFrame.minX; item.y = textFrame.minY
            item.width = textFrame.width; item.height = textFrame.height
            item.paddingLeft = min(item.paddingLeft, textFrame.width * 0.12)
            item.paddingRight = min(item.paddingRight, textFrame.width * 0.12)
            item.paddingTop = min(item.paddingTop, textFrame.height * 0.12)
            item.paddingBottom = min(item.paddingBottom, textFrame.height * 0.12)
            let sampled = try initialBGOverrides[item.id] ?? surface?.color ?? textBoxSurroundingColor(item: item, layout: layout, source: source,
                reader: reader, excluded: excluded)
            let channels = sampled ?? [255.0, 255.0, 255.0]
            if let sampled { panelColorPredictions[item.id] = sampled }
            if birthsAllowed.contains(item.id) { proposals[item.id]?.sourcePanelColorObserved = sampled != nil }
            panelColorEvidence[item.id] = sampled == nil ? "source-color-unavailable"
                : initialBGOverrides[item.id] != nil ? "owner-disjoint-exterior-heldout-model"
                : surface?.color != nil ? surface!.colorEvidence : "original-owner-ring-mode-median"
            panelSurfaceColorEvidence[item.id] = surface?.colorEvidence ?? "surface-unavailable"
            if sampled == nil { limitations.append("text-box-background-unavailable:\(item.id)") }
            let background = color(channels.map { CGFloat($0) })
            let light = NativeSourceColorSampler.luminance(channels) > 0.179
            // Missing source is explicit; never choose black/white from panel luminance.
            let foreground = color([0, 0, 0])
            var style = NativeTranslationTypography.Style(fontScript: item.fontScript,
                prefersDominantKoreanScript: !item.sourceTextOnly && item.wrappingScript == "korean",
                fontSize: item.fontSize, vertical: item.vertical, foreground: foreground,
                outlinePaintOrder: .strokeThenFill, tracking: -item.fontSize * 0.012,
                lineHeight: max(item.fontSize, item.lineHeight), alignsToTop: item.balancedColumn)
            if let bold = item.sourceRenderBold {
                style.bold = bold
                // A fixed named face can override bold=false; use the regular script family.
                if !bold { style.fontName = nil }
            }
            style.outline = nil
            style.outlineWidth = 0
            if let sourceStyleSampler, valid(owners[index]) {
                func sourceRect(_ rect: CGRect) -> [Double] {
                    [Double((rect.minX - layout.sourceRect.minX) / layout.sourceRect.width),
                     Double((rect.minY - layout.sourceRect.minY) / layout.sourceRect.height),
                     Double(rect.width / layout.sourceRect.width), Double(rect.height / layout.sourceRect.height)]
                }
                func polygon(_ rect: CGRect) -> [[Double]] {
                    let r = sourceRect(rect)
                    return [[r[0], r[1]], [r[0] + r[2], r[1]],
                            [r[0] + r[2], r[1] + r[3]], [r[0], r[1] + r[3]]]
                }
                let geometry: [String: Any] = ["polygon": polygon(owners[index]),
                    "sourceVertical": item.sourceVertical, "letteringScaleTransportVersion": 1,
                    "excluded": owners.indices.filter { $0 != index && valid(owners[$0]) }.map { polygon(owners[$0]) }]
                let sampleStarted = ProcessInfo.processInfo.systemUptime
                let prediction = sourceStyleSampler.sampleOriginalStyle(bounds: sourceRect(owners[index]), geometry: geometry)
                let observedStyle = NativeSourceColorSamplingStage.verifiedStyle(prediction)
                let scaleRecord = prediction?["sourceLetteringScale"] as? [String: Any]
                    ?? ["supported": false, "unknownReason": "source-sample-or-scale-unavailable"]
                let originalScaleRecord = NativeSourceLetteringScale.restorationTransport(record: scaleRecord,
                    sourceVertical: item.sourceVertical,
                    capturedWidth: Double(source?.width ?? 0), capturedHeight: Double(source?.height ?? 0),
                    originalWidth: Double(layout.imageSize.width), originalHeight: Double(layout.imageSize.height))
                sourceScaleRecords[item.id] = NativeSourceLetteringScale.logicalTransport(record: originalScaleRecord,
                    sourceVertical: item.sourceVertical,
                    originalCrossLength: Double(item.sourceVertical ? layout.imageSize.width : layout.imageSize.height),
                    logicalCrossLength: Double(item.sourceVertical ? layout.sourceRect.width : layout.sourceRect.height))
                sourceStyleMilliseconds += (ProcessInfo.processInfo.systemUptime - sampleStarted) * 1000
                let sourceInk = prediction?["sourceInk"] as? [String: Any]
                var predictedFill = NativeSourceColorSampler.rgb(prediction?["foreground"])
                    ?? NativeSourceColorSampler.rgb(sourceInk?["foreground"])
                var fillAuthority = "original source-role model"
                if predictedFill == nil, let source, let reader {
                    predictedFill = try NativeOriginalInkPrediction.foreground(owner: owners[index],
                        frame: layout.sourceRect, source: source, reader: reader, sourceBackground: channels,
                        remainingPixels: &originalInkPixelBudget)
                    fillAuthority = "original owner pixel mode excluding source surface; fill/stroke ambiguity uncalibrated"
                }
                let predictedStroke = NativeSourceColorSampler.rgb(prediction?["stroke"])
                if let predictedFill { style.foreground = color(predictedFill.map { CGFloat($0) }) }
                else { limitations.append("source-font-color-unavailable:\(item.id)") }
                if let predictedStroke {
                    style.outline = color(predictedStroke.map { CGFloat($0) })
                    style.outlineWidth = textBoxReadableOutlineWidth(fontSize: item.fontSize)
                }
                sourcePaintPredictions[item.id] = [
                    "foreground": predictedFill as Any? ?? NSNull(),
                    "stroke": predictedStroke as Any? ?? NSNull(),
                    "confidence": NativeOriginalColorFidelity.sourceRoleConfidenceAudit(prediction) as Any? ?? NSNull(),
                    "nativeTopologyRoleEvidence": prediction?["nativeTopologyRoleEvidence"] as Any? ?? NSNull(),
                    "strokeForecastEvidence": prediction?["sourceStrokeForecastEvidence"] as Any? ?? NSNull(),
                    "sourceSamplingPolicy": prediction?["sourceSamplingPolicy"] as Any? ?? NSNull(),
                    "sourceSamplingSelection": prediction?["sourceSamplingSelection"] as Any? ?? NSNull(),
                    "sourceInkDominance": prediction?["sourceInkDominance"] as Any? ?? NSNull(),
                    "sourceResolutionObservations": prediction?["sourceResolutionObservations"] as Any? ?? NSNull(),
                    "authority": "original pixel model prediction; not ground truth",
                    "readabilityColorOverride": false,
                    "foregroundAuthority": fillAuthority,
                    "sourceBandWidthAudit": NativeOriginalColorFidelity.sourceBandAudit(
                        finalRole: prediction?["widthEvidence"], preRole: sourceInk?["widthEvidence"]),
                    "sourceFullPenWidthPixels": NSNull(),
                    "displayOutlineWidth": Double(style.outlineWidth),
                    "displayOutlineWidthAuthority": "user-requested readability thickness; not source pen prediction"]
                if let observed = observedStyle {
                    style.foreground = color(observed.foreground.map { CGFloat($0) })
                    style.outline = color(observed.stroke.map { CGFloat($0) })
                    sourceStyles[item.id] = observed
                    // Keep source pen truth unknown; display thickness is an
                    // explicit readability decision, not a sampled-band conversion.
                }
            }
            if sourcePaintPredictions[item.id] == nil {
                limitations.append("source-font-color-unavailable:\(item.id)")
            }
            // Explicit readability policy: change fill only, before any native artifact
            // certification. Keep source forecasts, panel and stroke unchanged.
            let readabilityPixels = outputPixelSize.map { pixelSize(viewport: $0, scale: 1) }
                ?? pixelSize(viewport: bounds.size, scale: scale)
            let minimumPaintScale = min(readabilityPixels.width / bounds.width, readabilityPixels.height / bounds.height)
                * (style.vertical ? 1 : min(1, item.typesettingWidthScale ?? 1))
            let visibleOutlinePixels = Double(style.outlineWidth * minimumPaintScale / 2)
            let outlineRGB = rgb(style.outline)
            let opaqueStrokeThenFill = style.outline?.alpha == 1 && style.outlinePaintOrder == .strokeThenFill
            if let fill = rgb(style.foreground),
               let readable = textBoxReadableForeground(fill, panel: channels, outline: outlineRGB,
                    visibleOutlinePixels: visibleOutlinePixels, opaqueStrokeThenFill: opaqueStrokeThenFill) {
                let changed = readable != fill
                if changed { style.foreground = color(readable.map { CGFloat($0) }) }
                var prediction = sourcePaintPredictions[item.id] ?? [:]
                prediction["readabilityColorOverride"] = changed
                prediction["displayForeground"] = readable
                prediction["readabilityPolicy"] = "outline-aware: direct4.5 or both boundaries3 and outward1px; otherwise fill-only4.5"
                prediction["readabilityOutlineSupported"] = textBoxOutlineSupportsForeground(fill, panel: channels,
                    outline: outlineRGB, visibleOutlinePixels: visibleOutlinePixels, opaqueStrokeThenFill: opaqueStrokeThenFill)
                prediction["readabilityVisibleOutlinePixels"] = visibleOutlinePixels
                prediction["readabilityOutlineWidthAuthority"] = "output paint geometry; original source pen width unknown"
                prediction["readabilityFillStrokeContrast"] = outlineRGB.map { textBoxFillContrast(fill, panel: $0) } as Any? ?? NSNull()
                prediction["readabilityStrokePanelContrast"] = outlineRGB.map { textBoxFillContrast($0, panel: channels) } as Any? ?? NSNull()
                prediction["readabilityContrastBefore"] = textBoxFillContrast(fill, panel: channels)
                prediction["readabilityContrastAfter"] = textBoxFillContrast(readable, panel: channels)
                sourcePaintPredictions[item.id] = prediction
            }
            style.horizontalScale = item.typesettingWidthScale ?? 1
            // A containment reduction should shrink words before splitting them
            // into awkward fragments. Emergency wrapping remains the fallback.
            style.horizontalWrapping = item.wrappingScript == "korean"
                ? (balloonRectangleConstrained ? .keepAll : .keepAllWithEmergency) : .normal
            var typography = fitted(text: item.typesettingText ?? item.text, size: item.contentRect.size,
                                    style: &style)
            if balloonRectangleConstrained, item.wrappingScript == "korean",
               !typography.fits || style.fontSize < item.fontSize * 0.8 {
                style.horizontalWrapping = .keepAllWithEmergency
                style.fontSize = item.fontSize; style.lineHeight = item.lineHeight
                typography = fitted(text: item.typesettingText ?? item.text, size: item.contentRect.size, style: &style)
            }
            if !typography.fits { limitations.append("text-overflow:\(item.id)") }
            var card = Card(item: item, typography: typography, style: style,
                sourceBackgroundKind: "solid-text-box", sourceStrokeKind: "source-color-prediction",
                sourcePlateOwnerRect: box, straightenedPanelRect: box,
                cleanupSourceFrame: layout.sourceRect, drawsPanel: true, background: background,
                usesFallbackVeil: false, lightSurface: light, heavyStrokeWidth: 0, finalFontSize: style.fontSize)
            if collectDiagnostics {
                card.harmonyRecord["initialRequestedTextFrame"] = diagnosticRect(requestedTextFrame)
                card.harmonyRecord["initialRequestedPanelIntersection"] = diagnosticRect(requestedIntersection)
                card.harmonyRecord["sourceSurfaceIntersection"] = [
                    "before": diagnosticRect(preSurfaceIntersectionPanel),
                    "after": diagnosticRect(box),
                    "owner": diagnosticRect(owners[index]),
                    "surfaceBounds": surfaceIntersectionBounds.map(diagnosticRect) as Any? ?? NSNull(),
                    "beforeCoversOwner": preSurfaceIntersectionPanel.contains(owners[index]),
                    "afterCoversOwner": box.contains(owners[index]),
                    "trialEnabled": ProcessInfo.processInfo.environment["AIDOKU_EXPERIMENT_PRESERVE_SOURCE_INTERSECTION"] == "1"]
            }
            if uprightTranslatedSourceColumn(item) { card.textRotation = 0 }
            let scaleRecord = sourceScaleRecords[item.id]
                ?? ["supported": false, "unknownReason": "original-source-observation-unavailable"]
            let selection = NativeSourceLetteringScale.selectProxy(record: scaleRecord,
                forecast: item.sourceFontSize.map(Double.init), requested: Double(item.fontSize))
            card.harmonyRecord["observedSourceLetteringScale"] = scaleRecord
            card.harmonyRecord["sourceHierarchyProxyUsed"] = selection.value as Any? ?? NSNull()
            card.harmonyRecord["sourceHierarchyProxyProvenance"] = selection.provenance
            card.harmonyRecord["sourceHierarchyFallbackReason"] = selection.fallbackReason as Any? ?? NSNull()
            card.harmonyRecord["savedSourceFontSizeForecast"] = item.sourceFontSize as Any? ?? NSNull()
            card.textBoxClip = surface?.polygon ?? []
            if let surface { surfaces[item.id] = surface }
            cards.append(card)
        }
        var captionInkSamples = 32_000_000
        // Rebuild membership after observations, including owned ink tops. Do
        // not move erasure/placement owners or mutate immutable source forecasts.
        var knownSourceProxies: [String: CGFloat] = [:]
        var observedTopOwners = owners
        for index in items.indices {
            guard let record = sourceScaleRecords[items[index].id], record["supported"] as? Bool == true,
                  let proxy = record["logicalCrossSpan"] as? Double, proxy.isFinite, proxy > 0 else { continue }
            knownSourceProxies[items[index].id] = CGFloat(proxy)
            if items[index].sourceVertical, let originalTop = record["originalAlongInkStart"] as? Double,
               originalTop.isFinite, layout.imageSize.height > 0 {
                let top = max(owners[index].minY, layout.sourceRect.minY + CGFloat(originalTop)
                    * layout.sourceRect.height / layout.imageSize.height)
                if top < owners[index].maxY {
                    observedTopOwners[index] = CGRect(x: owners[index].minX, y: top,
                        width: owners[index].width, height: owners[index].maxY - top)
                    if let cardIndex = cards.firstIndex(where: { $0.item.id == items[index].id }) {
                        cards[cardIndex].harmonyRecord["sourceTopObservedInkAnchor"] = Double(top)
                        cards[cardIndex].harmonyRecord["sourceTopAnchorAuthority"] = "owned observed ink start; not exact first baseline"
                    }
                }
            }
        }
        let sourceTopGroups = source == nil ? [] : sourceCaptionTopGroups(items: items,
            owners: observedTopOwners, knownProxies: knownSourceProxies)
        for group in sourceTopGroups {
            let ids = group.map { items[$0].id }
            for index in cards.indices where ids.contains(cards[index].item.id) {
                cards[index].harmonyRecord["sourceTopGroupAfterObservations"] = ids
            }
        }
        var uniformCaptionFontIDs: Set<String> = []
        let captionOutputPixels = outputPixelSize.map { pixelSize(viewport: $0, scale: 1) }
            ?? pixelSize(viewport: bounds.size, scale: scale)
        for group in sourceTopGroups {
            let indices = group.compactMap { sourceIndex in
                cards.firstIndex { $0.item.id == items[sourceIndex].id }
            }
            guard indices.count >= 2 else { continue }
            let fonts = indices.map { cards[$0].style.fontSize }.sorted()
            guard let smallest = fonts.first, let largest = fonts.last,
                  smallest > 0, largest / smallest <= 1.12 else { continue }
            let sharedFont = fonts[fonts.count / 2]
            let ratios = indices.map { cards[$0].style.lineHeight / cards[$0].style.fontSize }.sorted()
            let sharedPitch = sharedFont * ratios[ratios.count / 2]
            var proposed = cards
            var complete = true
            for index in indices {
                proposed[index].style.fontSize = sharedFont
                proposed[index].style.lineHeight = sharedPitch
                proposed[index].item.fontSize = sharedFont
                proposed[index].item.lineHeight = sharedPitch
                proposed[index].finalFontSize = sharedFont
                let text = proposed[index].item.typesettingText ?? proposed[index].item.text
                proposed[index].typography = NativeTranslationTypography.layout(text: text,
                    in: proposed[index].item.contentRect.size, style: proposed[index].style)
                if !proposed[index].typography.fits
                    || !NativeTranslationTypography.committedParagraphRawComplete(proposed[index].typography, original: text) {
                    complete = false
                    break
                }
            }
            guard complete else { continue }
            guard try stagedCaptionInkPreserved(cards: proposed, indices: indices, bounds: bounds,
                pixels: captionOutputPixels, sourceRect: layout.sourceRect, pdfDeviceScale: pdfDeviceScale,
                remainingSamples: &captionInkSamples) else { continue }
            let baseline = cards
            let changed = Set(indices.map { proposed[$0].item.id })
            let rejected = try rejectNewReadabilityPeerInk(cards: &proposed, baseline: baseline,
                changed: changed, bounds: bounds, pixels: captionOutputPixels, sourceRect: layout.sourceRect,
                pdfDeviceScale: pdfDeviceScale, recordRejection: nil)
            guard rejected.isEmpty else { continue }
            cards = proposed
            uniformCaptionFontIDs.formUnion(indices.map { cards[$0].item.id })
        }
        // Every peer's final fitted frame is available before a placement is committed.
        // Original-pixel queries are complete. Drop only the reader's copied RGBA cache;
        // source image ownership remains unchanged for layout/capture and restoration.
        reader?.release()
        phaseMilliseconds["initialCardsIncludingSourceStyle"] = (ProcessInfo.processInfo.systemUptime - prepareStarted) * 1000
        phaseMilliseconds["sourceStyleObserverSubset"] = sourceStyleMilliseconds
        recordPanelStage("initial-cards")
        let placementStarted = ProcessInfo.processInfo.systemUptime
        let sourcePixelSize = CGSize(width: layout.sourceRect.width / layout.imageSize.width,
                                     height: layout.sourceRect.height / layout.imageSize.height)
        let ownerByID = Dictionary(uniqueKeysWithValues: items.indices.map { (items[$0].id, owners[$0]) })
        for index in cards.indices where cards[index].item.rotation == 0 && cards[index].typography.fits {
            guard let owner = ownerByID[cards[index].item.id] else { continue }
            let peerOwners = items.filter { $0.id != cards[index].item.id }.compactMap { ownerByID[$0.id] }
            let peerFrames = cards.indices.filter { $0 != index }.map { cards[$0].item.rect }
            if let surface = surfaces[cards[index].item.id] {
                let frame = surface.centered(frame: cards[index].item.rect, owner: owner,
                    within: cards[index].sourcePlateRect, otherOwners: peerOwners, otherTextFrames: peerFrames, pixelSize: sourcePixelSize)
                cards[index].item.x = frame.minX; cards[index].item.y = frame.minY
            } else if cards[index].textBoxClip.isEmpty {
                let peerPanels = cards.indices.filter { $0 != index }.map { cards[$0].sourcePlateRect }
                let delta = NativeTextBoxContainment.sourceAnchored(frame: cards[index].item.rect,
                    panel: cards[index].sourcePlateRect, owner: owner, sourceFrame: layout.sourceRect,
                    otherOwners: peerOwners, otherTextFrames: peerFrames, otherPanels: peerPanels, imageSize: layout.imageSize)
                cards[index].item.x += delta.x; cards[index].item.y += delta.y
                cards[index].sourcePlateOwnerRect = cards[index].sourcePlateRect.offsetBy(dx: delta.x, dy: delta.y)
                cards[index].straightenedPanelRect = cards[index].sourcePlateRect
            }
        }
        // Panel/stroke predictions and the chosen readable fill stay fixed during placement.
        phaseMilliseconds["sourcePlacement"] = (ProcessInfo.processInfo.systemUptime - placementStarted) * 1000
        recordPanelStage("source-placement")
        // No post-prediction background correction; fill-only policy runs before shaping.
        phaseMilliseconds["backgroundRefinement"] = 0
        let gutterStarted = ProcessInfo.processInfo.systemUptime
        // translated glyphs and export paint bounds retain their original scope.
        func normalized(_ rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX - layout.sourceRect.minX) / layout.sourceRect.width,
                y: (rect.minY - layout.sourceRect.minY) / layout.sourceRect.height,
                width: rect.width / layout.sourceRect.width, height: rect.height / layout.sourceRect.height)
        }
        let gutterPanels = cards.compactMap { card -> NativeIndependentPanelGutter.Panel? in
            guard card.drawsPanel, let owner = ownerByID[card.item.id] else { return nil }
            let box = normalized(card.straightenedPanelRect ?? card.sourcePlateRect)
            let polygon = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                           CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            guard polygon.count >= 3 else { return nil }
            return .init(id: card.item.id, pieces: [polygon], owner: normalized(owner),
                textFrame: normalized(card.item.rect), kept: card.item.keptLettering, rotation: card.item.rotation)
        }
        let gutters = NativeIndependentPanelGutter.propose(panels: gutterPanels,
            sourceSize: layout.sourceRect.size, imageSize: layout.imageSize)
        for index in cards.indices {
            guard let clip = gutters[cards[index].item.id] else { continue }
            let rectangle = CGRect(
                x: layout.sourceRect.minX + clip.minX * layout.sourceRect.width,
                y: layout.sourceRect.minY + clip.minY * layout.sourceRect.height,
                width: clip.width * layout.sourceRect.width, height: clip.height * layout.sourceRect.height)
            // Change the actual rectangle; never shave its paint using a separate mask.
            guard let owner = ownerByID[cards[index].item.id], rectangle.contains(owner),
                  rectangle.contains(cards[index].item.rect) else { continue }
            cards[index].sourcePlateOwnerRect = rectangle
            cards[index].straightenedPanelRect = rectangle
            cards[index].textBoxBackgroundClip = nil
        }
        let readabilityBaseline = cards
        phaseMilliseconds["panelGutters"] = (ProcessInfo.processInfo.systemUptime - gutterStarted) * 1000
        recordPanelStage("panel-gutters")
        let readabilityStarted = ProcessInfo.processInfo.systemUptime
        let outputPixels = outputPixelSize.map { pixelSize(viewport: $0, scale: 1) }
            ?? pixelSize(viewport: bounds.size, scale: scale)
        var readableFontIDs = try improveSmallTextBoxes(cards: &cards, owners: ownerByID,
            sourceRect: layout.sourceRect, imageSize: layout.imageSize, pdfDeviceScale: pdfDeviceScale)
        var capacityRecoveredIDs: Set<String> = []
        var waistPreviousFonts = try improveWaistTextBoxes(cards: &cards, surfaces: surfaces,
            requested: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }), owners: ownerByID,
            sourceRect: layout.sourceRect, imageSize: layout.imageSize, pdfDeviceScale: pdfDeviceScale,
            recordFitRecovery: { capacityRecoveredIDs.insert($0) })
        let readabilityChanged = readableFontIDs.union(waistPreviousFonts.keys).union(capacityRecoveredIDs)
        var readabilityRejectionReasons: [String: String] = [:]
        let recordReadabilityRejection: ((String, String) -> Void)? = collectDiagnostics ? { id, reason in
            readabilityRejectionReasons[id] = reason
        } : nil
        var readabilityRejected = try rejectNewReadabilityPeerInk(cards: &cards, baseline: readabilityBaseline,
            changed: readabilityChanged, bounds: bounds, pixels: outputPixels,
            sourceRect: layout.sourceRect, pdfDeviceScale: pdfDeviceScale,
            recordRejection: recordReadabilityRejection)
        // A rejection restores the pre-small/pre-waist card, so clear all readability gains.
        // Keep readabilityChanged immutable for the gate's joint rollback proof.
        readableFontIDs.subtract(readabilityRejected)
        capacityRecoveredIDs.subtract(readabilityRejected)
        for id in readabilityRejected { waistPreviousFonts.removeValue(forKey: id) }
        // Freeze approved ordinary results before aggressive fixed-frame recovery.
        // A rejected recovery restores this snapshot, never the original small font.
        let requestedFontBaseline = cards
        var requestedFontIDs = try improveSmallTextBoxes(cards: &cards, owners: ownerByID,
            sourceRect: layout.sourceRect, imageSize: layout.imageSize, pdfDeviceScale: pdfDeviceScale,
            recoverRequestedFont: true)
        let requestedFontRejected = try rejectNewReadabilityPeerInk(cards: &cards,
            baseline: requestedFontBaseline, changed: requestedFontIDs,
            bounds: bounds, pixels: outputPixels, sourceRect: layout.sourceRect,
            pdfDeviceScale: pdfDeviceScale, recordRejection: recordReadabilityRejection)
        requestedFontIDs.subtract(requestedFontRejected)
        readabilityRejected.subtract(requestedFontIDs)
        readabilityRejected.formUnion(requestedFontRejected)
        for id in requestedFontIDs { readabilityRejectionReasons.removeValue(forKey: id) }
        // Coarse-request gains remain frozen if dense non-monotone probes fail.
        let denseFontBaseline = cards
        var denseFontIDs = try improveSmallTextBoxes(cards: &cards, owners: ownerByID,
            sourceRect: layout.sourceRect, imageSize: layout.imageSize, pdfDeviceScale: pdfDeviceScale,
            recoverRequestedFont: true, denseRequestedFonts: true)
        let denseFontRejected = try rejectNewReadabilityPeerInk(cards: &cards, baseline: denseFontBaseline,
            changed: denseFontIDs, bounds: bounds, pixels: outputPixels, sourceRect: layout.sourceRect,
            pdfDeviceScale: pdfDeviceScale, recordRejection: recordReadabilityRejection)
        denseFontIDs.subtract(denseFontRejected)
        // A full UTF range and fits=true do not prove that the final clip retains ink.
        // Freeze every approved ordinary card before this independently budgeted repair.
        let clipRecoveryBaseline = cards
        phaseMilliseconds["ordinaryReadability"] = (ProcessInfo.processInfo.systemUptime - readabilityStarted) * 1000
        recordPanelStage("ordinary-readability")
        let clipRecoveryStarted = ProcessInfo.processInfo.systemUptime
        var beforeClipAudits: [String: [String: Any]] = [:]
        var clipAuditPixels = 8_000_000
        var confirmedClipLossIDs: Set<String> = []
        for card in cards {
            try Task.checkCancellation()
            if let audit = finalTextClipAudit(card, pixelScale: declaredScale,
                pdfDeviceScale: pdfDeviceScale, remainingPixels: &clipAuditPixels) {
                beforeClipAudits[card.item.id] = audit
                if audit["status"] as? String == "measured-within-allocation",
                   let modes = audit["modes"] as? [[String: Any]],
                   modes.contains(where: { ($0["clipLossPixels"] as? Int ?? 0) > 0 }) {
                    confirmedClipLossIDs.insert(card.item.id)
                }
            }
        }
        var clipRecoveryIDs: Set<String> = []
        if !confirmedClipLossIDs.isEmpty {
            _ = try improveWaistTextBoxes(cards: &cards, surfaces: surfaces,
                requested: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }), owners: ownerByID,
                sourceRect: layout.sourceRect, imageSize: layout.imageSize, pdfDeviceScale: pdfDeviceScale,
                confirmedClipLossIDs: confirmedClipLossIDs, onlyConfirmedClipLoss: true,
                recordInkRecovery: { clipRecoveryIDs.insert($0) })
            var verificationPixels = 8_000_000
            for index in cards.indices where clipRecoveryIDs.contains(cards[index].item.id) {
                let audit = finalTextClipAudit(cards[index], pixelScale: declaredScale,
                    pdfDeviceScale: pdfDeviceScale, remainingPixels: &verificationPixels, forceMeasurement: true)
                let modes = audit?["modes"] as? [[String: Any]]
                guard audit?["status"] as? String == "measured-within-allocation",
                      modes?.count == 2, modes!.allSatisfy({
                        ($0["rawOccupiedPixels"] as? Int ?? 0) > 0 && ($0["clipLossPixels"] as? Int) == 0
                      }) else {
                    clipRecoveryIDs.remove(cards[index].item.id)
                    cards[index] = clipRecoveryBaseline[index]
                    continue
                }
            }
            let rejected = try rejectNewReadabilityPeerInk(cards: &cards, baseline: clipRecoveryBaseline,
                changed: clipRecoveryIDs, bounds: bounds, pixels: outputPixels, sourceRect: layout.sourceRect,
                pdfDeviceScale: pdfDeviceScale, recordRejection: recordReadabilityRejection)
            clipRecoveryIDs.subtract(rejected)
        }
        // Only attempt painted-row recovery after ordinary font, waist and clip
        // recovery. An early trial can thin a card that those stages already fix.
        let disableFinalRowRecovery = ProcessInfo.processInfo.environment["AIDOKU_DISABLE_FINAL_ROW_RECOVERY"] == "1"
        for index in cards.indices where !disableFinalRowRecovery {
            try Task.checkCancellation()
            let card = cards[index]
            let text = card.item.typesettingText ?? card.item.text
            guard !card.typography.fits, card.style.outlineWidth > 0,
                  card.typography.visibleUTF16Range.location == 0,
                  card.typography.visibleUTF16Range.length == text.utf16.count,
                  let gap = NativeTranslationTypography.minimumPaintedRowGap(layout: card.typography), gap < 0 else { continue }
            var accepted = false
            for ratio in [CGFloat(1), 0.85, 0.7] where !accepted {
                for step in 1...4 {
                    var candidate = card
                    candidate.style.outlineWidth = max(1.5, card.style.outlineWidth * ratio)
                    candidate.style.lineHeight = card.style.lineHeight + CGFloat(step) * max(0.5, -gap / 2)
                    candidate.typography = NativeTranslationTypography.layout(text: text,
                        in: candidate.item.contentRect.size, style: candidate.style)
                    guard candidate.typography.fits,
                          NativeTranslationTypography.minimumPaintedRowGap(layout: candidate.typography).map({ $0 >= 0 }) == true,
                          NativeTranslationTypography.committedParagraphRawComplete(candidate.typography, original: text) else { continue }
                    var auditPixels = 1_000_000
                    let audit = finalTextClipAudit(candidate, pixelScale: declaredScale,
                        pdfDeviceScale: pdfDeviceScale, remainingPixels: &auditPixels, forceMeasurement: true)
                    let modes = audit?["modes"] as? [[String: Any]]
                    guard audit?["status"] as? String == "measured-within-allocation",
                          modes?.count == 2, modes!.allSatisfy({
                            ($0["rawOccupiedPixels"] as? Int ?? 0) > 0 && ($0["clipLossPixels"] as? Int) == 0
                          }) else { continue }
                    var proposed = cards
                    proposed[index] = candidate
                    let rejected = try rejectNewReadabilityPeerInk(cards: &proposed, baseline: cards,
                        changed: [card.item.id], bounds: bounds, pixels: outputPixels,
                        sourceRect: layout.sourceRect, pdfDeviceScale: pdfDeviceScale,
                        recordRejection: recordReadabilityRejection)
                    guard rejected.isEmpty else { continue }
                    cards = proposed
                    var prediction = sourcePaintPredictions[card.item.id] ?? [:]
                    prediction["displayOutlineWidth"] = Double(candidate.style.outlineWidth)
                    prediction["displayOutlineRecovery"] = "final-failed-complete-row-ink-fit; source-stroke-RGB-unchanged"
                    sourcePaintPredictions[card.item.id] = prediction
                    limitations.removeAll { $0 == "text-overflow:\(card.item.id)" }
                    accepted = true
                    break
                }
            }
        }
        var cohortUnknownSourceStyleIDs: Set<String> = []
        phaseMilliseconds["ordinaryClipRecovery"] = (ProcessInfo.processInfo.systemUptime - clipRecoveryStarted) * 1000
        recordPanelStage("ordinary-clip-recovery")
        // Finalize backing only after ordinary fitting/recovery, so a smaller
        // erasure rectangle cannot accidentally become the text search space.
        for index in cards.indices {
            try Task.checkCancellation()
            let card = cards[index]
            guard card.drawsPanel, let owner = ownerByID[card.item.id],
                  let surface = surfaces[card.item.id] else { continue }
            // Readability recovery may have enlarged the frame again. Reflow/shrink
            // before sealing a final artifact rather than clipping a panel or glyphs.
            if let rectangle = surface.rectangularPanel(covering: owner,
                near: card.sourcePlateRect, within: card.sourcePlateRect),
               !rectangle.contains(card.item.rect), card.textPaintDomain == nil,
               card.unitTextParts.isEmpty, card.effectiveTextRotation == 0 {
                var candidate = card
                let frame = card.item.rect.intersection(rectangle.insetBy(dx: 0.7, dy: 0.7))
                if valid(frame) {
                    candidate.item.x = frame.minX; candidate.item.y = frame.minY
                    candidate.item.width = frame.width; candidate.item.height = frame.height
                    candidate.textShift = .zero
                    candidate.typographyWidth = nil
                    candidate.typography = fitted(text: candidate.item.typesettingText ?? candidate.item.text,
                        size: candidate.item.contentRect.size, style: &candidate.style, item: candidate.item)
                    candidate.item.fontSize = candidate.style.fontSize
                    candidate.item.lineHeight = candidate.style.lineHeight
                    candidate.finalFontSize = candidate.style.fontSize
                    let ink = cardInkRect(candidate).insetBy(dx: -candidate.style.outlineWidth / 2,
                                                           dy: -candidate.style.outlineWidth / 2)
                    if candidate.typography.fits, valid(ink), rectangle.contains(ink) {
                        candidate.sourcePlateOwnerRect = rectangle
                        candidate.straightenedPanelRect = rectangle
                        candidate.harmonyRecord["balloonRectangleRefit"] = true
                        candidate.harmonyRecord["balloonRectanglePreviousFont"] = Double(card.style.fontSize)
                        cards[index] = candidate
                    }
                }
            }
            let finalized = cards[index]
            let ink = cardInkRect(finalized)
            let cover = valid(ink) ? owner.union(finalized.item.rect).union(ink) : owner.union(finalized.item.rect)
            if let rectangle = surface.rectangularPanel(covering: cover,
                near: card.sourcePlateRect, within: card.sourcePlateRect) {
                cards[index].sourcePlateOwnerRect = rectangle
                cards[index].straightenedPanelRect = rectangle
            }
        }
        let topAlignmentBaseline = cards
        var topAlignedIDs: Set<String> = []
        for group in sourceTopGroups {
            let indices = group.compactMap { sourceIndex in
                cards.firstIndex { $0.item.id == items[sourceIndex].id }
            }
            guard indices.count >= 2 else { continue }
            let baselines = indices.compactMap { index -> CGFloat? in
                let card = cards[index]
                guard card.effectiveTextRotation == 0, card.typography.fits,
                      let rows = NativeTranslationTypography.horizontalRowMetrics(layout: card.typography,
                        originalText: card.item.text, origin: card.textOrigin),
                      let first = rows.first?["unsnappedBaseline"] as? [Double], first.count == 2,
                      first[1].isFinite else { return nil }
                return CGFloat(first[1])
            }
            guard baselines.count == indices.count else { continue }
            // A common source-top cohort shares one rendered first-line baseline.
            // Preserve font, pitch, wrapping, panel and individual paragraph identity.
            // Membership and anchor must use the same observed lettering
            // reference. Detector-envelope tops may include empty lead-in
            // space and must not overwrite the measured ink-top reference.
            // This changes text placement only; erasure owners stay frozen.
            let sourceTops = group.map { observedTopOwners[$0].minY }.sorted()
            let insets = indices.compactMap { index -> CGFloat? in
                let card = cards[index]
                var topStyle = card.style
                topStyle.alignsToTop = true
                // Measure the same retained font without running a second shrink-to-fit search.
                let topLayout = NativeTranslationTypography.layout(text: card.item.typesettingText ?? card.item.text,
                    in: card.item.contentRect.size, style: topStyle)
                guard let rows = NativeTranslationTypography.horizontalRowMetrics(layout: topLayout,
                    originalText: card.item.text), let first = rows.first?["unsnappedBaseline"] as? [Double],
                      first.count == 2, first[1].isFinite else { return nil }
                return card.item.paddingTop + CGFloat(first[1])
            }.sorted()
            guard insets.count == indices.count else { continue }
            let desiredAnchor = sourceTops[sourceTops.count / 2] + insets[insets.count / 2]
            // Choose one baseline from the intersection of actual painted-ink
            // capacity intervals. A median source anchor outside one backing
            // previously discarded the entire aligned cohort even when a
            // nearby common baseline fitted every unchanged rectangle.
            var lowerAnchor = -CGFloat.infinity, upperAnchor = CGFloat.infinity
            for (ordinal, index) in indices.enumerated() {
                let card = cards[index]
                let space = card.item.clipsText
                    ? card.sourcePlateRect.intersection(card.item.rect) : card.sourcePlateRect
                guard let interval = captionBaselineInterval(ink: cardInkRect(card),
                    baseline: baselines[ordinal], space: space) else {
                    lowerAnchor = .infinity; break
                }
                lowerAnchor = max(lowerAnchor, interval.lowerBound)
                upperAnchor = min(upperAnchor, interval.upperBound)
            }
            guard lowerAnchor.isFinite, upperAnchor.isFinite, lowerAnchor <= upperAnchor else { continue }
            let anchor = min(upperAnchor, max(lowerAnchor, desiredAnchor))
            var proposed = cards
            var safe = true
            for (ordinal, index) in indices.enumerated() {
                proposed[index].textShift.y += anchor - baselines[ordinal]
                let ink = cardInkRect(proposed[index])
                if !valid(ink) || !proposed[index].sourcePlateRect.contains(ink)
                    || proposed[index].item.clipsText && !proposed[index].item.rect.contains(ink) {
                    safe = false
                    break
                }
            }
            guard safe else { continue }
            guard try stagedCaptionInkPreserved(cards: proposed, indices: indices, bounds: bounds,
                pixels: outputPixels, sourceRect: layout.sourceRect, pdfDeviceScale: pdfDeviceScale,
                remainingSamples: &captionInkSamples) else { continue }
            cards = proposed
            topAlignedIDs.formUnion(indices.map { cards[$0].item.id })
        }
        if !topAlignedIDs.isEmpty {
            let rejected = try rejectNewReadabilityPeerInk(cards: &cards, baseline: topAlignmentBaseline,
                changed: topAlignedIDs, bounds: bounds, pixels: outputPixels, sourceRect: layout.sourceRect,
                pdfDeviceScale: pdfDeviceScale, recordRejection: recordReadabilityRejection)
            topAlignedIDs.subtract(rejected)
            // A group is committed together; individual rejection must not leave staggered leftovers.
            for group in sourceTopGroups {
                let ids = Set(group.map { items[$0].id })
                guard !ids.isDisjoint(with: rejected) else { continue }
                for index in cards.indices where ids.contains(cards[index].item.id) {
                    cards[index] = topAlignmentBaseline[index]
                }
                topAlignedIDs.subtract(ids)
            }
        }
        if let auditCardObserver { for card in cards { auditCardObserver(.preCohort, card) } }
        let cohortStarted = ProcessInfo.processInfo.systemUptime
        var cohortConditionalGeometryIDs: Set<String> = []
        var cohortAudit: [String: Int] = [:]
        // A paragraph frame is a shaping/search domain, not painted coverage.
        // Trim backing to source plus real glyph ink before artifact certification.
        let outputScale = min(outputPixels.width / bounds.width, outputPixels.height / bounds.height)
        let panelGuard = max(0.35, 1 / max(0.001, outputScale))
        let backingSnapshot = cards.map(\.sourcePlateRect)
        recordPanelStage("before-tight-backing")
        for index in cards.indices {
            let card = cards[index]
            guard card.drawsPanel, card.textPaintDomain == nil, card.unitTextParts.isEmpty,
                  card.effectiveTextRotation == 0, let owner = ownerByID[card.item.id] else { continue }
            let glyphs = card.typography.glyphBounds.reduce(CGRect.null) { $0.union($1) }
            guard valid(glyphs) else { continue }
            let ink = glyphs.offsetBy(dx: card.textOrigin.x, dy: card.textOrigin.y)
                .insetBy(dx: -card.style.outlineWidth / 2 - card.style.outlineGlow,
                         dy: -card.style.outlineWidth / 2 - card.style.outlineGlow)
            // Detector boxes often stop at the colored core and omit source
            // outlines/closing brackets. Output-AA padding alone is insufficient.
            // Keep a small source-erasure guard independently from translated ink.
            let sourceGuard = settings.textBoxGeometryParameters.sourceGuard(owner: owner,
                sourceFontSize: card.item.sourceFontSize ?? 0, outputOutline: card.style.outlineWidth,
                panelPadding: panelGuard)
            // Unbounded captions may need a fraction more than the old erasure
            // box allowed. Never expand a known balloon or increase peer overlap.
            let limit = surfaces[card.item.id] == nil
                ? card.sourcePlateRect.insetBy(dx: -CGFloat(settings.textBoxGeometryParameters.openPanelExpansion),
                    dy: -CGFloat(settings.textBoxGeometryParameters.openPanelExpansion)).intersection(layout.sourceRect)
                : card.sourcePlateRect
            guard var panel = NativeTextBoxContainment.tightPanel(owner: owner, paintedInk: ink,
                within: limit, padding: panelGuard, sourcePadding: sourceGuard - panelGuard) else { continue }
            func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
                let r = a.intersection(b)
                return r.isNull ? 0 : max(0, r.width) * max(0, r.height)
            }
            if cards.indices.contains(where: { peer in peer != index
                && overlap(panel, backingSnapshot[peer]) > overlap(backingSnapshot[index], backingSnapshot[peer]) + 1e-9 }) {
                guard let fallback = NativeTextBoxContainment.tightPanel(owner: owner, paintedInk: ink,
                    within: card.sourcePlateRect, padding: panelGuard, sourcePadding: sourceGuard - panelGuard) else { continue }
                panel = fallback
            }
            cards[index].harmonyRecord["sourceErasureGuard"] = Double(sourceGuard)
            cards[index].harmonyRecord["tightPanelPreviousRect"] = [Double(card.sourcePlateRect.minX),
                Double(card.sourcePlateRect.minY), Double(card.sourcePlateRect.width), Double(card.sourcePlateRect.height)]
            cards[index].sourcePlateOwnerRect = panel
            cards[index].straightenedPanelRect = panel
        }
        let containmentStarted = ProcessInfo.processInfo.systemUptime
        recordPanelStage("after-tight-backing")
        var paragraphAlphaBudget = NativeSourceBootstrapBirth.Budget()
        var paragraphAlphaAttempts = 0
        let paragraphAlphaEnabled = paragraphGuardEnabled
        var paragraphAlphaUnknown: [String: Int] = [:]
        var legacyParagraphCards = cards
        if paragraphAlphaEnabled {
            try separateParagraphInk(cards: &legacyParagraphCards, surfaces: surfaces,
                keptOwners: items.indices.filter { items[$0].keptLettering }.map { owners[$0] }, outputScale: outputScale)
        }
        let admitParagraphShift: ((Card, [Card]) throws -> NativeSourceBootstrapBirth.Admission?)? = paragraphAlphaEnabled ? { candidate, peers in
            try Task.checkCancellation()
            guard paragraphAlphaUnknown.isEmpty else { return nil }
            guard paragraphAlphaAttempts < 24 else {
                paragraphAlphaUnknown["attempt-budget", default: 0] += 1
                return nil
            }
            paragraphAlphaAttempts += 1
            let admission = try NativeSourceBootstrapBirth.admitAlpha(card: candidate, peers: peers, bounds: bounds,
                sourceRect: layout.sourceRect, pixels: outputPixels, pdfScale: pdfDeviceScale, budget: &paragraphAlphaBudget)
            // Unknown is never candidate permission. Preserve the completed legacy
            // stage rather than a pre-stage world that could remove useful repairs.
            if !admission.accepted && !["born-empty-peer-collision", "strict-alpha-clip"].contains(admission.reason) {
                paragraphAlphaUnknown[admission.reason, default: 0] += 1
            }
            return admission
        } : nil
        try separateParagraphInk(cards: &cards, surfaces: surfaces,
            keptOwners: items.indices.filter { items[$0].keptLettering }.map { owners[$0] }, outputScale: outputScale,
            protectsPanelSupport: paragraphAlphaEnabled && paragraphPanelSupport,
            admitShift: admitParagraphShift)
        if paragraphAlphaEnabled, !paragraphAlphaUnknown.isEmpty {
            cards = legacyParagraphCards
            limitations.append("paragraph-shift-candidate-unmeasured-legacy-preserved")
        }
        recordPanelStage("after-paragraph-ink-separation")
        try containBalloonPanels(cards: &cards, owners: ownerByID, surfaces: &surfaces,
            source: source, sourceRect: layout.sourceRect, outputScale: outputScale,
            parameters: settings.textBoxGeometryParameters, sourcePredictions: sourcePaintPredictions,
            requestedFonts: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.fontSize) }),
            requestedFrames: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.rect) }),
            coverageRegions: Dictionary(uniqueKeysWithValues: cards.indices.map { (cards[$0].item.id, backingSnapshot[$0]) }))
        recordPanelStage("after-balloon-panel-containment")
        let recoveredSeparatedIDs = try recoverSeparatedTextCapacity(cards: &cards,
            requested: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }), surfaces: surfaces,
            keptOwners: items.indices.filter { items[$0].keptLettering }.map { owners[$0] },
            bounds: bounds, pixels: outputPixels, sourceRect: layout.sourceRect,
            imageSize: layout.imageSize, pdfDeviceScale: pdfDeviceScale)
        for id in recoveredSeparatedIDs { limitations.removeAll { $0 == "text-overflow:\(id)" } }
        phaseMilliseconds["balloonPanelContainment"] = (ProcessInfo.processInfo.systemUptime - containmentStarted) * 1000
        recordPanelStage("balloon-containment-and-separated-capacity")
        // Source erasure admission must not become translated shaping capacity.
        // This trial changes only a complete backing before artifact admission;
        // it never changes a sealed artifact or its fitted typography.
        if preserveLateBacking {
            for index in cards.indices {
                let original = cards[index]
                guard original.drawsPanel, original.effectiveTextRotation == 0,
                      original.unitTextParts.isEmpty, original.backings.isEmpty,
                      original.sourcePanels.isEmpty, original.textBoxBackgroundClip == nil,
                      let incumbent = incumbentSourceBackings[original.item.id],
                      let owner = ownerByID[original.item.id], let surface = surfaces[original.item.id] else { continue }
                let peers = cards.indices.filter { $0 != index }.flatMap {
                    [cards[$0].sourcePlateRect, cardInkRect(cards[$0])]
                } + items.indices.filter { items[$0].keptLettering }.map { owners[$0] }
                // An old admission also contains translation/search padding.
                // Only its bounded source-owner guard is an erasure obligation;
                // never restore the full old translated search rectangle.
                let sourceFont = items.first(where: { $0.id == original.item.id })?.sourceFontSize ?? 0
                let guardSize = settings.textBoxGeometryParameters.sourceGuard(owner: owner,
                    sourceFontSize: sourceFont, outputOutline: original.style.outlineWidth, panelPadding: panelGuard)
                let obligation = owner.insetBy(dx: -guardSize, dy: -guardSize).intersection(incumbent)
                guard let proposal = NativeTextBoxEarlySurfaceTrial.backingUnion(candidate: original.sourcePlateRect,
                    incumbent: obligation, owner: owner, peers: peers, contains: { surface.contains($0) }) else { continue }
                cards[index].sourcePlateOwnerRect = proposal
                cards[index].straightenedPanelRect = proposal
                cards[index].harmonyRecord["sourceBackingObligation"] = [
                    "phase": "post-typography-pre-artifact-admission", "before": diagnosticRect(original.sourcePlateRect),
                    "after": diagnosticRect(proposal), "incumbent": diagnosticRect(incumbent),
                    "boundedSourceObligation": diagnosticRect(obligation), "configuredSourceGuard": Double(guardSize),
                    "fontUnchangedAtAdmission": cards[index].style.fontSize == original.style.fontSize,
                    "textOriginUnchangedAtAdmission": cards[index].textOrigin == original.textOrigin,
                    "authority": "observed surface and live peer rectangle admission; not source glyph GT"]
            }
        }
        recordPanelStage("after-source-backing-obligation")
        let widthSeed = PreparedRender(inputLayout: layout, layout: layout, image: image, source: source,
            restoration: .init(), cards: cards, glossCards: [], gloss: .init(), settings: settings,
            bounds: bounds, pixels: outputPixels, scale: scale, composeSource: composeSource,
            capturePDF: capturePDF, pdfDeviceScale: pdfDeviceScale, sourcePatches: [], sourcePieces: [],
            limitations: limitations, diagnosticData: nil)
        let widthSession = NativeWidthFinalArtifactAdmission(plan: widthSeed,
            keptOwners: items.indices.filter { items[$0].keptLettering }.map { owners[$0] })
        var widthIncumbent = cards
        var widthIncumbentChanged: Set<String> = []
        var widthIncumbentUnknown = cohortUnknownSourceStyleIDs
        var widthIncumbentConditional = cohortConditionalGeometryIDs
        var widthIncumbentAudit: [String: Int] = [:]
        var cohortChangedIDs = try commitContourCohortsTiled(cards: &cards, items: items,
            owners: owners, surfaces: surfaces, bounds: bounds, sourceRect: layout.sourceRect,
            pixels: outputPixels, pdfDeviceScale: pdfDeviceScale,
            verifiedOriginalStyle: [], allowsStyleUnknownTrials: true,
            unknownSourceStyleIDs: &cohortUnknownSourceStyleIDs,
            allowsVerifiedBalloonInteriorModelTrials: true,
            conditionalGeometryIDs: &cohortConditionalGeometryIDs,
            useObservedFamilyRatios: settings.textBoxGeometryParameters.observedFamilyRatiosEnabled == 1,
            shapingPaddingScale: CGFloat(settings.textBoxGeometryParameters.translationPaddingScale ?? 1),
            widthStageCheckpoint: { priorCards, priorChanged, priorUnknown, priorConditional, priorAudit in
                widthIncumbent = priorCards; widthIncumbentChanged = priorChanged
                widthIncumbentUnknown = priorUnknown; widthIncumbentConditional = priorConditional
                widthIncumbentAudit = priorAudit
            },
            widthFinalArtifactAdmission: { widthSession.admission(before: $0, after: $1, ids: $2) },
            recordAudit: collectDiagnostics ? { cohortAudit = $0 } : nil)
        let widthWasPlanned = cards.contains { $0.harmonyRecord["widthRequiresRetainedArtifact"] as? Bool == true }
        // Install only the literal certified snapshot/document, never a
        // reconstructed world assembled from mutable caller cards.
        let sealedWidth = try widthSession.publishOwned(diagnosticData: nil)
        cards = sealedWidth?.cards ?? widthIncumbent
        if widthWasPlanned && sealedWidth == nil {
            cohortChangedIDs = widthIncumbentChanged
            cohortUnknownSourceStyleIDs = widthIncumbentUnknown
            cohortConditionalGeometryIDs = widthIncumbentConditional
            cohortAudit = widthIncumbentAudit
            cohortAudit["widthFinalizationRolledBack"] = 1
        }
        phaseMilliseconds["cohortLayout"] = (ProcessInfo.processInfo.systemUptime - cohortStarted) * 1000
        recordPanelStage("final-cohort")
        // A sealed width artifact owns its exact paint world; never mutate it.
        let rowClearanceStarted = ProcessInfo.processInfo.systemUptime
        let rowClearanceAudit: [[String: Any]]
        if sealedWidth == nil {
            rowClearanceAudit = try repairIntraRowClearance(cards: &cards, bounds: bounds,
                pixels: outputPixels, sourceRect: layout.sourceRect, pixelScale: declaredScale,
                pdfDeviceScale: pdfDeviceScale)
        } else {
            rowClearanceAudit = [["status": "sealed-artifact-abstention",
                "measuredClearance": NSNull()]]
        }
        phaseMilliseconds["rowClearance"] = (ProcessInfo.processInfo.systemUptime - rowClearanceStarted) * 1000
        if collectDiagnostics {
            for card in cards {
                var prediction = sourcePaintPredictions[card.item.id] ?? [:]
                prediction["preFinalDisplayOutlineWidth"] = prediction["displayOutlineWidth"] ?? NSNull()
                prediction["displayOutlineWidth"] = Double(card.style.outlineWidth)
                prediction["displayOutlineWidthAuthority"] = "final retained card style; not original pen width or raster measurement"
                prediction["readabilityAuditStage"] = "before-shaping; not a final retained-outline or pixel certificate"
                sourcePaintPredictions[card.item.id] = prediction
            }
        }
        if let auditCardObserver { for card in cards { auditCardObserver(.finalCard, card) } }
        recordStage?("native.solidTextBoxes")
        func diagnosticRect(_ rect: CGRect) -> [Double] {
            guard !rect.isNull, !rect.isInfinite,
                  [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return [] }
            return [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
        }
        func diagnosticPolygon(_ points: [CGPoint]) -> Any {
            guard points.count >= 3, points.count <= 4_096,
                  points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return NSNull() }
            return points.map { [Double($0.x), Double($0.y)] }
        }
        var finalClipAudits: [String: [String: Any]] = [:]
        var finalTextDomainCertificates: [String: [String: Any]] = [:]
        let finalAuditStarted = ProcessInfo.processInfo.systemUptime
        if collectDiagnostics {
            var finalClipAuditPixels = 8_000_000
            for card in cards {
                try Task.checkCancellation()
                if card.textPaintDomain != nil {
                    // The ordinary backing-sized audit is not a text-domain audit.
                    // Whole-world tiled proof is explicit model-conditional evidence.
                    let metadata = independentTextDomainAuditMetadata()
                    finalTextDomainCertificates[card.item.id] = metadata.certificate
                }
                finalClipAudits[card.item.id] = finalTextClipAudit(card, pixelScale: declaredScale,
                    pdfDeviceScale: pdfDeviceScale, remainingPixels: &finalClipAuditPixels,
                    forceMeasurement: true, auditEveryFinalCard: true)
                    ?? ["status": "unmeasured", "unmeasuredReason": "final-audit-no-observation",
                        "ordinaryClipMeasured": false, "serializedPDFMeasured": false,
                        "finalCompositeMeasured": false]
            }
        }
        phaseMilliseconds["finalClipAudit"] = (ProcessInfo.processInfo.systemUptime - finalAuditStarted) * 1000
        phaseMilliseconds["prepareTotalBeforeDiagnosticEncoding"] = (ProcessInfo.processInfo.systemUptime - prepareStarted) * 1000
        let diagnosticData = collectDiagnostics ? try JSONSerialization.data(withJSONObject: [
            "diagnosticsVersion": 2, "sourceReplacement": "solid-text-box",
            "panelStageTraceEnabled": tracePanelStages,
            "panelStageTrace": panelStageTrace,
            "earlySurfaceSeparationTrial": earlySurfaceTrial,
            "earlyBackingObligationTrial": preserveEarlyBacking,
            "lateBackingObligationTrial": preserveLateBacking,
            "earlySurfaceSeparationObservations": earlySurface.observations,
            "earlySurfaceSeparationSamplePixels": earlySurface.pixels,
            "inpainting": false, "glyphSegmentation": false,
            "omittedInputs": omittedInputs,
            "paragraphShiftNativeGuard": ["enabled": paragraphAlphaEnabled,
                "candidateAbstained": !paragraphAlphaUnknown.isEmpty,
                "completedLegacyStagePreserved": !paragraphAlphaUnknown.isEmpty,
                "unknownReasons": paragraphAlphaUnknown, "attempts": paragraphAlphaAttempts,
                "alphaPixelsCharged": paragraphAlphaBudget.charged,
                "maximumAttempts": 24, "maximumAlphaPixels": 8_000_000,
                "legacyFallbackIsImprovement": false],
            "cohortLayoutAudit": cohortAudit,
            "intraRowClearanceAudit": rowClearanceAudit,
            "phaseMilliseconds": phaseMilliseconds,
            "finalTextClipAudits": finalClipAudits,
            "finalTextDomainCertificates": finalTextDomainCertificates,
            "beforeTextClipAudits": beforeClipAudits,
            "readabilityRejectionRootCounts": readabilityRejectionReasons.values.reduce(into: [String: Int]()) {
                $0[$1, default: 0] += 1
            },
            // Report the final fitted state, not the planner's requested font.
            // Evaluation no longer needs to reconstruct colors/fonts from PDF state.
            "cards": cards.map { card -> [String: Any] in
                let hierarchy = NativeSourceLetteringScale.selectProxy(
                    record: card.harmonyRecord["observedSourceLetteringScale"] as? [String: Any],
                    forecast: card.item.sourceFontSize.map(Double.init), requested: Double(card.item.fontSize))
                return ["id": card.item.id, "drawsPanel": card.drawsPanel,
                 "frame": diagnosticRect(card.sourcePlateRect),
                 "sourceSurfaceIntersection": card.harmonyRecord["sourceSurfaceIntersection"] as Any? ?? NSNull(),
                 "sourceBackingObligation": card.harmonyRecord["sourceBackingObligation"] as Any? ?? NSNull(),
                 "balloonClipped": false,
                 "panelShape": "rectangle",
                 "tightPanelPreviousRect": card.harmonyRecord["tightPanelPreviousRect"] as Any? ?? NSNull(),
                 "sourceErasureGuard": card.harmonyRecord["sourceErasureGuard"] as Any? ?? NSNull(),
                 "textContourClipped": !card.textBoxClip.isEmpty,
                 "balloonRectangleRefit": card.harmonyRecord["balloonRectangleRefit"] as? Bool ?? false,
                 "balloonRectanglePreviousFont": card.harmonyRecord["balloonRectanglePreviousFont"] as Any? ?? NSNull(),
                 "balloonPanelContainmentStatus": card.harmonyRecord["balloonPanelContainmentStatus"] as Any? ?? NSNull(),
                 "balloonPanelGeometryResampled": card.harmonyRecord["balloonPanelGeometryResampled"] as? Bool ?? false,
                 "balloonPanelSourceGuard": card.harmonyRecord["balloonPanelSourceGuard"] as Any? ?? NSNull(),
                 "balloonPanelSourceGuardClamped": card.harmonyRecord["balloonPanelSourceGuardClamped"] as? Bool ?? false,
                 "balloonPanelWitnessExpanded": card.harmonyRecord["balloonPanelWitnessExpanded"] as? Bool ?? false,
                 "balloonPanelRetainedBackingLayoutOnly": card.harmonyRecord["balloonPanelRetainedBackingLayoutOnly"] as Any? ?? NSNull(),
                 "balloonPanelSourceWitnessCovered": card.harmonyRecord["balloonPanelSourceWitnessCovered"] as Any? ?? NSNull(),
                 "balloonPanelReadabilityObserved": card.harmonyRecord["balloonPanelReadabilityObserved"] as? Bool ?? false,
                 "balloonPanelSourceEnvelopeRefined": card.harmonyRecord["balloonPanelSourceEnvelopeRefined"] as? Bool ?? false,
                 "balloonPanelCoveringWitness": card.harmonyRecord["balloonPanelCoveringWitness"] as Any? ?? NSNull(),
                 "balloonPanelObservedSourceBounds": card.harmonyRecord["balloonPanelObservedSourceBounds"] as Any? ?? NSNull(),
                 "paragraphInkSeparationShift": card.harmonyRecord["paragraphInkSeparationShift"] as Any? ?? NSNull(),
                 "paragraphInkSeparationAudit": card.harmonyRecord["paragraphInkSeparationAudit"] as Any? ?? NSNull(),
                 "minimumPaintedRowGap": NativeTranslationTypography.minimumPaintedRowGap(layout: card.typography).map(Double.init) as Any? ?? NSNull(),
                 "balloonPanelPreviousFont": card.harmonyRecord["balloonPanelPreviousFont"] as Any? ?? NSNull(),
                 "balloonPanelPreviousRect": card.harmonyRecord["balloonPanelPreviousRect"] as Any? ?? NSNull(),
                 "balloonPanelRejection": card.harmonyRecord["balloonPanelRejection"] as Any? ?? NSNull(),
                 "balloonPanelCandidateRejections": card.harmonyRecord["balloonPanelCandidateRejections"] as Any? ?? NSNull(),
                 "sourceSurfacePolygon": diagnosticPolygon(card.textBoxClip),
                 "sourceSurfacePointCount": card.textBoxClip.count,
                 "backgroundClip": card.textBoxBackgroundClip.map(diagnosticRect) ?? [],
                 "independentTextDomain": card.textPaintDomain.map { diagnosticRect($0.rect) } as Any? ?? NSNull(),
                 "independentTextDomainPolygon": card.textPaintDomain.map { diagnosticPolygon($0.polygon) } as Any? ?? NSNull(),
                 "cohortLayoutChanged": cohortChangedIDs.contains(card.item.id),
                 "cohortGeometryModelConditional": cohortConditionalGeometryIDs.contains(card.item.id),
                 "cohortOriginalStyleUnknown": cohortUnknownSourceStyleIDs.contains(card.item.id),
                 "textFrame": diagnosticRect(card.item.rect),
                 "initialRequestedTextFrame": card.harmonyRecord["initialRequestedTextFrame"] as Any? ?? NSNull(),
                 "initialRequestedPanelIntersection": card.harmonyRecord["initialRequestedPanelIntersection"] as Any? ?? NSNull(),
                 "separatedTextCapacityRecovered": card.harmonyRecord["separatedTextCapacityRecovered"] as Any? ?? NSNull(),
                 "separatedTextCapacityRejections": card.harmonyRecord["separatedTextCapacityRejections"] as Any? ?? NSNull(),
                 "contentFrame": diagnosticRect(card.item.contentRect),
                 "sourceTopCohortAligned": topAlignedIDs.contains(card.item.id),
                 "sourceCaptionFontShared": uniformCaptionFontIDs.contains(card.item.id),
                 "sourceColumnRotationSuppressed": uprightTranslatedSourceColumn(card.item),
                 "textRotation": Double(card.effectiveTextRotation),
                 "background": rgb(card.background) ?? [], "foreground": rgb(card.style.foreground) ?? [],
                 "outline": rgb(card.style.outline) ?? [], "outlineWidth": Double(card.style.outlineWidth),
                 "sourcePaintPrediction": sourcePaintPredictions[card.item.id] as Any? ?? NSNull(),
                 "observedSourceLetteringScale": card.harmonyRecord["observedSourceLetteringScale"] as Any? ?? NSNull(),
                 "sourceHierarchyProxyUsed": hierarchy.value as Any? ?? NSNull(),
                 "sourceHierarchyProxyProvenance": hierarchy.provenance,
                 "sourceHierarchyFallbackReason": hierarchy.fallbackReason as Any? ?? NSNull(),
                 "savedSourceFontSizeForecast": card.harmonyRecord["savedSourceFontSizeForecast"] as Any? ?? NSNull(),
                 "sourceTopObservedInkAnchor": card.harmonyRecord["sourceTopObservedInkAnchor"] as Any? ?? NSNull(),
                 "sourceTopAnchorAuthority": card.harmonyRecord["sourceTopAnchorAuthority"] as Any? ?? NSNull(),
                 "sourceTopGroupAfterObservations": card.harmonyRecord["sourceTopGroupAfterObservations"] as Any? ?? NSNull(),
                 "originalColorFidelity": NativeOriginalColorFidelity.evaluate(
                    panelPrediction: panelColorPredictions[card.item.id],
                    foregroundPrediction: NativeSourceColorSampler.rgb(sourcePaintPredictions[card.item.id]?["foreground"]),
                    strokePrediction: NativeSourceColorSampler.rgb(sourcePaintPredictions[card.item.id]?["stroke"]),
                    panelPaint: card.drawsPanel ? rgb(card.background) : nil,
                    foregroundPaint: rgb(card.style.foreground),
                    strokePaint: card.style.outlineWidth > 0 ? rgb(card.style.outline) : nil),
                 "sourcePaintModel": sourceStyles[card.item.id].map { observed -> [String: Any] in
                    ["foreground": observed.foreground, "stroke": observed.stroke,
                     "modelConfidence": observed.modelConfidence,
                     "evidence": "owner-local fill to stroke to exterior transitions",
                     "sourceFullPenWidthPixels": observed.sourceStrokeWidthPixels as Any? ?? NSNull(),
                     "paintWidthProvenance": "user-requested readability thickness; not calibrated source pen",
                     "weight": NSNull(), "slant": NSNull()]
                 } as Any? ?? NSNull(),
                 "fontSize": Double(card.style.fontSize), "lineHeight": Double(card.style.lineHeight),
                 "smallFontReadabilityImproved": readableFontIDs.contains(card.item.id),
                 "requestedFontRecoveryImproved": requestedFontIDs.contains(card.item.id),
                 "denseRequestedFontImproved": denseFontIDs.contains(card.item.id),
                 "finalClipInkRecovered": clipRecoveryIDs.contains(card.item.id),
                 "readabilityPeerInkRejected": readabilityRejected.contains(card.item.id),
                 "readabilityPeerInkRejectionReason": readabilityRejectionReasons[card.item.id] as Any? ?? NSNull(),
                 "reducedWaistFitImproved": waistPreviousFonts[card.item.id] != nil,
                 "capacityFitRecovered": capacityRecoveredIDs.contains(card.item.id),
                 "waistFontBefore": waistPreviousFonts[card.item.id].map { Double($0) } as Any? ?? NSNull(),
                 "tracking": Double(card.style.tracking), "horizontalScale": Double(card.style.horizontalScale),
                 "currentAlignmentModel": card.style.horizontalAlignment == .left ? "left"
                    : card.style.horizontalAlignment == .right ? "right" : "center",
                 "currentAlignmentModelProvenance": "committed style model; not observed original alignment",
                 "committedAlignmentAnchors": card.unitTextParts.isEmpty && card.effectiveTextRotation == 0 && !card.item.vertical
                    ? (NativeTranslationTypography.committedRowAlignmentAnchors(layout: card.typography,
                        alignment: card.style.horizontalAlignment, origin: card.textOrigin,
                        pixelSnapScale: capturePDF ? pdfDeviceScale : nil).map { $0.map(Double.init) } as Any? ?? NSNull()) : NSNull(),
                 "rotation": Double(card.item.rotation), "vertical": card.item.vertical,
                 "fits": card.typography.fits, "lineCount": card.typography.lineCount,
                 "visibleUTF16Range": [card.typography.visibleUTF16Range.location, card.typography.visibleUTF16Range.length],
                 "shapedUTF16Length": card.typography.shapedText.utf16.count,
                 "inputUTF16Length": (card.item.typesettingText ?? card.item.text).utf16.count,
                 "paintUTF16Length": card.typography.shapedText.utf16.count,
                 "visibleUTF16RangeAuthority": "producer input UTF16; not paint string or decoded final glyph coverage",
                 "fromManualWrap": card.typography.fromManualWrap as Any? ?? NSNull(),
                 "finalSealedGlyphCompleteness": NSNull(),
                 "finalRasterTextCompleteness": NSNull(),
                 "horizontalRowMetrics": card.unitTextParts.isEmpty && card.effectiveTextRotation == 0 && !card.item.vertical
                    ? (NativeTranslationTypography.horizontalRowMetrics(layout: card.typography,
                        originalText: card.item.typesettingText ?? card.item.text, origin: card.textOrigin,
                        pixelSnapScale: capturePDF ? pdfDeviceScale : nil) as Any? ?? NSNull()) : NSNull(),
                 "localGlyphBounds": card.typography.glyphBounds.map(diagnosticRect),
                 "textOrigin": [Double(card.textOrigin.x), Double(card.textOrigin.y)],
                 "textBoxGeometryParameters": settings.textBoxGeometryParameters.diagnosticValues,
                 "localRangeBounds": card.typography.rangeBounds.map(diagnosticRect),
                 "backgroundRefined": false,
                 "backgroundPrediction": panelColorPredictions[card.item.id] as Any? ?? NSNull(),
                 "backgroundConfidence": NSNull(),
                 "backgroundReason": panelColorEvidence[card.item.id] ?? "source-color-unavailable",
                 "backgroundSurfaceColorEvidence": panelSurfaceColorEvidence[card.item.id] ?? "surface-unavailable",
                 "initialBackgroundModelObservation": initialBGBudget.observations[card.item.id] as Any? ?? NSNull(),
                 "initialBGHostObservation": retryBGBudget.observations[card.item.id] as Any? ?? NSNull(),
                 "initialBGWork": ["primary": initialBGBudget.spent, "retry": retryBGBudget.spent,
                    "primaryRemaining": initialBGBudget.remaining, "retryRemaining": retryBGBudget.remaining],
                 "backgroundCorrectionEligible": false,
                 "sourceOwner": ownerByID[card.item.id].map(diagnosticRect) ?? []]
            }
        ], options: [.sortedKeys]) : nil
        // Width is the last paint-mutating stage. Consume its owned final world, not a rebuilt mutable card list.
        if sealedWidth != nil, let receipt = widthSession.accepted {
            return retainedWidthPreparedRender(receipt,
                diagnosticData: try widthSession.boundDiagnostics(diagnosticData))
        }
        return PreparedRender(inputLayout: layout, layout: layout, image: image, source: source,
            restoration: .init(), cards: cards, glossCards: [], gloss: .init(), settings: settings,
            bounds: bounds, pixels: outputPixels, scale: scale, composeSource: composeSource,
            capturePDF: capturePDF, pdfDeviceScale: pdfDeviceScale, sourcePatches: [], sourcePieces: [],
            limitations: limitations, diagnosticData: diagnosticData)
    }

    static func textBoxFillContrast(_ fill: [Double], panel: [Double]) -> Double {
        let a = NativeSourceColorSampler.luminance(fill)
        let b = NativeSourceColorSampler.luminance(panel)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Preserve readable original colors; otherwise minimally blend fill alone.
    /// Unknown/invalid RGB is not an accurate prediction or a successful measurement.
    static func textBoxReadableOutlineWidth(fontSize: CGFloat) -> CGFloat {
        guard fontSize.isFinite, fontSize > 0 else { return 0 }
        // Display-only readability override; the independently predicted stroke RGB stays unchanged.
        return max(2.25, fontSize * 0.18)
    }

    /// An OCR column quadrilateral angle is not an instruction to tilt translated horizontal captions.
    static func uprightTranslatedSourceColumn(_ item: NativeTranslationLayoutItem) -> Bool {
        item.sourceVertical && !item.vertical && !item.keptLettering && !item.sourceTextOnly
            && item.balloonInterior == nil && item.balloonUnit == nil
    }

    static func sourceCaptionTopGroups(items: [NativeTranslationLayoutItem], owners: [CGRect],
                                      knownProxies: [String: CGFloat] = [:]) -> [[Int]] {
        guard items.count == owners.count, items.count <= 128 else { return [] }
        func proxy(_ index: Int) -> CGFloat? {
            let observed = knownProxies[items[index].id].flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            return observed ?? items[index].sourceFontSize.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        let candidates = items.indices.filter {
            uprightTranslatedSourceColumn(items[$0]) && valid(owners[$0])
                && proxy($0) != nil
        }.sorted { owners[$0].minX < owners[$1].minX }
        var groups: [[Int]] = []
        for index in candidates {
            var matched = false
            for groupIndex in groups.indices {
                let group = groups[groupIndex] + [index]
                let fonts = group.compactMap(proxy)
                let observedFonts = group.compactMap { knownProxies[items[$0].id] }
                    .filter { $0.isFinite && $0 > 0 }
                if let smallest = observedFonts.min(), let largest = observedFonts.max(), observedFonts.count >= 2,
                   largest / smallest > CGFloat(NativeSourceLetteringScale.qualityThresholds.maximumAggregateLaneRatio) {
                    continue // Supported distinct source scales retain emphasis.
                }
                guard let minFont = fonts.min(), let maxFont = fonts.max(),
                      let minTop = group.map({ owners[$0].minY }).min(),
                      let maxTop = group.map({ owners[$0].minY }).max(),
                      let right = groups[groupIndex].map({ owners[$0].maxX }).max(),
                      maxFont / minFont <= 2, maxTop - minTop <= maxFont * 0.25,
                      max(0, owners[index].minX - right) <= maxFont * 8 else { continue }
                groups[groupIndex].append(index)
                matched = true
                break
            }
            if !matched { groups.append([index]) }
        }
        return groups.filter { $0.count >= 2 }
    }

    /// Complete painted ink, including the current outline, translated rigidly
    /// with its first baseline. This is search geometry, not a raster certificate.
    static func captionBaselineInterval(ink: CGRect, baseline: CGFloat, space: CGRect) -> ClosedRange<CGFloat>? {
        guard valid(ink), valid(space), baseline.isFinite,
              ink.minX >= space.minX, ink.maxX <= space.maxX else { return nil }
        let lower = baseline + space.minY - ink.minY
        let upper = baseline + space.maxY - ink.maxY
        guard lower.isFinite, upper.isFinite, lower <= upper else { return nil }
        return lower...upper
    }

    /// A visible opaque outline may supply contrast without replacing the source fill.
    /// This is a readability policy, not a source-accuracy or WCAG certificate.
    static func textBoxOutlineSupportsForeground(_ fill: [Double], panel: [Double], outline: [Double]?,
                                                visibleOutlinePixels: Double, opaqueStrokeThenFill: Bool) -> Bool {
        guard opaqueStrokeThenFill, visibleOutlinePixels.isFinite, visibleOutlinePixels >= 1,
              let outline, [fill, panel, outline].allSatisfy({
                  $0.count == 3 && $0.allSatisfy { $0.isFinite && (0...255).contains($0) }
              }) else { return false }
        return textBoxFillContrast(fill, panel: outline) >= 3 && textBoxFillContrast(outline, panel: panel) >= 3
    }

    static func textBoxReadableForeground(_ fill: [Double], panel: [Double], outline: [Double]? = nil,
                                         visibleOutlinePixels: Double = 0, opaqueStrokeThenFill: Bool = false) -> [Double]? {
        guard [fill, panel].allSatisfy({ $0.count == 3 && $0.allSatisfy { $0.isFinite && (0...255).contains($0) } }) else { return nil }
        let target = 4.5
        if textBoxFillContrast(fill, panel: panel) >= target
            || textBoxOutlineSupportsForeground(fill, panel: panel, outline: outline,
                visibleOutlinePixels: visibleOutlinePixels, opaqueStrokeThenFill: opaqueStrokeThenFill) { return fill }
        var candidates: [[Double]] = []
        for endpoint in [0.0, 255.0] {
            let extreme = [endpoint, endpoint, endpoint]
            guard textBoxFillContrast(extreme, panel: panel) >= target else { continue }
            var low = 0.0, high = 1.0
            for _ in 0..<24 {
                let amount = (low + high) / 2
                let trial = fill.map { $0 + (endpoint - $0) * amount }
                if textBoxFillContrast(trial, panel: panel) >= target { high = amount } else { low = amount }
            }
            // Round away from the original toward the endpoint, keeping byte paint safe.
            candidates.append(fill.map { value in
                let channel = value + (endpoint - value) * high
                return endpoint == 0 ? floor(channel) : ceil(channel)
            })
        }
        return candidates.min { lhs, rhs in
            zip(lhs, fill).reduce(0) { $0 + pow($1.0 - $1.1, 2) }
                < zip(rhs, fill).reduce(0) { $0 + pow($1.0 - $1.1, 2) }
        }
    }

    static func textBoxSurroundingColor(item: NativeTranslationLayoutItem, layout: NativeTranslationLayout,
                                       source: CGImage?, reader: NativeSourcePixelReader?, excluded: [CGRect]) throws -> [Double]? {
        guard let source, let reader, item.sourceBounds.count == 4 else { return nil }
        let b = item.sourceBounds, frame = layout.sourceRect
        let inner = CGRect(x: frame.minX + b[0] * frame.width, y: frame.minY + b[1] * frame.height,
                           width: b[2] * frame.width, height: b[3] * frame.height)
        guard valid(inner) else { return nil }
        let margin = max(3, min(12, min(inner.width, inner.height) * 0.15))
        let outer = inner.insetBy(dx: -margin, dy: -margin).intersection(frame)
        guard valid(outer) else { return nil }
        let nearbyText = excluded.filter { $0.intersects(outer) }
        guard let projection = NativeTextBoxSourceProjection.project(outer, frame: frame,
            sourceSize: CGSize(width: source.width, height: source.height)) else { return nil }
        let width = 96, height = 96
        let rgba = try reader.read(x: Double(projection.minX), y: Double(projection.minY),
            sourceWidth: Double(projection.width), sourceHeight: Double(projection.height), width: width, height: height)
        var bins: [Int: [[UInt8]]] = [:]
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let point = CGPoint(x: outer.minX + (CGFloat(x) + 0.5) * outer.width / CGFloat(width),
                                    y: outer.minY + (CGFloat(y) + 0.5) * outer.height / CGFloat(height))
                guard !inner.contains(point), !nearbyText.contains(where: { $0.contains(point) }) else { continue }
                let offset = (y * width + x) * 4
                guard rgba[offset + 3] >= 240 else { continue }
                let red = Double(rgba[offset])
                let green = Double(rgba[offset + 1])
                let blue = Double(rgba[offset + 2])
                let key = (Int(red) / 32) * 64 + (Int(green) / 32) * 8 + Int(blue) / 32
                bins[key, default: []].append([rgba[offset], rgba[offset + 1], rgba[offset + 2]])
            }
        }
        guard let key = bins.keys.sorted().max(by: { bins[$0]!.count < bins[$1]!.count }),
              let samples = bins[key], !samples.isEmpty else { return nil }
        // A glyph's antialiased white halo can share the paper's quantized bin.
        // Its mean biases even a flat authored background; the dominant-bin
        // channel median keeps that contamination from becoming the panel paint.
        return (0..<3).map { channel in
            let values = samples.map { $0[channel] }.sorted()
            let middle = values.count / 2
            return values.count.isMultiple(of: 2)
                ? ((Double(values[middle - 1]) + Double(values[middle])) / 2).rounded()
                : Double(values[middle])
        }
    }
}

// Independent original-pixel prediction before shaping; never a post-paint color correction.
enum NativeOwnerExteriorBGPrediction {
    /// Source color extraction has no per-page or per-owner work quota.
    static func primaryWorkLimit(eligibleOwnerCount: Int) -> Int {
        Int.max
    }
    struct CachedObservation {
        let rgb: [Double]?
        let work: Int
        let charges: [ChargeRun]
        let evidence: [String: Any]
    }
    struct ChargeRun {
        let cost: Int
        var count: Int
    }
    final class Budget {
        var observations: [String: [String: Any]] = [:]
        var remaining = Int.max
        var spent = 0
        var exhausted = false
        var recording = false
        var charges: [ChargeRun] = []
        func replay(_ runs: [ChargeRun]) -> Bool {
            guard remaining >= 0 else { exhausted = true; return false }
            for run in runs {
                guard run.cost >= 0, run.count >= 0 else { exhausted = true; return false }
                let available = remaining == .max || run.cost == 0 ? run.count : min(run.count, remaining / run.cost)
                let (work, overflow) = available.multipliedReportingOverflow(by: run.cost)
                let (total, totalOverflow) = spent.addingReportingOverflow(work)
                guard !overflow, !totalOverflow else { return false }
                if remaining != .max { remaining -= work }
                spent = total
                if available < run.count { exhausted = true; return false }
            }
            return true
        }
        func charge(_ n: Int = 1) -> Bool {
            guard n >= 0 else { exhausted = true; return false }
            if recording {
                if let last = charges.last, last.cost == n { charges[charges.count - 1].count += 1 }
                else { charges.append(.init(cost: n, count: 1)) }
            }
            guard remaining == .max || remaining >= n else { exhausted = true; return false }
            let (total, overflow) = spent.addingReportingOverflow(n)
            guard !overflow else { return false }
            if remaining != .max { remaining -= n }
            spent = total
            return true
        }
    }
    static func predict(rgba: [UInt8], width: Int, height: Int, roi: CGRect,
                        owner: CGRect, peers: [CGRect], budget: Budget, id: String) throws -> [Double]? {
        guard budget.charge(13 + 4 * peers.count) else {
            budget.observations[id] = ["id": id, "accepted": false, "status": "quota",
                "remainingPageWork": budget.remaining, "work": 0]
            return nil
        }
        guard width >= 8, height >= 8, width <= 320, height <= 320,
              rgba.count == width * height * 4, roi.contains(owner),
              [roi.minX, roi.minY, roi.width, roi.height, owner.minX, owner.minY, owner.width, owner.height]
                .allSatisfy({ $0.isFinite }), roi.width > 0, roi.height > 0, owner.width > 0, owner.height > 0,
              peers.allSatisfy({ [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }) else {
            budget.observations[id] = ["id": id, "accepted": false, "status": "invalid-geometry",
                "remainingPageWork": budget.remaining, "work": 13 + 4 * peers.count]
            return nil
        }
        let start = budget.spent
        let margin = max(3, min(12, min(owner.width, owner.height) * 0.15))
        let inner = owner.insetBy(dx: -margin, dy: -margin).intersection(roi)
        let outer = owner.insetBy(dx: -2 * margin, dy: -2 * margin).intersection(roi)
        // Sample centres lie strictly inside this ROI. Disjoint peers cannot
        // contain them; keep validation above and all intersecting peers intact.
        let samplingPeers = peers.filter {
            let intersection = $0.intersection(roi)
            return !intersection.isNull && !intersection.isEmpty
        }
        func model(_ area: CGRect, excluding: CGRect?) throws -> [String: Any] {
            var fit: [[Int]] = [], hold: [[Int]] = [], sides = [Int](repeating: 0, count: 4), seen: Set<Int> = []
            var partitionSamples: [(index: Int, rgb: [Int], side: Int)] = []
            for y in 0..<32 {
                try Task.checkCancellation()
                for x in 0..<32 {
                    guard budget.charge() else { return ["status": "quota"] }
                    let p = CGPoint(x: area.minX + (Double(x) + 0.5) * area.width / 32,
                                    y: area.minY + (Double(y) + 0.5) * area.height / 32)
                    let px = Int(floor((p.x - roi.minX) / roi.width * Double(width)))
                    let py = Int(floor((p.y - roi.minY) / roi.height * Double(height)))
                    guard px >= 0, px < width, py >= 0, py < height else { continue }
                    let index = py * width + px
                    guard seen.insert(index).inserted else { continue }
                    let point = CGPoint(x: roi.minX + (Double(px) + 0.5) * roi.width / Double(width),
                                        y: roi.minY + (Double(py) + 0.5) * roi.height / Double(height))
                    guard !(excluding?.contains(point) ?? false), !owner.contains(point) else { continue }
                    guard budget.charge() else { return ["status": "quota"] }
                    guard rgba[index * 4 + 3] >= 240 else { continue }
                    var blocked = false
                    for peer in samplingPeers {
                        guard budget.charge() else { return ["status": "quota"] }
                        if peer.contains(point) { blocked = true; break }
                    }
                    guard !blocked, budget.charge(3) else { if budget.exhausted { return ["status": "quota"] }; continue }
                    let rgb = (0..<3).map { Int(rgba[index * 4 + $0]) }
                    let partitionSide = point.x < owner.minX ? 0 : point.x >= owner.maxX ? 1 : point.y < owner.minY ? 2 : 3
                    partitionSamples.append((index, rgb, partitionSide))
                    if index % 3 == 2 { hold.append(rgb) } else {
                        fit.append(rgb)
                        let side = point.x < owner.minX ? 0 : point.x >= owner.maxX ? 1 : point.y < owner.minY ? 2 : 3
                        sides[side] += 1
                    }
                }
            }
            // Retain an already supported partition byte-for-byte. Only an
            // underpopulated lattice partition gets a deterministic re-partition;
            // acceptance counts and RGB consensus thresholds remain unchanged.
            if fit.count < 24 || hold.count < 8 || sides.filter({ $0 >= 8 }).count < 2 {
                fit.removeAll(keepingCapacity: true); hold.removeAll(keepingCapacity: true)
                sides = [Int](repeating: 0, count: 4)
                for sample in partitionSamples {
                    var key = UInt64(sample.index) &+ 0x9e3779b97f4a7c15
                    key = (key ^ (key >> 30)) &* 0xbf58476d1ce4e5b9
                    key = (key ^ (key >> 27)) &* 0x94d049bb133111eb
                    key ^= key >> 31
                    if key % 3 == 2 { hold.append(sample.rgb) }
                    else { fit.append(sample.rgb); sides[sample.side] += 1 }
                }
            }
            guard fit.count >= 24, hold.count >= 8, sides.filter({ $0 >= 8 }).count >= 2 else {
                return ["status": "insufficient", "fit": fit.count, "hold": hold.count]
            }
            var bins: [Int: Int] = [:]
            for c in fit {
                guard budget.charge() else { return ["status": "quota"] }
                let key = c[0] / 32 * 64 + c[1] / 32 * 8 + c[2] / 32
                bins[key, default: 0] += 1
            }
            var winning = -1, count = 0
            for (key, n) in bins {
                guard budget.charge() else { return ["status": "quota"] }
                if n > count || (n == count && key > winning) { winning = key; count = n }
            }
            guard budget.charge(768) else { return ["status": "quota"] }
            var hist = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
            for c in fit {
                guard budget.charge() else { return ["status": "quota"] }
                let key = c[0] / 32 * 64 + c[1] / 32 * 8 + c[2] / 32
                if key == winning {
                    guard budget.charge(3) else { return ["status": "quota"] }
                    for k in 0..<3 { hist[k][c[k]] += 1 }
                }
            }
            var median = [Int](repeating: 0, count: 3)
            for k in 0..<3 {
                var n = 0
                for value in 0..<256 {
                    guard budget.charge() else { return ["status": "quota"] }
                    n += hist[k][value]
                    if n > count / 2 { median[k] = value; break }
                }
            }
            func matching(_ values: [[Int]]) -> Int? {
                var n = 0
                for c in values {
                    guard budget.charge(3) else { return nil }
                    if (0..<3).allSatisfy({ abs(c[$0] - median[$0]) <= 12 }) { n += 1 }
                }
                return n
            }
            guard let f = matching(fit), let h = matching(hold) else { return ["status": "quota"] }
            let accepted = Double(f) >= Double(fit.count) * 0.8 && Double(h) >= Double(hold.count) * 0.8
            return ["status": accepted ? "consensus" : "ambiguous", "rgb": accepted ? median as Any : NSNull(),
                    "mode": median, "fit": fit.count, "hold": hold.count, "fitMatching": f, "holdMatching": h]
        }
        let first = try model(inner, excluding: nil)
        if first["status"] as? String == "quota" {
            budget.observations[id] = ["id": id, "accepted": false, "status": "quota", "inner": first,
                "remainingPageWork": budget.remaining, "work": budget.spent - start]
            return nil
        }
        let second = try model(outer, excluding: inner)
        let a = first["rgb"] as? [Int], b = second["rgb"] as? [Int]
        let accepted = a != nil && b != nil && (0..<3).allSatisfy({ abs(a![$0] - b![$0]) <= 12 })
        let result = accepted ? a!.map(Double.init) : nil
        budget.observations[id] = ["id": id, "accepted": accepted, "rgb": result as Any? ?? NSNull(),
                      "inner": first, "outer": second, "work": budget.spent - start,
                      "remainingPageWork": budget.remaining, "authority": "source spatial model; not RGBGT"]
        return result
    }
}
