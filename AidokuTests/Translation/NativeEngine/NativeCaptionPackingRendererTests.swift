import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeCaptionPackingRendererTests {
    @Test(arguments: [false, true])
    func onlyCommittedWordAwareChildrenSurvivePackingPreparation(_ wordAware: Bool) throws {
        let rawText = "부, 부탁드립니다♡", controlledText = "부, \n부탁드립\n니다♡"
        let frame = CGRect(x: 0, y: 0, width: 390, height: 536)
        let panel = CGRect(x: 0, y: 375.0625, width: 33.265625, height: 73.4375)
        let descriptor: [String: Any] = ["id": "child-flow", "text": rawText, "typesettingText": controlledText,
            "typesettingQuoteMode": 0, "captionFixedBoxReflowDisabled": wordAware,
            "x": 0, "y": 375.0625, "width": 80, "height": 73.4375, "fontSize": 8.75, "lineHeight": 10.5,
            "paddingTop": 3, "paddingRight": 3, "paddingBottom": 3, "paddingLeft": 3,
            "sourceBounds": [0.02,0.72,0.05,0.07], "sourceFrame": [0,0,390,536],
            "sourceTextOnly": false, "sourceColorEligible": true, "fontScript": "korean", "wrappingScript": "korean"]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: descriptor))
        var style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 8.75,
            foreground: NativeTranslationRenderer.color([20,20,20]), lineHeight: 10.5)
        style.usesBlockWordLayout = true
        let typography = NativeTranslationTypography.layout(text: controlledText, in: item.contentRect.size, style: style)
        let card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            sourcePanels: [.init(rect: panel, background: [245,245,245], coverage: [panel])], drawsPanel: false,
            background: NativeTranslationRenderer.color([245,245,245]), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 8.75)
        let layout = NativeTranslationLayout(imageSize: frame.size, sourceRect: frame, viewport: frame.size, items: [item])
        let settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        var cards = [card]
        NativeTranslationRenderer.packCaptions(cards: &cards, gloss: .init(), layout: layout, restoration: .init(),
            settings: settings, source: nil, collectDiagnostics: true)
        let record = try #require(cards[0].captionPackingRecord)
        #expect(record["beforeText"] as? String == (wordAware ? controlledText : rawText))
        #expect(record["preservedWordAwareRows"] as? Bool == wordAware)
        #expect(cards[0].sourcePanels.allSatisfy { $0.overflowClip == (record["unified"] as? Bool == true) })
        let probes = try #require(record["probes"] as? [[String: Any]])
        #expect(!probes.isEmpty)
        #expect(probes.allSatisfy { $0["text"] as? String == (wordAware ? controlledText : rawText) })
        if !wordAware {
            #expect(record["unified"] as? Bool == true)
            #expect(cards[0].sourcePanels.allSatisfy { !$0.sourceBridgeClipped })
            #expect(cards[0].item.typesettingText == nil && cards[0].item.typesettingQuoteMode == nil)
            #expect(!cards[0].style.usesBlockWordLayout)
            #expect(cards[0].item.typesettingPreservedBlockWrapper != true)
        } else {
            #expect(probes.allSatisfy { $0["lineCount"] as? Int == 3 })
            if record["unified"] as? Bool == false {
                #expect(cards[0].sourcePanels.allSatisfy { $0.sourceBridgeClipped })
            }
            #expect(cards[0].item.typesettingText == controlledText && cards[0].style.usesBlockWordLayout)
            if record["unified"] as? Bool == true {
                #expect(cards[0].item.typesettingPreservedBlockWrapper == true)
                #expect(NativeTranslationRenderer.cardWholeRangeRect(cards[0]) ==
                    NativeTranslationRenderer.cardWholeRangeRect(cards[0], preservesBlockWrapper: true))
            }
        }
    }
    @Test func finalSourceAnchorClampsToTheCommittedUsedOwnerWidth() throws {
        // Captured BUILD44 real7/card16: the authored partition has a
        // fractional CSS width, while getBoundingClientRect is 33.453125.
        let cell = CGRect(x:0,y:375.078125,width:33.464296875,height:73.421875)
        let ink = CGRect(x:5.5309375,y:390.78125,width:22.39125,height:41)
        let frame = CGRect(x:0,y:212.3529411764706,width:390,height:275.29411764705884)
        let bounds:[CGFloat] = [0.03352130325814536,0.6765749778172139,0.046992481203007516,0.17036379769299023]
        let source = try #require(NativeTranslationRenderer.pageRect(bounds,frame:frame))
        var entry = NativeCaptionPacking.Entry(id:"16",text:"부, 부탁드립니다♡",font:8.75,ink:ink,source:source,
            sourceFont:9.720582038022568,panels:[.init(rect:cell,color:[70,80,90])])
        entry.cell = cell
        let correct = NativeCaptionPacking.anchorPackedCaption(entry,obstacles:[],home:nil,
            usedPanelRect:NativeTranslationRenderer.usedRect)
        let shift = try #require(correct.finalAnchorShift)
        #expect(Double(shift.x) == 2.515625)
        let raw = NativeCaptionPacking.anchorPackedCaption(entry,obstacles:[],home:nil)
        let wrong = try #require(raw.finalAnchorShift)
        #expect(Double(wrong.x) == 2.53125)
        func used(_ v: CGFloat) -> CGFloat { CGFloat((Float(v)*64).rounded(.towardZero))/64 }
        #expect(Double(used(shift.x)) == 2.515625)
        #expect(Double(used(wrong.x)) == 2.53125)
        // Quantizing the owner query does not rewrite its authored partition.
        #expect(correct.cell == cell && correct.text == entry.text && correct.font == entry.font)
    }

}
