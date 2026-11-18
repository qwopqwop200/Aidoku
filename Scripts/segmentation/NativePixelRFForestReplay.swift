import Foundation

/// Portable source-feature inference. No label files or page identities.
/// This replay verifies tree parity before the adapter can enter production.
@main struct NativePixelRFForestReplay {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
        let model = try NativePixelRFForest(data: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        guard data.count % (4 * model.featureCount) == 0 else { throw CocoaError(.fileReadCorruptFile) }
        let values: [Float] = data.withUnsafeBytes { bytes in
            (0..<(data.count / 4)).map { Float(bitPattern: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
        guard values.allSatisfy(\.isFinite) else { throw CocoaError(.fileReadCorruptFile) }
        let count = values.count / model.featureCount
        let result = try model.probabilities(.init(values: values, featureCount: model.featureCount, pixelCount: count))
        try result.withUnsafeBytes {
            try Data($0).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
        }
    }
}
