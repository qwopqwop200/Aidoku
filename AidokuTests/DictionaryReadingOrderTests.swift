import Testing
import UIKit
@testable import Aidoku

@MainActor @Suite struct DictionaryReadingOrderTests {
    private func observation(_ text: String, x: CGFloat, y: CGFloat, direction: TextRecognizer.ObservationDirection) -> TextRecognizer.OCRObservation {
        let box = CGRect(x: x, y: y, width: 0.1, height: 0.1)
        return .init(text: text, boundingRect: box, direction: direction, confidence: 1,
                     characters: [.init(text: text, boundingRect: box)])
    }

    @Test func visionCoordinatesOrderHorizontalRowsTopFirst() {
        let recognizer = TextRecognizer()
        recognizer.observations = [observation("下", x: 0.2, y: 0.4, direction: .leftToRight),
                                   observation("上", x: 0.2, y: 0.55, direction: .leftToRight)]
        recognizer.rebuildClusterCache()
        #expect(recognizer.orderedClusterIndices([0, 1]) == [1, 0])
    }

    @Test func visionCoordinatesOrderVerticalColumnTopFirst() {
        let recognizer = TextRecognizer()
        recognizer.observations = [observation("下", x: 0.2, y: 0.4, direction: .topToBottom),
                                   observation("上", x: 0.2, y: 0.55, direction: .topToBottom)]
        recognizer.rebuildClusterCache()
        #expect(recognizer.orderedClusterIndices([0, 1]) == [1, 0])
    }
    @Test func dictionaryOverlayMapsWholeUnicodeCharactersToLookupHits() throws {
        guard #available(iOS 18.0, *) else { return }
        for text in ["𠮷野家", "か\u{3099}くせい"] {
            let rect = CGRect(x: 0, y: 0, width: 240, height: 60)
            let suffixes = text.indices.map { String(text[$0...]) }
            let button = DictionaryOverlayButton(type: .system)
            button.apply(overlay: .init(text: text, rect: rect, segments: [
                .init(text: text, rect: rect, charHits: suffixes.map { .init(text: $0, rect: rect) })
            ]))
            var observed = Set<String>()
            for y in stride(from: CGFloat(0), to: rect.height, by: 1) {
                for x in stride(from: CGFloat(0), to: rect.width, by: 1) {
                    if let hit = button.lookupHit(at: CGPoint(x: x, y: y)) { observed.insert(hit.text) }
                }
            }
            #expect(observed == Set(suffixes))
        }
    }

    @Test func dictionaryPopupFitsLandscapeAndOffsetSafeFrame() {
        let frame = CGRect(x: 50, y: 24, width: 320, height: 180)
        for vertical in [false, true] {
            for fullWidth in [false, true] {
                for selection in [CGRect(x: 120, y: 90, width: 30, height: 20), frame] {
                    let layout = PopupLayout(selectionRect: selection, availableFrame: frame,
                                             maxWidth: 320, maxHeight: 350,
                                             isVertical: vertical, isFullWidth: fullWidth)
                    #expect(layout.width > 0 && layout.height > 0)
                    let result = CGRect(x: layout.position.x - layout.width / 2,
                                        y: layout.position.y - layout.height / 2,
                                        width: layout.width, height: layout.height)
                    #expect(frame.contains(result))
                }
            }
        }
    }

}
