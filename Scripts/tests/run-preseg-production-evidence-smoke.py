#!/usr/bin/env python3
"""Compile the actual preseg signal policies in an isolated temporary directory."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / 'Aidoku/Core/Translation'
OCR = CORE / 'NativeEngine/OCR'

checks = r'''
import Foundation
typealias F = NativeOCRPremergeCandidateFeatures
typealias R = NativePostLLMContentReclassifier
let quad: [F.Point] = [.init(x: 0, y: 0), .init(x: 20, y: 0),
    .init(x: 20, y: 80), .init(x: 0, y: 80)]
let original = F.DetectorBox(polygon: quad, score: 0.91)
let detector = R.detectorSignals(polygon: quad, baseline: nil,
    originalDetectors: [original], recognitionConfidence: 0.31)!
precondition(detector == [1, 0.91, 1, 1, 1])
// REC cannot become detector confidence, and text is not a predictor.
precondition(R.detectorSignals(polygon: quad, baseline: nil,
    originalDetectors: [original], recognitionConfidence: 0.99) == detector)
precondition(R.detectorSignals(polygon: quad, baseline: nil,
    originalDetectors: [], recognitionConfidence: 0.99) == [0, 0, 0, 0, 0])
precondition(R.detectorSignals(polygon: [], baseline: nil,
    originalDetectors: [original], recognitionConfidence: 0.99) == nil)
precondition(R.detectorSignals(polygon: quad, baseline: nil,
    originalDetectors: [.init(polygon: quad, score: .nan)], recognitionConfidence: 0.99) == nil)
let moved = quad.map { F.Point(x: $0.x + 10, y: $0.y) }
let shifted = R.detectorSignals(polygon: moved, baseline: quad,
    originalDetectors: [original], recognitionConfidence: 0.31)!
precondition(shifted[2] == 1 && abs(shifted[3] - 1.0 / 3) < 1e-10 && shifted[4] == 0.5)
let aggregate = R.detectorFeatures(bodySignals: [detector, shifted])!
precondition(aggregate.count == 15 && aggregate[1] == 0.91 && aggregate[11] == 0.91)
precondition(R.detectorFeatures(bodySignals: [detector, nil]) == nil)
// Long mask runs, a boundary-touching owner, and first-witness score ties.
let side = 162
let mask = F.RFMask(sourceWidth: side, sourceHeight: side, side: side,
    logits: (0..<(side * side)).map { $0 % side < 10 && $0 / side < 80 ? 1 : -1 })!
let otherMask = F.RFMask(sourceWidth: side, sourceHeight: side, side: side,
    logits: (0..<(side * side)).map { $0 % side < 20 && $0 / side < 80 ? 1 : -1 })!
let queries: [NativeOCRPremergeSpatialEvidence.Query] = (0..<300).map { q in
    .init(x: 0, y: 0, width: 20, height: 80, probabilities: q == 0 ? [1, 0.5, 0, 0, 0] : [0.5, 0.25, 0, 0, 0], queryID: q)
}
let primitives: [F.RFPrimitive] = [mask, otherMask].enumerated().map { i, m in
    .init(x: 0, y: 0, width: 20, height: 80, confidence: 1, semanticClass: i, mask: m, queryID: i)
}
let spatial = NativeOCRPremergeSpatialEvidence(width: side, height: side, primitives: primitives, queries: queries)!
let features = spatial.extract(polygon: quad)!
precondition(features[3] == 0 && features[4] == 0.5 && features[5] == 0.5 && features[6] == 1)
precondition(F.rfMaskOverlap(quad, mask: mask) == 0.5 && F.rfMaskOverlap(moved, mask: mask) == 0)
let joint = NativeOCRPremergeQueryRelations(primitives: primitives, queries: queries)!
precondition(joint.extract(polygon: quad)! == [0.5, 0.25, 1.0 / 3, 0.5, 0.25, 0.5, 2.0 / 3, 0.5])
precondition(joint.extract(polygon: []) == nil)
let emptyJoint = NativeOCRPremergeQueryRelations(primitives: [], queries: queries)!
precondition(emptyJoint.extract(polygon: []) == Array(repeating: 0, count: 8))
let semantic = [Double](repeating: 0.1, count: 92)
let evidence = R.Evidence(features: semantic, detectorFeatures: aggregate)!
let codec = JSONDecoder()
let roundtrip = try codec.decode(R.Evidence.self, from: JSONEncoder().encode(evidence))
precondition(roundtrip == evidence && roundtrip.isValid)
// Missing evidence never deletes an owner or changes a provider role.
let raw = RemoteTranslatedSegment(id: "opaque", text: "translated", isSFX: true, textRole: .sfx)
precondition(R.resolved(raw, evidence: nil) == raw)
precondition(NativePostMergeSignalFilter.decide(nil).keep)
precondition(NativePostMergeSignalFilter.defaultPolicy?.isValid == true)
print("PASS preseg production evidence: original DET binding, REC independence, absent/invalid inputs, changed geometry, member aggregation, evidence codec and abstention")
'''

sources = [OCR / (name + '.swift') for name in (
    'NativeOCRPremergeCandidateFeatures', 'NativeOCRPremergeSpatialEvidence',
    'NativeOCRPremergeQueryRelations')]
sources += [CORE / (name + '.swift') for name in (
    'NativeFinalOutputContentFilter', 'NativePostLLMContentReclassifier', 'NativePostMergeSignalFilter')]
models = (CORE / 'NativeEngine/Translation/TranslationModels.swift').read_text()
roles = models[models.index('enum RemoteTranslationTextRole:'):models.index('/// Request-local derived value;')]

# These contracts ensure the tested fallback actually reaches app metadata and
# the independent postmerge policy participates in the derived OCR cache key.
pipeline = (OCR / 'NativeCoreMLOCRPipeline.swift').read_text()
fallback = pipeline.index('originalDetectors: detectors, recognitionConfidence: region.confidence')
policy = pipeline.index('if postprocessConfiguration == .manga, let model = premergeCandidateModel')
assert fallback < policy
assert 'detectorSignals: admittedDetectorSignals[region.sourceIndex]' in pipeline
cache = (CORE / 'ReaderTranslationDiskCache.swift').read_text()
ocr_key = cache[cache.index('static func ocr(page:'):cache.index('static func translation(page:')]
assert 'NativePostMergeSignalFilter.policyVersion' in ocr_key
assert 'NativeOCRRawCanonicalPolicy.version' in ocr_key

with tempfile.TemporaryDirectory(prefix='aidoku-preseg-production-') as directory:
    folder = Path(directory)
    main = folder / 'main.swift'
    main.write_text('import Foundation\n' + roles + checks)
    binary = folder / 'smoke'
    subprocess.run(['xcrun', 'swiftc', '-O', *map(str, sources), str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
