import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativePanelPhaseTests {
    private func fixture() -> NativePanelGeometry.Record {
        .init(id: "phase",ink: CGRect(x: 50,y: 50,width: 20,height: 20),
            source: CGRect(x: 20,y: 20,width: 20,height: 20),sources: [],sourceColorEligible: true,
            sourceTextOnly: false,balancedColumn: false,vertical: false,rotation: 0,font: 16,sourceFont: nil,
            sourceVertical: false,inkPadding: 0,foreground: [128,128,128],fallbackBackground: [255,255,255],
            panels: [.init(rect: CGRect(x: 0,y: 0,width: 100,height: 100),background: [255,255,255],coverage: [])],
            restoredSourcePanels: true)
    }
    @Test func compactOnlyTrimsPlateWithoutCommittingAnchorBackingOrContrast() {
        let input = fixture()
        let compact = NativePanelGeometry.polish([input],opacity: 1,phase: .compactOnly)[0]
        let contrast = NativePanelGeometry.polish([input],opacity: 1,phase: .compactContrast)[0]
        let anchor = NativePanelGeometry.polish([input],opacity: 1,phase: .anchorBacking)[0]
        #expect(compact.panels[0].rect.size.width < input.panels[0].rect.size.width)
        #expect(compact.panels[0].rect == contrast.panels[0].rect)
        #expect(compact.ink == input.ink && compact.shift == .zero)
        #expect(compact.foreground == input.foreground && compact.backings.isEmpty)
        #expect(contrast.foreground != input.foreground)
        #expect(anchor.shift != .zero)
        #expect(anchor.panels[0].rect == input.panels[0].rect)
    }
    @Test func defaultCombinedPolicyRetainsExistingPhaseOrder() {
        let input = [fixture()]
        let combined = NativePanelGeometry.polish(input,opacity: 1)
        let split = NativePanelGeometry.polish(NativePanelGeometry.polish(input,opacity: 1,phase: .anchorBacking),opacity: 1,phase: .compactContrast)
        #expect(combined[0].ink == split[0].ink)
        #expect(combined[0].shift == split[0].shift)
        #expect(combined[0].foreground == split[0].foreground)
        #expect(combined[0].panels[0].rect == split[0].panels[0].rect)
        #expect(combined[0].panels[0].coverage == split[0].panels[0].coverage)
        #expect(combined[0].backings.map(\.frame) == split[0].backings.map(\.frame))
        #expect(combined[0].backings.map(\.coverage) == split[0].backings.map(\.coverage))
    }
}
