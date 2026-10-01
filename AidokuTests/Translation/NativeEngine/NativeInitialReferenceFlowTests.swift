import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeInitialReferenceFlowTests {
    private func item() throws -> NativeTranslationLayoutItem {
        // Captured common planner input; expected profiles come from the frozen
        // renderer and actual WKWebView CSS measurement, before page cohorts.
        let value: [String: Any] = ["id": "16", "text": "부, 부탁드립니다♡",
            "sourceTextOnly": false, "sourceColorEligible": true, "allowsAutomaticFontRecovery": true,
            "sourceBounds": [0.03352130325814536, 0.6765749778172139, 0.046992481203007516, 0.17036379769299023],
            "sourceFrame": [0, 212.30263157894737, 390, 275.39473684210526],
            "sourceFontSize": 9.720582038022568, "x": 0, "y": 398.62781954887214,
            "width": 36.02, "height": 46.91729323308272, "fontSize": 11, "lineHeight": 13.126953125,
            "fontScript": "korean", "wrappingScript": "korean", "clipsText": false,
            "paddingTop": 3.01, "paddingRight": 3.01, "paddingBottom": 3.01, "paddingLeft": 3.01,
            "smallTextReference": ["additionalLines": 4, "allowsEmergencyWordBreak": false,
                "exclusionRects": [], "fontSize": 7.25, "padding": [3.01, 3.01, 3.01, 3.01],
                "fallbackFontSize": 7.75, "fallbackPadding": [3.01, 3.01, 3.01, 3.01]]]
        return try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @Test func rawReferencePreservesBrowserBreakIdentityBeforeCohorts() throws {
        let original = try item()
        var baseline = original
        baseline.fontSize = 7.25
        baseline.lineHeight = baseline.fontSize * original.lineHeight / original.fontSize
        let layout = NativeTranslationLayout(imageSize: CGSize(width: 3192, height: 2254),
            sourceRect: CGRect(x: 0, y: 212.30263157894737, width: 390, height: 275.39473684210526),
            viewport: CGSize(width: 390, height: 700), items: [baseline])
        var settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        settings.preserveSourceColors = true
        let context = NativeTypographyPostPolish.rendererGrowthSession(layout: layout, restoration: .init(),
            settings: settings, sourceImage: nil).context
        let candidate = context.candidate(baseline)
        #expect(candidate.shaped.shapedText.components(separatedBy: "\n") == ["부, ", "부탁드립", "니다♡"])
        #expect(candidate.profile.lines == 3 && candidate.profile.breaks == [7])
        #expect(context.contentFits(candidate))
        #expect(!context.contentFits(context.candidate(original)))
        var overflow = original
        overflow.fontSize = 10.75
        overflow.lineHeight = overflow.fontSize * original.lineHeight / original.fontSize
        let overflowCandidate = context.candidate(overflow)
        #expect(!overflowCandidate.shaped.fits && context.contentFits(overflowCandidate))
    }

    @Test func initialReferenceAcceptsReadableCandidateWithTheOriginalWordFlow() throws {
        let original = try item()
        let layout = NativeTranslationLayout(imageSize: CGSize(width: 3192, height: 2254),
            sourceRect: CGRect(x: 0, y: 212.30263157894737, width: 390, height: 275.39473684210526),
            viewport: CGSize(width: 390, height: 700), items: [original])
        var settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        settings.preserveSourceColors = true
        let refined = try NativeTranslationLayoutPlanner.refining(layout: layout, restoration: .init(), settings: settings)
        #expect(refined.items[0].fontSize == 8.75)
        #expect(refined.items[0].smallTextReferenceResolved == true)
        #expect(refined.items[0].sourceBounds == original.sourceBounds && refined.items[0].sourceFrame == original.sourceFrame)
        // Other registered observations are captured frozen stage records.
        let context = NativeTypographyPostPolish.rendererGrowthSession(layout: refined, restoration: .init(),
            settings: settings, sourceImage: nil).context
        let registered = context.captionRecovering(refined.items[0])
        #expect(registered.fontSize == 8.75)
        var entries: [NativeTypographyPostPolish.FontEntry] = [
            .init(id: "0", source: 9.660995852475684, font: 10.5, script: "korean", vertical: false, column: false),
            .init(id: "2", source: 10.54722346292459, font: 5.0, script: "korean", vertical: false, column: false),
            .init(id: "3", source: 8.774642661425997, font: 5.0, script: "korean", vertical: false, column: false),
            .init(id: "4", source: 10.693164519257884, font: 9.0, script: "korean", vertical: false, column: false),
            .init(id: "5", source: 9.52044805542012, font: 10.5, script: "korean", vertical: false, column: false),
            .init(id: "6", source: 10.047139105636473, font: 10.5, script: "korean", vertical: false, column: false),
            .init(id: "8", source: 10.790685269009588, font: 6.0, script: "korean", vertical: false, column: false),
            .init(id: "10", source: 10.281504926512634, font: 5.75, script: "korean", vertical: false, column: false),
            .init(id: "14", source: 9.560721641827598, font: 7.5, script: "korean", vertical: false, column: false),
            .init(id: "15", source: 10.66306069698542, font: 10.5, script: "korean", vertical: false, column: false),
            .init(id: "19", source: 9.514692315524092, font: 5.0, script: "korean", vertical: false, column: false),
            .init(id: "21", source: 10.6296992481203, font: 6.0, script: "korean", vertical: false, column: false),
            .init(id: "22", source: 9.665120136829492, font: 5.5, script: "korean", vertical: false, column: false)
        ]
        let sourceFont = try #require(original.sourceFontSize)
        entries.append(.init(id: original.id, source: sourceFont, font: registered.fontSize,
            script: "korean", vertical: false, column: false))
        let targets = NativeTypographyPostPolish.fontClusterTargets(entries)
        #expect(targets[original.id] == 8.75 && targets["0"] == 8.75)
        // The previous emergency observation lowers the page median.
        entries[entries.count - 1] = .init(id: original.id, source: sourceFont, font: 7.25,
            script: "korean", vertical: false, column: false)
        #expect(NativeTypographyPostPolish.fontClusterTargets(entries)["0"] == 8.25)

    }
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
