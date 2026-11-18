import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct NativeOriginalColorTests {
    @Test
    func visibleOrangeOutlinePreservesOriginalWhiteInsteadOfGray() throws {
        let fill = [253.0, 254, 251], panel = [227.0, 241, 236], stroke = [225.0, 90, 3]
        #expect(NativeTranslationRenderer.textBoxFillContrast(fill, panel: panel) < 4.5)
        let displayed = try #require(NativeTranslationRenderer.textBoxReadableForeground(fill, panel: panel,
            outline: stroke, visibleOutlinePixels: 1.25, opaqueStrokeThenFill: true))
        #expect(displayed == fill)
        #expect(NativeTranslationRenderer.textBoxReadableOutlineWidth(fontSize: 8) == 2.25)
        #expect(abs(NativeTranslationRenderer.textBoxReadableOutlineWidth(fontSize: 20) - 3.6) < 0.000001)
    }

    @Test(arguments: [0.0, 0.999, Double.nan, Double.infinity])
    func unobservableOutlineDoesNotDisableFillProtection(width: Double) throws {
        let fill = [253.0, 254, 251], panel = [227.0, 241, 236]
        let displayed = try #require(NativeTranslationRenderer.textBoxReadableForeground(fill, panel: panel,
            outline: [225, 90, 3], visibleOutlinePixels: width, opaqueStrokeThenFill: true))
        #expect(displayed != fill)
        #expect(NativeTranslationRenderer.textBoxFillContrast(displayed, panel: panel) >= 4.5)
    }

    @Test(arguments: [nil, [235.0, 238, 236], [253.0, 254, 251], [227.0, 241, 236],
                      [Double.nan, 90, 3], [225.0, 90]] as [[Double]?])
    func unreliableStrokeEvidenceRetainsFillFallback(stroke: [Double]?) throws {
        let fill = [253.0, 254, 251], panel = [227.0, 241, 236]
        let displayed = try #require(NativeTranslationRenderer.textBoxReadableForeground(fill, panel: panel,
            outline: stroke, visibleOutlinePixels: 2, opaqueStrokeThenFill: true))
        #expect(displayed != fill)
        #expect(NativeTranslationRenderer.textBoxFillContrast(displayed, panel: panel) >= 4.5)
    }

    @Test
    func unknownPaintOrderAndInvalidFontCannotInventReadableOutline() throws {
        let fill = [253.0, 254, 251], panel = [227.0, 241, 236]
        let displayed = try #require(NativeTranslationRenderer.textBoxReadableForeground(fill, panel: panel,
            outline: [225, 90, 3], visibleOutlinePixels: 2, opaqueStrokeThenFill: false))
        #expect(displayed != fill)
        for fontSize in [CGFloat.nan, .infinity, 0, -1] {
            #expect(NativeTranslationRenderer.textBoxReadableOutlineWidth(fontSize: fontSize) == 0)
        }
        #expect(NativeTranslationRenderer.textBoxReadableForeground([0, 0, 0], panel: panel) == [0, 0, 0])
    }

    @Test(arguments: [[255, 255, 255], [70, 130, 210], [18, 25, 35]])
    func sourceHostUsesObservedPaperEndpoints(rgb: [Int]) throws {
        let roi = CGRect(x: 0, y: 0, width: 96, height: 96)
        let owner = CGRect(x: 28, y: 20, width: 40, height: 56)
        var pixels = [UInt8](repeating: 255, count: 96 * 96 * 4)
        for y in 0..<96 {
            for x in 0..<96 {
                let ink = x >= 42 && x < 46 && y >= 32 && y < 64
                for channel in 0..<3 {
                    pixels[(y * 96 + x) * 4 + channel] = UInt8(ink ? 255 - rgb[channel] : rgb[channel])
                }
            }
        }
        let budget = NativeOwnerExteriorBGPrediction.Budget()
        let result = try NativeOwnerHostBackgroundPrediction.predict(rgba: pixels, width: 96, height: 96,
            sourceROI: roi, owner: owner, peers: [], budget: budget)
        #expect(result["accepted"] as? Bool == true)
        #expect(result["selected"] as? [Int] == rgb)
        #expect(result["additionalCapturePixels"] as? Int == 0)
        #expect(result["fitHeldAddressOverlap"] as? Int == 0)
        #expect(budget.spent > 0 && budget.remaining >= 0)
        #expect(JSONSerialization.isValidJSONObject(result))
        let blocked = try NativeOwnerHostBackgroundPrediction.predict(rgba: pixels, width: 96, height: 96,
            sourceROI: roi, owner: owner, peers: [owner], budget: .init())
        #expect(blocked["accepted"] as? Bool == false)
    }

    @Test
    func sourceHostRejectsInvalidCaptureAndTransparentEvidence() throws {
        let roi = CGRect(x: 0, y: 0, width: 96, height: 96)
        let owner = CGRect(x: 28, y: 20, width: 40, height: 56)
        let budget = NativeOwnerExteriorBGPrediction.Budget()
        let invalid = try NativeOwnerHostBackgroundPrediction.predict(rgba: [], width: Int.max, height: 2,
            sourceROI: roi, owner: owner, peers: [], budget: budget)
        #expect(invalid["status"] as? String == "invalid-geometry")
        #expect(budget.spent == 0)
        let transparent = try NativeOwnerHostBackgroundPrediction.predict(
            rgba: [UInt8](repeating: 0, count: 96 * 96 * 4), width: 96, height: 96,
            sourceROI: roi, owner: owner, peers: [], budget: budget)
        #expect(transparent["accepted"] as? Bool == false)
        #expect(transparent["selected"] == nil || transparent["selected"] is NSNull)
    }

    @Test(arguments: [[255, 255, 255], [0, 0, 0], [233, 143, 184]])
    func disjointExteriorPredictsSourceSurfaceWithoutUsingLetterColor(rgb: [Int]) throws {
        let roi = CGRect(x: 0, y: 0, width: 96, height: 96)
        let owner = CGRect(x: 36, y: 24, width: 24, height: 48)
        var pixels = [UInt8](repeating: 255, count: 96 * 96 * 4)
        for y in 0..<96 {
            for x in 0..<96 {
                let inside = owner.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
                for channel in 0..<3 {
                    pixels[(y * 96 + x) * 4 + channel] = UInt8(inside ? 255 - rgb[channel] : rgb[channel])
                }
            }
        }
        let budget = NativeOwnerExteriorBGPrediction.Budget()
        budget.recording = true
        let prediction = try NativeOwnerExteriorBGPrediction.predict(rgba: pixels, width: 96, height: 96,
            roi: roi, owner: owner, peers: [], budget: budget, id: "source-owner")
        budget.recording = false
        #expect(prediction == rgb.map(Double.init))
        #expect(budget.observations["source-owner"]?["accepted"] as? Bool == true)
        let replay = NativeOwnerExteriorBGPrediction.Budget()
        #expect(replay.replay(budget.charges))
        #expect(replay.remaining == budget.remaining && replay.spent == budget.spent)
        #expect(JSONSerialization.isValidJSONObject(budget.observations))
    }

    @Test
    func disjointExteriorUnknownAndLogicalReplayDoNotInventPredictions() throws {
        let roi = CGRect(x: 0, y: 0, width: 96, height: 96)
        let owner = CGRect(x: 36, y: 24, width: 24, height: 48)
        let transparent = [UInt8](repeating: 0, count: 96 * 96 * 4)
        let budget = NativeOwnerExteriorBGPrediction.Budget()
        let unknown = try NativeOwnerExteriorBGPrediction.predict(rgba: transparent, width: 96, height: 96,
            roi: roi, owner: owner, peers: [], budget: budget, id: "transparent")
        #expect(unknown == nil)
        #expect(budget.observations["transparent"]?["accepted"] as? Bool == false)
        let empty = NativeOwnerExteriorBGPrediction.Budget()
        empty.remaining = 0
        let quota = try NativeOwnerExteriorBGPrediction.predict(rgba: transparent, width: 96, height: 96,
            roi: roi, owner: owner, peers: [], budget: empty, id: "quota")
        #expect(quota == nil && empty.spent == 0 && empty.remaining == 0)
        #expect(empty.observations["quota"]?["status"] as? String == "quota")
        let replay = NativeOwnerExteriorBGPrediction.Budget()
        replay.remaining = 10
        #expect(!replay.replay([.init(cost: 3, count: 2), .init(cost: 768, count: 1)]))
        #expect(replay.spent == 6 && replay.remaining == 4)
        #expect(!replay.replay([.init(cost: -1, count: 1)]))
        #expect(replay.spent == 6 && replay.remaining == 4)
    }

    @Test
    func sourceBandAuditKeepsRejectedRoleAndNeverClaimsFullPenWidth() throws {
        let prior: [String: Any] = ["samplePixels": 2.5, "glyphPixels": 20.0, "relativeToGlyph": 0.125,
            "sampleScale": 0.5, "method": "external band"]
        let audit = NativeOriginalColorFidelity.sourceBandAudit(finalRole: NSNull(), preRole: prior)
        #expect(audit["finalRoleMeasured"] as? Bool == false)
        #expect(audit["preRoleMeasured"] as? Bool == true)
        #expect(audit["finalRoleBand"] is NSNull)
        let observed = try #require(audit["preRoleBand"] as? [String: Any])
        #expect(observed["samplePixels"] as? Double == 2.5)
        #expect(observed["sampleScale"] as? Double == 0.5)
        #expect(audit["sourceFullPenWidthPixels"] is NSNull)
        #expect(audit["sourceWidthAccuracy"] is NSNull)
        #expect(JSONSerialization.isValidJSONObject(audit))
    }

    @Test(arguments: [Double.nan, Double.infinity, -1.0, 0.0])
    func invalidBandEvidenceRemainsUnknown(band: Double) {
        let invalid: [String: Any] = ["samplePixels": band, "glyphPixels": 20.0, "relativeToGlyph": 0.1]
        let audit = NativeOriginalColorFidelity.sourceBandAudit(finalRole: invalid, preRole: nil)
        #expect(audit["finalRoleMeasured"] as? Bool == false)
        #expect(audit["finalRoleBand"] is NSNull)
        #expect(audit["preRoleMeasured"] as? Bool == false)
        #expect(JSONSerialization.isValidJSONObject(audit))
    }

    @Test(arguments: [false, true])
    func renderedInkPreservesPredictionAndAppliesFillOnlyReadability(dark: Bool) throws {
        let size = CGSize(width: 180, height: 120)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: size, format: format).image { output in
            let context = output.cgContext
            context.setFillColor(NativeTranslationRenderer.color(dark ? [12, 18, 25] : [245, 240, 235]))
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(NativeTranslationRenderer.color([170, 30, 80]))
            for x in [55, 80, 105] { context.fill(CGRect(x: x, y: 40, width: 9, height: 35)) }
        }
        let value: [String: Any] = ["id": "source-ink", "text": "가나다", "x": 45, "y": 30,
            "width": 80, "height": 55, "fontSize": 12, "lineHeight": 15,
            "sourceBounds": [55.0 / 180, 40.0 / 120, 59.0 / 180, 35.0 / 120],
            "sourceFrame": [0, 0, 180, 120], "fontScript": "korean", "wrappingScript": "korean"]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: value))
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size),
            viewport: size, items: [item])
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: source,
            settings: ReaderTranslationSettings.defaultOverlay, collectDiagnostics: true)
        let card = try #require(plan.cards.first)
        let diagnostics = try #require(plan.diagnosticData)
        let object = try #require(JSONSerialization.jsonObject(with: diagnostics) as? [String: Any])
        let cards = try #require(object["cards"] as? [[String: Any]])
        let predicted = try #require(cards.first?["sourcePaintPrediction"] as? [String: Any])
        let widthAudit = try #require(predicted["sourceBandWidthAudit"] as? [String: Any])
        #expect(widthAudit["sourceFullPenWidthPixels"] is NSNull)
        #expect(widthAudit["sourceWidthAccuracy"] is NSNull)
        let panelPrediction = try #require(NativeSourceColorSampler.rgb(cards.first?["backgroundPrediction"]))
        #expect(NativeTranslationRenderer.rgb(card.background) == panelPrediction)
        #expect(cards.first?["backgroundRefined"] as? Bool == false)
        #expect(cards.first?["backgroundCorrectionEligible"] as? Bool == false)
        let fidelity = try #require(cards.first?["originalColorFidelity"] as? [String: Any])
        #expect((fidelity["sourceAccuracy"] as? NSNull) != nil)
        let fill = try #require(NativeSourceColorSampler.rgb(predicted["foreground"]))
        let display = try #require(NativeTranslationRenderer.rgb(card.style.foreground))
        let needsOverride = NativeTranslationRenderer.textBoxFillContrast(fill, panel: panelPrediction) < 4.5
        #expect(predicted["readabilityColorOverride"] as? Bool == needsOverride)
        #expect(NativeTranslationRenderer.textBoxFillContrast(display, panel: panelPrediction) >= 4.5)
        #expect((fidelity["mismatchedColorCount"] as? Int) == (needsOverride ? 1 : 0))
        if !needsOverride { #expect(display == fill) }
        // Known authored colors test estimation accuracy separately from prediction/paint equality.
        #expect(zip(fill, [170.0, 30, 80]).allSatisfy { abs($0 - $1) <= 8 })
        if let stroke = NativeSourceColorSampler.rgb(predicted["stroke"]) {
            #expect(NativeTranslationRenderer.rgb(card.style.outline) == stroke)
        } else {
            #expect(card.style.outline == nil && card.style.outlineWidth == 0)
        }
    }

    @Test(arguments: [0.0, 16.0, 96.0, 127.0, 180.0, 240.0, 255.0])
    func unreadableFillChangesWithoutChangingPanelOrStroke(panelChannel: Double) throws {
        let panel = [panelChannel, panelChannel, panelChannel]
        let fill = panel
        let result = try #require(NativeTranslationRenderer.textBoxReadableForeground(fill, panel: panel))
        #expect(result != fill)
        #expect(NativeTranslationRenderer.textBoxFillContrast(result, panel: panel) >= 4.5)
        #expect(panel == [panelChannel, panelChannel, panelChannel])
        #expect(NativeTranslationRenderer.textBoxReadableForeground(result, panel: panel) == result)
    }

    @Test func readableColoredFillIsExactAndInvalidEvidenceAbstains() {
        let fill = [8.0, 80.0, 140.0], panel = [249.0, 247.0, 247.0]
        #expect(NativeTranslationRenderer.textBoxReadableForeground(fill, panel: panel) == fill)
        #expect(NativeTranslationRenderer.textBoxReadableForeground([Double.nan, 0, 0], panel: panel) == nil)
        #expect(NativeTranslationRenderer.textBoxReadableForeground(fill, panel: [255, 255]) == nil)
        #expect(NativeTranslationRenderer.textBoxReadableForeground([256, 0, 0], panel: panel) == nil)
    }

    private func rimRoleFixture(transparentInterior: Bool = false)
        -> (rgba: [UInt8], owner: CGRect, peers: [CGRect]) {
        var rgba = [UInt8](repeating: 0, count: 32 * 32 * 4)
        func paint(_ rect: CGRect, _ color: [UInt8]) {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let offset = (y * 32 + x) * 4
                    for channel in 0..<4 { rgba[offset + channel] = color[channel] }
                }
            }
        }
        let owner = CGRect(x: 10, y: 10, width: 12, height: 12)
        let peers = [CGRect(x: 7, y: 10, width: 3, height: 12), CGRect(x: 22, y: 10, width: 3, height: 12)]
        paint(CGRect(x: 0, y: 0, width: 32, height: 32), [40, 40, 40, 255])
        paint(CGRect(x: 4, y: 4, width: 24, height: 24), [255, 255, 255, 255])
        paint(CGRect(x: 6, y: 6, width: 20, height: 20),
            transparentInterior ? [0, 0, 0, 0] : [209, 209, 209, 255])
        paint(owner, [170, 30, 80, 255])
        for peer in peers { paint(peer, transparentInterior ? [0, 0, 0, 255] : [170, 30, 80, 255]) }
        return (rgba, owner, peers)
    }

    @Test func matchingPeerPixelsCannotCertifyOwnerBackground() throws {
        let f = rimRoleFixture(), roi = CGRect(x: 0, y: 0, width: 32, height: 32)
        let unrestricted = try #require(try NativeTextBoxContainment.measured(
            rgba: f.rgba, width: 32, height: 32, roi: roi, owner: f.owner))
        let excluded = try #require(try NativeTextBoxContainment.measured(
            rgba: f.rgba, width: 32, height: 32, roi: roi, owner: f.owner, excluding: f.peers))
        #expect(unrestricted.color == [170.0, 30, 80])
        #expect(excluded.color == nil)
        #expect(excluded.colorEvidence == "rim-candidate-unavailable-or-unsupported")
        #expect(excluded.rect == unrestricted.rect)
        #expect(excluded.spans.map { [$0.0, $0.1] } == unrestricted.spans.map { [$0.0, $0.1] })
    }

    @Test func transparentHolesCannotDominateRimColorCandidate() throws {
        let f = rimRoleFixture(transparentInterior: true), roi = CGRect(x: 0, y: 0, width: 32, height: 32)
        let transparent = try #require(try NativeTextBoxContainment.measured(
            rgba: f.rgba, width: 32, height: 32, roi: roi, owner: f.owner))
        var opaqueRGBA = f.rgba
        for offset in stride(from: 3, to: opaqueRGBA.count, by: 4) { opaqueRGBA[offset] = 255 }
        let opaque = try #require(try NativeTextBoxContainment.measured(
            rgba: opaqueRGBA, width: 32, height: 32, roi: roi, owner: f.owner))
        #expect(transparent.color == nil)
        #expect(transparent.colorEvidence == "rim-candidate-unavailable-or-unsupported")
        #expect(opaque.color == [0.0, 0, 0])
        #expect(transparent.rect == opaque.rect)
        #expect(transparent.spans.map { [$0.0, $0.1] } == opaque.spans.map { [$0.0, $0.1] })
    }

    @Test(arguments: [0.0, 209.0, 245.0])
    func whiteEnclosingGlyphBandsDoNotProvidePanelColor(background: Double) throws {
        let size = CGSize(width: 180, height: 120)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: size, format: format).image { output in
            let c = output.cgContext
            c.setFillColor(NativeTranslationRenderer.color([background, background, background]))
            c.fill(CGRect(origin: .zero, size: size))
            c.setStrokeColor(UIColor.white.cgColor); c.setLineWidth(3)
            c.stroke(CGRect(x: 20, y: 20, width: 140, height: 80))
            for x in [55, 80, 105] {
                c.setFillColor(UIColor.white.cgColor)
                c.fill(CGRect(x: x - 2, y: 38, width: 13, height: 39))
                c.setFillColor(NativeTranslationRenderer.color([170, 30, 80]))
                c.fill(CGRect(x: x, y: 40, width: 9, height: 35))
            }
        }
        let value: [String: Any] = ["id": "white-bands", "text": "가나다", "x": 45, "y": 30,
            "width": 80, "height": 55, "fontSize": 12, "lineHeight": 15,
            "sourceBounds": [55.0 / 180, 40.0 / 120, 59.0 / 180, 35.0 / 120],
            "sourceFrame": [0, 0, 180, 120], "fontScript": "korean", "wrappingScript": "korean"]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: value))
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size),
            viewport: size, items: [item])
        let prepared = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: source,
            settings: ReaderTranslationSettings.defaultOverlay, collectDiagnostics: true)
        let card = try #require(prepared.cards.first)
        let actual = try #require(NativeTranslationRenderer.rgb(card.background))
        // Ring resampling/quantized-bin averaging can include a one-byte halo
        // contribution. This bounds color accuracy, not just nonblack appearance.
        #expect(actual.allSatisfy { abs($0 - background) <= 1 })
        if background == 0 { #expect(actual == [0, 0, 0]) }
        #expect(card.background.alpha == 1)
    }

    @Test
    func missingForecastIsNotPerfectColorAccuracyOrKnownNoOutline() throws {
        let result = NativeOriginalColorFidelity.evaluate(panelPrediction: nil, foregroundPrediction: nil,
            strokePrediction: nil, panelPaint: [255, 255, 255], foregroundPaint: [0, 0, 0], strokePaint: nil)
        #expect(result["measuredColorCount"] as? Int == 0)
        #expect(result["unmeasuredColorCount"] as? Int == 3)
        for name in ["panel", "foreground", "stroke"] {
            let observation = try #require(result[name] as? [String: Any])
            #expect(observation["state"] as? String == "unmeasured")
            #expect(observation["maxRGBChannelError"] is NSNull)
        }
    }

    @Test
    func knownForecastWithoutActivePanelOrStrokeIsUnmeasured() throws {
        let result = NativeOriginalColorFidelity.evaluate(panelPrediction: [245, 240, 235],
            foregroundPrediction: [170, 30, 80], strokePrediction: [255, 255, 255],
            panelPaint: nil, foregroundPaint: [170, 30, 80], strokePaint: nil)
        #expect(result["measuredColorCount"] as? Int == 1)
        #expect(result["unmeasuredColorCount"] as? Int == 2)
        #expect(result["mismatchedColorCount"] as? Int == 0)
        #expect(result["rasterMeasurement"] is NSNull)
        #expect(result["sourceAccuracy"] is NSNull)
        for name in ["panel", "stroke"] {
            let observation = try #require(result[name] as? [String: Any])
            #expect(observation["predictionAvailable"] as? Bool == true)
            #expect(observation["paintAvailable"] as? Bool == false)
            #expect(observation["state"] as? String == "unmeasured")
            #expect(observation["maxRGBChannelError"] is NSNull)
        }
    }

    @Test
    func recolorAndInventedOutlineCannotBecomeMeasuredSuccess() throws {
        let result = NativeOriginalColorFidelity.evaluate(panelPrediction: [12, 18, 25],
            foregroundPrediction: [170, 30, 80], strokePrediction: [240, 220, 200],
            panelPaint: [14, 18, 25], foregroundPaint: [0, 0, 0], strokePaint: [240, 220, 200])
        #expect(result["measuredColorCount"] as? Int == 3)
        #expect(result["mismatchedColorCount"] as? Int == 2)
        let panel = try #require(result["panel"] as? [String: Any])
        #expect(panel["maxRGBChannelError"] as? Double == 2)
        let invalid = NativeOriginalColorFidelity.evaluate(panelPrediction: [Double.nan, 0, 0],
            foregroundPrediction: [0, 0], strokePrediction: nil,
            panelPaint: [0, 0, 0], foregroundPaint: [0, 0, 0], strokePaint: [255, 255, 255])
        #expect(invalid["measuredColorCount"] as? Int == 0)
        #expect(invalid["unmeasuredColorCount"] as? Int == 3)
    }
}
