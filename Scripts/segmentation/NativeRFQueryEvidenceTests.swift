import CoreML
import Foundation

@main struct NativeRFQueryEvidenceTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }
    static func main() throws {
        let boxes = try MLMultiArray(shape: [1, 300, 4], dataType: .float32)
        let logits = try MLMultiArray(shape: [1, 300, 5], dataType: .float32)
        let masks = try MLMultiArray(shape: [1, 300, 162, 162], dataType: .float32)
        let b = boxes.dataPointer.assumingMemoryBound(to: Float.self)
        let l = logits.dataPointer.assumingMemoryBound(to: Float.self)
        let m = masks.dataPointer.assumingMemoryBound(to: Float.self)
        l.initialize(repeating: -12, count: logits.count)
        m.initialize(repeating: -2, count: masks.count)
        for q in 0..<300 {
            b[q * 4] = 0.5; b[q * 4 + 1] = 0.5
            b[q * 4 + 2] = 0.2; b[q * 4 + 3] = 0.3
        }
        l[0] = 4; l[6] = 3
        m[123] = 5; m[162 * 162 + 456] = 6; m[299 * 162 * 162 + 789] = 7
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "boxes": MLFeatureValue(multiArray: boxes), "logits": MLFeatureValue(multiArray: logits),
            "instance_masks": MLFeatureValue(multiArray: masks)])
        let source = try NativeRFDETRSourceImage(width: 32, height: 32, rgb: Data(repeating: 0, count: 32 * 32 * 3))
        let baseline = try NativeRFDETRLayoutTensorContract.decode(provider, source: source, maximumMaskQueries: 160)
        let all = try NativeRFDETRLayoutTensorContract.decode(provider, source: source,
            maximumMaskQueries: 160, retainAllQueryMasks: true)
        try require(baseline.primitives.count == 2 && all.primitives.count == 2, "accepted primitive count changed")
        try require(all.classEvidence.count == 300 && all.classEvidence.allSatisfy { $0.mask != nil }, "missing query masks")
        try require(baseline.classEvidence[299].mask == nil, "default query budget changed")
        try require(all.classEvidence[299].mask?.logits[789] == 7, "weak query evidence lost")
        try require(all.omitted == baseline.omitted, "accepted-layout budget semantics changed")
        let previous = ProcessInfo.processInfo.environment[NativeRFDETRSemanticGrid.environmentKey]
        setenv(NativeRFDETRSemanticGrid.environmentKey,"synthetic-test",1)
        let semantic = try NativeRFDETRLayoutTensorContract.decode(provider, source:source, maximumMaskQueries:160)
        if let previous { setenv(NativeRFDETRSemanticGrid.environmentKey,previous,1) }
        else { unsetenv(NativeRFDETRSemanticGrid.environmentKey) }
        try require(semantic.semanticGrid?.isValid == true, "all-query semantic grid missing")
        let expected:Float = (1/(1+exp(-Float(5)))) * (1/(1+exp(-Float(4))))
        try require(abs((semantic.semanticGrid?.probabilities[123] ?? 0)-expected)<1e-6,"semantic class/mask product changed")
        try require(semantic.primitives.count==baseline.primitives.count,"semantic export changed accepted queries")
        for index in baseline.primitives.indices {
            let a = baseline.primitives[index], c = all.primitives[index]
            try require(a.queryID == c.queryID && a.semanticClass == c.semanticClass &&
                a.confidence == c.confidence && a.mask?.logits == c.mask?.logits, "accepted primitive changed")
        }
        let result = NativeRFDETRLayoutResult(imageIdentity: source.identity, sourceWidth: 32, sourceHeight: 32,
            primitives: all.primitives, maskQueriesOmittedByBudget: all.omitted,
            preprocessingMilliseconds: 0, modelMilliseconds: 0, decodeMilliseconds: 0,
            computeUnits: "synthetic-no-model", fromCache: false, classEvidence: all.classEvidence)
        try require(result.evidenceStorageBytes == 300 * 162 * 162 * 4, "all-query memory accounting incomplete")
        m[299 * 162 * 162 + 790] = .nan
        var rejected = false
        do {
            _ = try NativeRFDETRLayoutTensorContract.decode(provider, source: source,
                maximumMaskQueries: 160, retainAllQueryMasks: true)
        } catch NativeRFDETRLayoutError.nonfiniteOutput { rejected = true }
        try require(rejected, "nonfinite weak query accepted")
        print("10 all-query RF evidence checks passed; no detector inference or GT reads")
    }
}
