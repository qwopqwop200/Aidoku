// Add after the CURRENT atomic six-file patch plus main-owned bounded PDF helper. UIKit execution is pending MAIN.
// Not executed on UIKit here; main owns the affected simulator cache.
import Foundation
import CoreGraphics
import Testing
import UIKit
import CryptoKit
@testable import Aidoku

extension NativeTextBoxReplacementTests {
    @Test(arguments: ["bold", "italic", "typography", "outline", "glow", "typesetting", "identity"])
    func retainedWidthConsumerUsesReceiptCardsNotSnapshotCards(kind: String) throws {
        typealias R = NativeTranslationRenderer
        let (seed, item, surface, owner) = try widthReceiptFixture()
        let (candidate, _) = try retainedWidth(plan: seed, item: item, surface: surface, owner: owner)
        let admitted = try #require(candidate)
        let artifact = try #require(admitted.retainedWidthArtifact)
        let card = try #require(admitted.cards.first)
        var detachedCards = admitted.cards
        switch kind {
        case "bold": detachedCards[0].style.bold.toggle()
        case "italic": detachedCards[0].style.fontName = "Helvetica-Oblique"
        case "typesetting": detachedCards[0].item.typesettingText = "가"
        case "typography":
            detachedCards[0].typography = NativeTranslationTypography.layout(
                text: "가", in: card.item.contentRect.size, style: card.style)
        case "outline": detachedCards[0].style.outlineWidth += 1
        case "glow": detachedCards[0].style.outlineGlow += 1
        case "identity":
            var payload = try #require(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(card.item)) as? [String: Any])
            payload["id"] = "detached-owner"
            detachedCards[0].item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
                from: JSONSerialization.data(withJSONObject: payload))
        default: Issue.record("Unexpected fixture variant")
        }
        let s = admitted
        let detachedSnapshot = R.PreparedRender(inputLayout: s.inputLayout, layout: s.layout,
            image: s.image, source: s.source, restoration: s.restoration, cards: detachedCards,
            glossCards: s.glossCards, gloss: s.gloss, settings: s.settings, bounds: s.bounds,
            pixels: s.pixels, scale: s.scale, composeSource: s.composeSource,
            capturePDF: s.capturePDF, pdfDeviceScale: s.pdfDeviceScale,
            sourcePatches: s.sourcePatches, sourcePieces: s.sourcePieces,
            limitations: s.limitations, diagnosticData: nil)
        // Deliberately conflicting snapshot metadata cannot replace the cards
        // owned by the same admitted raster/document. No mutable cards parameter exists.
        let receipt = NativeWidthFinalArtifactAdmission.Receipt(snapshot: detachedSnapshot,
            data: artifact.data, image: artifact.image, mediaBox: artifact.mediaBox,
            logicalBounds: admitted.bounds, sourceRect: admitted.layout.sourceRect,
            pixels: admitted.pixels, deviceScale: admitted.pdfDeviceScale, cards: admitted.cards)
        let consumedPlan = R.retainedWidthPreparedRender(receipt, diagnosticData: nil)
        #expect(consumedPlan.cards[0].item == card.item)
        #expect(consumedPlan.cards[0].style.bold == card.style.bold)
        #expect(consumedPlan.cards[0].style.fontName == card.style.fontName)
        #expect(consumedPlan.cards[0].style.outlineWidth == card.style.outlineWidth)
        #expect(consumedPlan.cards[0].style.outlineGlow == card.style.outlineGlow)
        #expect(consumedPlan.cards[0].typography.shapedText == card.typography.shapedText)
        let consumed = try R.finishPreparedSynchronously(consumedPlan)
        #expect(consumed.exportPDFData == artifact.data)
    }

    private func widthReceiptFixture(capturePDF: Bool = true) throws -> (NativeTranslationRenderer.PreparedRender,
        NativeTranslationLayoutItem, NativeTextBoxContainment.Surface, CGRect) {
        typealias R = NativeTranslationRenderer
        typealias T = NativeTranslationTypography
        let page = CGRect(x: 0, y: 0, width: 120, height: 120)
        let text = "가나다라마바사 아자차카타파하"
        let sourceBounds: [Double] = [44.0 / 120, 44.0 / 120, 10.0 / 120, 20.0 / 120]
        let interiorRect: [Double] = [10.0 / 120, 10.0 / 120, 100.0 / 120, 100.0 / 120]
        let interiorSpans: [Double] = [10.0 / 120, 110.0 / 120, 10.0 / 120, 110.0 / 120]
        let interior: [String: Any] = ["rect": interiorRect, "center": [0.5, 0.5],
            "spans": interiorSpans, "contourVerified": true]
        let value: [String: Any] = ["id": "neutral-width", "text": text, "x": 40, "y": 20,
            "width": 39.95, "height": 90, "fontSize": 11.5, "lineHeight": 13.5439453125,
            "sourceFontSize": 11.5, "fontScript": "korean", "wrappingScript": "korean", "sourceTextOnly": false,
            "paddingLeft": 2, "paddingRight": 2, "paddingTop": 2, "paddingBottom": 2,
            "sourceFrame": [0, 0, 120, 120], "sourceBounds": sourceBounds, "balloonInterior": interior]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: value))
        let surface = try #require(NativeTextBoxContainment.known(item.balloonInterior, frame: page))
        let style = T.Style(fontScript: "korean", prefersDominantKoreanScript: true, fontSize: 11.5,
            foreground: CGColor(red: 0.9, green: 0.3, blue: 0.05, alpha: 1), outline: CGColor(gray: 1, alpha: 1),
            outlineWidth: 0.5, tracking: -0.138, lineHeight: 13.5439453125,
            horizontalWrapping: .keepAllWithEmergency, horizontalAlignment: .center)
        var card = R.Card(item: item, typography: T.layout(text: text, in: item.contentRect.size, style: style),
            style: style, sourceBackgroundKind: "solid-text-box", drawsPanel: true, background: CGColor(gray: 0.9, alpha: 1),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 11.5)
        card.sourcePlateOwnerRect = surface.rect
        let layout = NativeTranslationLayout(imageSize: page.size, sourceRect: page, viewport: page.size, items: [item])
        let plan = R.PreparedRender(inputLayout: layout, layout: layout, image: nil, source: nil,
            restoration: .init(), cards: [card], glossCards: [], gloss: .init(),
            settings: IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
                textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 2, subtitleContextSentences: 0),
            bounds: page, pixels: CGSize(width: 240, height: 240), scale: 2, composeSource: false,
            capturePDF: capturePDF, pdfDeviceScale: 1, sourcePatches: [], sourcePieces: [], limitations: [], diagnosticData: nil)
        return (plan, item, surface, CGRect(x: 44, y: 44, width: 10, height: 20))
    }

    private func retainedWidth(plan: NativeTranslationRenderer.PreparedRender, item: NativeTranslationLayoutItem,
        surface: NativeTextBoxContainment.Surface, owner: CGRect, kept: [CGRect] = []) throws
        -> (NativeTranslationRenderer.PreparedRender?, [NativeTranslationRenderer.Card]) {
        typealias R = NativeTranslationRenderer
        let session = NativeWidthFinalArtifactAdmission(plan: plan, keptOwners: kept)
        var incumbent = plan.cards
        var cards = plan.cards, unknown: Set<String> = [], conditional: Set<String> = []
        _ = try R.commitContourCohortsTiled(cards: &cards, items: [item], owners: [owner], surfaces: [item.id: surface],
            bounds: plan.bounds, sourceRect: plan.layout.sourceRect, pixels: plan.pixels,
            pdfDeviceScale: plan.pdfDeviceScale, verifiedOriginalStyle: [], allowsStyleUnknownTrials: true,
            unknownSourceStyleIDs: &unknown, allowsVerifiedBalloonInteriorModelTrials: true,
            conditionalGeometryIDs: &conditional,
            widthStageCheckpoint: { prior, _, _, _, _ in incumbent = prior },
            widthFinalArtifactAdmission: { session.admission(before: $0, after: $1, ids: $2) })
        return (try session.finalizeOrRollback(cards: &cards, incumbent: incumbent, diagnosticData: nil), cards)
    }

    @Test func widthAdmissionReusesActualDocumentAtFinalRenderer() throws {
        let (seed, item, surface, owner) = try widthReceiptFixture()
        let (value, cards) = try retainedWidth(plan: seed, item: item, surface: surface, owner: owner)
        let sealed = try #require(value), capture = try #require(sealed.retainedWidthArtifact)
        #expect(cards[0].item.width > seed.cards[0].item.width)
        #expect(cards[0].finalFontSize == seed.cards[0].finalFontSize)
        #expect(cards[0].style.foreground == seed.cards[0].style.foreground)
        #expect(cards[0].style.outline == seed.cards[0].style.outline)
        #expect(cards[0].sourcePlateRect == seed.cards[0].sourcePlateRect)
        let result = try NativeTranslationRenderer.finishPreparedSynchronously(sealed)
        #expect(result.exportPDFData == capture.data)
        #expect(sealed.cards[0].item == cards[0].item)
    }

    @Test func widthReceiptCannotSurviveReconstructedCardWorldOrBounds() throws {
        typealias R = NativeTranslationRenderer
        let (seed, item, surface, owner) = try widthReceiptFixture()
        let (value, _) = try retainedWidth(plan: seed, item: item, surface: surface, owner: owner)
        let old = try #require(value), capture = try #require(old.retainedWidthArtifact)
        var changed = old.cards; changed[0].textShift.x += 8
        for bounds in [old.bounds, old.bounds.insetBy(dx: -1, dy: -1)] {
            let new = R.PreparedRender(inputLayout: old.inputLayout, layout: old.layout, image: old.image,
                source: old.source, restoration: old.restoration, cards: changed, glossCards: old.glossCards,
                gloss: old.gloss, settings: old.settings, bounds: bounds, pixels: old.pixels, scale: old.scale,
                composeSource: old.composeSource, capturePDF: old.capturePDF, pdfDeviceScale: old.pdfDeviceScale,
                sourcePatches: old.sourcePatches, sourcePieces: old.sourcePieces,
                limitations: old.limitations, diagnosticData: old.diagnosticData)
            #expect(new.retainedWidthArtifact == nil)
            #expect(throws: R.RenderError.self) { _ = try R.finishPreparedSynchronously(new) }
            #expect(throws: R.RenderError.self) {
                _ = try R.finishPreparedResult(new, overlayCGImage: capture.image, exportPDFData: capture.data)
            }
        }
        #expect(try R.finishPreparedSynchronously(old).exportPDFData == capture.data)
    }

    @Test func widthReceiptSourceOrCompositorReplacementStartsUnsealed() throws {
        typealias R = NativeTranslationRenderer
        let (seed, item, surface, owner) = try widthReceiptFixture()
        let (value, _) = try retainedWidth(plan: seed, item: item, surface: surface, owner: owner)
        let old = try #require(value)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120), format: format).image {
            UIColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1).setFill(); $0.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        }
        let new = R.PreparedRender(inputLayout: old.inputLayout, layout: old.layout, image: image,
            source: image.cgImage, restoration: old.restoration, cards: old.cards, glossCards: old.glossCards,
            gloss: old.gloss, settings: old.settings, bounds: old.bounds, pixels: old.pixels, scale: old.scale,
            composeSource: true, capturePDF: old.capturePDF, pdfDeviceScale: old.pdfDeviceScale,
            sourcePatches: old.sourcePatches, sourcePieces: [CGRect(x: 0, y: 0, width: 5, height: 5)],
            limitations: old.limitations, diagnosticData: old.diagnosticData)
        #expect(new.retainedWidthArtifact == nil)
        #expect(throws: R.RenderError.self) { _ = try R.finishPreparedSynchronously(new) }
    }

    @Test func cancelledRetainedExportProducesNoResult() async throws {
        let (seed, item, surface, owner) = try widthReceiptFixture()
        let (value, _) = try retainedWidth(plan: seed, item: item, surface: surface, owner: owner)
        let sealed = try #require(value)
        let cancelled = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try NativeTranslationRenderer.finishPreparedSynchronously(sealed); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        #expect(cancelled)
    }

    @Test func missingOrExhaustedActualPDFProducerKeepsSameOldStageWorld() throws {
        typealias R = NativeTranslationRenderer
        let (seed, item, surface, owner) = try widthReceiptFixture()
        let session = NativeWidthFinalArtifactAdmission(plan: seed, keptOwners: [])
        var exhausted = NativeWidthFinalArtifactAdmission.Budget(); exhausted.deviceSamples = 0
        func run(_ callback: (([R.Card], [R.Card], Set<String>) throws -> Bool?)?) throws -> [R.Card] {
            var cards = seed.cards, unknown: Set<String> = [], conditional: Set<String> = []
            _ = try R.commitContourCohortsTiled(cards: &cards, items: [item], owners: [owner], surfaces: [item.id: surface],
                bounds: seed.bounds, sourceRect: seed.layout.sourceRect, pixels: seed.pixels,
                pdfDeviceScale: seed.pdfDeviceScale, verifiedOriginalStyle: [], allowsStyleUnknownTrials: true,
                unknownSourceStyleIDs: &unknown, allowsVerifiedBalloonInteriorModelTrials: true,
                conditionalGeometryIDs: &conditional, widthFinalArtifactAdmission: callback)
            return cards
        }
        let baseline = try run(nil)
        let blocked = try run { before, after, ids in
            try session.certify(plan: seed, before: before, after: after, ids: ids, keptOwners: [], budget: &exhausted)
        }
        #expect(session.accepted == nil)
        #expect(blocked.map { $0.item } == baseline.map { $0.item })
        #expect(blocked.map { $0.textShift } == baseline.map { $0.textShift })
        #expect(blocked.map { $0.typography.rangeBounds } == baseline.map { $0.typography.rangeBounds })
    }

    @Test func actualRectangleProducerOwnsDocumentThroughBitmapAndVectorExport() throws {
        typealias R = NativeTranslationRenderer
        let (seed, _, _, _) = try widthReceiptFixture()
        let plan = try R.prepareRenderSynchronously(layout: seed.inputLayout, image: nil, settings: seed.settings,
            scale: seed.scale, renderBounds: seed.bounds, composeSource: false, outputPixelSize: seed.pixels,
            collectDiagnostics: true, capturePDF: true, pdfDeviceScale: seed.pdfDeviceScale)
        let held = try #require(plan.retainedWidthArtifact)
        #expect(plan.cards.contains { $0.harmonyRecord["widthRequiresRetainedArtifact"] as? Bool == true })
        let bitmap = try R.finishPreparedSynchronously(plan)
        #expect(bitmap.exportPDFData == held.data)
        let vector = try R.renderPDFSynchronously(layout: seed.inputLayout, image: nil, settings: seed.settings,
            scale: seed.scale, renderBounds: seed.bounds, outputPixelSize: seed.pixels,
            collectDiagnostics: true, pdfDeviceScale: seed.pdfDeviceScale)
        let diagnostics = try #require(vector.diagnosticData)
        let object = try #require(JSONSerialization.jsonObject(with: diagnostics) as? [String: Any])
        let receipt = try #require(object["widthRetainedArtifactReceipt"] as? [String: Any])
        let digest = SHA256.hash(data: vector.exportPDFData).map { String(format: "%02x", $0) }.joined()
        #expect(receipt["pdfSHA256"] as? String == digest)
        // No source pixels in this authored fixture: fidelity/source accuracy remain unknown.
    }

    @Test func actualDefaultBitmapProducerRetainsAdmittedImageWithoutPDF() throws {
        typealias R = NativeTranslationRenderer
        let (seed, _, _, _) = try widthReceiptFixture(capturePDF: false)
        let plan = try R.prepareRenderSynchronously(layout: seed.inputLayout, image: nil, settings: seed.settings,
            scale: seed.scale, renderBounds: seed.bounds, composeSource: false, outputPixelSize: seed.pixels,
            collectDiagnostics: true) // capturePDF omitted, exactly as the reader.
        let artifact = try #require(plan.retainedWidthArtifact)
        #expect(!plan.capturePDF && artifact.data == nil)
        let final = try R.finishPreparedSynchronously(plan)
        #expect(final.exportPDFData == nil)
        #expect(final.overlayImage.cgImage === artifact.image)
    }

    @Test func actualDefaultAsyncReaderPathReachesBitmapWidthAdmission() async throws {
        typealias R = NativeTranslationRenderer
        let (seed, _, _, _) = try widthReceiptFixture(capturePDF: false)
        let result = try await R.render(image: nil, imageSize: seed.inputLayout.imageSize, items: [],
            settings: seed.settings, targetLanguage: "ko", viewport: seed.inputLayout.viewport,
            scale: seed.scale, preparedLayout: JSONEncoder().encode(seed.inputLayout),
            renderBounds: seed.bounds, composeSource: false, outputPixelSize: seed.pixels,
            collectDiagnostics: true) // no PDF forcing, no planner/provider call with matching saved layout.
        #expect(result.exportPDFData == nil)
        let diagnostics = try #require(result.diagnosticData)
        let object = try #require(JSONSerialization.jsonObject(with: diagnostics) as? [String: Any])
        let receipt = try #require(object["widthRetainedArtifactReceipt"] as? [String: Any])
        #expect(receipt["artifactMode"] as? String == "bitmap")
    }

    @Test(arguments: [false, true])
    func finalizationFailureRestoresPostFixedFlowIncumbent(capturePDF: Bool) throws {
        typealias R = NativeTranslationRenderer
        for failure in ["budget", "worldMutation", "pixelMismatch"] {
            let (seed, item, surface, owner) = try widthReceiptFixture(capturePDF: capturePDF)
            var budget = NativeWidthFinalArtifactAdmission.Budget()
            if failure == "budget" { budget.finalizationCaptures = 0 }
            let session = NativeWidthFinalArtifactAdmission(plan: seed, keptOwners: [], budget: budget)
            var cards = seed.cards, incumbent = seed.cards
            var unknown: Set<String> = [], conditional: Set<String> = []
            _ = try R.commitContourCohortsTiled(cards: &cards, items: [item], owners: [owner],
                surfaces: [item.id: surface], bounds: seed.bounds, sourceRect: seed.layout.sourceRect,
                pixels: seed.pixels, pdfDeviceScale: seed.pdfDeviceScale, verifiedOriginalStyle: [],
                allowsStyleUnknownTrials: true, unknownSourceStyleIDs: &unknown,
                allowsVerifiedBalloonInteriorModelTrials: true, conditionalGeometryIDs: &conditional,
                widthStageCheckpoint: { prior, _, _, _, _ in incumbent = prior },
                widthFinalArtifactAdmission: { session.admission(before: $0, after: $1, ids: $2) })
            #expect(cards[0].item.width > incumbent[0].item.width)
            if failure == "worldMutation" { cards[0].textShift.x += 8 }
            if failure == "pixelMismatch" {
                cards[0].typography = NativeTranslationTypography.layout(text: "한",
                    in: cards[0].item.contentRect.size, style: cards[0].style)
            }
            #expect(try session.finalizeOrRollback(cards: &cards, incumbent: incumbent, diagnosticData: nil) == nil)
            #expect(cards.map { $0.item } == incumbent.map { $0.item })
            #expect(cards.map { $0.textShift } == incumbent.map { $0.textShift })
            #expect(cards.map { $0.typography.rangeBounds } == incumbent.map { $0.typography.rangeBounds })
            #expect(!cards.contains { $0.harmonyRecord["widthRequiresRetainedArtifact"] as? Bool == true })
            let restored = R.PreparedRender(inputLayout: seed.inputLayout, layout: seed.layout, image: seed.image,
                source: seed.source, restoration: seed.restoration, cards: cards, glossCards: seed.glossCards,
                gloss: seed.gloss, settings: seed.settings, bounds: seed.bounds, pixels: seed.pixels,
                scale: seed.scale, composeSource: seed.composeSource, capturePDF: seed.capturePDF,
                pdfDeviceScale: seed.pdfDeviceScale, sourcePatches: seed.sourcePatches, sourcePieces: seed.sourcePieces,
                limitations: seed.limitations, diagnosticData: nil)
            let final = try R.finishPreparedSynchronously(restored)
            #expect(final.overlayImage.cgImage != nil)
            #expect((final.exportPDFData != nil) == capturePDF)
        }
    }
}


extension NativeTextBoxReplacementTests {
    @Test func streamedKeptPredicateMatchesActualRGBAIncludingAAAndPartialRows() throws {
        typealias H = NativeWidthFinalArtifactAdmission
        for size in [CGSize(width: 129, height: 131), CGSize(width: 16384, height: 127)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.opaque = false; format.preferredRange = .standard
            let raster = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                let c = renderer.cgContext
                c.setFillColor(CGColor(gray: 1, alpha: 0.375))
                c.fill(CGRect(x: 0.375, y: 0.625, width: size.width - 1.125, height: 68.375))
                c.setStrokeColor(CGColor(gray: 1, alpha: 0.8125))
                c.setLineWidth(1.375)
                c.move(to: CGPoint(x: 3.375, y: 11.625))
                c.addLine(to: CGPoint(x: size.width - 4.125, y: size.height - 2.375)); c.strokePath()
            }
            let image = try #require(raster.cgImage), rgba = try H.rgba(image)
            let alpha = try H.alphaBytes(rgba), streamed = try H.streamingKept(image)
            var expected = [UInt64](repeating: 0, count: (alpha.count + 63) / 64)
            for k in alpha.indices where alpha[k] > 0 { expected[k >> 6] |= UInt64(1) << UInt64(k & 63) }
            #expect(streamed.bits == expected)
            #expect(streamed.rgbaHash == H.hash(rgba))
            #expect(alpha.contains { $0 > 0 && $0 < 255 })
        }
    }

    @Test func keptBankReuseEvictsOnAuthorityChangeAndKeepsApprovedArtifact() throws {
        typealias R = NativeTranslationRenderer
        typealias H = NativeWidthFinalArtifactAdmission
        for pdf in [false, true] {
            let (plan, item, surface, owner) = try widthReceiptFixture(capturePDF: pdf)
            var before = plan.cards, after = plan.cards, unknown: Set<String> = [], conditional: Set<String> = []
            let producer = H(plan: plan, keptOwners: [])
            _ = try R.commitContourCohortsTiled(cards: &after, items: [item], owners: [owner],
                surfaces: [item.id: surface], bounds: plan.bounds, sourceRect: plan.layout.sourceRect,
                pixels: plan.pixels, pdfDeviceScale: plan.pdfDeviceScale, verifiedOriginalStyle: [],
                allowsStyleUnknownTrials: true, unknownSourceStyleIDs: &unknown,
                allowsVerifiedBalloonInteriorModelTrials: true, conditionalGeometryIDs: &conditional,
                widthStageCheckpoint: { prior, _, _, _, _ in before = prior },
                widthFinalArtifactAdmission: { producer.admission(before: $0, after: $1, ids: $2) })
            #expect(after[0].item.width > before[0].item.width)
            let owners = [CGRect(x: 1.125, y: 16.3125, width: 8.5, height: 82.625)]
            let ids: Set<String> = [item.id]
            var budget = H.Budget(); budget.documentCaptures = 256
            let session = H(plan: plan, keptOwners: owners, budget: budget)
            #expect(session.admission(before: before, after: after, ids: ids) == true)
            #expect(session.documentReceipts.count == (pdf ? 27 : 10))
            #expect(session.admission(before: before, after: after, ids: ids) == true)
            #expect(session.documentReceipts.count == (pdf ? 24 : 9))
            var changed = budget
            #expect(try session.certify(plan: plan, before: before, after: after, ids: ids,
                keptOwners: owners + [CGRect(x: 12.125, y: 12.375, width: 2.5, height: 3.25)], budget: &changed) == true)
            #expect(session.documentReceipts.count == (pdf ? 27 : 10))
            #expect(session.admission(before: before, after: after, ids: ids) == true)
            #expect(session.documentReceipts.count == (pdf ? 27 : 10)) // A-B-A cannot resurrect A.
            var tight = budget
            tight.maximumLiveManagedBytes = 128 * 1024 * 1024 + 48 * 240 * 240
            #expect(try session.certify(plan: plan, before: before, after: after, ids: ids,
                keptOwners: owners, budget: &tight) == true)
            #expect(session.documentReceipts.count == (pdf ? 27 : 10))
            #expect(session.admission(before: before, after: after, ids: ids) == true)
            #expect(session.documentReceipts.count == (pdf ? 27 : 10)) // Fallback also retired the bank.
            let sealed = try #require(session.finalizeOrRollback(cards: &after, incumbent: before, diagnosticData: nil))
            let artifact = try #require(sealed.retainedWidthArtifact)
            let result = try R.finishPreparedSynchronously(sealed)
            #expect(result.overlayImage.cgImage === artifact.image)
            #expect(result.exportPDFData == artifact.data) // RAW approved bytes, never canonicalized bytes.
            session.cancel()
            #expect(session.admission(before: before, after: after, ids: ids) == nil)
            #expect(throws: CancellationError.self) { _ = try session.finalized(cards: after, diagnosticData: nil) }
        }
    }
}
