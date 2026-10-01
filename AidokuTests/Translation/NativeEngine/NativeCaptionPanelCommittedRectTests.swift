import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeCaptionPanelCommittedRectTests {
    @Test func spacingReadsUsedPlateAfterRawTargetCommit() {
        // Real7/card22 target height and source bounds from BUILD47. A piece
        // caption keeps this control focused on fixed-owner geometry stages.
        let old = CGRect(x: 203.25, y: 405.859375, width: 31.28125, height: 54.109375)
        let source = CGRect(x: 221.63533834586468, y: 408.890977443609,
            width: 9.896616541353383, height: 48.139097744360896)
        let frame = CGRect(x: 0, y: 212.30263157894737, width: 390, height: 275.39473684210526)
        var first = NativeTranslationCaptionPanelPolish.Entry(id: "22", sourceTextOnly: false,
            rotation: 0, vertical: false, lettering: "piece", wrappingScript: "korean", font: 6.5,
            frame: frame, sources: [source], balancedColumn: false, column: nil, columnPaddingTop: 0,
            ink: CGRect(x: 206.3563125, y: 424.90625, width: 22.178, height: 15),
            panels: [.init(rect: old, background: [72, 54, 41], coverage: [old])])
        first.panels[0].clipped = true; first.panels[0].captionUnionClipped = true
        let neighborRect = CGRect(x: 227.882625, y: 398.53125, width: 23.1955, height: 82.453125)
        let neighbor = NativeTranslationCaptionPanelPolish.Entry(id: "neighbor", sourceTextOnly: false,
            rotation: 0, vertical: false, lettering: "piece", wrappingScript: "korean", font: 5.5,
            frame: frame, sources: [CGRect(x: 228.843984962406, y: 401.56015037594, width: 18.93797, height: 76.485)],
            balancedColumn: false, column: nil, columnPaddingTop: 0,
            ink: CGRect(x: 228.382625, y: 413.671875, width: 20.1465, height: 25),
            panels: [.init(rect: neighborRect, background: [62, 53, 41], coverage: [neighborRect])])
        let kept = [CGRect(x: 203.25, y: 459, width: 31, height: 3)]
        let input = [first, neighbor]
        let actual = NativeTranslationCaptionPanelPolish.polish(input, opacity: 1, kept: kept,
            committedPanelRect: NativeTranslationRenderer.usedRect)
        let prior = NativeTranslationCaptionPanelPolish.polish(input, opacity: 1, kept: kept)
        #expect(Double(actual[0].panels[0].rect.height) == 52.15625)
        #expect(Double(actual[0].panels[0].rect.width) == 28.78125)
        // The first place writes authored coverage. The subsequent spacing
        // setup rereads the physical owner, so its coverage height is used.
        #expect(Double(actual[0].panels[0].coverage[0].height) == 52.15625)
        #expect(abs(Double(prior[0].panels[0].rect.height) - 52.17070018796994) < 1e-9)
        #expect(actual[0].ink == first.ink && actual[0].font == first.font)
        #expect(actual[0].sources == first.sources)
    }
}
