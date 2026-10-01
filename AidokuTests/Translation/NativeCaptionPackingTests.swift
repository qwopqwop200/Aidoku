import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct NativeCaptionPackingTests {
    private func entry(id: String, font: Double, demand: Int, ink: CGRect, panel: CGRect, source: CGRect?,
                       valid: Bool = true, color: [Double] = [255, 255, 255]) -> NativeCaptionPacking.Entry {
        .init(id: id, text: String(repeating: "가", count: demand), font: font, ink: ink, source: source,
              packingValid: valid, panels: [.init(rect: panel, color: color)])
    }
    private func measure(_ e: NativeCaptionPacking.Entry, _ cell: CGRect, _ font: Double) -> NativeCaptionPacking.Measurement? {
        let demand = Double(e.text.count) * font, available = max(0, Double(cell.width) - 6)
        let lines = max(1, ceil(demand / max(1, available))), width = min(demand, available), height = font * 1.2 * lines
        return .init(ink: CGRect(x: cell.midX - width / 2, y: cell.midY - height / 2, width: width, height: height))
    }

    @Test func compactionCannotCountNonintersectingSourceFootprints() {
        let input = [
            entry(id: "0", font: 18, demand: 5, ink: CGRect(x: 121, y: 66, width: 37, height: 15),
                  panel: CGRect(x: 116, y: 61, width: 47, height: 37), source: CGRect(x: 118, y: 53, width: 20, height: 20)),
            entry(id: "1", font: 8, demand: 3, ink: CGRect(x: 44, y: 92, width: 79, height: 15),
                  panel: CGRect(x: 39, y: 87, width: 89, height: 81), source: CGRect(x: 29, y: 82, width: 20, height: 20)),
            entry(id: "2", font: 8, demand: 15, ink: CGRect(x: 99, y: 155, width: 74, height: 15),
                  panel: CGRect(x: 94, y: 150, width: 84, height: 78), source: CGRect(x: 95, y: 146, width: 20, height: 20)),
            entry(id: "3", font: 8, demand: 5, ink: CGRect(x: 174, y: 134, width: 69, height: 15),
                  panel: CGRect(x: 169, y: 129, width: 79, height: 90), source: CGRect(x: 171, y: 138, width: 20, height: 20), valid: false)
        ]
        let result = NativeCaptionPacking.pack(input, page: CGRect(x: 0, y: 0, width: 300, height: 300), opacity: 1, measure: measure)
        // Frozen partition: the first cell has no coverage from the two lower
        // plates. A negative raw intersection must not become a standardized rectangle.
        #expect(result.fallbacks == 0)
        #expect(result.entries[0].cell == CGRect(x: 39, y: 61, width: 124, height: 42.5))
        #expect(result.entries[0].compactOriginal == CGRect(x: 39, y: 61, width: 209, height: 42.5))
        #expect(result.entries[0].font == 18)
    }

    @Test func foreignCoverageUsesItsOwnerOnlyWhenSourcePixelsCorroborateColor() {
        let input = [
            entry(id: "a", font: 12, demand: 3, ink: CGRect(x: 25, y: 25, width: 45, height: 15),
                  panel: CGRect(x: 20, y: 20, width: 60, height: 30), source: CGRect(x: 25, y: 25, width: 30, height: 15), valid: false),
            entry(id: "b", font: 12, demand: 3, ink: CGRect(x: 80, y: 60, width: 50, height: 15),
                  panel: CGRect(x: 70, y: 40, width: 70, height: 60), source: CGRect(x: 80, y: 60, width: 30, height: 15), valid: false, color: [0, 0, 0])
        ]
        func render(_ color: [UInt8]) -> NativeCaptionPacking.Result {
            NativeCaptionPacking.pack(input, page: CGRect(x: 0, y: 0, width: 300, height: 300), opacity: 1,
                measure: measure, readSource: { rect, width, height in
                    let w = width == 0 ? max(1, Int(ceil(rect.maxX) - floor(rect.minX))) : width
                    let h = height == 0 ? max(1, Int(ceil(rect.maxY) - floor(rect.minY))) : height
                    return .init(rgba: (0..<(w * h)).flatMap { _ in color + [255] }, width: w, height: h)
                })
        }
        let verified = render([0, 0, 0])
        #expect(verified.entries.flatMap(\.foreignFills).count == 1)
        #expect(verified.entries.flatMap(\.foreignFills).first?.color == [0, 0, 0])
        #expect(render([180, 80, 40]).entries.flatMap(\.foreignFills).isEmpty)
    }
}
