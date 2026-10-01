import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeRecoveredLineProtectionTests {
    private func item(_ id: String = "recovered", plates: [NativeRecoveredLineProtection.Plate]? = nil) -> NativeRecoveredLineProtection.Item {
        .init(id: id, recoveredLine: true, sourceBounds: [0.4, 0.4, 0.2, 0.2], sourceFontSize: 12, hasNode: true,
            plates: plates ?? [.init(rect: CGRect(x: 0, y: 0, width: 100, height: 100), color: [255, 255, 255])])
    }
    @Test func twoPercentArtworkHarmKeepsSourceAndSubtractsPaintedNeighborFromHalo() throws {
        let owner = NativeRecoveredLineProtection.Item(id: "neighbor", recoveredLine: false,
            sourceBounds: [0.55, 0.3, 0.2, 0.4], sourceFontSize: nil, hasNode: true, plates: [])
        let result = try NativeRecoveredLineProtection.evaluate(items: [item(), owner],
            cleanupFrame: CGRect(x: 0, y: 0, width: 100, height: 100), imageSize: CGSize(width: 100, height: 100), opacity: 1) { crop in
            var rgba = [UInt8](repeating: 255, count: crop.width * crop.height * 4)
            for y in 0..<100 { for x in 0..<2 { let p = (y * 100 + x) * 4; rgba[p] = 0; rgba[p+1] = 0; rgba[p+2] = 0 } }
            return rgba
        }
        #expect(result.droppedIDs == ["recovered"])
        #expect(result.shares.first?.value == 0.02)
        #expect(result.remainingBudget == 252_144)
        let zones = NativeKeptSourceRestoration.zones(kept: result.kept.map { .init(id: $0.id, rect: $0.rect, sourceFontSize: $0.sourceFontSize) },
            painted: result.painted)
        #expect(!zones.isEmpty)
        #expect(zones.allSatisfy { !NativePanelGeometry.intersects($0.rect, result.painted[0]) })
    }
    @Test func sourceInkAndExactlyFortyChannelDifferenceDoNotCountAsArtworkHarm() throws {
        let result = try NativeRecoveredLineProtection.evaluate(items: [item()], cleanupFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            imageSize: CGSize(width: 100, height: 100), opacity: 1) { _ in
            var rgba = [UInt8](repeating: 255, count: 40_000)
            for y in 0..<100 { for x in 0..<100 {
                let p = (y * 100 + x) * 4; rgba[p] = 215
                if x >= 38 && x < 62 && y >= 38 && y < 62 { rgba[p] = 0; rgba[p+1] = 0; rgba[p+2] = 0 }
            } }
            return rgba
        }
        #expect(result.droppedIDs.isEmpty)
        #expect(result.shares.first?.value == 0)
    }
    @Test func sharedBudgetSkipsLaterPlatesAndTranslucencySkipsEntirePolicy() throws {
        let plates = (0..<12).map { _ in NativeRecoveredLineProtection.Plate(rect: CGRect(x: 0, y: 0, width: 2048, height: 1024), color: [255,255,255]) }
        var reads = 0
        let result = try NativeRecoveredLineProtection.evaluate(items: [item(plates: plates)],
            cleanupFrame: CGRect(x: 0, y: 0, width: 2048, height: 1024), imageSize: CGSize(width: 2048, height: 1024), opacity: 1) { crop in
            reads += 1
            #expect(crop.width * crop.height <= 32_768)
            return [UInt8](repeating: 255, count: crop.width * crop.height * 4)
        }
        #expect(reads == 8)
        #expect(result.remainingBudget >= 0)
        let disabled = try NativeRecoveredLineProtection.evaluate(items: [item()], cleanupFrame: CGRect(x: 0,y: 0,width: 100,height: 100),
            imageSize: CGSize(width: 100,height: 100), opacity: 0.99) { _ in Issue.record("Translucent plates must not be sampled"); return nil }
        #expect(disabled.shares.isEmpty)
        #expect(disabled.remainingBudget == 262_144)
    }
}
