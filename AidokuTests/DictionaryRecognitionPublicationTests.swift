import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct DictionaryRecognitionPublicationTests {
    private func observation(_ text: String, x: CGFloat, y: CGFloat,
                             direction: TextRecognizer.ObservationDirection = .leftToRight) -> TextRecognizer.OCRObservation {
        let box = CGRect(x: x, y: y, width: 0.1, height: 0.1)
        return .init(text: text, boundingRect: box, direction: direction, confidence: 1,
                     characters: [.init(text: text, boundingRect: box)])
    }

    @Test func resetRejectsLatePreparedResultAndAllowsNextAnalysis() {
        let recognizer = TextRecognizer()
        let oldGeneration = recognizer.analysisGeneration()
        let stale = TextRecognizer.prepareAnalysis([observation("旧", x: 0.2, y: 0.55)])
        recognizer.reset()
        #expect(!recognizer.commitAnalysis(stale, generation: oldGeneration))
        #expect(recognizer.orderedClusterForObservation(0) == nil)
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(recognizer.paragraphOverlays(in: view, imageSize: CGSize(width: 100, height: 100)).isEmpty)
        #expect(recognizer.findText(at: CGPoint(x: 75, y: 40), in: view,
                                    imageSize: CGSize(width: 100, height: 100)) == nil)
        let current = TextRecognizer.prepareAnalysis([observation("新", x: 0.2, y: 0.55)])
        #expect(recognizer.commitAnalysis(current, generation: recognizer.analysisGeneration()))
        #expect(recognizer.orderedClusterForObservation(0) == [0])
        #expect(recognizer.findText(at: CGPoint(x: 75, y: 40), in: view,
                                    imageSize: CGSize(width: 100, height: 100))?.text == "新")
    }

    @Test func publicationPreservesReadingOrderCharactersAndAspectFitGeometry() throws {
        for direction in [TextRecognizer.ObservationDirection.leftToRight, .topToBottom] {
            let recognizer = TextRecognizer()
            let prepared = TextRecognizer.prepareAnalysis([
                observation("下", x: 0.2, y: 0.4, direction: direction),
                observation("上", x: 0.2, y: 0.55, direction: direction)
            ])
            #expect(recognizer.commitAnalysis(prepared, generation: recognizer.analysisGeneration()))
            #expect(recognizer.orderedClusterForObservation(0) == [1, 0])
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
            let result = try #require(recognizer.findText(at: CGPoint(x: 75, y: 40), in: view,
                                                         imageSize: CGSize(width: 100, height: 100)))
            #expect(result.text == "上下")
            #expect(result.fullText == "上下")
            // Match the existing normalized lower-left -> aspect-fit expression
            // exactly; no newly introduced geometric tolerance.
            let top = CGRect(x: 50 + 0.2 * 100, y: (1 - 0.55 - 0.1) * 100, width: 0.1 * 100, height: 0.1 * 100)
            let bottom = CGRect(x: 50 + 0.2 * 100, y: (1 - 0.4 - 0.1) * 100, width: 0.1 * 100, height: 0.1 * 100)
            #expect(result.charRect == top)
            #expect(result.charRects == [top, bottom])
            recognizer.reset()
            #expect(recognizer.orderedClusterForObservation(0) == nil)
        }
    }

    @Test func cancelledTaskCannotPublishEvenWithoutReset() async {
        let recognizer = TextRecognizer()
        let prepared = TextRecognizer.prepareAnalysis([observation("待", x: 0.2, y: 0.55)])
        let generation = recognizer.analysisGeneration()
        let task = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            return recognizer.commitAnalysis(prepared, generation: generation)
        }
        task.cancel()
        #expect(await task.value == false)
        #expect(recognizer.orderedClusterForObservation(0) == nil)
    }

    /// Bounded diagnostic, no Vision/model. Measures construction separately from
    /// short publication/reset critical sections. Not a screen latency benchmark.
    @Test func publicationTimingSeparatesClusterWorkFromLock() throws {
        let recognizer = TextRecognizer()
        let input = (0..<200).map { index in
            observation("字", x: CGFloat(index % 10) * 0.09, y: CGFloat(index / 10) * 0.045)
        }
        var samples: [[String: Any]] = []
        for iteration in 0..<6 {
            let start = ProcessInfo.processInfo.systemUptime
            let prepared = TextRecognizer.prepareAnalysis(input)
            let afterPrepare = ProcessInfo.processInfo.systemUptime
            #expect(recognizer.commitAnalysis(prepared, generation: recognizer.analysisGeneration()))
            let afterCommit = ProcessInfo.processInfo.systemUptime
            #expect(recognizer.orderedClusterForObservation(199) != nil)
            recognizer.reset()
            let afterReset = ProcessInfo.processInfo.systemUptime
            samples.append(["iteration": iteration, "observations": input.count,
                            "prepareMS": (afterPrepare - start) * 1000,
                            "commitWithGenerationReadMS": (afterCommit - afterPrepare) * 1000,
                            "lookupAndResetMS": (afterReset - afterCommit) * 1000])
        }
        let directory = URL.documentsDirectory.appendingPathComponent("FullAuditPerformance/DictionaryPublication")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
            .write(to: output, options: .atomic)
    }
}
