import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeOCRSlantedDependentColumnsTests {
    private typealias Column = NativeOCRSlantedDependentColumns.Column

    private func fixture(_ text: String, right: Bool, scale: CGFloat = 1, id: Int? = nil) -> Column {
        // fresh54/0062 native OCR quads, in original 900x1200 pixel space.
        let coordinates: [(CGFloat, CGFloat)] = right
            ? [(521, 231), (571, 221), (619, 468), (569, 478)]
            : [(475, 278), (536, 260), (612, 522), (551, 540)]
        return Column(id: id ?? (right ? 0 : 1), text: text,
                      polygon: coordinates.map { CGPoint(x: $0.0 * scale, y: $0.1 * scale) }, isVertical: true)
    }

    private func accepts(_ a: Column, _ b: Column, nearby: [Column] = [],
                         separated: Bool = false, ink: Bool = false, polarity: Bool = false) -> Bool {
        NativeOCRSlantedDependentColumns.accepts(a, b, nearby: nearby,
            ownershipSeparated: separated, inkContrasted: ink, polarityContrasted: polarity)
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func temporalRequestUsesQuadGeometryAndStableOrder(scale: CGFloat) {
        let a = fixture("逃げるときも…", right: true, scale: scale)
        let b = fixture("手…ひっぱってね…", right: false, scale: scale)
        #expect(accepts(a, b, nearby: [a, b]))
        #expect(accepts(b, a, nearby: [b, a]))
        // A grammatical family, not an exact corpus-text allowlist.
        #expect(accepts(fixture("帰る時は…", right: true, scale: scale),
                        fixture("声をかけてください…", right: false, scale: scale)))
    }

    @Test func independentQuotesSentencesAndSpeakersRemainSeparate() {
        let head = fixture("逃げるときも…", right: true)
        let tail = fixture("手…ひっぱってね…", right: false)
        #expect(!accepts(fixture("「逃げるときも…」", right: true), tail))
        #expect(!accepts(head, fixture("「手…ひっぱってね…」", right: false)))
        #expect(!accepts(fixture("逃げるよ…", right: true), tail))
        #expect(!accepts(fixture("もう帰ります。", right: true), fixture("また来てね…", right: false)))
        #expect(!accepts(head, fixture("私は帰る…", right: false)))
        #expect(!accepts(head, fixture("花子：手をひっぱってね…", right: false)))
        #expect(!accepts(head, tail, separated: true))
        #expect(!accepts(head, tail, ink: true))
        #expect(!accepts(head, tail, polarity: true))
    }

    @Test func ambiguousNeighboursAndRemoteColumnsDoNotBorrowOwnership() {
        let a = fixture("逃げるときも…", right: true)
        let b = fixture("手…ひっぱってね…", right: false)
        let neighbour = fixture("違う人の話", right: false, id: 2)
        #expect(!accepts(a, b, nearby: [a, b, neighbour]))
        let remote = Column(id: b.id, text: b.text,
                            polygon: b.polygon.map { CGPoint(x: $0.x - 300, y: $0.y) }, isVertical: true)
        #expect(!accepts(a, remote))
        let horizontal = Column(id: b.id, text: b.text, polygon: b.polygon, isVertical: false)
        #expect(!accepts(a, horizontal))
        #expect(!accepts(a, a))
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func productionMergePreservesBothOwnedPolygonsAndWords(scale: CGFloat) {
        let columns = [fixture("逃げるときも…", right: true, scale: scale),
                       fixture("手…ひっぱってね…", right: false, scale: scale)]
        for ordered in [columns, Array(columns.reversed())] {
            let raw = ordered.map { NativeCoreMLOCRLine(polygon: $0.polygon, text: $0.text,
                score: 0.98, orientation: .vertical, erasurePolygons: [$0.polygon]) }
            let result = NativeOCRTextLineMerger.merge(raw, imageWidth: Int(900 * scale), imageHeight: Int(1200 * scale))
            #expect(result.count == 1)
            #expect(result.first?.text.replacingOccurrences(of: "\n", with: "") == "逃げるときも…手…ひっぱってね…")
            for column in columns {
                #expect(result.first?.auxiliaryInkPolygons.contains(column.polygon) == true)
            }
            let vetoed = NativeOCRTextLineMerger.merge(raw, imageWidth: Int(900 * scale), imageHeight: Int(1200 * scale),
                                                      separationCheck: { _, _, _ in true })
            #expect(vetoed.count == 2)
        }
    }
}
