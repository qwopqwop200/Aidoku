import CoreGraphics
import Testing
@testable import Aidoku

/// Production literal-native route, independent of the environment and rollback suite.
struct NativeSimpleParagraphGroupingTests {
    private typealias Pipeline = NativeParagraphFragmentGrouping
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

    @available(iOS 18.0, *)
    @Test func horizontalIndependentRowsRemainSeparateWithinOneRFScope() throws {
        let first = quad(.init(x: 40, y: 40, width: 92, height: 20))
        let second = quad(.init(x: 40, y: 71, width: 92, height: 27))
        let lines = NativeOCRAcceptedSource.bindingPrimary([
            .init(polygon: first, text: "用語一覧", score: 0.95, orientation: .horizontal, erasurePolygons: [first]),
            .init(polygon: second, text: "会場案内", score: 0.94, orientation: .horizontal, erasurePolygons: [second]),
        ], width: 400, height: 400)
        let scope = Pipeline.TextScope(owner: 1,
            box: .init(x: 0, y: 0, width: 0.5, height: 0.5), confidence: 0.9)
        let result = try Pipeline.simpleNativeResult(lines, width: 400, height: 400, scopes: [scope], balloons: [scope])
        #expect(result.outputOwners == 2)
        #expect(result.regions.map(\.source) == ["用語一覧", "会場案内"])
        #expect(result.regions.map { $0.acceptedSource.membership?.body } == [[0], [1]])
        #expect(result.regions.map { $0.auxiliaryInkPolygons.count } == [1, 1])
        #expect(result.regions.map(\.polygon) == [first, second].map { $0.map { .init(x: $0.x/400, y: $0.y/400) } })
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

    @available(iOS 18.0, *)
    @Test func disjointVerticalFragmentsReadTopFirstWithoutChangingTheirRepresentative() throws {
        let top = quad(.init(x: 100, y: 40, width: 30, height: 100))
        let bottom = quad(.init(x: 101, y: 150, width: 30, height: 80))
        let lines = NativeOCRAcceptedSource.bindingPrimary([
            .init(polygon: bottom, text: "bottom", score: 0.95, orientation: .vertical, erasurePolygons: [bottom]),
            .init(polygon: top, text: "top", score: 0.96, orientation: .vertical, erasurePolygons: [top]),
        ], width: 400, height: 400)
        let result = try Pipeline.simpleNativeResult(lines, width: 400, height: 400, scopes: [])
        #expect(result.outcome == .coalesced && result.outputOwners == 1)
        let region = try #require(result.regions.first)
        #expect(region.id == "simple-native-line-0")
        #expect(region.source == "top\nbottom")
        #expect(region.sourceSingleVerticalColumn == true)
        #expect(region.unitMemberRects.map(\.minY) == [40.0 / 400, 150.0 / 400])
        #expect(region.acceptedSource.membership?.body == [0, 1])
        #expect(region.auxiliaryInkPolygons.count == 2)
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

    @available(iOS 18.0, *)
    @Test func literalNativeRoutePreservesEveryPacketAndErasureWitness() throws {
        let first = quad(.init(x: 100, y: 100, width: 100, height: 20))
        let second = quad(.init(x: 100, y: 130, width: 100, height: 20))
        let lines = NativeOCRAcceptedSource.bindingPrimary([
            .init(polygon: first, text: "  literal  ", score: 0.96, orientation: .horizontal, erasurePolygons: [first]),
            .init(polygon: second, text: "tail", score: 0.55, orientation: .horizontal, erasurePolygons: [second]),
        ], width: 400, height: 400)
        let membership = try #require(lines[0].acceptedSource.membership)
        let split = try Pipeline.simpleNativeResult(lines, width: 400, height: 400, scopes: [])
        #expect(split.outcome == .noMatch && split.inputAtoms == 2 && split.outputOwners == 2)
        #expect(split.regions.map(\.source) == ["  literal  ", "tail"])
        #expect(split.regions.allSatisfy { $0.acceptedSource.membership?.table === membership.table })
        let scope = Pipeline.TextScope(owner: 7,
            box: CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.125), confidence: 0.9)
        let merged = try Pipeline.simpleNativeResult(lines, width: 400, height: 400, scopes: [scope])
        #expect(merged.outcome == .coalesced && merged.inputAtoms == 2 && merged.outputOwners == 1)
        let owner = try #require(merged.regions.first)
        #expect(owner.source == "  literal  \ntail")
        #expect(owner.confidence == 0.55)
        #expect(owner.acceptedSource.membership?.table === membership.table)
        #expect(owner.acceptedSource.membership?.body == [0, 1])
        #expect(owner.auxiliaryInkPolygons.count == 2)
        #expect(owner.unitMemberRects.count == 2)
    }

    @available(iOS 18.0, *)
    @Test func unknownSourceRetainsTheAtomButMalformedIngressThrows() throws {
        let box = quad(.init(x: 100, y: 100, width: 100, height: 20))
        let unknown = NativeCoreMLOCRLine(polygon: box, text: "unknown", score: 0.9, orientation: .horizontal)
        let empty = try Pipeline.simpleNativeResult([], width: 400, height: 400, scopes: [])
        #expect(empty.outcome == .empty && empty.inputAtoms == 0 && empty.outputOwners == 0)
        let unavailable = try Pipeline.simpleNativeResult([unknown], width: 400, height: 400, scopes: [])
        #expect(unavailable.outcome == .sourceUnavailable)
        #expect(unavailable.regions.map(\.source) == ["unknown"])
        let malformed = NativeCoreMLOCRLine(polygon: [], text: "bad", score: 0.9, orientation: .horizontal)
        do {
            _ = try Pipeline.simpleNativeResult([unknown, malformed], width: 400, height: 400, scopes: [])
            Issue.record("Malformed ingress silently became an empty or thinned page")
        } catch Pipeline.SimpleIngressError.invalidNativeGeometry(let index) {
            #expect(index == 1)
        }
        do {
            let bound = NativeOCRAcceptedSource.bindingPrimary([unknown], width: 400, height: 400)
            _ = try Pipeline.simpleNativeResult(bound, width: 401, height: 400, scopes: [])
            Issue.record("Mismatched packet dimensions silently succeeded")
        } catch Pipeline.SimpleIngressError.invalidDimensions {}
    }
}
