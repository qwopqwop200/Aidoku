import CryptoKit
import Foundation

@main
enum NativeDBFloatDigestSmoke {
    static func reference(_ values: [Float]) -> String {
        var hash = SHA256()
        for start in stride(from: 0, to: values.count, by: 4096) {
            let words = values[start..<min(start + 4096, values.count)].map { $0.bitPattern.littleEndian }
            words.withUnsafeBytes { hash.update(data: Data($0)) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func main() throws {
        let special: [UInt32] = [0, 0x80000000, 1, 0x80000001, 0x007fffff, 0x00800000,
            0x3e800000, 0x3f800000, 0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000,
            0x7fc00000, 0x7f800001, 0x7fc00001, 0xffc01234]
        var cases = [[Float](), [Float(0)], [Float(bitPattern: 0x80000000)], special.map(Float.init(bitPattern:))]
        for count in [3, 31, 1023, 4095, 4096, 4097, 16383, 16384, 16385, 100003] {
            cases.append((0..<count).map { Float(bitPattern: UInt32(truncatingIfNeeded: $0 &* 2654435761)) })
        }
        for values in cases {
            let before = values.map(\.bitPattern)
            precondition(NativeMainEnsembleDBCapability.digest(values) == reference(values))
            precondition(values.map(\.bitPattern) == before)
        }
        precondition(NativeMainEnsembleDBCapability.digest([0]) != NativeMainEnsembleDBCapability.digest([Float(bitPattern: 0x80000000)]))
        precondition(NativeMainEnsembleDBCapability.digest([0, 0.25, 0.5, 1]) ==
            "853c546e8e6312a0ab23b67267d5ba1a34b3120a2f472181f6e6d00786aa3a69")
        let result: [String: Any] = ["passed": true, "cases": cases.count,
            "canonicalFloatBitsPreserved": true, "signedZeroAndNaNPayloads": true,
            "boundarySizes": [4095, 4096, 4097, 16383, 16384, 16385],
            "modelCalls": 0, "GTRead": false, "pipelineSpeedMeasured": false]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
