import CoreGraphics
import Testing
@testable import Aidoku

/// Production literal-native route, independent of the environment and rollback suite.
struct NativeSimpleParagraphGroupingTests {
    private typealias Simple = NativeSimpleParagraphGrouping

    private func quad(_ box: CGRect) -> [CGPoint] {
        [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
         CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
    }

    @Test func verticalParallelColumnsCanBeStaggeredWithoutRelaxingHorizontalRows() throws {
        func atom(_ box: CGRect, vertical: Bool) -> Simple.Input {
            .init(polygon: quad(box), orientation: vertical ? .vertical : .horizontal,
                  operation: 0, confidence: 0.95)
        }
        let column = atom(.init(x: 100, y: 100, width: 20, height: 100), vertical: true)
        let staggered = atom(.init(x: 130, y: 140, width: 20, height: 100), vertical: true)
        let distantAlong = atom(.init(x: 130, y: 155, width: 20, height: 100), vertical: true)
        let merged = try #require(Simple.group([column, staggered], textScopes: [], balloons: []))
        #expect(merged.map(\.members) == [[0, 1]])
        #expect(merged.first?.readingOrder == [1, 0])
        #expect(Simple.group([column, distantAlong], textScopes: [], balloons: [])?.count == 2)

        let row = atom(.init(x: 100, y: 100, width: 100, height: 20), vertical: false)
        let offsetRow = atom(.init(x: 140, y: 130, width: 100, height: 20), vertical: false)
        #expect(Simple.group([row, offsetRow], textScopes: [], balloons: [])?.count == 2)
    }

    @Test func weakParallelAttachmentNeedsSharedTextEvidenceButSameLineDoesNot() throws {
        func atom(x: CGFloat, y: CGFloat, confidence: Double) -> Simple.Input {
            .init(polygon: quad(.init(x: x, y: y, width: 100, height: 20)),
                  orientation: .horizontal, operation: 0, confidence: confidence)
        }
        let strong = atom(x: 100, y: 100, confidence: 0.96)
        let weak = atom(x: 100, y: 130, confidence: 0.55)
        let shared = Simple.Scope(owner: 7, box: CGRect(x: 100, y: 100, width: 100, height: 50), confidence: 0.9)
        let split = try #require(Simple.group([strong, weak], textScopes: [], balloons: []))
        #expect(split.map(\.members).sorted { $0.lexicographicallyPrecedes($1) } == [[0], [1]])
        #expect(Simple.group([strong, weak], textScopes: [shared], balloons: [])?.count == 1)
        #expect(Simple.group([strong, atom(x: 100, y: 130, confidence: 0.61)], textScopes: [], balloons: [])?.count == 1)
        #expect(Simple.group([strong, atom(x: 210, y: 100, confidence: 0.55)], textScopes: [], balloons: [])?.count == 1)
    }

    @Test func closeEqualMeasureHorizontalRowsAndSameBaselineFragmentsStillMerge() throws {
        func atom(_ x: CGFloat, _ y: CGFloat, _ source: String) -> Simple.Input {
            .init(polygon: quad(.init(x: x, y: y, width: 90, height: 20)), orientation: .horizontal,
                  operation: 0, confidence: 0.97, source: source)
        }
        let a = atom(20, 20, "文章前半"), b = atom(20, 45, "文章後半"), c = atom(117, 20, "追加部分")
        #expect(Simple.group([a, b], textScopes: [], balloons: [])?.map(\.members) == [[0, 1]])
        #expect(Simple.group([a, c], textScopes: [], balloons: [])?.map(\.members) == [[0, 1]])
    }

    @Test func verticallyOverlappingFragmentsKeepTheExistingTieBreak() throws {
        let inputs = [CGRect(x: 100, y: 40, width: 30, height: 100),
                      CGRect(x: 101, y: 135, width: 30, height: 80)].map {
            Simple.Input(polygon: quad($0), orientation: .vertical, operation: 0, confidence: 0.95)
        }
        let groups = try #require(Simple.group(inputs, textScopes: [], balloons: []))
        #expect(groups.count == 1)
        #expect(groups.first?.singleVerticalColumn == true)
        #expect(groups.first?.readingOrder == [1, 0])
    }

    @Test func parallelColumnsRetainTheirOrderAndReadDisjointFragmentsTopFirst() throws {
        let inputs = [
            CGRect(x: 131, y: 138, width: 20, height: 92),
            CGRect(x: 100, y: 75, width: 20, height: 70),
            CGRect(x: 130, y: 40, width: 20, height: 90),
            CGRect(x: 101, y: 153, width: 20, height: 90),
        ].map {
            Simple.Input(polygon: quad($0), orientation: .vertical, operation: 0, confidence: 0.95)
        }
        let groups = try #require(Simple.group(inputs, textScopes: [], balloons: []))
        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group.members == [0, 1, 2, 3])
        #expect(!group.singleVerticalColumn)
        #expect(group.representative == 0)
        #expect(group.readingOrder == [2, 0, 1, 3])
    }

    @Test func chainedCrossOverlapWithoutACommonStripKeepsLegacyOrder() throws {
        let inputs = [
            CGRect(x: 100, y: 20, width: 20, height: 56),
            CGRect(x: 108, y: 80, width: 20, height: 56),
            CGRect(x: 116, y: 140, width: 20, height: 56),
        ].map {
            Simple.Input(polygon: quad($0), orientation: .vertical, operation: 0, confidence: 0.95)
        }
        let groups = try #require(Simple.group(inputs, textScopes: [], balloons: []))
        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(!group.singleVerticalColumn)
        #expect(group.readingOrder == [2, 1, 0])
    }
}
