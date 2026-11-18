import Foundation

/// Max over ALL 300 queries of sigmoid(maskLogit) * class probability.
/// Native order: text0, SFX1, balloon2, frame3. This is neither RGB nor GT.
struct NativeRFDETRSemanticGrid: Sendable {
    static let environmentKey = "AIDOKU_OCR_RF_SEMANTIC_POLICY"
    static let boundaryFieldsEnvironmentKey = "AIDOKU_OCR_RF_BOUNDARY_FIELDS"
    static var boundaryFieldsEnabled: Bool { ProcessInfo.processInfo.environment[boundaryFieldsEnvironmentKey] == "1" }
    static let schema = "rf-all300-native-class-max-mask-v1"
    static var enabled: Bool { boundaryFieldsEnabled || !(ProcessInfo.processInfo.environment[environmentKey] ?? "").isEmpty }
    let width: Int
    let height: Int
    let side: Int
    let probabilities: [Float]
    var modelWeightsSHA256: String? = nil
    var imageIdentity: String? = nil
    /// Optional four class planes in the SAME native text/SFX/balloon/frame order.
    /// Sum over ALL 300 sigmoid-mask * class probabilities, divided by the
    /// corresponding sum of class probabilities. Never a max-field alias.
    var weightedMeanProbabilities: [Float]? = nil

    var hasValidWeightedMeanProbabilities: Bool {
        guard let means = weightedMeanProbabilities else { return false }
        return means.count == 4 * side * side && means.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    var isValid: Bool {
        width > 0 && height > 0 && side == 162 && probabilities.count == 4 * side * side
            && probabilities.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    enum Failure: Error { case invalidEvidence }

    static func aggregate(width: Int, height: Int, classProbabilities: [Float],
                          maskLogit: (Int, Int, Int) throws -> Float) throws -> Self {
        guard classProbabilities.count == 300 * 5,
              classProbabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw Failure.invalidEvidence
        }
        let side = 162, cells = side * side
        var values = [Float](repeating: 0, count: 4 * cells)
        let retainMeans = boundaryFieldsEnabled
        var sums = retainMeans ? [Float](repeating: 0, count: 4 * cells) : []
        var denominators = [Float](repeating: 0, count: 4)
        if retainMeans {
            for query in 0..<300 {
                for semantic in 0..<4 { denominators[semantic] += classProbabilities[query * 5 + semantic] }
            }
        }
        for query in 0..<300 {
            try Task.checkCancellation()
            for y in 0..<side {
                for x in 0..<side {
                    let raw = try maskLogit(query, y, x)
                    guard raw.isFinite else { throw Failure.invalidEvidence }
                    let value = min(80, max(-80, raw))
                    let mask: Float = 1 / (1 + exp(-value))
                    let index = y * side + x
                    for semantic in 0..<4 {
                        let weighted = mask * classProbabilities[query * 5 + semantic]
                        values[semantic * cells + index] = max(values[semantic * cells + index], weighted)
                        if retainMeans { sums[semantic * cells + index] += weighted }
                    }
                }
            }
        }
        if retainMeans {
            for semantic in 0..<4 {
                let denominator = max(Float(1e-9), denominators[semantic])
                for index in 0..<cells { sums[semantic * cells + index] /= denominator }
            }
        }
        return .init(width: width, height: height, side: side, probabilities: values,
                     weightedMeanProbabilities: retainMeans ? sums : nil)
    }
}
