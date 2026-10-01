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
}
