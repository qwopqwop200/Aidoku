import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativePlateGrowthScrollTests {
    @Test(arguments: [0, 1, 2])
    func acceptedWideGrowthClearsOnlyItsActualParentOverflow(relation: Int) throws {
        var value = try card(text: "AB CD", width: 80, font: 10)
        value.sourcePanels = [.init(rect: value.item.rect, background: [255,255,255], coverage: [value.item.rect])]
        value.sourcePanels[0].overflowClip = true
        value.captionParentPlate = relation != 2
        value.captionParentOwner = .init(cardIndex: relation == 1 ? 7 : 3, panelIndex: 0)
        let original = value
        NativeTranslationRenderer.releaseWidePlateOverflow(&value, cardIndex: 3, panelIndex: 0)
        #expect(value.sourcePanels[0].overflowClip == (relation != 0))
        #expect(original.sourcePanels[0].overflowClip)
        #expect(value.sourcePanels[0].rect == original.sourcePanels[0].rect)
        #expect(value.captionParentOwner == original.captionParentOwner)
    }
    private func card(text: String = "달칵!", width: CGFloat = 83.5, font: CGFloat = 42.75, scale: CGFloat = 1,
                      vertical: Bool = false, staleFont: CGFloat? = nil, sourceGlyph: CGFloat? = nil) throws -> NativeTranslationRenderer.Card {
        var fields: [String: Any] = ["id": "scroll-probe", "text": text, "typesettingText": text,
            "typesettingQuoteMode": 0, "fontScript": "korean", "wrappingScript": "korean",
            "sourceBounds": [0.0,0.0,0.5,0.5], "sourceFrame": [0,0,200,200],
            "x": 0, "y": 0, "width": width, "height": 100, "fontSize": staleFont ?? font,
            "lineHeight": (staleFont ?? font) * 1.2, "vertical": vertical]
        if let sourceGlyph { fields["sourceFontSize"] = sourceGlyph }
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: font,
            vertical: vertical, lineHeight: font * 1.2,
            optimizesKoreanWrapping: false, horizontalScale: scale, usesBlockWordLayout: true)
        let typography = NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style)
        return NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            drawsPanel: false, background: NativeTranslationRenderer.color([255,255,255]),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: font)
    }

    @Test(arguments: [0,1,2,3,4,5,6,7], [false,true])
    func plateAndRoomTrialsInheritLiveWrappingMode(mode: Int, room: Bool) throws {
        var baseline = try card(text: "안녕  세상 함께 출발하자", width: 48, font: 9)
        let wrapping = mode % 4
        baseline.style.horizontalWrapping = wrapping == 1 ? .keepAll : wrapping == 2 ? .keepAllWithEmergency : .normal
        baseline.style.horizontalWhitespace = mode < 4 ? .preWrap : .normal
        baseline.style.keepsWholeWords = wrapping == 3
        baseline.style.balancesHorizontalLines = true
        baseline.item.typesettingText = "안녕  세상\n 함께 출발하자"
        baseline.item.typesettingQuoteMode = 0
        baseline.style.usesBlockWordLayout = true
        let proposal = NativeTypographyPlateGrowth.Proposal(box: baseline.item.rect, font: 10, pitch: 12,
            padding: 3, horizontalScale: 1, room: room, lifting: false)
        let actual = try #require(NativeTranslationRenderer.plateGrowthTrial(baseline, proposal))
        #expect(actual.style.keepsWholeWords == baseline.style.keepsWholeWords)
        #expect(actual.style.horizontalWrapping == baseline.style.horizontalWrapping)
        #expect(actual.style.horizontalWhitespace == baseline.style.horizontalWhitespace)
        #expect(actual.style.balancesHorizontalLines)
        #expect(actual.style.usesBlockWordLayout == room)
        var expected = actual
        expected.style.keepsWholeWords = baseline.style.keepsWholeWords
        expected.style.horizontalWrapping = baseline.style.horizontalWrapping
        expected.style.horizontalWhitespace = baseline.style.horizontalWhitespace
        expected.typography = NativeTranslationRenderer.remeasureTypography(expected)
        #expect(actual.typography.lineRanges == expected.typography.lineRanges)
        #expect(actual.typography.rangeBounds == expected.typography.rangeBounds)
        #expect(actual.typography.fits == expected.typography.fits)
    }

    @Test(arguments: [1.0,0.9])
    func plateTrialRetainsAuthoredCSSOriginBeforePhysicalQuantization(scale: Double) throws {
        var baseline = try card(text:"AB CD",width:80,font:10)
        baseline.authoredTextOrigin = CGPoint(x:5.125,y:6.875)
        let proposal = NativeTypographyPlateGrowth.Proposal(box:CGRect(x:1.127,y:2.783,width:80,height:100),
            font:12,pitch:14.4,padding:3,horizontalScale:scale,room:false,lifting:false)
        let candidate = try #require(NativeTranslationRenderer.plateGrowthTrial(baseline,proposal))
        // The authored CSS layout box precedes scale and LayoutUnit rounding.
        // Its origin remains available for subsequent parent-local CSS writes.
        #expect(candidate.authoredTextOrigin == CGPoint(x:5.125+proposal.box.minX,y:6.875+proposal.box.minY))
        #expect(candidate.item.rect.origin != candidate.authoredTextOrigin)
        var retained = candidate
        NativeTranslationRenderer.preparePlateGrowthCard(&retained,preservingControlledChildren:false)
        #expect(retained.authoredTextOrigin == candidate.authoredTextOrigin)
    }

    @Test(arguments: [false,true])
    func restoredProducerQuantizesGeometryBeforeRemeasuringAndKeepsAuthoredOrigin(controlled: Bool) throws {
        var next = try card(text:"안녕 세상 함께",width:253.5,font:14)
        next.captionParentPlate = true
        next.sourcePanels = [.init(rect:CGRect(x:25.5,y:120,width:280.5,height:120),background:[255,255,255],coverage:[CGRect(x:25.5,y:120,width:280.5,height:120)])]
        next.authoredTextOrigin = CGPoint(x:2.001,y:3.002)
        next.style.horizontalWrapping = .keepAll
        next.style.horizontalWhitespace = .normal
        var item = next.item
        item.x=39.0001;item.y=122.88388671875;item.width=253.505;item.height=111.05
        item.paddingTop=4.50888671875;item.paddingBottom=56.5751953125
        item.paddingLeft=3.008;item.paddingRight=3.008
        item.typesettingText=controlled ? "안녕\n세상\n함께" : nil
        item.typesettingQuoteMode=controlled ? 0 : nil
        item.typesettingBlockDisplay=controlled ? true : nil
        var style = next.style
        NativeTranslationRenderer.syncRestoredPlateTextStyle(item:item,style:&style)
        NativeTranslationRenderer.commitRestoredPlateGrowth(item,to:&next,style:style)
        #expect(next.authoredTextOrigin == CGPoint(x:39.0001,y:122.88388671875))
        #expect(next.item.x == 39 && next.item.y == 122.875)
        #expect(next.item.width == 253.5 && next.item.height == 111.046875)
        #expect(next.item.paddingTop == 4.5 && next.item.paddingBottom == 56.5625)
        #expect(next.item.paddingLeft == 3 && next.item.paddingRight == 3)
        #expect(next.item.contentRect.minY == 127.375)
        #expect(next.captionParentPlate && next.sourcePanels.count == 1)
        #expect(next.sourcePanels[0].rect == CGRect(x:25.5,y:120,width:280.5,height:120))
        #expect(next.style.horizontalWrapping == .keepAll && next.style.horizontalWhitespace == .normal)
        #expect(next.style.usesBlockWordLayout == controlled)
        let measured = NativeTranslationRenderer.remeasureTypography(next)
        #expect(next.typography.rangeBounds == measured.rangeBounds)
        #expect(next.typography.lineRanges == measured.lineRanges)
        #expect(next.textShift == .zero && next.lineOffsets.isEmpty && next.typographyWidth == nil)
        // A size-only commit retains the authored origin rather than deriving
        // a different one from already quantized physical coordinates.
        let authored = next.authoredTextOrigin
        item = next.item;item.height=112.057
        NativeTranslationRenderer.commitRestoredPlateGrowth(item,to:&next,style:next.style)
        #expect(next.authoredTextOrigin == authored && next.item.height == 112.046875)
    }

    @Test(arguments: [nil, "balloon", "rotated-plate"] as [String?])
    func restoredCommitUsesCanonicalDisplayMarkerIncludingDeletion(marker: String?) throws {
        var baseline = try card(text:"AB CD",width:80,font:6)
        baseline.typographyDisplayGrowth = "rotated-plate"
        baseline.item.typesettingDisplayGrowth = "rotated-plate"
        var accepted = baseline
        var item = baseline.item
        item.typesettingDisplayGrowth = marker
        item.height += 0.025
        NativeTranslationRenderer.commitRestoredPlateGrowth(item,to:&accepted,style:accepted.style)
        #expect(accepted.item.typesettingDisplayGrowth == marker)
        #expect(accepted.typographyDisplayGrowth == marker)
        // The immutable original retains both marker representations until a
        // candidate is committed, so failed-policy rollback can recover it.
        #expect(baseline.item.typesettingDisplayGrowth == "rotated-plate")
        #expect(baseline.typographyDisplayGrowth == "rotated-plate")
    }

    @Test func actualCardAcceptsIntegerScrollFitWhenGlyphInkOverflows() throws {
        // Same font/text/cell as the captured frozen WK contentFits probe:
        // width83.5, advance84.34575, integer scroll/client84.
        let card = try card()
        #expect(!card.typography.fits)
        let metrics = try #require(NativeTranslationRenderer.plateGrowthScrollMetrics(card))
        #expect(metrics.usesCSSLayout && metrics.clientWidth == 84 && metrics.scrollWidth == 84)
        #expect(metrics.fits)
        #expect(metrics.scrollWidth <= metrics.clientWidth + 0.5)
    }

    @Test func actualCardUsesCandidateStyleInsteadOfStaleItemFont() throws {
        let current = try card(), stale = try card(staleFont: 7)
        let expected = try #require(NativeTranslationRenderer.plateGrowthScrollMetrics(current))
        let actual = try #require(NativeTranslationRenderer.plateGrowthScrollMetrics(stale))
        #expect(actual.clientWidth == expected.clientWidth && actual.scrollWidth == expected.scrollWidth)
        #expect(actual.clientHeight == expected.clientHeight && actual.scrollHeight == expected.scrollHeight)
    }

    @Test func actualCondensedCardReportsUnscaledCSSClientWidth() throws {
        let physical = try card(width: 84 * 0.9, scale: 0.9)
        let metrics = try #require(NativeTranslationRenderer.plateGrowthScrollMetrics(physical))
        #expect(metrics.usesCSSLayout && metrics.clientWidth == 84)
        #expect(metrics.clientWidth != Double(physical.item.width))
    }

    @Test func verticalFallbackIsExplicitAndInvalidHorizontalScaleRejects() throws {
        let vertical = try card(vertical: true)
        let metrics = try #require(NativeTranslationRenderer.plateGrowthScrollMetrics(vertical))
        if let shared = NativeTypographyPostPolish.contentFitMetrics(item: vertical.item, typography: vertical.typography) {
            #expect(metrics.usesCSSLayout && metrics.clientWidth == Double(shared.clientWidth))
            #expect(metrics.scrollHeight == Double(shared.scrollHeight))
        } else {
            #expect(!metrics.usesCSSLayout && metrics.clientWidth == Double(vertical.item.width))
        }
        var invalid = try card()
        invalid.style.horizontalScale = 0
        #expect(NativeTranslationRenderer.plateGrowthScrollMetrics(invalid) == nil)
    }
    @Test func rawPlateProbeClearsStoredBlockStyleAndActuallyWraps() throws {
        var probe = try card(text: "안녕 세상 함께", width: 30, font: 14)
        probe.item.typesettingText = "안녕\n세상\n함께"
        probe.item.typesettingQuoteMode = 0
        probe.style.usesBlockWordLayout = true
        probe.style.blockWordLayoutUsesTopPadding = true
        probe.item.typesettingBlockDisplay = true
        NativeTranslationRenderer.preparePlateGrowthText(item:&probe.item,style:&probe.style,
                                                         preservingControlledChildren:false)
        probe.typography = NativeTranslationRenderer.remeasureTypography(probe)
        #expect(probe.item.typesettingText == nil && probe.item.typesettingQuoteMode == nil)
        #expect(!probe.style.usesBlockWordLayout && !probe.style.blockWordLayoutUsesTopPadding)
        #expect(probe.item.typesettingBlockDisplay == nil && probe.typography.lineCount > 1)
        #expect(probe.typography.visibleUTF16Range.length == probe.item.text.utf16.count)
    }

    @Test func roomProbePreservesOnlyChildrenWithIdenticalConcatenatedText() throws {
        var probe = try card(text: "안녕 세상 함께", width: 50,font: 14)
        probe.item.typesettingText = "안녕 \n세상 \n함께"
        probe.style.usesBlockWordLayout = true
        probe.item.typesettingBlockDisplay = true
        probe.item.typesettingPreservedBlockWrapper = true
        probe.style.blockWordLayoutUsesTopPadding = true
        NativeTranslationRenderer.preparePlateGrowthText(item:&probe.item,style:&probe.style,
                                                         preservingControlledChildren:true)
        #expect(probe.style.usesBlockWordLayout && probe.item.typesettingText != nil)
        #expect(probe.item.typesettingBlockDisplay == nil && !probe.style.blockWordLayoutUsesTopPadding)
        #expect(probe.item.typesettingPreservedBlockWrapper == true)
        probe.typography = NativeTranslationRenderer.remeasureTypography(probe)
        #expect(probe.typography.lineCount == 3)
        probe.item.typesettingText = "다른\n문구"
        NativeTranslationRenderer.preparePlateGrowthText(item:&probe.item,style:&probe.style,
                                                         preservingControlledChildren:true)
        #expect(!probe.style.usesBlockWordLayout && probe.item.typesettingText == nil)
        #expect(probe.item.typesettingPreservedBlockWrapper == nil)
    }

    @Test func restoredCommitReshapesRawAndControlledTextUsingCommittedState() throws {
        var probe = try card(text: "안녕 세상 함께",width: 15,font: 14)
        probe.style.usesBlockWordLayout = true
        probe.item.typesettingText = nil; probe.item.typesettingQuoteMode = nil
        NativeTranslationRenderer.syncRestoredPlateTextStyle(item:probe.item,style:&probe.style)
        probe.typography = NativeTranslationRenderer.remeasureTypography(probe)
        #expect(!probe.style.usesBlockWordLayout && probe.typography.lineCount > 3)
        probe.item.typesettingText = "안녕\n세상\n함께"; probe.item.typesettingQuoteMode = 0
        probe.item.typesettingBlockDisplay = true
        NativeTranslationRenderer.syncRestoredPlateTextStyle(item:probe.item,style:&probe.style)
        probe.typography = NativeTranslationRenderer.remeasureTypography(probe)
        #expect(probe.style.usesBlockWordLayout && probe.style.blockWordLayoutUsesTopPadding && probe.typography.lineCount == 3)
    }

    @Test func sourceGeometryUsesCleanupOffsetAndScaleWithoutMovingCaption() throws {
        let probe = try card(width: 83.5)
        let cleanup = NativeSourceSurfaceGeometry.Geometry(
            frame: CGRect(x: 40, y: 25, width: 300, height: 120),
            clip: CGRect(x: 50, y: 30, width: 200, height: 100))
        let mapped = try #require(NativeTranslationRenderer.plateGrowthSourceRect(item:probe.item,cleanup:cleanup))
        #expect(mapped == CGRect(x:40,y:25,width:150,height:60))
        #expect(min(mapped.width,mapped.height) == 60)
        // The fallback is the immutable item's own sourceFrame, not a global
        // payload frame or the visible clip of a cover image.
        let fallback = try #require(NativeTranslationRenderer.plateGrowthSourceRect(item:probe.item,cleanup:nil))
        #expect(fallback == CGRect(x:0,y:0,width:100,height:100))
        #expect(probe.item.rect == CGRect(x:0,y:0,width:83.5,height:100))
        #expect(probe.item.sourceFrame == [0,0,200,200])
    }

    @Test func wholeContentsRangeMapsCandidateOriginAndRetainedSpanBoxes() throws {
        var probe = try card(text:"안녕 세상 함께",width:80,font:14)
        probe.item.typesettingText = "안녕\n세상\n함께"
        probe.item.typesettingQuoteMode = 0; probe.item.typesettingBlockDisplay = true
        probe.item.x = 40; probe.item.y = 25
        NativeTranslationRenderer.syncRestoredPlateTextStyle(item:probe.item,style:&probe.style)
        probe.typography = NativeTranslationRenderer.remeasureTypography(probe)
        let local = try #require(NativeTranslationTypography.wholeRangeBounds(layout:probe.typography,
            style:probe.style,available:probe.textLayoutSize))
        let mapped = try #require(NativeTranslationRenderer.cardWholeRangeRect(probe))
        #expect(mapped == local.offsetBy(dx:probe.textOrigin.x,dy:probe.textOrigin.y))
        let wrapper = try #require(NativeTranslationRenderer.cardWholeRangeRect(probe,preservesBlockWrapper:true))
        #expect(wrapper.width > mapped.width)
        #expect(wrapper.width == probe.textLayoutSize.width)
        #expect(wrapper.contains(mapped))
        #expect(probe.style.blockWordLayoutUsesTopPadding)
        let scalar = probe.typography.rangeBounds.reduce(CGRect.null) { $0.union($1) }
        #expect(local != scalar)
        probe.item.typesettingPreservedBlockWrapper = true
        #expect(NativeTranslationRenderer.cardWholeRangeRect(probe) == wrapper)
        NativeTranslationRenderer.preparePlateGrowthCard(&probe,preservingControlledChildren:false)
        #expect(probe.item.typesettingPreservedBlockWrapper == nil)
    }

    @Test func rawCandidateRemovesActualUnitChildrenWhileEqualRoomTextRetainsThem() throws {
        var probe = try card(text:"안녕 세상 함께",width:80,font:14)
        let children = ["안녕 세상 ", "함께"].map { text in
            NativeTranslationRenderer.TextPart(text:text,frame:CGRect(x:0,y:0,width:50,height:20),
                typography:NativeTranslationTypography.layout(text:text,in:CGSize(width:50,height:20),style:probe.style),
                style:probe.style)
        }
        probe.unitTextParts = children; probe.unitTextPartsOrigin = CGPoint(x:6,y:7)
        #expect(NativeTranslationRenderer.preparePlateGrowthCard(&probe,preservingControlledChildren:true))
        #expect(probe.unitTextParts.count == 2 && probe.unitTextPartsOrigin == CGPoint(x:6,y:7))
        #expect(!NativeTranslationRenderer.preparePlateGrowthCard(&probe,preservingControlledChildren:false))
        #expect(probe.unitTextParts.isEmpty && probe.unitTextPartsOrigin == nil)
        probe.unitTextParts = Array(children.prefix(1)); probe.unitTextPartsOrigin = .zero
        #expect(!NativeTranslationRenderer.preparePlateGrowthCard(&probe,preservingControlledChildren:true))
        #expect(probe.unitTextParts.isEmpty && probe.unitTextPartsOrigin == nil)
    }

    @Test func explicitLegacyWholeWordTrialsRetainInheritedCSSBalance() throws {
        var baseline0 = try card(text:"그렇다면 알몸이 된 것에 감사해야 하고,",width:38.703125,font:8.5)
        // Explicit legacy control: this fixture compares the older whole-word
        // solver's balanced and greedy policies, not the captured live CSS mode.
        baseline0.style.keepsWholeWords = true
        baseline0.style.balancesHorizontalLines = true
        let proposal0 = NativeTypographyPlateGrowth.Proposal(box:CGRect(x:160.625,y:216.5,width:38.703125,height:68.296875),
            font:9,pitch:10.740234375,padding:3,horizontalScale:1,room:false,lifting:true)
        let balanced0 = try #require(NativeTranslationRenderer.plateGrowthTrial(baseline0,proposal0))
        baseline0.style.balancesHorizontalLines = false
        let greedy0 = try #require(NativeTranslationRenderer.plateGrowthTrial(baseline0,proposal0))
        #expect(balanced0.style.balancesHorizontalLines && !greedy0.style.balancesHorizontalLines)
        #expect(!balanced0.style.usesBlockWordLayout && balanced0.item.typesettingText == nil)
        #expect(balanced0.typography.lineRanges != greedy0.typography.lineRanges)
        let ink0 = try #require(NativeTranslationRenderer.cardWholeRangeRect(balanced0))
        let oldInk0 = try #require(NativeTranslationRenderer.cardWholeRangeRect(greedy0))
        let permitted0 = proposal0.box.insetBy(dx:3,dy:3)
        #expect(!NativePanelGeometry.inside(ink0,permitted0,tolerance:0.5))
        #expect(NativePanelGeometry.inside(oldInk0,permitted0,tolerance:0.5))
        print("captured-trial-0","balanced",ink0,"greedy",oldInk0,"rows",balanced0.typography.lineCount,greedy0.typography.lineCount)
        var baseline1 = try card(text:"내가 갔다는 걸 모두에게 확실히 증명받아야 하니까... 웃는 얼굴로 부탁하는 게 당연한 거...겠지.",width:65.375,font:8.25)
        baseline1.style.keepsWholeWords = true
        baseline1.style.balancesHorizontalLines = true
        let proposal1 = NativeTypographyPlateGrowth.Proposal(box:CGRect(x:7.140625,y:397.796875,width:65.375,height:82.328125),
            font:9,pitch:10.740234375,padding:3,horizontalScale:1,room:false,lifting:false)
        let balanced1 = try #require(NativeTranslationRenderer.plateGrowthTrial(baseline1,proposal1))
        baseline1.style.balancesHorizontalLines = false
        let greedy1 = try #require(NativeTranslationRenderer.plateGrowthTrial(baseline1,proposal1))
        #expect(balanced1.style.balancesHorizontalLines && !greedy1.style.balancesHorizontalLines)
        #expect(!balanced1.style.usesBlockWordLayout && balanced1.item.typesettingText == nil)
        let ink1 = try #require(NativeTranslationRenderer.cardWholeRangeRect(balanced1))
        let oldInk1 = try #require(NativeTranslationRenderer.cardWholeRangeRect(greedy1))
        print("captured-trial-1","balanced",ink1,"greedy",oldInk1,"rows",balanced1.typography.lineCount,greedy1.typography.lineCount)
    }

    @Test func capturedLivePlateRejectsWholeRangeOverflowWithoutChangingTolerance() throws {
        var baseline = try card(text:"내가 갔다는 걸 모두에게 확실히 증명받아야 하니까... 웃는 얼굴로 부탁하는 게 당연한 거...겠지.",width:65.375,font:8.25)
        // BUILD38 frozen real15/card9: pre-wrap / keep-all / anywhere / balance.
        baseline.style.horizontalWrapping = .keepAllWithEmergency
        baseline.style.horizontalWhitespace = .preWrap
        let proposal = NativeTypographyPlateGrowth.Proposal(box:CGRect(x:7.140625,y:397.796875,width:65.375,height:82.328125),
            font:9,pitch:10.740234375,padding:3,horizontalScale:1,room:false,lifting:false)
        for balanced in [false,true] {
            baseline.style.balancesHorizontalLines = balanced
            let candidate = try #require(NativeTranslationRenderer.plateGrowthTrial(baseline,proposal))
            #expect(candidate.style.balancesHorizontalLines == balanced)
            #expect(!candidate.style.keepsWholeWords)
            let metrics = try #require(NativeTranslationRenderer.plateGrowthScrollMetrics(candidate))
            #expect(metrics.fits)
            let ink = try #require(NativeTranslationRenderer.cardWholeRangeRect(candidate))
            let permitted = proposal.box.insetBy(dx:proposal.padding,dy:proposal.padding)
            // Scroll/client fits alone must not admit a whole-content range
            // outside the plate. This is the frozen literal 0.5px gate.
            #expect(!NativePanelGeometry.inside(ink,permitted,tolerance:0.5))
            print("captured-live-plate",balanced,"font",proposal.font,"wholeRange",ink,
                  "allowed",permitted,"scroll",metrics.scrollWidth,metrics.scrollHeight)
        }
    }

    @Test func persistentPlateRefitsKeepOriginalStateAndApplyStyleGlyphWithoutReset() throws {
        var baseline = try card(text:"안녕 세상",width:80,font:6,sourceGlyph:10)
        baseline.item.allowsAutomaticFontRecovery = true
        baseline.item.typesettingDisplayGrowth = "rotated-plate"
        baseline.typographyDisplayGrowth = "rotated-plate"
        baseline.sourcePanels = [.init(rect:baseline.item.rect,background:[255,255,255],coverage:[baseline.item.rect])]
        var cards = [baseline]
        let layout = NativeTranslationLayout(imageSize:CGSize(width:200,height:200),sourceRect:CGRect(x:0,y:0,width:200,height:200),
            viewport:CGSize(width:200,height:200),items:[baseline.item])
        let settings = IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,
            textPlacement:.replace,subtitlePosition:.bottom,subtitleMaxLines:2,subtitleContextSentences:1)
        let session = NativeTranslationRenderer.PlateGrowthSession()
        try NativeTranslationRenderer.growPlateTypography(cards:&cards,layout:layout,restoration:.init(),
            settings:settings,source:nil,plateSession:session)
        let initial = try #require(session.snapshot)
        #expect(initial.originalFonts[baseline.item.id] == 6)
        cards[0].item.fontSize = 30; cards[0].style.fontSize = 30; cards[0].finalFontSize = 30
        let restoredResult = session.refit(id:baseline.item.id,cap:8.5,strict:true,styleGlyph:0,cards:&cards)
        let restored = try #require(restoredResult)
        #expect(restored == 8.5 && cards[0].finalFontSize == 8.5)
        let elevatedResult = session.refit(id:baseline.item.id,cap:12,strict:true,styleGlyph:20,cards:&cards)
        let elevated = try #require(elevatedResult)
        #expect(elevated > 9.5 && elevated <= 12)
        let reused = try #require(session.snapshot)
        #expect(reused.originalFonts == initial.originalFonts)
        #expect(reused.flatRoomPixels == initial.flatRoomPixels && reused.wideningPixels == initial.wideningPixels)
        var failed = cards
        let failedResult = session.refit(id:baseline.item.id,cap:1,strict:true,styleGlyph:20,cards:&failed)
        #expect(failedResult == nil)
        #expect(failed[0].finalFontSize == 6 && cards[0].finalFontSize == elevated)
        #expect(failed[0].item.typesettingDisplayGrowth == "rotated-plate")
        #expect(failed[0].typographyDisplayGrowth == "rotated-plate")
        session.close()
        #expect(session.snapshot == nil)
        let closedResult = session.refit(id:baseline.item.id,cap:12,strict:true,styleGlyph:20,cards:&cards)
        #expect(closedResult == nil)
    }

    @Test func persistentSourceRoomReusesConsumedBudgetReaderAndLiveObstacles() throws {
        // This regression owns room/cache/resource transport, not Korean font
        // registration. Use the same explicit Apple face on macOS and iOS.
        var baseline = try card(text:"AB CD",width:8,font:6,sourceGlyph:10)
        baseline.style.fontName = "Helvetica"
        baseline.item.allowsAutomaticFontRecovery = true
        baseline.item.x = 90; baseline.item.y = 90; baseline.item.height = 24
        NativeTranslationRenderer.preparePlateGrowthCard(&baseline,preservingControlledChildren:false)
        baseline.typography = NativeTranslationRenderer.remeasureTypography(baseline)
        baseline.sourcePanels = [.init(rect:baseline.item.rect,background:[255,255,255],coverage:[baseline.item.rect])]
        let data = Data(repeating:255,count:200 * 200 * 4)
        let provider = try #require(CGDataProvider(data:data as CFData))
        let image = try #require(CGImage(width:200,height:200,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:800,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let layout = NativeTranslationLayout(imageSize:CGSize(width:200,height:200),sourceRect:CGRect(x:0,y:0,width:200,height:200),
            viewport:CGSize(width:200,height:200),items:[baseline.item])
        var restoration = NativeTranslationRestoration.Result()
        restoration.cleanupGeometry = .init(frame:layout.sourceRect,clip:layout.sourceRect)
        let settings = IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,
            textPlacement:.replace,subtitlePosition:.bottom,subtitleMaxLines:2,subtitleContextSentences:1)
        var cards = [baseline]
        let session = NativeTranslationRenderer.PlateGrowthSession()
        try NativeTranslationRenderer.growPlateTypography(cards:&cards,layout:layout,restoration:restoration,
            settings:settings,source:image,plateSession:session)
        let initial = try #require(session.snapshot)
        #expect(cards[0].finalFontSize > 6 && initial.flatRoomPixels < 786_432)
        #expect(initial.roomLayouts > 0 && initial.sourceReaderIdentity != nil)
        let acceptedResult = session.refit(id:baseline.item.id,cap:8.5,strict:true,styleGlyph:0,cards:&cards)
        let accepted = try #require(acceptedResult)
        #expect(accepted == 8.5 && cards[0].finalFontSize == 8.5)
        let reused = try #require(session.snapshot)
        #expect(reused.sourceReaderIdentity == initial.sourceReaderIdentity)
        #expect(reused.flatRoomPixels == initial.flatRoomPixels && reused.roomLayouts >= initial.roomLayouts)
        var obstacle = try card(text:"막힘",width:190,font:10)
        obstacle.item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:[
            "id":"live-obstacle","text":"막힘","fontScript":"korean","wrappingScript":"korean",
            "sourceBounds":[0.0,0.0,1.0,1.0],"sourceFrame":[0,0,200,200],
            "x":5,"y":5,"width":190,"height":190,"fontSize":10,"lineHeight":12]))
        obstacle.sourcePanels = [.init(rect:obstacle.item.rect,background:[0,0,0],coverage:[obstacle.item.rect])]
        obstacle.typography = NativeTranslationRenderer.remeasureTypography(obstacle)
        var blocked = cards + [obstacle]
        let blockedResult = session.refit(id:baseline.item.id,cap:8.5,strict:true,styleGlyph:0,cards:&blocked)
        #expect(blockedResult == nil)
        #expect(blocked[0].finalFontSize == 6 && blocked[1].item.id == "live-obstacle")
        #expect(session.snapshot?.flatRoomPixels == initial.flatRoomPixels)
        session.close()
        #expect(session.snapshot == nil)
        let closedResult = session.refit(id:baseline.item.id,cap:8.5,strict:true,styleGlyph:0,cards:&cards)
        #expect(closedResult == nil)
    }

    @Test func cancelledRestoredStageWritesAcceptedPlateBeforeRethrowing() async throws {
        let result = try await Task { () throws -> Bool in
            var baseline = try card(text:"안녕 세상",width:80,font:6,sourceGlyph:10)
            baseline.item.allowsAutomaticFontRecovery = true
            baseline.sourcePanels = [.init(rect:baseline.item.rect,background:[255,255,255],coverage:[baseline.item.rect])]
            var cards = [baseline]
            let frame = CGRect(x:0,y:0,width:200,height:200)
            let layout = NativeTranslationLayout(imageSize:frame.size,sourceRect:frame,viewport:frame.size,items:[baseline.item])
            let settings = IPhoneOverlaySettings(visible:true,mode:.translateOnly,colorMode:.white,opacity:1,
                textPlacement:.replace,subtitlePosition:.bottom,subtitleMaxLines:2,subtitleContextSentences:1)
            let growth = NativeTypographyPostPolish.rendererGrowthSession(layout:layout,restoration:.init(),
                settings:settings,sourceImage:nil)
            let plate = NativeTranslationRenderer.PlateGrowthSession()
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try NativeTranslationRenderer.growPlateTypography(cards:&cards,layout:layout,restoration:.init(),
                    settings:settings,source:nil,growthSession:growth,plateSession:plate)
                return false
            } catch is CancellationError {
                return cards.count == 1 && cards[0].finalFontSize > 6 && plate.snapshot == nil
            }
        }.value
        #expect(result)
    }

    @Test func retainedRoomPreformattedRowsKeepSpacesButRawReplacementClearsThem() throws {
        var probe = try card(text:" 안녕 세상 ",width:50,font:14)
        probe.item.typesettingText = " 안녕 \n세상 "
        probe.item.typesettingQuoteMode = nil; probe.item.typesettingPreformattedRows = true
        probe.item.typesettingBlockDisplay = true; probe.item.typesettingPreservedBlockWrapper = true
        probe.style.usesBlockWordLayout = false; probe.style.usesPreformattedBlockRows = true
        #expect(NativeTranslationRenderer.preparePlateGrowthCard(&probe,preservingControlledChildren:true))
        #expect(probe.item.typesettingText == " 안녕 \n세상 " && probe.item.typesettingPreservedBlockWrapper == true)
        #expect(!probe.style.usesBlockWordLayout && probe.style.usesPreformattedBlockRows && !probe.style.blockWordLayoutUsesTopPadding)
        #expect(!NativeTranslationRenderer.preparePlateGrowthCard(&probe,preservingControlledChildren:false))
        #expect(probe.item.typesettingText == nil && probe.item.typesettingPreformattedRows == nil)
        #expect(!probe.style.usesPreformattedBlockRows && probe.item.typesettingPreservedBlockWrapper == nil)
    }

}
