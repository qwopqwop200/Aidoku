import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeSlantedRendererAdapterTests {
    private func fixture(korean: Bool = false) throws -> (NativeTranslationLayoutItem, NativeTranslationLayout, IPhoneOverlaySettings) {
        var data = Data(#"{"id":"slanted-adapter","text":"SOURCE WORDS","sourceBounds":[0.15,0.2,0.8,0.5],"sourceFrame":[0,0,240,200],"sourceFontSize":14,"sourceColorEligible":true,"x":30,"y":40,"width":160,"height":100,"fontSize":12,"lineHeight":14.4,"rotation":0.2,"paddingTop":2,"paddingRight":2,"paddingBottom":2,"paddingLeft":2}"#.utf8)
        if korean {
            var payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            payload["fontScript"] = "korean"; payload["wrappingScript"] = "korean"
            data = try JSONSerialization.data(withJSONObject: payload)
        }
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: data)
        let size = CGSize(width: 240,height: 200)
        let layout = NativeTranslationLayout(imageSize: size,sourceRect: CGRect(origin: .zero,size: size),viewport: size,items: [item])
        var settings = IPhoneOverlaySettings(visible: true,mode: .translateOnly,colorMode: .white,opacity: 1,
            textPlacement: .replace,subtitlePosition: .bottom,subtitleMaxLines: 2,subtitleContextSentences: 0)
        settings.preserveSourceColors = true
        return (item,layout,settings)
    }
    private func card(_ item: NativeTranslationLayoutItem) -> NativeTranslationRenderer.Card {
        let style = NativeTranslationTypography.Style(fontSize: item.fontSize,lineHeight: item.lineHeight)
        var card = NativeTranslationRenderer.Card(item: item,
            typography: NativeTranslationTypography.layout(text: item.text,in: item.contentRect.size,style: style),style: style,
            drawsPanel: true,background: CGColor(gray: 1,alpha: 1),usesFallbackVeil: false,
            lightSurface: true,heavyStrokeWidth: 0,finalFontSize: item.fontSize)
        card.sourcePanels = [.init(rect: item.rect,background: [255,255,255],coverage: [item.rect])]
        return card
    }
    @Test func sizeOnlySlantedStyleRetainsPreformattedChildrenAndParentDisplay() throws {
        var (item, layout, settings) = try fixture(korean: true)
        item.typesettingText = "SOURCE WORDS\n SECOND ROW"
        item.typesettingQuoteMode = nil
        item.typesettingPreformattedRows = true
        item.typesettingBlockDisplay = true
        let context = NativeTranslationRenderer.SlantedContext(layout: layout, source: nil, settings: settings)
        let appearance = NativeTranslationRestoration.Appearance(foreground: CGColor(gray: 0, alpha: 1),
            background: CGColor(gray: 1, alpha: 1), restored: false)
        let trial = NativeSlantedTypographyTrial.Candidate(rect: item.rect, font: 14, pitch: 16.8,
            padding: [2,2,2,2])
        let style = context.style(item: item, appearance: appearance, candidate: trial)
        #expect(style.usesPreformattedBlockRows && !style.usesBlockWordLayout)
        #expect(style.blockWordLayoutUsesTopPadding)
        #expect(style.fontSize == 14 && style.lineHeight == 16.8)
        #expect(style.horizontalWrapping == .keepAllWithEmergency)
        item.typesettingStrictLineBreak = true
        #expect(context.style(item: item, appearance: appearance, candidate: trial).horizontalWrapping == .normal)
    }

    @Test func nativeShapingAdmissionCommitsFontForegroundAndCertifiedSurface() throws {
        let (item,layout,settings) = try fixture()
        let context = NativeTranslationRenderer.SlantedContext(layout: layout,source: nil,settings: settings)
        let appearance = NativeTranslationRestoration.Appearance(foreground: NativeTranslationRenderer.color([40,60,80]),
            background: CGColor(gray: 1,alpha: 1),restored: true,erasureComplete: true,
            sourceSample: ["foreground":[40.0,60.0,80.0],"background":[255.0,255.0,255.0]])
        let proof = NativeSlantedRestoration.ProofRaster(width: 340,height: 340,box: [80,80,160,100],
            safe: Array(repeating: 1,count: 340*340),luminance: Array(repeating: 255,count: 340*340),auxiliary: [])
        #expect(context.admit(item: item,appearance: appearance,proof: proof,scale: 1))
        let accepted = try #require(context.results[item.id])
        #expect(accepted.accepted && accepted.measurement?.glyphs.isEmpty == false)
        #expect(accepted.histogram?.reduce(0,+) ?? 0 > 0)
        #expect(context.lockedIDs == [item.id])
        let initial = context.applyInitial(to: layout)
        #expect(Double(initial.items[0].fontSize) == accepted.candidate.font)
        var restoration = NativeTranslationRestoration.Result()
        restoration.appearances[item.id] = appearance
        var cards = [card(item)]
        NativeTranslationRenderer.applySlantedTrials(cards: &cards,restoration: &restoration,layout: initial,
            source: nil,settings: settings,context: context)
        let committed = try #require(cards[0].slantedTrial)
        #expect(Double(cards[0].item.fontSize) == committed.candidate.font)
        #expect(Double(cards[0].style.fontSize) == committed.candidate.font)
        #expect(NativeTranslationRenderer.rgb(cards[0].style.foreground) == committed.foreground)
        #expect(cards[0].typographyWidth.map(Double.init) == Double(cards[0].item.contentRect.width) * committed.candidate.condense)
        #expect(cards[0].sourcePanels.isEmpty && !cards[0].drawsPanel)
        #expect(cards[0].slantedClip?.count == 4)
        #expect(restoration.appearances[item.id]?.sourceGlyphsVerified == true)
    }
    @Test func rejectedOwnershipKeepsOriginalOpaqueFallback() throws {
        let (item,layout,settings) = try fixture()
        let context = NativeTranslationRenderer.SlantedContext(layout: layout,source: nil,settings: settings)
        let appearance = NativeTranslationRestoration.Appearance(foreground: CGColor(gray: 0,alpha: 1),background: nil,restored: false)
        let proof = NativeSlantedRestoration.ProofRaster(width: 340,height: 340,box: [80,80,160,100],
            safe: Array(repeating: 0,count: 340*340),luminance: Array(repeating: 255,count: 340*340),auxiliary: [])
        #expect(!context.admit(item: item,appearance: appearance,proof: proof,scale: 1))
        #expect(context.lockedIDs.isEmpty)
        #expect(context.applyInitial(to: layout) == layout)
        var restoration = NativeTranslationRestoration.Result(), cards = [card(item)]
        let original = cards[0]
        NativeTranslationRenderer.applySlantedTrials(cards: &cards,restoration: &restoration,layout: layout,
            source: nil,settings: settings,context: context)
        #expect(cards[0].item == original.item && cards[0].style.fontSize == original.style.fontSize)
        #expect(cards[0].sourcePanels[0].rect == original.sourcePanels[0].rect && cards[0].drawsPanel)
        #expect(cards[0].slantedTrial == nil)
    }
    @Test func cleanupPreparationKeepsDescriptorGlyphClipAndCachedRecoveryBudget() throws {
        let (item, original, settings) = try fixture()
        let layout = NativeTranslationLayout(imageSize: original.imageSize,
            sourceRect: CGRect(x: 0, y: 10, width: 240, height: 180), viewport: original.viewport,
            items: [item], readableRecoveryRemaining: 73, sourceObjectFit: "fill")
        let cleanup = NativeSourceSurfaceGeometry.Geometry(frame: CGRect(x: 15, y: 20, width: 200, height: 150),
            clip: CGRect(x: 20, y: 25, width: 190, height: 140))
        let context = NativeTranslationRenderer.SlantedContext(layout: layout, source: nil, settings: settings, cleanupGeometry: cleanup)
        let appearance = NativeTranslationRestoration.Appearance(foreground: CGColor(gray: 0, alpha: 1),
            background: CGColor(gray: 1, alpha: 1), restored: true, erasureComplete: true)
        let proof = NativeSlantedRestoration.ProofRaster(width: 340, height: 340, box: [80,80,160,100],
            safe: Array(repeating: 1, count: 340 * 340), luminance: Array(repeating: 255, count: 340 * 340), auxiliary: [])
        #expect(context.admit(item: item, appearance: appearance, proof: proof, scale: 1))
        let entry = try #require(context.entries[item.id])
        #expect(entry.frame == CGRect(x: 0, y: 0, width: 240, height: 200))
        #expect(entry.cropFrame == cleanup.frame)
        #expect(entry.sourceBounds == CGRect(x: 36, y: 40, width: 192, height: 100))
        let initial = context.applyInitial(to: layout)
        #expect(initial.readableRecoveryRemaining == 73 && initial.sourceObjectFit == "fill")
        var restoration = NativeTranslationRestoration.Result(), cards = [card(item)]
        restoration.appearances[item.id] = appearance
        NativeTranslationRenderer.applySlantedTrials(cards: &cards, restoration: &restoration,
            layout: initial, source: nil, settings: settings, context: context)
        let committed = try #require(cards[0].slantedTrial), polygon = try #require(cards[0].slantedClip)
        let c = committed.candidate, cs = cos(c.angle), sn = sin(c.angle)
        let world = polygon.map { point -> CGPoint in
            let x = (point[0] - Double(c.rect.width) / 2) * c.condense
            let y = point[1] - Double(c.rect.height) / 2
            return CGPoint(x: Double(c.rect.midX) + x * cs - y * sn, y: Double(c.rect.midY) + x * sn + y * cs)
        }
        #expect(abs((world.map(\.x).min() ?? 1) - 0) < 1e-6)
        #expect(abs((world.map(\.x).max() ?? 1) - 240) < 1e-6)
        #expect(abs((world.map(\.y).min() ?? 1) - 0) < 1e-6)
        #expect(abs((world.map(\.y).max() ?? 1) - 200) < 1e-6)
    }

    @Test(arguments: [false, true])
    func acceptedSlantedResultReplacesOrDeletesCanonicalDisplayGrowth(_ clear: Bool) throws {
        var (item,layout,settings) = try fixture()
        item.typesettingDisplayGrowth = "old-growth"
        let context = NativeTranslationRenderer.SlantedContext(layout:layout,source:nil,settings:settings)
        let appearance = NativeTranslationRestoration.Appearance(foreground:CGColor(gray:0,alpha:1),
            background:CGColor(gray:1,alpha:1),restored:true,erasureComplete:true)
        let proof = NativeSlantedRestoration.ProofRaster(width:340,height:340,box:[80,80,160,100],
            safe:Array(repeating:1,count:340*340),luminance:Array(repeating:255,count:340*340),auxiliary:[])
        #expect(context.admit(item:item,appearance:appearance,proof:proof,scale:1))
        var accepted = try #require(context.results[item.id])
        accepted.metadata["displayGrowth"] = clear ? nil : "restored-readable"
        context.results[item.id] = accepted
        #expect(context.applying(accepted,to:item).typesettingDisplayGrowth == accepted.metadata["displayGrowth"])
        var restoration = NativeTranslationRestoration.Result(),cards = [card(item)]
        restoration.appearances[item.id] = appearance
        cards[0].typographyDisplayGrowth = "old-growth"
        NativeTranslationRenderer.applySlantedTrials(cards:&cards,restoration:&restoration,layout:layout,
            source:nil,settings:settings,context:context)
        let committed = try #require(cards[0].slantedTrial)
        #expect(cards[0].item.typesettingDisplayGrowth == committed.metadata["displayGrowth"])
        #expect(cards[0].typographyDisplayGrowth == cards[0].item.typesettingDisplayGrowth)
        if clear { #expect(cards[0].item.typesettingDisplayGrowth == nil) }
    }

}
