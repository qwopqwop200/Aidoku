import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeInitialReferenceFlowTests {


    @Test(arguments: [0, 1])
    func preservedParagraphReferenceKeepsTheRecordedReadableSize(index: Int) throws {
        // Identical immutable planner descriptors from current-Web page11.
        // The original Web reference accepts 11.75/11.25 before font cohorts.
        let data = Data(#"""
        [
          {
            "id": "1",
            "text": "가문의 번영과\n종의 존속을 꾀했다",
            "sourceTextOnly": false,
            "sourceColorEligible": true,
            "allowsAutomaticFontRecovery": true,
            "sourceBounds": [0.1362530413625304, 0.6741666666666667, 0.1021897810218978, 0.21666666666666667],
            "sourceFrame": [0, 86.13138686131384, 430, 627.7372262773723],
            "sourceFontSize": 20.661361540137577,
            "sourceVertical": true,
            "x": 55.1396107055961,
            "y": 509.330900243309,
            "width": 50.84,
            "height": 136.00973236009736,
            "fontSize": 11.75,
            "lineHeight": 14.02197265625,
            "fontScript": "korean",
            "wrappingScript": "korean",
            "clipsText": false,
            "paddingTop": 4.42,
            "paddingRight": 4.42,
            "paddingBottom": 4.42,
            "paddingLeft": 4.42,
            "smallTextReference": {
              "fontSize": 7.75,
              "allowsEmergencyWordBreak": false,
              "additionalLines": 13,
              "fallbackFontSize": 7.75,
              "exclusionRects": [],
              "padding": [4.42, 4.42, 4.42, 4.42],
              "fallbackPadding": [4.42, 4.42, 4.42, 4.42]
            }
          },
          {
            "id": "2",
            "text": "비술이라는 힘의\n유용성을 보여줌으로써",
            "sourceTextOnly": false,
            "sourceColorEligible": true,
            "allowsAutomaticFontRecovery": true,
            "sourceBounds": [0.2725060827250608, 0.6758333333333333, 0.16423357664233573, 0.23833333333333329],
            "sourceFrame": [0, 86.13138686131384, 430, 627.7372262773723],
            "sourceFontSize": 22.98431372929572,
            "sourceVertical": true,
            "x": 112.70072992700736,
            "y": 510.37712895377126,
            "width": 70.62043795620437,
            "height": 149.61070559610698,
            "fontSize": 11.25,
            "lineHeight": 13.42529296875,
            "fontScript": "korean",
            "wrappingScript": "korean",
            "clipsText": false,
            "paddingTop": 5.88,
            "paddingRight": 5.88,
            "paddingBottom": 5.88,
            "paddingLeft": 5.88,
            "smallTextReference": {
              "fontSize": 6.5,
              "allowsEmergencyWordBreak": false,
              "additionalLines": 14,
              "fallbackFontSize": 7.75,
              "exclusionRects": [],
              "padding": [5.88, 5.88, 5.88, 5.88],
              "fallbackPadding": [5.88, 5.88, 5.88, 5.88]
            }
          }
        ]
        """#.utf8)
        let originals = try JSONDecoder().decode([NativeTranslationLayoutItem].self, from: data)
        let original = originals[index]
        let frame = CGRect(x: 0, y: 0, width: 430, height: 800)
        let layout = NativeTranslationLayout(imageSize: frame.size, sourceRect: frame, viewport: frame.size, items: [original])
        let settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        let refined = try NativeTranslationLayoutPlanner.refining(layout: layout, restoration: .init(), settings: settings)
        #expect(refined.items[0].fontSize == original.fontSize)
        #expect(refined.items[0].smallTextReferenceResolved == true)
        #expect(refined.items[0].text == original.text)
        #expect(refined.items[0].sourceBounds == original.sourceBounds && refined.items[0].sourceFrame == original.sourceFrame)

        // The corrected wrapping must not bypass the existing foreign-ink veto.
        var obstructed = original
        let reference = try #require(original.smallTextReference)
        obstructed.smallTextReference = .init(fontSize: reference.fontSize, additionalLines: reference.additionalLines,
            allowsEmergencyWordBreak: reference.allowsEmergencyWordBreak, fallbackFontSize: reference.fallbackFontSize,
            fallbackPadding: reference.fallbackPadding,
            exclusionRects: [[original.x, original.y, original.width, original.height]],
            padding: reference.padding, paragraphRecovery: reference.paragraphRecovery)
        let blocked = NativeTranslationLayout(imageSize: frame.size, sourceRect: frame, viewport: frame.size, items: [obstructed])
        let retained = try NativeTranslationLayoutPlanner.refining(layout: blocked, restoration: .init(), settings: settings)
        #expect(retained.items[0].fontSize == reference.fontSize)
    }

}
