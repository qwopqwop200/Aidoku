import CoreGraphics
import Testing
@testable import Aidoku

struct NativeOCRDetectorAlternateBindingTests {
    typealias G = NativeOCRIndividualGeometryHypotheses
    @available(iOS 18.0, *)
    typealias Runtime = NativeOCRRawCanonicalRuntime

    @available(iOS 18.0, *)
    @Test func enlargedQuadsKeepTheirOwnDetectorParent() throws {
        let raw = quad(x: 10, y: 20, width: 8, height: 20)
        let expanded = quad(x: 9, y: 19, width: 10, height: 22)
        let originals = [NativeCoreMLDetectionBox(polygon: quad(x: 40, y: 20, width: 8, height: 20), score: 0.8),
                         .init(polygon: raw, score: 0.9, alternateRecognitionPolygon: expanded)]

        let rows = try Runtime.detectorAlternateRecords(requestID: "page", originals: originals, width: 80, height: 100)

        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.requestID == "page")
        #expect(row.sourceIndex == 5)
        #expect(row.sourceParent == 1)
        #expect(row.sourceMembers.isEmpty)
        #expect(row.originalDetectorIndex == nil)
        #expect(row.polygon == geometry(expanded))
        #expect(originals[1].polygon == raw)
    }

    @available(iOS 18.0, *)
    @Test func invalidGeometryAndExcessAlternatesFailClosed() {
        let raw = quad(x: 10, y: 20, width: 8, height: 20)
        let shifted = quad(x: 15, y: 20, width: 10, height: 24)
        let expanded = quad(x: 9, y: 19, width: 10, height: 22)
        let invalid = NativeCoreMLDetectionBox(polygon: raw, score: 0.9, alternateRecognitionPolygon: shifted)
        let valid = NativeCoreMLDetectionBox(polygon: raw, score: 0.9, alternateRecognitionPolygon: expanded)

        #expect(throws: Runtime.Failure.invalidDetectorAlternate) {
            _ = try Runtime.detectorAlternateRecords(requestID: "page", originals: [invalid], width: 80, height: 100)
        }
        #expect(throws: Runtime.Failure.invalidDetectorAlternate) {
            let originals = Array(repeating: valid, count: NativeCoreMLDBPostprocessor.maximumAlternateCellEnvelopes + 1)
            _ = try Runtime.detectorAlternateRecords(requestID: "page", originals: originals, width: 80, height: 100)
        }
    }

    @available(iOS 18.0, *)
    @Test func parentElectionRetainsConflictsAndUsesOnlyActualAlternateReads() throws {
        let originals = (0..<5).map { index -> NativeCoreMLDetectionBox in
            let x = CGFloat(index * 15 + 2)
            return .init(polygon: quad(x: x, y: 10, width: 6, height: 10), score: 0.9,
                         alternateRecognitionPolygon: quad(x: x - 1, y: 9, width: 8, height: 12))
        }
        let alternateRecords = try Runtime.detectorAlternateRecords(requestID: "page", originals: originals,
            width: 100, height: 100)
        let originalRecords = originals.enumerated().map { index, box in
            G.Record(requestID: "page", sourceIndex: originals.count + index, sourceParent: index, sourceMembers: [],
                alternativeID: "raw/\(index)", origin: .corrected, originalDetectorIndex: nil, polygon: geometry(box.polygon))
        }
        let bank = G.emit(requestID: "page", corrected: originalRecords + alternateRecords, originals: [])
        let observations: [(Int, String, Double)] = [(0, "old", 0.9), (1, "same", 0.7), (3, "same", 0.9),
            (4, "\u{e9}", 0.8), (5, "different", 0.99), (6, "same", 0.8), (7, "recovered", 0.7),
            (8, "same", 0.8), (9, "e\u{301}", 0.99)]
        let reads = observations.map { index, text, confidence in
            NativeCoreMLRecognizedRegion(sourceIndex: index,
                polygon: bank.individuals[index].polygon.map { CGPoint(x: $0.x, y: $0.y) },
                text: text, confidence: confidence)
        }

        let elected = Runtime.detectorAlternateElection(reads: reads, bank: bank, originalCount: originals.count)

        #expect(elected.kept.map { reads[$0].sourceIndex } == [0, 6, 7, 3, 4])
        let suppressed = Dictionary(uniqueKeysWithValues: elected.suppressedByWinner.map { winner, rejected in
            (reads[winner].sourceIndex, reads[rejected].sourceIndex)
        })
        #expect(suppressed == [0: 5, 6: 1, 3: 8, 4: 9])
    }

    private func quad(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> [CGPoint] {
        [.init(x: x, y: y), .init(x: x + width, y: y), .init(x: x + width, y: y + height), .init(x: x, y: y + height)]
    }

    private func geometry(_ quad: [CGPoint]) -> [G.Point] {
        quad.map { .init(x: Double($0.x), y: Double($0.y)) }
    }
}
