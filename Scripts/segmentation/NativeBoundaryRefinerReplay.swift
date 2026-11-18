import Foundation

@main struct NativeBoundaryRefinerReplay {
    struct Input: Decodable {
        let rgb: String
        let primary: String
        let nativeMask: String
        let coarseRF: String
        let fullRF: String
        let width: Int
        let height: Int
        let fontPixels: Double
        let output: String
        let constrainExpansion: Bool?
        let probabilityOutput: String?
        let boundaryProbabilities: String?
        let uniformityContrastThreshold: Int?
    }
    static func floats(_ path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count % 4 == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return data.withUnsafeBytes { bytes in
            (0..<(data.count / 4)).map { Float(bitPattern: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
    }
    static func main() throws {
        let uniformityMode = CommandLine.arguments[1] == "--uniformity-features"
        let edgeMode = CommandLine.arguments[1] == "--edge-context-features"
        let featureMode = CommandLine.arguments[1] == "--features" || uniformityMode || edgeMode
        let model: NativePixelRFForest?
        if featureMode { model = nil } else {
            model = try NativePixelRFForest(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        }
        while let line = readLine() {
            try autoreleasepool {
                let input = try JSONDecoder().decode(Input.self, from: Data(line.utf8))
                let rgb = Array(try Data(contentsOf: URL(fileURLWithPath: input.rgb)))
                let primary = try floats(input.primary)
                let base = Array(try Data(contentsOf: URL(fileURLWithPath: input.nativeMask)))
                var audit: [String: Any]
                if uniformityMode {
                    let values = try NativePixelRFBoundarySegmentation.uniformDistances(rgb: rgb, width: input.width,
                        height: input.height, contrastThreshold: input.uniformityContrastThreshold ?? 16).map { Int32($0) }
                    try values.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: input.output), options: .atomic) }
                    audit = ["featureCount": 1, "GTRead": false]
                } else if featureMode {
                    let coarse = try floats(input.coarseRF), full = try floats(input.fullRF)
                    let features: NativePixelRFFeatures.Matrix
                    if edgeMode {
                        features = try NativePixelRFBoundaryFeatures.extractEdgeContext(rgb: rgb, probabilities: primary,
                            nativeMask: base, coarseRF: coarse, fullRF: full, width: input.width, height: input.height,
                            fontPixels: input.fontPixels)
                    } else {
                        features = try NativePixelRFBoundaryFeatures.extract(rgb: rgb, probabilities: primary,
                            nativeMask: base, coarseRF: coarse, fullRF: full, width: input.width, height: input.height,
                            fontPixels: input.fontPixels)
                    }
                    try features.values.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: input.output), options: .atomic) }
                    audit = ["featureCount": features.featureCount, "GTRead": false]
                } else if let observed = input.boundaryProbabilities {
                    let result = try NativePixelRFBoundarySegmentation.complete(rgb: rgb, primary: primary,
                        probabilities: try floats(observed), nativeMask: base, width: input.width, height: input.height,
                        fontPixels: input.fontPixels, model: model!, constrainExpansion: input.constrainExpansion ?? true)
                    try Data(result.mask).write(to: URL(fileURLWithPath: input.output), options: .atomic)
                    audit = result.audit
                    audit["boundaryObservationReused"] = true
                } else {
                    let coarse = try floats(input.coarseRF), full = try floats(input.fullRF)
                    let result = try NativePixelRFBoundarySegmentation.refine(rgb: rgb, primary: primary,
                        nativeMask: base, coarseRF: coarse, fullRF: full, width: input.width, height: input.height,
                        fontPixels: input.fontPixels, model: model!, constrainExpansion: input.constrainExpansion ?? true,
                        captureBoundary: { probabilities in
                            if let path = input.probabilityOutput {
                                try probabilities.withUnsafeBytes {
                                    try Data($0).write(to: URL(fileURLWithPath: path), options: .atomic)
                                }
                            }
                        })
                    try Data(result.mask).write(to: URL(fileURLWithPath: input.output), options: .atomic)
                    audit = result.audit
                    audit["boundaryObservationReused"] = false
                }
                var data = try JSONSerialization.data(withJSONObject: audit, options: .sortedKeys)
                data.append(10);try FileHandle.standardOutput.write(contentsOf: data)
            }
        }
    }
}
