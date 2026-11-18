import CryptoKit
import Foundation

/// Model-free regression of the ACTUAL immutable production policy. The runner
/// separately derives and hash-pins its pre-optimization dense reference.
@main
enum NativeSegmentationJointDomainSmoke {
    static func main() throws {
        let enabled = CommandLine.arguments.dropFirst().first == "1"
        let policy = NativeSegmentationFinalPolicy.accepted
        let frozen = NativeSegmentationFinalPolicy.frozenBaseline
        precondition(policy.requiredVotes == frozen.requiredVotes)
        precondition(policy.auxiliaryPixelGate.maximumSourceStrengthCode == frozen.auxiliaryPixelGate.maximumSourceStrengthCode)
        precondition(policy.auxiliaryPixelGate.thresholdCode == frozen.auxiliaryPixelGate.thresholdCode)
        precondition(policy.ensembleMembers.count == frozen.ensembleMembers.count)
        for (actual, original) in zip(policy.ensembleMembers, frozen.ensembleMembers) {
            precondition(actual.coreRadiusPixels == (enabled ? 0 : original.coreRadiusPixels))
            let left = Mirror(reflecting: actual).children.filter { $0.label != "coreRadiusPixels" }
            let right = Mirror(reflecting: original).children.filter { $0.label != "coreRadiusPixels" }
            precondition(left.map { String(reflecting: $0.value) } == right.map { String(reflecting: $0.value) })
        }
        precondition(NativeSegmentationFinalPolicy.requiredJointRadius == policy.ensembleMembers.map(\.outerRadiusPixels).max())
        precondition(NativeSegmentationFinalPolicy.policySHA256 == (enabled
            ? "1a0d65f54aacbc01caaa8ca5b96412ac6797646371a304a574f3e40e48bb1905"
            : "dbe62f855cc112ba607c0c1a62d136c3d20779181c0b5a8a025e1fb584db6be1"))
        var cases = 0, exactMasks = 0, rejected = 0, outsideIgnored = 0, weakExact = 0
        var digest = SHA256()
        for (width, height) in [(65, 65), (1, 1), (17, 23)] {
            let n = width * height, cx = width / 2, cy = height / 2
            for seedMode in 0..<3 { for styleCase in 0..<4 {
                var base = [UInt8](repeating: seedMode == 2 ? 255 : 0, count: n)
                if seedMode == 0 { base[cy * width + cx] = 255 }
                let distance = (0..<n).map { i -> Int in
                    if seedMode == 2 { return 0 }
                    if seedMode == 1 { return 8192 }
                    return max(abs(i % width - cx), abs(i / width - cy))
                }
                let radius = NativeSegmentationFinalPolicy.requiredJointRadius
                let required = (0..<n).map { base[$0] != 0 || distance[$0] <= radius }
                let fullCodes = (0..<n).map { UInt16(($0 * 3571 + styleCase * 1013 + 2813) % 8192) }
                let sparse = (0..<n).map { required[$0] ? fullCodes[$0] : UInt16(65535) }
                let primary = (0..<n).map { styleCase == 0 ? Float(1) : Float($0 % 200) / 1000 }
                let boundary = (0..<n).map { Float(($0 * 19) % 180) / 1000 }
                let auxiliary = (0..<n).map { UInt16(($0 * 223 + 3070) % 8192) }
                let highAuxiliary = [UInt16](repeating: 8191, count: n)
                let style = (0..<18).map { Double(($0 + styleCase) % 5) / 7 }
                func dense(_ aux: [UInt16]) throws -> DenseSegmentationPolicy.Result {
                    try DenseSegmentationPolicy.apply(.init(width: width, height: height, base: base, primary: primary,
                        boundary: boundary, jointCodes: fullCodes, style: style, auxiliaryCodes: aux))
                }
                func actual(_ codes: [UInt16], _ aux: [UInt16]) throws -> NativeSegmentationFinalPolicy.Result {
                    try NativeSegmentationFinalPolicy.apply(.init(width: width, height: height, base: base, primary: primary,
                        boundary: boundary, jointCodes: codes, style: style, auxiliaryCodes: aux))
                }
                let reference = try dense(auxiliary), output = try actual(sparse, auxiliary)
                precondition(reference.mask == output.mask && reference.auxiliaryRemoved == output.auxiliaryRemoved)
                let referenceUnpruned = try dense(highAuxiliary), unpruned = try actual(sparse, highAuxiliary)
                precondition(referenceUnpruned.mask == unpruned.mask)
                let weak = (0..<n).filter { unpruned.mask[$0] != 0 &&
                    min(64, Int(ceil(max(primary[$0], boundary[$0]) * 64 - 1e-6))) <= policy.auxiliaryPixelGate.maximumSourceStrengthCode }
                let referenceWeak = (0..<n).filter { referenceUnpruned.mask[$0] != 0 &&
                    min(64, Int(ceil(max(primary[$0], boundary[$0]) * 64 - 1e-6))) <= policy.auxiliaryPixelGate.maximumSourceStrengthCode }
                precondition(weak == referenceWeak)
                weakExact += 1; exactMasks += 2
                digest.update(data: Data(output.mask)); digest.update(data: Data(unpruned.mask))
                if let pixel = required.lastIndex(of: true) {
                    for bad in [UInt16(8192), 65535] {
                        var corrupted = sparse; corrupted[pixel] = bad
                        do { _ = try actual(corrupted, highAuxiliary); preconditionFailure("Required uncomputed joint code accepted") }
                        catch { rejected += 1 }
                    }
                }
                if let pixel = required.lastIndex(of: false) {
                    for irrelevant in [UInt16(0), 8191, 8192, 65534, 65535] {
                        var codes = sparse; codes[pixel] = irrelevant
                        let result = try actual(codes, auxiliary)
                        precondition(result.mask == reference.mask && result.auxiliaryRemoved == reference.auxiliaryRemoved)
                        outsideIgnored += 1
                    }
                }
                if let pixel = weak.first {
                    var missingAuxiliary = highAuxiliary; missingAuxiliary[pixel] = 65535
                    do { _ = try actual(sparse, missingAuxiliary); preconditionFailure("Required uncomputed auxiliary code accepted") }
                    catch { rejected += 1 }
                }
                cases += 1
            } }
        }
        let result: [String: Any] = ["passed": true, "cases": cases, "maskAndUnprunedExact": exactMasks,
            "weakPositionsExact": weakExact, "requiredInvalidCodesRejected": rejected,
            "outsideDomainCodesIgnoredBeforeNumericUse": outsideIgnored,
            "coreZeroEnabled": enabled, "policySHA256": NativeSegmentationFinalPolicy.policySHA256,
            "resultDigest": digest.finalize().map { String(format: "%02x", $0) }.joined(),
            "learnedTablesAndOtherPolicyFieldsUnchanged": true, "modelRuns": 0, "corpusFilesRead": 0]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
