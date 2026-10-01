import CoreGraphics
import Testing
@testable import Aidoku

struct NativeOCRStackedAsideRecoveryTests {
    @Test(arguments: [0.5, 1.0, 2.0])
    func separateSmallColumnsBoundOverlongBodyColumns(scale: CGFloat) throws {
        func read(_ id: Int, _ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NativeCoreMLRecognizedRegion {
            let box = CGRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale)
            return .init(sourceIndex: id, polygon: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)], text: text, confidence: 0.99)
        }
        // Actual detector bounds from the attached page; two columns swallowed the smaller aside below.
        let rows = [read(0, "だろうねぇ", 12, 327, 46, 167), read(1, "何されるんホントに", 50, 343, 46, 255),
                    read(2, "今夜、ボクはー", 87, 343, 47, 293), read(3, "ないなー♡", 3, 509, 36, 121),
                    read(4, "しょうが", 33, 503, 32, 107), read(5, "ホントに", 60, 503, 30, 105)]
        for input in [rows, Array(rows.reversed())] {
            let proposals = NativeOCRStackedAsideRecovery.proposals(input)
            #expect(proposals.count == 1)
            let proposal = try #require(proposals.first)
            #expect(Set(proposal.regions.map(\.sourceIndex)) == [1, 2])
            #expect(proposal.regions.allSatisfy { (NativeOCRScopeGeometry.bounds(for: $0.polygon)?.maxY ?? 0) == 498.5 * scale })
            let reread = proposal.regions.map { region in
                NativeCoreMLRecognizedRegion(sourceIndex: region.sourceIndex, polygon: region.polygon,
                    text: region.sourceIndex == 1 ? "何されるん" : "今夜、ボクは", confidence: 0.99)
            }
            #expect(NativeOCRStackedAsideRecovery.replacements(proposal, reads: reread)?.count == 2)
            #expect(NativeOCRStackedAsideRecovery.replacements(proposal, reads: Array(reread.prefix(1))) == nil)
            let wrong = proposal.regions.map { region in
                NativeCoreMLRecognizedRegion(sourceIndex: region.sourceIndex, polygon: region.polygon, text: "別の文章", confidence: 0.99)
            }
            #expect(NativeOCRStackedAsideRecovery.replacements(proposal, reads: wrong) == nil)
        }
        #expect(NativeOCRStackedAsideRecovery.proposals(Array(rows.prefix(3))).isEmpty)
        #expect(NativeOCRStackedAsideRecovery.proposals(Array(rows.dropFirst())).isEmpty)
    }
}
