import CoreGraphics
import Foundation

// Standalone contract test. Stubs isolate source-packet plumbing; no models or
// renderer run. Compile with the three production SourceInput Swift files.
enum NativeRFDETRLayoutResource {
    static let highresSourceWeightsSHA256 = "test-rf27-binding"
}
struct NativeRFDETRSourceImage {
    let identity: String
    let width: Int
    let height: Int
    let rgb: Data
}
struct NativePixelRFEvidence {
    let imageIdentity: String
    let width: Int
    let height: Int
    struct Support { let full: [Float]; let coarse: [Float]; let affinityScores: [Float] }
    func support(crop: CGRect, polygons: [[CGPoint]], sourceIdentity: String) throws -> Support {
        let n = Int(crop.width * crop.height)
        return Support(full: .init(repeating: 0, count: n * 27), coarse: .init(repeating: 0, count: n * 4),
                       affinityScores: .init(repeating: 0, count: 5))
    }
}
protocol NativeAppearanceImageOperations {
    func raster(polygons: [[CGPoint]], width: Int, height: Int) throws -> [UInt8]
}
struct TestOperations: NativeAppearanceImageOperations {
    func raster(polygons: [[CGPoint]], width: Int, height: Int) throws -> [UInt8] {
        .init(repeating: 0, count: width * height)
    }
}
enum NativeIndependentPanelGutter {
    static func clip(_ points: [CGPoint], to: CGRect) -> [CGPoint] { points }
}
struct NativeSelectedSourceSegmentationProducer {
    typealias Capture = () -> Void
    var truncated = false
    struct Prediction {
        let primary: [Float]; let boundary: [Float]; let rawNative: [UInt8]
        let completed: [UInt8]; let mask: [UInt8]; let audit: [String: Any]
    }
    func predict(rgb: [UInt8], width: Int, height: Int, polygons: [[CGPoint]], fontPixels: Double,
                 coarseRF: [Float], fullRF: [Float], affinity: [Float], rfModelWeightsSHA256: String,
                 capture: Capture?) throws -> Prediction {
        let n = width * height
        return Prediction(primary: .init(repeating: 0, count: truncated ? n - 1 : n),
            boundary: .init(repeating: 0, count: n), rawNative: .init(repeating: 0, count: n),
            completed: .init(repeating: 255, count: n), mask: .init(repeating: 255, count: n), audit: [:])
    }
}
@main enum NativeSourceWordEvidenceTests {
    static func reject(_ body: () throws -> Void) {
        do { try body(); fatalError("Expected rejection") } catch {}
    }
    static func main() throws {
        let quad: [[Double]] = [[20, 20], [30, 20], [30, 40], [20, 40]]
        let other: [[Double]] = [[32, 20], [36, 20], [36, 40], [32, 40]]
        let rows: [[String: Any]] = [
            ["text": " first\n", "sourceIndex": 19, "polygon": other],
            ["text": "一語", "sourceIndex": 3, "polygon": quad],
            ["text": "same geometry, distinct observation", "sourceIndex": 7, "polygon": quad],
            ["text": "unassociated", "sourceIndex": 99, "polygon": [[0.0, 0], [1, 0], [1, 1]]],
            ["text": "no fabricated index", "polygon": quad],
            ["text": "fractional index", "sourceIndex": 1.5, "polygon": quad]
        ]
        let item: [String: Any] = ["text": "translation", "sourceOriginalText": "unsplit paragraph",
            "sourceBounds": [0.2, 0.2, 0.16, 0.2], "sourceMemberPolygons": [quad, other]]
        let source = NativeRFDETRSourceImage(identity: "source", width: 100, height: 100,
                                             rgb: Data(repeating: 0, count: 30_000))
        let owners = try NativeSourceInputFactory.make(source: source, items: [item],
            sourceEvidence: ["originalRecognizer": ["regions": rows]],
            rf: NativePixelRFEvidence(imageIdentity: "source", width: 100, height: 100), ops: TestOperations())
        var input = owners[0].input
        precondition(input.rf.count == input.width * input.height * 27)
        precondition(input.wordEvidence.map(\.sourceIndex) == [19, 3, 7])
        precondition(input.wordEvidence.map(\.text) == [" first\n", "一語", "same geometry, distinct observation"])
        precondition(input.sourceText == "unsplit paragraph" && input.observationValid.isEmpty)
        let word = input.wordEvidence[1]
        precondition(word.bbox.offsetBy(dx: input.crop.minX, dy: input.crop.minY) == CGRect(x: 20, y: 20, width: 10, height: 20))
        precondition(word.polygon[0].x + input.crop.minX == 20)
        let copied = try NativeSelectedSourceSegmentationProducer().segment(input).input
        precondition(copied.wordEvidence.map(\.text) == input.wordEvidence.map(\.text))
        precondition(copied.rawNative.allSatisfy { $0 == 0 } && copied.completed.allSatisfy { $0 == 255 })
        precondition(copied.observationValid.allSatisfy { $0 == 1 }) // observed zero probabilities stay valid
        try copied.validateWeightObservations()
        try copied.validateWeightObservations(requireWordEvidence: true)
        reject { _ = try NativeSelectedSourceSegmentationProducer(truncated: true).segment(input) }
        input = copied
        input.observationValid = []
        try input.validate() // compatibility: legacy consumers do not require availability
        reject { try input.validateWeightObservations() }
        input.observationValid = .init(repeating: 0, count: input.width * input.height)
        reject { try input.validateWeightObservations() }
        input = copied; input.rawNative[0] = 2
        reject { try input.validateWeightObservations() }
        input = copied; input.boundary[0] = .nan
        reject { try input.validateWeightObservations() }
        input = copied; input.wordEvidence = []
        try input.validate()
        try input.validateWeightObservations() // binary base/directional correction remain available
        try input.validateWeightObservations(requireWordEvidence: false)
        reject { try input.validateWeightObservations(requireWordEvidence: true) }
        precondition(input.wordEvidence.isEmpty) // validation never fabricates observations
        // Page-valid geometry alone cannot certify a text/bbox/polygon pairing.
        func withBox(_ box: CGRect) -> SourceNativeInput {
            var packet = copied
            packet.wordEvidence = [SourceWordEvidence(text: word.text, sourceIndex: word.sourceIndex,
                                                       bbox: box, polygon: word.polygon)]
            return packet
        }
        reject { try withBox(word.bbox.offsetBy(dx: 0.1, dy: 0)).validate(requirePredictions: false) }
        reject { try withBox(word.bbox.offsetBy(dx: 0, dy: 0.1)).validate() }
        reject { try withBox(CGRect(x: word.bbox.minX, y: word.bbox.minY,
                                   width: word.bbox.width + 0.1, height: word.bbox.height)).validate() }
        reject { try withBox(CGRect(x: word.bbox.minX, y: word.bbox.minY,
                                   width: word.bbox.width, height: word.bbox.height + 0.1)).validate() }
        try withBox(word.bbox.offsetBy(dx: 1e-6, dy: -1e-6)).validateWeightObservations(requireWordEvidence: true)
        // Original evidence survives a feature crop that cuts through a member.
        let crop = CGRect(x: 25, y: 25, width: 10, height: 10)
        let words = try NativeSourceInputFactory.wordEvidence(recognizedRows: rows,
            members: [quad.map { CGPoint(x: $0[0], y: $0[1]) }], crop: crop)
        precondition(words.count == 2 && words[0].polygon[0] == CGPoint(x: -5, y: -5))
        let reversed = Array(quad.reversed()).map { CGPoint(x: $0[0], y: $0[1]) }
        let reversedWords = try NativeSourceInputFactory.wordEvidence(recognizedRows: rows, members: [reversed], crop: crop)
        let absentWords = try NativeSourceInputFactory.wordEvidence(recognizedRows: [], members: [reversed], crop: crop)
        precondition(reversedWords.count == 2 && absentWords.isEmpty)
        print("NativeSourceWordEvidenceTests passed (factory + copy + opt-in validation; model execution stubbed)")
    }
}
