import CoreGraphics
import Foundation
import UIKit

extension NativeTranslationRenderer {
    /// The source guard is fixed. Reflow the translation into a complete interior
    /// rectangle; never cut paint, change source color roles, or omit a paragraph.
    static func containBalloonPanels(cards: inout [Card], owners: [String: CGRect],
                                     surfaces: inout [String: NativeTextBoxContainment.Surface],
                                     source: CGImage?, sourceRect: CGRect, outputScale: CGFloat,
                                     parameters: NativeTextBoxGeometryParameters,
                                     sourcePredictions: [String: [String: Any]], requestedFonts: [String: CGFloat],
                                     requestedFrames: [String: CGRect], coverageRegions: [String: CGRect],
                                     backingInvariants: [String: NativeTextBoxContainment.BackingInvariant] = [:],
                                     allowIndependentText: Bool? = nil) throws {
        let reader = source.map { NativeSourcePixelReader(image: $0, preservesSamplingGeometry: true) }
        defer { reader?.release() }
        var geometryPixels = 2_000_000
        var shapingWork = 131_072
        let snapshot = cards
        let initialSurfaces = surfaces
        var independentAccepted = false
        func paintedGlyphs(_ card: Card) -> [CGRect] {
            guard card.effectiveTextRotation == 0, card.unitTextParts.isEmpty else { return [cardInkRect(card)] }
            return card.typography.glyphBounds.map {
                $0.offsetBy(dx: card.textOrigin.x, dy: card.textOrigin.y)
                    .insetBy(dx: -card.style.outlineGlow, dy: -card.style.outlineGlow)
            }.filter(valid)
        }
        func rowDebts(_ card: Card) -> (single: Int, cuts: Int)? {
            guard let rows = NativeTranslationTypography.horizontalRowMetrics(layout: card.typography,
                originalText: card.item.text) else { return nil }
            return (rows.filter { $0["singleHangulLetterRow"] as? Bool == true }.count,
                    rows.filter { $0["tokenCutAfterRowProxy"] as? Bool == true }.count)
        }
        let baselineGlyphs = snapshot.map(paintedGlyphs)
        let pixelGuard = max(0.35, 1 / max(0.001, outputScale))
        let boundaryInset = 1 / max(0.001, outputScale)
        let experimentIndependentText = allowIndependentText
            ?? (ProcessInfo.processInfo.environment["AIDOKU_DISABLE_INDEPENDENT_TEXT_DOMAIN"] != "1")
        func area(_ r: CGRect) -> CGFloat { valid(r) ? r.width * r.height : 0 }
        for index in cards.indices {
            try Task.checkCancellation()
            let original = cards[index]
            guard original.drawsPanel, original.textPaintDomain == nil, original.unitTextParts.isEmpty,
                  original.effectiveTextRotation == 0, let owner = owners[original.item.id],
                  var surface = surfaces[original.item.id] else { continue }
            guard let invariant = backingInvariants[original.item.id]
                ?? NativeTextBoxContainment.BackingInvariant(baseline: original.sourcePlateRect, surface: surface,
                    protectedRects: owners.filter { $0.key != original.item.id }.map(\.value)) else { continue }
            let baselineDebt = rowDebts(original)
            let outside = !surface.contains(original.sourcePlateRect)
            let crampedRows = NativeTranslationTypography.minimumPaintedRowGap(layout: original.typography)
                .map { $0 < boundaryInset } ?? false
            let recovery = original.item.text.count > 3 && original.item.wrappingScript == "korean"
                && (crampedRows || ((baselineDebt.map { $0.single + $0.cuts > 0 } ?? false)
                && (requestedFonts[original.item.id] ?? 0) > original.style.fontSize * 1.15))
            guard outside || recovery else { continue }
            let guardSize = parameters.sourceGuard(owner: owner, sourceFontSize: original.item.sourceFontSize ?? 0,
                outputOutline: original.style.outlineWidth, panelPadding: pixelGuard)
            // Retain all existing source-margin coverage, not the oversized text-search frame.
            var required = owner.union(owner.insetBy(dx: -guardSize, dy: -guardSize)
                .intersection(original.sourcePlateRect)).intersection(sourceRect)
            var resampled = false
            var boundedGuard = guardSize
            if !surface.contains(required), let source, let reader {
                // A supplied "verified" row contour can actually follow lettering
                // holes. Re-observe the enclosed balloon in source pixels, GEOMETRY
                // ONLY; all already predicted/displayed colors remain unchanged.
                let roi = surface.rect.union(required).insetBy(dx: -8, dy: -8).intersection(sourceRect)
                if let projection = NativeTextBoxSourceProjection.project(roi, frame: sourceRect,
                    sourceSize: CGSize(width: source.width, height: source.height)) {
                    let width = Int(min(320, max(8, ceil(projection.width))))
                    let height = Int(min(320, max(8, ceil(projection.height))))
                    if width * height <= geometryPixels {
                        geometryPixels -= width * height
                        let rgba = try reader.read(x: Double(projection.minX), y: Double(projection.minY),
                            sourceWidth: Double(projection.width), sourceHeight: Double(projection.height),
                            width: width, height: height)
                        if let observed = try NativeTextBoxContainment.measured(rgba: rgba, width: width, height: height,
                            roi: roi, owner: owner, excluding: owners.filter { $0.key != original.item.id }.map(\.value)),
                           observed.certifiedSpans, observed.geometryObserved {
                            surface = .init(rect: observed.rect, spans: observed.spans, color: surface.color,
                                colorEvidence: surface.colorEvidence, geometryObserved: observed.geometryObserved)
                            resampled = true
                        }
                    }
                }
            }
            var witnessed = owner
            var observedSource = CGRect.null
            if let source, let reader, let prediction = sourcePredictions[original.item.id],
               let fill = NativeSourceColorSampler.rgb(prediction["foreground"]),
               let background = rgb(original.background) {
                // Missing display-outline prediction is not proof that original
                // source lettering has no outline. Observe conservative extrema
                // as coverage hypotheses ONLY; do not invent a rendered stroke.
                let strokes = NativeSourceColorSampler.rgb(prediction["stroke"]).map { [$0] }
                    ?? [[0.0, 0.0, 0.0], [255.0, 255.0, 255.0]]
                // Inspect the backing BEFORE any tightening. Otherwise a narrow
                // owner can first expose an unassigned original column, then the
                // subsequent witness never even samples those lost pixels.
                let roi = (coverageRegions[original.item.id] ?? original.sourcePlateRect).intersection(sourceRect)
                if let projection = NativeTextBoxSourceProjection.project(roi, frame: sourceRect,
                    sourceSize: CGSize(width: source.width, height: source.height)) {
                    let width = Int(min(320, max(8, ceil(projection.width))))
                    let height = Int(min(320, max(8, ceil(projection.height))))
                    if width * height <= geometryPixels {
                        geometryPixels -= width * height
                        let rgba = try reader.read(x: Double(projection.minX), y: Double(projection.minY),
                            sourceWidth: Double(projection.width), sourceHeight: Double(projection.height), width: width, height: height)
                        for stroke in strokes {
                            if let evidence = try NativeSourceCoverageWitness.evidence(rgba: rgba, width: width, height: height,
                                roi: roi, surface: surface, foreground: fill, stroke: stroke, background: background,
                                peers: owners.filter { $0.key != original.item.id }.map(\.value),
                                maximumGlyphSpan: original.item.sourceFontSize.map { max(4, $0) * 2 }) {
                                // A color witness may add missing original coverage,
                                // never subtract the saved source ownership obligation.
                                observedSource = observedSource.union(evidence.bounds)
                                witnessed = witnessed.union(evidence.bounds)
                            }
                        }
                        required = witnessed.union(witnessed.insetBy(dx: -guardSize, dy: -guardSize)
                            .intersection(original.sourcePlateRect)).intersection(sourceRect)
                    }
                }
            }
            // A wider re-observation cannot silently supersede an earlier admitted
            // contour. If source coverage fits that contour, repair against it and
            // reduce only the optional margin using the existing boundary policy.
            if let frozen = invariant.surface, frozen.contains(witnessed) { surface = frozen }
            if !surface.contains(required.insetBy(dx: -boundaryInset, dy: -boundaryInset)) {
                // A display-outline-driven blanket margin is not source ink.
                // Preserve the complete OCR owner plus at least an output-pixel
                // guard, and reduce only surplus margin at a closed balloon edge.
                func sourceEnvelope(_ margin: CGFloat) -> CGRect {
                    witnessed.union(witnessed.insetBy(dx: -margin, dy: -margin)
                        .intersection(original.sourcePlateRect)).intersection(sourceRect)
                }
                if surface.contains(sourceEnvelope(pixelGuard).insetBy(dx: -boundaryInset, dy: -boundaryInset)) {
                    var low = pixelGuard, high = guardSize
                    for _ in 0..<12 {
                        let middle = (low + high) / 2
                        if surface.contains(sourceEnvelope(middle).insetBy(dx: -boundaryInset, dy: -boundaryInset)) {
                            low = middle
                        } else { high = middle }
                    }
                    boundedGuard = low
                    required = sourceEnvelope(low)
                }
            }
            cards[index].harmonyRecord["balloonPanelContainmentStatus"] = "source-guard-or-contour-infeasible"
            cards[index].harmonyRecord["balloonPanelGeometryResampled"] = resampled
            if valid(observedSource) {
                cards[index].harmonyRecord["balloonPanelObservedSourceBounds"] = [Double(observedSource.minX),
                    Double(observedSource.minY), Double(observedSource.width), Double(observedSource.height)]
            }
            cards[index].harmonyRecord["balloonPanelCoveringWitness"] = [Double(witnessed.minX), Double(witnessed.minY),
                Double(witnessed.width), Double(witnessed.height)]
            cards[index].harmonyRecord["balloonPanelRejection"] = surface.contains(owner)
                ? "required-source-margin-or-witness-outside-observed-interior" : "source-owner-outside-observed-interior"
            var layoutOnly = !surface.contains(required)
            let peers = snapshot.indices.filter { $0 != index }
            let livePanels = cards.map(\.sourcePlateRect)
            let liveGlyphs = cards.map(paintedGlyphs)
            func glyphOverlap(_ a: [CGRect], _ b: [CGRect]) -> CGFloat {
                a.reduce(0) { sum, glyph in sum + b.reduce(0) { $0 + area(glyph.intersection($1)) } }
            }
            let oldGlyphOverlaps = peers.map { glyphOverlap(baselineGlyphs[index], baselineGlyphs[$0]) }
            // A roomy/compound contour is not authority to erase new artwork for
            // larger translated type. Bound each card's search by its incumbent
            // backing and independently established source coverage. Include the
            // searcher's clearance halo so an exact new coverage edge is reachable;
            // admission below rejects painting that halo or unrequired corners.
            let coverageLimit = original.sourcePlateRect.union(required)
                .intersection(invariant.baseline.union(required))
                .insetBy(dx: -boundaryInset, dy: -boundaryInset).intersection(sourceRect)
            let admission: (CGRect) -> Bool = { panel in
                NativeTextBoxContainment.addsOnlyRequiredSourceCoverage(panel: panel,
                    baseline: original.sourcePlateRect, required: required)
                && invariant.admits(panel, required: required) && peers.allSatisfy({ peer in
                    area(panel.intersection(livePanels[peer]))
                        <= area(original.sourcePlateRect.intersection(snapshot[peer].sourcePlateRect)) + 1e-9
                }) && owners.filter({ $0.key != original.item.id }).allSatisfy({ _, peer in
                    area(panel.intersection(peer)) <= area(original.sourcePlateRect.intersection(peer)) + 1e-9
                })
            }
            let initialPanel = surface.rectangularPanel(covering: required, near: original.sourcePlateRect,
                within: original.sourcePlateRect, accepts: admission, allowsExactCover: true, boundaryInset: boundaryInset)
                ?? surface.rectangularPanel(covering: required, near: original.sourcePlateRect,
                    within: surface.rect.intersection(coverageLimit), accepts: admission, allowsExactCover: true,
                    boundaryInset: boundaryInset)
            var panels: [CGRect] = layoutOnly ? [original.sourcePlateRect] : initialPanel.map { [$0] } ?? []
            if !layoutOnly, let requested = requestedFrames[original.item.id] {
                let width = max(required.width, min(surface.rect.width, requested.width + original.style.outlineWidth + pixelGuard * 2))
                let height = max(required.height, min(surface.rect.height, requested.height))
                let desired = CGRect(x: required.midX - width / 2, y: required.midY - height / 2,
                    width: width, height: height)
                if let wider = surface.rectangularPanel(covering: required, near: desired,
                    within: surface.rect.intersection(coverageLimit), accepts: admission, allowsExactCover: true,
                    boundaryInset: boundaryInset), !panels.contains(wider) { panels.append(wider) }
            }
            // An unchanged opaque backing cannot expose any additional source or
            // paint new artwork. A witness extending outside it remains unresolved,
            // but must not prohibit independently safe text-only capacity repair.
            // This is paint identity, NOT an alternate guard for changed backings.
            let retainedLayoutBacking = original.background.alpha == 1
                && original.textBoxBackgroundClip == nil && !original.sourceLayersSuppressed
                ? NativeTextBoxContainment.RetainedLayoutBacking(panel: original.sourcePlateRect, owner: owner) : nil
            panels = panels.filter {
                if layoutOnly { return retainedLayoutBacking?.accepts($0) == true }
                return invariant.admits($0, required: required) && surface.contains($0) && admission($0)
            }
            // A source envelope can fit the surface while no complete expanded
            // rectangle satisfies its corners/foreign-space constraints. Never
            // weaken those constraints: try paint-identical text repair instead.
            if panels.isEmpty, let retainedLayoutBacking {
                layoutOnly = true
                panels = [retainedLayoutBacking.panel]
            }
            guard !panels.isEmpty else {
                cards[index].harmonyRecord["balloonPanelContainmentStatus"] = "peer-space-infeasible"
                continue
            }
            let inset = original.style.outlineWidth / 2
                + pixelGuard * CGFloat(parameters.translationPaddingScale ?? 1)
            let text = original.item.typesettingText ?? original.item.text
            var accepted: Card?
            var rejections: [String: Int] = [:]
            var textFrameCache: [Int: [CGRect]] = [:]
            func reject(_ reason: String) { rejections[reason, default: 0] += 1 }
            let requestedFont = (requestedFonts[original.item.id] ?? original.style.fontSize)
                * CGFloat(parameters.translationFontRecoveryScale ?? 1)
            let maximumFont = max(original.style.fontSize, min(requestedFont,
                original.style.fontSize * 2))
            let fonts = [maximumFont] + stride(from: Int(ceil(maximumFont * 4)) - 1,
                through: Int(ceil(BrowserOverlayLayoutPlanner.minimumRenderedFontSize * 4)), by: -1).map { CGFloat($0) / 4 }
            // Retained paint is a capacity/readability repair, not a reason to
            // shrink a paragraph that cannot receive new source-coverage paint.
            fontSearch: for font in fonts where !layoutOnly || font >= original.style.fontSize {
              for (panelIndex, panel) in panels.enumerated() {
                var textFrames = [panel]
                if let cached = textFrameCache[panelIndex] { textFrames = cached }
                else if layoutOnly {
                    let requested = requestedFrames[original.item.id] ?? original.item.rect
                    textFrames = []
                    // Erasure width/height are not translated shaping capacity.
                    // Try translation-derived widths and shorter full-width row
                    // windows, rather than forcing a tall source-column envelope.
                    var windows = [panel]
                    // Peer contact windows are shaping capacity, not source
                    // erasure cuts. Retain the complete backing while allowing a
                    // paragraph above, below or beside a separate annotation.
                    peerWindows: for peer in peers {
                        let ink = liveGlyphs[peer].reduce(CGRect.null) { $0.union($1) }
                            .insetBy(dx: -pixelGuard, dy: -pixelGuard)
                        guard valid(ink), panel.intersects(ink) else { continue }
                        let contacts = [
                            CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: ink.minY - panel.minY),
                            CGRect(x: panel.minX, y: ink.maxY, width: panel.width, height: panel.maxY - ink.maxY),
                            CGRect(x: panel.minX, y: panel.minY, width: ink.minX - panel.minX, height: panel.height),
                            CGRect(x: ink.maxX, y: panel.minY, width: panel.maxX - ink.maxX, height: panel.height)
                        ]
                        // CGRect normalizes reported width/height of negative
                        // sizes; raw size must be positive before admission.
                        for contact in contacts where contact.size.width > inset * 2
                            && contact.size.height > inset * 2 && valid(contact) && !windows.contains(contact) {
                            windows.append(contact)
                            if windows.count == 17 { break peerWindows }
                        }
                    }
                    for window in windows.prefix(17) {
                    for width in [window.width - pixelGuard * 2, requested.width,
                                  requested.width + original.style.outlineWidth + pixelGuard * 2,
                                  requested.width * 0.8] {
                        let wanted = CGRect(x: requested.minX, y: requested.minY,
                            width: min(window.width - pixelGuard * 2, width), height: window.height)
                        guard valid(wanted) else { continue }
                        if let frame = surface.inscribed(near: wanted, within: window), !textFrames.contains(frame) {
                            textFrames.append(frame)
                        }
                        for frame in surface.reducedHeightFrontier(near: wanted, within: window)
                            .sorted(by: { $0.width * $0.height > $1.width * $1.height }).prefix(8)
                            where !textFrames.contains(frame) { textFrames.append(frame) }
                    }
                    }
                    textFrameCache[panelIndex] = textFrames
                }
                if experimentIndependentText, !original.typography.fits,
                   surface.certifiedSpans, surface.geometryObserved {
                    if let wide = surface.inscribed(near: surface.rect, within: surface.rect),
                       !textFrames.contains(wide) { textFrames.append(wide) }
                    for frame in surface.reducedHeightFrontier(near: surface.rect, within: surface.rect)
                        .sorted(by: { $0.width * $0.height > $1.width * $1.height }).prefix(8)
                        where !textFrames.contains(frame) { textFrames.append(frame) }
                }
                for textFrame in textFrames {
                let independent = experimentIndependentText && !panel.contains(textFrame)
                let independentDomain = independent
                    ? TextPaintDomain(rect: surface.rect, polygon: surface.polygon, within: sourceRect) : nil
                if independent {
                    let distance = hypot(textFrame.midX - panel.midX, textFrame.midY - panel.midY)
                    guard independentDomain != nil,
                          distance <= hypot(panel.width, panel.height) * 0.45 else {
                        reject("independent-owner-anchor"); continue
                    }
                }
                for keepWords in [true, false] {
                    for compactPadding in [false, true] {
                        let cost = max(1, text.utf16.count)
                        guard cost <= shapingWork else { reject("page-shaping-budget"); break fontSearch }
                        shapingWork -= cost
                        var proposal = original
                        proposal.sourcePlateOwnerRect = panel; proposal.straightenedPanelRect = panel
                        proposal.textBoxClip = surface.polygon; proposal.textBoxBackgroundClip = nil
                        if independent { proposal.textPaintDomain = independentDomain }
                        proposal.item.x = textFrame.minX; proposal.item.y = textFrame.minY
                        proposal.item.width = textFrame.width; proposal.item.height = textFrame.height
                        proposal.item.paddingLeft = compactPadding ? inset : max(original.item.paddingLeft, inset)
                        proposal.item.paddingRight = compactPadding ? inset : max(original.item.paddingRight, inset)
                        proposal.item.paddingTop = compactPadding ? inset : max(original.item.paddingTop, inset)
                        proposal.item.paddingBottom = compactPadding ? inset : max(original.item.paddingBottom, inset)
                        proposal.textShift = .zero; proposal.typographyWidth = nil
                        proposal.style.fontSize = font
                        proposal.style.lineHeight = max(font * original.style.lineHeight / original.style.fontSize,
                            font * CGFloat(parameters.translationLineHeightScale ?? 1.05)
                                + original.style.outlineWidth + pixelGuard * 2)
                        proposal.style.tracking = original.style.tracking * font / original.style.fontSize
                        if keepWords { proposal.style.horizontalWrapping = .keepAll }
                        proposal.typography = NativeTranslationTypography.layout(text: text,
                            in: proposal.item.contentRect.size, style: proposal.style)
                        proposal.item.fontSize = font; proposal.item.lineHeight = proposal.style.lineHeight
                        proposal.finalFontSize = font
                        guard proposal.typography.fits,
                              NativeTranslationTypography.committedParagraphRawComplete(proposal.typography, original: text) else { reject("incomplete-fit"); continue }
                        if independent {
                            guard font >= original.style.fontSize,
                                  proposal.typography.lineCount <= original.typography.lineCount else {
                                reject("independent-readability-regression"); continue
                            }
                            let oldGap = NativeTranslationTypography.minimumPaintedRowGap(layout: original.typography)
                            let newGap = NativeTranslationTypography.minimumPaintedRowGap(layout: proposal.typography)
                            guard !original.typography.fits || font > original.style.fontSize + 0.01
                                || proposal.typography.lineCount < original.typography.lineCount
                                || (oldGap.map { $0 < boundaryInset } == true
                                    && newGap.map { $0 >= boundaryInset } == true) else {
                                reject("independent-no-readability-gain"); continue
                            }
                        }
                        let local = proposal.typography.glyphBounds.reduce(CGRect.null) { $0.union($1) }
                        var ink = local.offsetBy(dx: proposal.textOrigin.x, dy: proposal.textOrigin.y)
                            .insetBy(dx: -proposal.style.outlineGlow - pixelGuard,
                                     dy: -proposal.style.outlineGlow - pixelGuard)
                        // Nominal advances do not include shaped side bearings.
                        let inkLimit = independent ? surface.rect : panel
                        guard valid(ink), ink.width <= inkLimit.width, ink.height <= inkLimit.height else { reject("paint-exceeds-panel"); continue }
                        let dx = max(inkLimit.minX - ink.minX, min(0, inkLimit.maxX - ink.maxX))
                        let dy = max(inkLimit.minY - ink.minY, min(0, inkLimit.maxY - ink.maxY))
                        proposal.textShift.x += dx; proposal.textShift.y += dy
                        ink = ink.offsetBy(dx: dx, dy: dy)
                        let proposedGlyphs = paintedGlyphs(proposal)
                        if independent {
                            let glyphArea = proposedGlyphs.reduce(CGFloat.zero) { $0 + area($1) }
                            guard owners.allSatisfy({ id, protected in
                                if id == original.item.id { return true }
                                let overlap = proposedGlyphs.reduce(CGFloat.zero) {
                                    $0 + area($1.intersection(protected))
                                }
                                return overlap <= min(glyphArea * 0.01, area(protected) * 0.02)
                                    && proposedGlyphs.allSatisfy {
                                        !protected.contains(CGPoint(x: $0.midX, y: $0.midY))
                                    }
                            }) else { reject("independent-foreign-owner"); continue }
                        }
                        guard (independent ? surface.contains(ink) : panel.contains(ink)),
                              independent || !layoutOnly
                            || retainedLayoutBacking?.accepts(panel, paintedInk: ink, surface: surface) == true
                        else { reject("paint-outside-interior"); continue }
                        guard peers.enumerated().allSatisfy({ position, peer in
                            glyphOverlap(proposedGlyphs, liveGlyphs[peer]) <= oldGlyphOverlaps[position] + 1e-9
                        }) else { reject("peer-ink-collision"); continue }
                        if let baselineDebt {
                            guard let debt = rowDebts(proposal), debt.single <= baselineDebt.single,
                                  debt.cuts <= baselineDebt.cuts else { reject("word-wrap-regression"); continue }
                        }
                        if crampedRows, proposal.typography.lineCount > 1 {
                            guard let gap = NativeTranslationTypography.minimumPaintedRowGap(layout: proposal.typography),
                                  gap >= boundaryInset else { reject("painted-row-gap"); continue }
                        }
                        proposal.harmonyRecord["balloonPanelReadabilityObserved"] = baselineDebt != nil
                        accepted = proposal
                        break fontSearch
                    }
                }
                }
            }
            }
            guard var candidate = accepted else {
                cards[index].harmonyRecord["balloonPanelContainmentStatus"] = "complete-text-fit-infeasible"
                cards[index].harmonyRecord["balloonPanelCandidateRejections"] = rejections
                continue
            }
            candidate.harmonyRecord["balloonPanelContainmentStatus"] = layoutOnly
                ? "text-reflow-source-panel-uncontained" : (outside ? "contained-rectangle-reflow" : "contained-capacity-recovery")
            if layoutOnly {
                // Keep the actual geometry failure visible; text completeness is
                // not proof of full source-witness coverage or panel containment.
                candidate.harmonyRecord["balloonPanelRejection"] = surface.contains(owner)
                    ? (surface.contains(required) ? "source-coverage-rectangle-or-peer-space-infeasible"
                        : "required-source-margin-or-witness-outside-observed-interior") : "source-owner-outside-observed-interior"
                candidate.harmonyRecord["balloonPanelRetainedBackingLayoutOnly"] = true
                candidate.harmonyRecord["balloonPanelSourceWitnessCovered"] = original.sourcePlateRect.contains(witnessed)
            } else {
                candidate.harmonyRecord.removeValue(forKey: "balloonPanelRejection")
            }
            candidate.harmonyRecord["balloonPanelGeometryResampled"] = resampled
            candidate.harmonyRecord["balloonPanelSourceGuard"] = Double(boundedGuard)
            candidate.harmonyRecord["balloonPanelSourceGuardClamped"] = boundedGuard < guardSize
            candidate.harmonyRecord["balloonPanelWitnessExpanded"] = witnessed != owner
            candidate.harmonyRecord["balloonPanelCoveringWitness"] = [Double(witnessed.minX), Double(witnessed.minY),
                Double(witnessed.width), Double(witnessed.height)]
            candidate.harmonyRecord["balloonPanelPreviousFont"] = Double(original.style.fontSize)
            candidate.harmonyRecord["balloonPanelPreviousRect"] = [Double(original.sourcePlateRect.minX),
                Double(original.sourcePlateRect.minY), Double(original.sourcePlateRect.width), Double(original.sourcePlateRect.height)]
            cards[index] = candidate
            surfaces[original.item.id] = surface
            if candidate.textPaintDomain != nil && original.textPaintDomain == nil {
                independentAccepted = true
            }
        }
        if independentAccepted {
            var baselineCards = snapshot
            var baselineSurfaces = initialSurfaces
            try containBalloonPanels(cards: &baselineCards, owners: owners, surfaces: &baselineSurfaces,
                source: source, sourceRect: sourceRect, outputScale: outputScale, parameters: parameters,
                sourcePredictions: sourcePredictions, requestedFonts: requestedFonts,
                requestedFrames: requestedFrames, coverageRegions: coverageRegions,
                backingInvariants: backingInvariants, allowIndependentText: false)
            let regressed = zip(cards, baselineCards).contains { candidate, baseline in
                guard candidate.item.id == baseline.item.id else { return true }
                let candidateGap = NativeTranslationTypography.minimumPaintedRowGap(layout: candidate.typography)
                let baselineGap = NativeTranslationTypography.minimumPaintedRowGap(layout: baseline.typography)
                return (baseline.typography.fits && !candidate.typography.fits)
                    || candidate.style.fontSize + 1e-7 < baseline.style.fontSize
                    || candidate.typography.lineCount > baseline.typography.lineCount
                    || (candidateGap != nil && baselineGap != nil && candidateGap! + 1e-7 < baselineGap!)
            }
            if regressed || cards.count != baselineCards.count {
                cards = baselineCards
                surfaces = baselineSurfaces
            }
        }
    }
}
