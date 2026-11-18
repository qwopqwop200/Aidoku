#!/usr/bin/env python3
"""Actual shared commit/admission+CTC+stream sink; simulated outputs, no models."""
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OCR = ROOT / "Aidoku/Core/Translation/NativeEngine/OCR"
source = (OCR / "NativeCoreMLRecognizer.swift").read_text()


def section(start, end):
    return source[source.index(start):source.index(end)]


types = section("enum NativeCoreMLRecognitionPhotometricMode:", "/// Explicit in-memory diagnostic events")
cached = section("private struct NativeCoreMLCachedRecognition:", "/// Native PP-OCRv6 text recognition backed")
step = section("private struct NativeCoreMLRecognitionStreamingChunkStep:", "private struct NativeCoreMLPlannedRegionWork:")
commit = section("    private func commitChunk(", "    private func requireCurrent(")
errors = section("enum NativeCoreMLRecognizerError:", "    var errorDescription:").replace(", LocalizedError", "") + "}\n"
decoder = source[source.index("struct NativeCoreMLDecodedText:"):source.index("/// Read-only replay identity;")]
# Check lifecycle wiring in the actual async entrypoint, without loading models.
perform = section("    private func performRecognition(", "    private static func preparationWindowEnd(")
assert perform.index("observationPass?.began") < perform.index("resourceStore.load")
assert perform.index("observationPass?.finished") < perform.index("store(diagnostics)") < perform.index("return NativeCoreMLRecognitionResult")
assert "observationPass?.finished" not in perform[perform.index("} onCancel:"):]
carriers = r'''
import CoreGraphics
import CoreML
import Foundation
import Dispatch
struct NativeOCRDetectorColumnEvidence: Equatable, Sendable {}
struct NativeCoreMLRecognitionCropFingerprint: Hashable, Sendable { let id: Int }
struct Work: Sendable { let region: NativeCoreMLRecognitionRegion }
struct NativeCoreMLPreparedRegionWork: Sendable { let work: Work; let fingerprint: NativeCoreMLRecognitionCropFingerprint }
struct NativeCoreMLChunkCacheLookup: Sendable {
    let works: [NativeCoreMLPreparedRegionWork]
    let cachedValues: [NativeCoreMLCachedRecognition?]
    let cacheHitRegions: Int
}
struct Variant: Sendable { let functionName: String }
struct Prediction: @unchecked Sendable { let outputs: [MLMultiArray]; let modelWasLoaded: Bool; let modelLoadMilliseconds: Double }
struct Group: Sendable {
    let prediction: Prediction; let works: [NativeCoreMLPreparedRegionWork]; let variant: Variant
    let packingMilliseconds: Double; let predictionTotalMilliseconds: Double
}
struct NativeCoreMLChunkPredictionOutcome: Sendable { let groups: [Group]; let error: (any Error)? }
enum Audit { case decoded(requestID: String, region: NativeCoreMLRecognitionRegion, text: String,
                         confidence: Double, threshold: Double, cacheHit: Bool) }
enum NativeOCRMultilineColumnRecovery {
    static func eligible(_ read: NativeCoreMLRecognizedRegion) -> Bool { !read.text.isEmpty }
}
enum FixtureError: Error { case overflow, cancelled }
final class Recorder: @unchecked Sendable {
    let lock = NSLock()
    var events: [NativeCoreMLRecognitionObservations.Event] = []
    func append(_ event: NativeCoreMLRecognitionObservations.Event) { lock.withLock { events.append(event) } }
}
func check(_ value: Bool, _ reason: String) { precondition(value, reason) }
'''
harness = r'''
final class Harness {
    let recognitionCropCache = NativeCoreMLRecognitionCropCache(capacity: 8)
    static let outputShape = [2, 4]
    let observeEmissionSpans = false
    let languageModelLoader: () throws -> NativeMangaNGram? = { nil }
    static func nowMilliseconds() -> Double { Date.timeIntervalSinceReferenceDate * 1000 }
    func requireCurrent(_ generation: UInt64, cancellationCheck: @escaping @Sendable () throws -> Void) throws { try cancellationCheck() }
    func emitAudit(_ audit: Audit) {}
'''
checks = r'''
let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 8, y: 4), CGPoint(x: 0, y: 4)]
let works = (0..<4).map { index in NativeCoreMLPreparedRegionWork(work: Work(region: .init(sourceIndex: index + 20,
    polygon: polygon, samplingPolygon: polygon.map { CGPoint(x: $0.x, y: $0.y + 2) }, minimumSequenceWidth: 96)),
    fingerprint: .init(id: index)) }
let output = try MLMultiArray(shape: [2, 4], dataType: .float32)
output.dataPointer.assumingMemoryBound(to: Float.self).initialize(repeating: 0, count: output.count)
output[[0, 0]] = 1; output[[1, 0]] = 0.29
let lookup = NativeCoreMLChunkCacheLookup(works: works, cachedValues: [
    .init(text: "", confidence: 0), .init(text: "low", confidence: 0.2),
    .init(text: "exact", confidence: 0.3), nil], cacheHitRegions: 3)
let outcome = NativeCoreMLChunkPredictionOutcome(groups: [Group(prediction: .init(outputs: [output],
    modelWasLoaded: false, modelLoadMilliseconds: 0), works: [works[3]], variant: .init(functionName: "fixture"),
    packingMilliseconds: 0, predictionTotalMilliseconds: 0)], error: nil)
let recorder = Recorder()
let sink = NativeCoreMLRecognitionObservations(observer: { recorder.append($0) })
let request = NativeCoreMLRecognitionObservations.Request(requestID: "actual-pass", generation: 7,
    callerConfidenceThreshold: 0.3, appliedConfidenceThreshold: 0.3)
let pass = NativeCoreMLRecognitionObservationPass(sink: sink, request: request)
for work in works { try sink.record(.requested(request: request, region: work.work.region)) }
let observedHarness = Harness()
let observed = try observedHarness.commitChunk(lookup, outcome: outcome, requestID: request.requestID,
    threshold: 0.3, dictionary: ["fresh"], recognitionCacheEpoch: 0, observationPass: pass, generation: 7,
    cancellationCheck: {})
let baseline = try Harness().commitChunk(lookup, outcome: outcome, requestID: request.requestID,
    threshold: 0.3, dictionary: ["fresh"], recognitionCacheEpoch: 0, observationPass: nil, generation: 7,
    cancellationCheck: {})
check(observed.recognizedRegions == baseline.recognizedRegions && observed.recognizedRegions.map(\.text) == ["exact"],
    "observer changed production acceptance")
check(observed.leadingDashCandidates == baseline.leadingDashCandidates && observed.predictedRegions == 1 && observed.cacheHitRegions == 3,
    "committed/recovery counters changed")
let decoded = recorder.events.compactMap { event -> NativeCoreMLRecognitionObservations.Decoded? in
    if case .decoded(let value) = event { return value }; return nil
}
check(recorder.events.count == 8 && decoded.count == 4, "all actual empty/low/cached/fresh rows retained")
check(decoded.map(\.reason) == [.empty, .belowThreshold, .accepted, .belowThreshold], "admission reasons")
check(decoded.map(\.admitted) == [false, false, true, false] && decoded.map(\.cacheHit) == [true, true, true, false], "cache/admission flags")
check(decoded.map { $0.region.sourceIndex } == [20, 21, 22, 23] && decoded.allSatisfy { $0.region.samplingPolygon != nil
    && $0.region.minimumSequenceWidth == 96 && $0.request == request }, "request geometry identity")
check(decoded[0].tokenObservations.isEmpty && decoded[0].finalText.isEmpty, "empty is an actual decode")
check(decoded[0].greedyObservation == nil && decoded[3].greedyObservation?.text == "fresh", "unobserved cache provenance not fabricated")
check(decoded[3].tokenObservations.count == 1 && decoded[3].finalConfidence == Double(Float(0.29)), "fresh token/confidence exact")
check(decoded[3].greedyObservation?.tokenObservations?.count == 1, "available raw CTC tokens retained")
let cached = observedHarness.recognitionCropCache.values(for: [works[3].fingerprint])[0]!
check(cached.greedyObservation == decoded[3].greedyObservation, "observed raw decode survives existing cache")
let failing = NativeCoreMLRecognitionObservations(observer: { _ in throw FixtureError.overflow })
do {
    _ = try Harness().commitChunk(lookup, outcome: outcome, requestID: request.requestID, threshold: 0.3,
        dictionary: ["fresh"], recognitionCacheEpoch: 0, observationPass: .init(sink: failing, request: request), generation: 7,
        cancellationCheck: {})
    preconditionFailure("sink overflow silently succeeded")
} catch FixtureError.overflow { }
let cancelledRecorder = Recorder()
let cancelled = NativeCoreMLRecognitionObservations(observer: { cancelledRecorder.append($0) })
let cancelledPass = NativeCoreMLRecognitionObservationPass(sink: cancelled, request: request)
try cancelledPass.began(requestedRegions: 1)
do {
    _ = try Harness().commitChunk(.init(works: [works[3]], cachedValues: [nil], cacheHitRegions: 0), outcome: outcome,
        requestID: request.requestID, threshold: 0.3, dictionary: ["fresh"], recognitionCacheEpoch: 0,
        observationPass: cancelledPass, generation: 7,
        cancellationCheck: { throw FixtureError.cancelled })
    preconditionFailure("cancelled pass succeeded")
} catch FixtureError.cancelled { }
check(cancelledRecorder.events.count == 1, "cancellation fabricated a decoded/finished row")
if case .began(_, let count) = cancelledRecorder.events[0] { check(count == 1, "actual planned count") }
else { preconditionFailure("missing actual began event") }
let emptyRecorder = Recorder()
let emptyPass = NativeCoreMLRecognitionObservationPass(sink: .init(observer: { emptyRecorder.append($0) }), request: request)
try emptyPass.began(requestedRegions: 0)
try emptyPass.finished(decodedRegions: 0)
check(emptyRecorder.events == [.began(request: request, requestedRegions: 0), .finished(request: request, decodedRegions: 0)],
    "observed empty must have actual zero lifecycle, unlike a missing stream")
let unavailable = Recorder()
let noPass: NativeCoreMLRecognitionObservationPass? = nil
try noPass?.began(requestedRegions: 0); try noPass?.finished(decodedRegions: 0)
check(unavailable.events.isEmpty, "default nil cannot invent empty lifecycle")
let finishErrorPass = NativeCoreMLRecognitionObservationPass(sink: .init(observer: { event in
    if case .finished = event { throw FixtureError.overflow }
}), request: request)
try finishErrorPass.began(requestedRegions: 0)
do { try finishErrorPass.finished(decodedRegions: 0); preconditionFailure("failed finish silently succeeded") }
catch FixtureError.overflow { }
let parallel = Recorder()
let serialized = NativeCoreMLRecognitionObservations(observer: { parallel.append($0) })
DispatchQueue.concurrentPerform(iterations: 1000) { _ in try! serialized.record(.requested(request: request, region: works[0].work.region)) }
check(parallel.events.count == 1000, "concurrent streaming lost rows")
check(NativeCoreMLRecognitionObservations.current == nil, "observer must default nil")
NativeCoreMLRecognitionObservations.$current.withValue(sink) {
    check(NativeCoreMLRecognitionObservations.current === sink, "page-scoped binding")
}
check(NativeCoreMLRecognitionObservations.current == nil, "page sink leaked after scope")
print("PASS actual commit/admission+CTC:empty/below/exact/cache/fresh/raw tokens;throw/cancel;1000stream callbacks")
'''
with tempfile.TemporaryDirectory(prefix="aidoku-rec-observation-") as folder:
    folder = Path(folder)
    main = folder / "main.swift"
    # Access-level relaxation is only for the private extracted test harness.
    program = carriers + types + cached + step + errors + decoder + harness + commit + "}\n" + checks
    program = program.replace("private struct", "struct").replace("private final class", "final class").replace("private func commitChunk", "func commitChunk")
    main.write_text(program)
    started = time.monotonic()
    subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(folder / "modules"),
                    str(OCR / "NativeMangaNGram.swift"), str(main), "-o", str(folder / "check")], check=True)
    built = time.monotonic()
    subprocess.run([str(folder / "check")], check=True)
    print(f"build={built-started:.3f}s tests={time.monotonic()-built:.3f}s;no models/sharedbuild/API")
