import UIKit
import Foundation
@testable import Aidoku

// Independent pre-migration payload planning. No call to the native payload planner.
enum LegacyReaderTranslationLayout {
    nonisolated static func layoutPayload(
        items: [BrowserOverlayItem],
        imageSize: CGSize,
        sourceRect: CGRect,
        settings: IPhoneOverlaySettings,
        targetLanguage: String,
        viewport: CGSize,
        measurementCache: BrowserOverlayTextMeasurementCache? = BrowserOverlayTextMeasurementCache()
    ) -> [[String: Any]] {
        guard imageSize.width > 0, imageSize.height > 0,
              viewport.width > 0, viewport.height > 0
        else { return [] }

        let scaleX = sourceRect.width / imageSize.width
        let scaleY = sourceRect.height / imageSize.height
        // Kept source lettering is never typeset: its box is reserved like
        // another caption's source, and the overlay receives it as a
        // protected-lettering descriptor (appended after the captions).
        let keptLettering = items.filter(\.keepsSourceLettering)
        let keptSources = keptLettering.map {
            CGRect(x: sourceRect.minX + $0.rect.minX * scaleX, y: sourceRect.minY + $0.rect.minY * scaleY,
                   width: max(1, $0.rect.width * scaleX), height: max(1, $0.rect.height * scaleY))
        }
        let sanitized = items.filter { !$0.keepsSourceLettering }.map { item -> BrowserOverlayItem in
            guard let translated = item.translatedText else { return item }
            let clean = ReaderTranslationLanguageFilter.removingForeignScriptTail(
                translated, target: targetLanguage
            )
            guard clean != translated else { return item }
            return BrowserOverlayItem(
                stableRegionID: item.stableRegionID,
                rect: item.rect,
                sourceText: item.sourceText,
                translatedText: clean,
                confidence: item.confidence,
                sourceOrientation: item.sourceOrientation,
                sourceSingleVerticalColumn: item.sourceSingleVerticalColumn,
                translationReuseIdentity: item.translationReuseIdentity,
                sourcePolygon: item.sourcePolygon,
                auxiliaryInkRects: item.auxiliaryInkRects,
                auxiliaryInkPolygons: item.auxiliaryInkPolygons,
                balloonInterior: item.balloonInterior,
                unitMemberRects: item.unitMemberRects,
                keepsSourceLettering: item.keepsSourceLettering,
                recoveredLine: item.recoveredLine
            )
        }
        let sorted = BrowserOverlayItemOrdering.ordered(sanitized)
        var segments = sorted.map { item -> (
            item: BrowserOverlayItem,
            source: CGRect,
            sourceVertical: Bool,
            content: BrowserOverlayCardContent
        ) in
            let sourceVertical =
                BrowserOverlayTextFlow.usesVerticalSourceLayout(
                    rect: item.rect,
                    text: item.sourceText,
                    sourceOrientation: item.sourceOrientation
                )
            let translatedVertical =
                BrowserOverlayTextFlow.displayedTextUsesVerticalLayout(
                    item: item,
                    sourceIsVertical: sourceVertical,
                    targetLanguage: targetLanguage
                )
            let content = BrowserOverlayCardContent.make(
                item: item,
                mode: settings.mode,
                sourceVertical: sourceVertical,
                translatedVertical: translatedVertical
            )
            return (
                item,
                CGRect(
                    x: sourceRect.minX + item.rect.minX * scaleX,
                    y: sourceRect.minY + item.rect.minY * scaleY,
                    width: max(1, item.rect.width * scaleX),
                    height: max(1, item.rect.height * scaleY)
                ),
                sourceVertical,
                content
            )
        }
        let sourceRects = segments.map(\.source)
        let sourceRotations = segments.map {
            BrowserOverlayRotation.mapped(item: $0.item, imageSize: imageSize, sourceRect: sourceRect, settings: settings)
        }
        let nearUprightQuads = segments.map {
            BrowserOverlayRotation.nearUpright(item: $0.item, imageSize: imageSize, sourceRect: sourceRect, settings: settings)
        }
        var intrinsicLayouts = segments.map { segment in
            BrowserOverlayLayoutPlanner.plan(
                source: segment.source,
                variants: [segment.content.displayed],
                settings: settings,
                viewport: viewport,
                occupied: [],
                sourceVertical: segment.sourceVertical,
                singleVerticalColumn:
                    segment.content.singleVerticalColumn,
                reservedSources: [],
                measurementCache: measurementCache
            )
        }
        var verticalContents: [Int: BrowserOverlayCardContent] = [:]
        var verticalLayouts: [Int: BrowserOverlayCardLayout] = [:]
        for index in segments.indices {
            if Task.isCancelled { return [] }
            let segment = segments[index]
            guard let verticalContent =
                BrowserOverlayCardContent.adaptiveVerticalCandidate(
                    item: segment.item,
                    current: segment.content,
                    mode: settings.mode,
                    textPlacement: settings.textPlacement,
                    sourceVertical: segment.sourceVertical,
                    sourceRect: segment.source
                )
            else { continue }
            verticalContents[index] = verticalContent
            verticalLayouts[index] = BrowserOverlayLayoutPlanner.plan(
                source: segment.source,
                variants: [verticalContent.displayed],
                settings: settings,
                viewport: viewport,
                occupied: [],
                sourceVertical: segment.sourceVertical,
                singleVerticalColumn: verticalContent.singleVerticalColumn,
                reservedSources: [],
                measurementCache: measurementCache
            )
        }
        let verticalIndices =
            BrowserOverlayLayoutPlanner.adaptiveVerticalTranslationIndices(
                horizontalLayouts: intrinsicLayouts,
                verticalLayouts: verticalLayouts,
                eligibleIndices: verticalLayouts.isEmpty ? [] :
                    BrowserOverlayLayoutPlanner
                        .severelyDisplacedTranslationIndices(
                            intrinsicLayouts: intrinsicLayouts,
                            sources: sourceRects,
                            variants: segments.map { $0.content.displayed },
                            settings: settings,
                            viewport: viewport,
                            sourceVerticals: segments.map(\.sourceVertical),
                            singleVerticalColumns: segments.map {
                                $0.content.singleVerticalColumn
                            },
                            placementBounds: sourceRect,
                            allowsDetachedPlacements: segments.map {
                                $0.content.hasTranslation &&
                                    settings.mode == .translateOnly
                            },
                            returnableCards: sourceRotations.map { $0 == nil },
                            protectedRects: keptSources,
                            measurementCache: measurementCache
                        )
            )
        for index in verticalIndices {
            guard let content = verticalContents[index],
                  let layout = verticalLayouts[index]
            else { continue }
            let segment = segments[index]
            segments[index] = (
                segment.item,
                segment.source,
                segment.sourceVertical,
                content
            )
            intrinsicLayouts[index] = layout
        }
        let planningOrder = BrowserOverlayLayoutPlanner.packingOrder(
            intrinsicLayouts
        )
        var occupied: [CGRect] = []
        var plannedLayouts = Array<BrowserOverlayCardLayout?>(
            repeating: nil,
            count: segments.count
        )
        for index in planningOrder {
            if Task.isCancelled { return [] }
            let segment = segments[index]
            let reservedSources = sourceRects.enumerated().compactMap {
                otherIndex, rect in otherIndex == index ? nil : rect
            } + keptSources
            let layout = BrowserOverlayLayoutPlanner.resolvePositionedLayout(
                intrinsicLayouts[index],
                source: segment.source,
                variants: [segment.content.displayed],
                settings: settings,
                viewport: viewport,
                occupied: occupied,
                sourceVertical: segment.sourceVertical,
                singleVerticalColumn:
                    segment.content.singleVerticalColumn,
                reservedSources: reservedSources,
                measurementCache: measurementCache
            )
            guard !layout.rect.isNull,
                  layout.rect.width > 0, layout.rect.height > 0
            else { continue }
            plannedLayouts[index] = layout
            occupied.append(layout.rect)
        }
        let concreteLayouts = plannedLayouts.compactMap { $0 }
        if concreteLayouts.count == plannedLayouts.count {
            let relaxed = BrowserOverlayLayoutPlanner.restoringSourceCoverage(
                BrowserOverlayLayoutPlanner.relaxingCardPositions(
                concreteLayouts,
                sources: sourceRects,
                sourceVerticals: segments.map(\.sourceVertical),
                viewport: viewport,
                placementBounds: sourceRect,
                preferredRects: intrinsicLayouts.map(\.rect),
                allowsDetachedPlacements: segments.map {
                    $0.content.hasTranslation &&
                        settings.mode == .translateOnly
                },
                returnableCards: sourceRotations.map { $0 == nil },
                protectedRects: keptSources
                ),
                sources: sourceRects,
                bounds: sourceRect,
                enabled: settings.mode == .translateOnly && settings.textPlacement == .replace
            )
            for index in relaxed.indices {
                plannedLayouts[index] = relaxed[index]
            }
        }

        // Dense sheets: cards stay in the neighbourhood of their own source box.
        let cellEligible = segments.indices.map {
            segments[$0].content.hasTranslation && sourceRotations[$0] == nil && !segments[$0].content.displayed.vertical
        }
        if settings.mode == .translateOnly && settings.textPlacement == .replace &&
            cellEligible.filter({ $0 }).count >= BrowserOverlayLayoutPlanner.denseSheetCaptionCount {
            plannedLayouts = BrowserOverlayLayoutPlanner.confiningToSourceCells(
                plannedLayouts, sources: sourceRects, variants: segments.map { $0.content.displayed },
                sourceVerticals: segments.map(\.sourceVertical),
                sourceSizes: segments.map { BrowserOverlayTypography.sourceSize(text: $0.item.sourceText, rect: $0.source) },
                eligible: cellEligible,
                bounds: sourceRect, settings: settings, measurementCache: measurementCache)
        }

        // Captions sharing one balloon (native shared interior) may be set as one unit: stacked in
        // source reading order at one size inside the balloon paper. The planner proposes the unit
        // (order, paper, a stack that fits); every card keeps its own layout and erasure, and the
        // overlay commits the unit only once each member's erasure is verified and the stack keeps
        // the members' final size (`balloonUnit`).
        var unitMembership: [Int: (unit: BrowserOverlayBalloonUnit, order: Int)] = [:]
        if settings.mode == .translateOnly && settings.textPlacement == .replace,
           segments.contains(where: { $0.item.balloonInterior?.members != nil }) {
            let unitEligible = segments.indices.map { index -> Bool in
                let content = segments[index].content
                guard content.hasTranslation, sourceRotations[index] == nil, nearUprightQuads[index] == nil,
                      !content.displayed.vertical, case .plain = content.displayed.content else { return false }
                return true
            }
            let units = BrowserOverlayLayoutPlanner.balloonUnits(
                items: segments.map(\.item), sources: sourceRects, sourceVerticals: segments.map(\.sourceVertical),
                variants: segments.map { $0.content.displayed }, eligible: unitEligible, planned: plannedLayouts,
                frame: sourceRect, measurementCache: measurementCache)
            for unit in units {
                for (order, member) in unit.members.enumerated() { unitMembership[member] = (unit, order) }
            }
        }

        var columns = settings.mode == .translateOnly && settings.textPlacement == .replace
            ? BrowserOverlayColumnLayout.plan(sources: sourceRects, variants: segments.map { $0.content.displayed },
                eligible: segments.indices.map { segments[$0].sourceVertical && segments[$0].content.hasTranslation && sourceRotations[$0] == nil },
                bounds: sourceRect, measurementCache: measurementCache,
                sourceSizes: segments.map { BrowserOverlayTypography.sourceSize(text: $0.item.sourceText, rect: $0.source) }) : [:]
        // A rejected neighbor returns to its original footprint. Recheck that
        // footprint before accepting any remaining coordinated column.
        while !columns.isEmpty {
            let rejected = columns.keys.filter { index in
                guard let frame = columns[index]?.rect else { return false }
                return plannedLayouts.indices.contains { other in
                    guard other != index, let obstacle = columns[other]?.rect ?? plannedLayouts[other]?.rect else { return false }
                    let overlap = frame.intersection(obstacle)
                    return !overlap.isNull && overlap.width > 0.25 && overlap.height > 0.25
                } || keptSources.contains { kept in
                    let overlap = frame.intersection(kept)
                    return !overlap.isNull && overlap.width > 0.25 && overlap.height > 0.25
                }
            }
            if rejected.isEmpty { break }
            for index in rejected { columns.removeValue(forKey: index) }
        }
        // Sound-effect / logo evidence from the source text (the overlay's keep-source + gloss path).
        let hiraganaSources = items.filter { ReaderTranslationNonContentText.containsHiragana($0.sourceText) }.count
        let creditSources = items.filter { ReaderTranslationNonContentText.containsTitleCredits($0.sourceText) }.count
        var result: [[String: Any]] = []
        for (index, segment) in segments.enumerated() {
            if Task.isCancelled { return [] }
            guard let resolvedLayout = plannedLayouts[index] else { continue }
            // All placement and source-coverage adjustments are finished. Growing
            // fonts earlier feeds back into packing and can shrink other captions.
            let ordinaryLayout = segment.content.hasTranslation
                ? BrowserOverlayLayoutPlanner.fittingFinalHorizontalFont(
                    resolvedLayout, variants: [segment.content.displayed], settings: settings,
                    occupied: plannedLayouts.enumerated().compactMap { $0.offset == index ? nil : $0.element?.rect },
                    reservedSources: sourceRects.enumerated().compactMap { $0.offset == index ? nil : $0.element } + keptSources,
                    measurementCache: measurementCache
                ) : resolvedLayout
            func quadLayout(display: Bool) -> BrowserOverlayCardLayout? {
                sourceRotations[index].flatMap {
                    BrowserOverlayRotation.layout(geometry: $0, variant: segment.content.displayed,
                        maximumFontSize: BrowserOverlayRotation.maximumFontSize(geometry: $0, sourceText: segment.item.sourceText,
                                                                                planned: ordinaryLayout.maximumFontSize,
                                                                                display: display),
                        plannedFontSize: ordinaryLayout.maximumFontSize,
                        obstacles: sourceRects.enumerated().compactMap { $0.offset == index ? nil : $0.element } + keptSources,
                        displayMargins: display, measurementCache: measurementCache)
                }
            }
            let bodyRotatedLayout = quadLayout(display: false)
            // A quad tilted only by detector noise is set upright. When its
            // rotated layout would fit, it stays outside the page's size
            // cohorts, like a rotated caption.
            let nearUprightRotation = nearUprightQuads[index].flatMap { geometry -> CGFloat? in
                BrowserOverlayRotation.layout(geometry: geometry, variant: segment.content.displayed,
                    maximumFontSize: BrowserOverlayRotation.maximumFontSize(geometry: geometry, sourceText: segment.item.sourceText,
                                                                            planned: ordinaryLayout.maximumFontSize),
                    plannedFontSize: ordinaryLayout.maximumFontSize,
                    obstacles: sourceRects.enumerated().compactMap { $0.offset == index ? nil : $0.element },
                    measurementCache: measurementCache) == nil ? nil : geometry.radians
            }
            // Rotated and slanted display lettering (titles, shouts, sound
            // effects) stopped only by the body ceiling is sized from its source
            // glyph inside the same quad. The body-ceiling layout still decides
            // the upright alternative below.
            var rotatedLayout = bodyRotatedLayout
            if let body = bodyRotatedLayout, let geometry = sourceRotations[index], !segment.content.displayed.vertical {
                let text = segment.item.sourceText, planned = ordinaryLayout.maximumFontSize
                let ceiling = BrowserOverlayRotation.maximumFontSize(geometry: geometry, sourceText: text, planned: planned)
                let display = BrowserOverlayRotation.maximumFontSize(geometry: geometry, sourceText: text, planned: planned,
                                                                     display: true)
                if display > ceiling + 0.25, body.maximumFontSize >= ceiling - 0.5,
                   let grown = quadLayout(display: true), grown.maximumFontSize > body.maximumFontSize {
                    rotatedLayout = grown
                }
            }
            // Horizontal Korean in a narrow slanted column breaks every word.
            // Offer the planner's upright card; the overlay uses it only when the
            // slanted source erasure leaves clean surface under every glyph,
            // otherwise the rotated layout below stays in place.
            let uprightAlternative = bodyRotatedLayout.flatMap { rotated in
                BrowserOverlayRotation.prefersUprightLayout(rotated: rotated, radians: sourceRotations[index]?.radians ?? 0,
                    upright: ordinaryLayout, variant: segment.content.displayed, sourceVertical: segment.sourceVertical,
                    measurementCache: measurementCache) ? ordinaryLayout : nil
            }
            // The size the quad held under the planner's ceiling. Artwork-safe
            // slanted fitting keeps its floor there, so growth never costs a
            // restoration that fit before.
            let plannedRotatedFont = rotatedLayout == nil ? nil : sourceRotations[index].flatMap {
                BrowserOverlayRotation.layout(geometry: $0, variant: segment.content.displayed,
                    maximumFontSize: ordinaryLayout.maximumFontSize, measurementCache: measurementCache)?.maximumFontSize
            }
            // A vertical column tilted only by detector noise: the quad's layout
            // (glyph-based size, erasure, plate) with upright text; the overlay
            // clips any plate to the quad and keeps the rotated caption when
            // source ink leaves the upright box.
            let uprightQuadText = rotatedLayout != nil && sourceRotations[index].map {
                BrowserOverlayRotation.setsUprightInQuad($0, sourceVertical: segment.sourceVertical,
                                                         translatedVertical: segment.content.displayed.vertical)
            } == true
            let layout = rotatedLayout ?? ordinaryLayout
            let renderedText: String
            if segment.content.hasTranslation,
               settings.mode == .translateOnly
            {
                renderedText =
                    segment.item.translatedText ?? segment.item.sourceText
            } else if !segment.content.hasTranslation {
                renderedText = segment.item.sourceText
            } else {
                renderedText = segment.content.displayed.displayText
            }
            var payload: [String: Any] = [
                "id": String(segment.item.stableRegionID ?? UInt64(index)),
                "rotation": rotatedLayout == nil ? 0 : (sourceRotations[index]?.radians ?? 0),
                "rotationPlannedFontSize": plannedRotatedFont as Any? ?? NSNull(),
                "nearUprightRotation": nearUprightRotation as Any? ?? NSNull(),
                "uprightQuadText": uprightQuadText,
                "uprightAlternative": uprightAlternative.map { upright -> [String: Any] in
                    ["x": upright.rect.minX, "y": upright.rect.minY, "width": upright.rect.width, "height": upright.rect.height,
                     "fontSize": upright.maximumFontSize,
                     "lineHeight": BrowserOverlayFont.system(ofSize: upright.maximumFontSize, weight: .bold).lineHeight,
                     "paddingTop": upright.contentInsets.top, "paddingRight": upright.contentInsets.right,
                     "paddingBottom": upright.contentInsets.bottom, "paddingLeft": upright.contentInsets.left]
                } as Any? ?? NSNull(),
                "sourceTextOnly": !segment.content.hasTranslation,
                "sourceFontSize": BrowserOverlayTypography.sourceSize(text: segment.item.sourceText, rect: segment.source) as Any? ?? NSNull(),
                "sourceColorEligible": settings.mode == .translateOnly &&
                    settings.textPlacement == .replace,
                "sourcePanelRestorationEligible": settings.mode == .translateOnly &&
                    settings.textPlacement == .replace,
                "sourceCleanupLexical": BrowserSourceInkCleanup.hasColoredCleanupText(segment.item.sourceText),
                "sourceLettering": ReaderTranslationNonContentText.letteringRole(
                    segment.item.sourceText,
                    pageHasHiragana: hiraganaSources - (ReaderTranslationNonContentText.containsHiragana(segment.item.sourceText) ? 1 : 0) > 0,
                    pageHasCredits: creditSources - (ReaderTranslationNonContentText.containsTitleCredits(segment.item.sourceText) ? 1 : 0) > 0
                )?.rawValue as Any? ?? NSNull(),
                "columnLayout": columns[index].map { column -> [String: Any] in
                    let height = segment.content.displayed.measuredSize(
                        width: column.rect.width - column.contentInsets.left - column.contentInsets.right,
                        fontSize: column.maximumFontSize, measurementCache: measurementCache).height
                    return ["x": column.rect.minX, "y": column.rect.minY,
                     "width": column.rect.width, "height": column.rect.height,
                     "inspectionHeight": min(column.rect.height, ceil(height) + 8),
                     "fontSize": column.maximumFontSize,
                     "lineHeight": BrowserOverlayFont.system(ofSize: column.maximumFontSize, weight: .bold).lineHeight,
                     "paddingTop": column.contentInsets.top, "paddingLeft": column.contentInsets.left,
                     "paddingBottom": column.contentInsets.bottom, "paddingRight": column.contentInsets.right,
                     "smallTextReference": NSNull(), "balancedColumn": true,
                     "allowsAutomaticFontRecovery": false]
                } as Any? ?? NSNull(),
                "allowsAutomaticFontRecovery": rotatedLayout == nil && settings.mode == .translateOnly &&
                    settings.textPlacement == .replace,
                "sourceCleanup": settings.mode == .translateOnly &&
                    settings.textPlacement == .replace &&
                    settings.colorMode == .white,
                "sourceBounds": [segment.item.rect.minX / imageSize.width, segment.item.rect.minY / imageSize.height,
                                 segment.item.rect.width / imageSize.width, segment.item.rect.height / imageSize.height],
                "sourcePolygon": segment.item.sourcePolygon.map { [$0.x / imageSize.width, $0.y / imageSize.height] },
                "auxiliaryInkRects": segment.item.auxiliaryInkRects.map {
                    [$0.minX / imageSize.width, $0.minY / imageSize.height, $0.width / imageSize.width, $0.height / imageSize.height]
                },
                "auxiliaryInkPolygons": segment.item.auxiliaryInkPolygons.map { $0.map { [$0.x / imageSize.width, $0.y / imageSize.height] } },
                "balloonInterior": segment.item.balloonInterior.flatMap { $0.members == nil ? $0.payload : nil } as Any? ?? NSNull(),
                "balloonUnit": unitMembership[index].map { membership -> [String: Any] in
                    ["members": membership.unit.members.map { String(segments[$0].item.stableRegionID ?? UInt64($0)) },
                     "order": membership.order,
                     "interior": segments[index].item.balloonInterior?.payload ?? [:]]
                } as Any? ?? NSNull(),
                "unitMemberRects": segment.item.unitMemberRects.map {
                    [$0.minX / imageSize.width, $0.minY / imageSize.height, $0.width / imageSize.width, $0.height / imageSize.height]
                },
                "sourceSingleColumn": segment.item.sourceSingleVerticalColumn == true,
                "recoveredLine": segment.item.recoveredLine,
                "sourceRubyEligible": segment.item.sourceText.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) },
                "sourceFrame": [sourceRect.minX, sourceRect.minY, sourceRect.width, sourceRect.height],
                "sourceVertical": segment.sourceVertical,
                "x": layout.rect.minX,
                "y": layout.rect.minY,
                "width": layout.rect.width,
                "height": layout.rect.height,
                "text": renderedText,
                "vertical": segment.content.displayed.vertical,
                "wrappingScript":
                    BrowserOverlayTextFlow.wrappingScript(
                        for: renderedText
                    ).rawValue,
                "fontScript":
                    BrowserOverlayTextFlow.fontScript(
                        for: renderedText
                    ).rawValue,
                "fontSize": layout.maximumFontSize,
                "smallTextReference": layout.smallTextReference.map { reference -> [String: Any] in
                    ["fontSize": reference.fontSize, "additionalLines": reference.additionalLines,
                     "allowsEmergencyWordBreak": reference.allowsEmergencyWordBreak,
                     "fallbackFontSize": reference.fallbackFontSize ?? reference.fontSize,
                     "fallbackPadding": [reference.fallbackInsets?.top ?? reference.insets.top,
                                         reference.fallbackInsets?.right ?? reference.insets.right,
                                         reference.fallbackInsets?.bottom ?? reference.insets.bottom,
                                         reference.fallbackInsets?.left ?? reference.insets.left],
                     "exclusionRects": reference.exclusionRects.map { [$0.minX, $0.minY, $0.width, $0.height] },
                     "padding": [reference.insets.top, reference.insets.right, reference.insets.bottom, reference.insets.left]]
                } as Any? ?? NSNull(),
                "lineHeight": segment.content.displayed.vertical
                    ? layout.maximumFontSize
                    : BrowserOverlayFont.system(
                        ofSize: layout.maximumFontSize,
                        weight: .bold
                    ).lineHeight,
                "paddingTop": layout.contentInsets.top,
                "paddingLeft": layout.contentInsets.left,
                "paddingBottom": layout.contentInsets.bottom,
                "paddingRight": layout.contentInsets.right,
                "lightSurface":
                    settings.colorMode == .white,
                "clipsText": !segment.content.hasTranslation ||
                    segment.content.displayed.vertical ||
                    segment.content.singleVerticalColumn ||
                    settings.textPlacement != .replace,
            ]
            // Keep-source glosses follow the lettering's own tilt: the detector quad of a lettering role, or
            // the baseline of italic lettering, as [centre x, centre y (fractions of the page), width, height
            // (fractions of its width), radians].
            if payload["sourceLettering"] is String, sourceRect.width > 0, sourceRect.height > 0,
               let quad = sourceRotations[index] ?? nearUprightQuads[index] ??
                BrowserOverlayRotation.baselineAxis(item: segment.item, imageSize: imageSize, sourceRect: sourceRect) {
                payload["sourceQuad"] = [(quad.panelRect.midX - sourceRect.minX) / sourceRect.width,
                                         (quad.panelRect.midY - sourceRect.minY) / sourceRect.height,
                                         quad.panelRect.width / sourceRect.width, quad.panelRect.height / sourceRect.width, quad.radians]
            }
            result.append(payload)
        }
        for (offset, (item, source)) in zip(keptLettering, keptSources).enumerated() {
            let text = item.translatedText ?? item.sourceText
            let sourceVertical = BrowserOverlayTextFlow.usesVerticalSourceLayout(
                rect: item.rect, text: item.sourceText, sourceOrientation: item.sourceOrientation)
            result.append([
                "keptLettering": true,
                "id": "kept-" + String(item.stableRegionID ?? UInt64(offset)),
                "sourceBounds": [item.rect.minX / imageSize.width, item.rect.minY / imageSize.height,
                                 item.rect.width / imageSize.width, item.rect.height / imageSize.height],
                "sourcePolygon": item.sourcePolygon.map { [$0.x / imageSize.width, $0.y / imageSize.height] },
                "sourceFrame": [sourceRect.minX, sourceRect.minY, sourceRect.width, sourceRect.height],
                "sourceFontSize": BrowserOverlayTypography.sourceSize(text: item.sourceText, rect: source) as Any? ?? NSNull(),
                "fontScript": BrowserOverlayTextFlow.fontScript(for: text).rawValue,
                "vertical": BrowserOverlayTextFlow.displayedTextUsesVerticalLayout(
                    item: item, sourceIsVertical: sourceVertical, targetLanguage: targetLanguage),
                "sourceVertical": sourceVertical,
            ])
        }
        return result
    }

}
