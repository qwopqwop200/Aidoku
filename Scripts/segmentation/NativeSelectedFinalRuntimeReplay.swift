import CoreGraphics
import Foundation

/// Isolated real native final graph, sharing the exact iOS producer and assets.
@main struct NativeSelectedFinalRuntimeReplay {
    struct Input: Decodable {
        let rgb: String
        let coarseRF: String
        let fullRF: String
        let width: Int
        let height: Int
        let polygons: [[[Double]]]
        let fontPixels: Double
        let affinity: [Float]
        let rfModelWeightsSHA256: String
        let output: String
    }
    static func floats(_ path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count % 4 == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return data.withUnsafeBytes { bytes in
            (0..<(data.count / 4)).map { Float(bitPattern: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
    }
    static func write<T>(_ values: [T], _ path: String) throws {
        try values.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: path)) }
    }
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let models = try NativeSelectedSourceSegmentationProducer.Models.loadAccepted(
            sourceDirectory: arguments.count >= 1 ? URL(fileURLWithPath: arguments[0]) : nil,
            numericDirectory: arguments.count >= 2 ? URL(fileURLWithPath: arguments[1]) : nil)
        let producer = NativeSelectedSourceSegmentationProducer(models: models, operations: NativeSegmentationOpenCVOperations())
        while let line = readLine() {
            try autoreleasepool {
                let i = try JSONDecoder().decode(Input.self, from: Data(line.utf8))
                let polygons = i.polygons.map { $0.map { CGPoint(x: $0[0], y: $0[1]) } }
                let merged = polygons[0]
                let input = try SourceNativeInput(width: i.width, height: i.height,
                    rgb: Array(Data(contentsOf: URL(fileURLWithPath: i.rgb))), rf: floats(i.fullRF),
                    coarseRF: floats(i.coarseRF), affinityScores: i.affinity, rfModelWeightsSHA256: i.rfModelWeightsSHA256,
                    memberPolygons: polygons, mergedPolygon: merged, bbox: CGRect(x: 0, y: 0, width: i.width, height: i.height),
                    fontPriorSourcePixels: i.fontPixels, crop: CGRect(x: 0, y: 0, width: i.width, height: i.height),
                    pageSize: CGSize(width: i.width, height: i.height), sourceIdentity: "live-replay-source",
                    sourceText: "source", confidence: nil, role: nil)
                let result = try producer.segment(input, capture: { name, matrix, positions in
                        try write(matrix.values, i.output + "." + name + ".f32")
                        try write(positions.map(Int32.init), i.output + "." + name + ".positions.i32")
                        let classifier = name == "context83" ? models.context83 : models.style78
                        let probabilities = try classifier.probabilities(matrix)
                        try write(probabilities, i.output + "." + name + ".probabilities.f64")
                        try write(probabilities.map { try NativeSegmentationFinalPolicy.quantize(probability: $0) },
                            i.output + "." + name + ".codes.u16")
                    })
                try write(result.input.ownMask, i.output + ".mask.u8")
                try write(result.input.primary, i.output + ".p.f32")
                try write(result.input.boundary, i.output + ".q.f32")
                try write(result.input.rawNative, i.output + ".native.u8")
                try write(result.input.completed, i.output + ".completed.u8")
                let data = try JSONSerialization.data(withJSONObject: result.audit, options: [.sortedKeys])
                try data.write(to: URL(fileURLWithPath: i.output + ".audit.json"))
                print(String(decoding: data, as: UTF8.self))
            }
        }
    }
}
