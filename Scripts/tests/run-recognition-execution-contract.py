#!/usr/bin/env python3
"""Production counters/LRU/audit sink; simulated scheduler eviction, no models."""
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OCR = ROOT / "Aidoku/Core/Translation/NativeEngine/OCR"
source = (OCR / "NativeCoreMLRecognizer.swift").read_text()
counters = source[source.index("struct NativeCoreMLRecognitionExecutionSnapshot:"):source.index("struct NativeCoreMLRecognitionDiagnostics:")]
cache = source[source.index("private final class NativeCoreMLRecognitionCropCache:"):source.index("/// Native PP-OCRv6 text recognition backed")]
carriers = r'''
import Foundation
import CoreGraphics
import Dispatch
struct NativeCoreMLRecognitionCropFingerprint: Hashable, Sendable { let id: Int }
struct NativeCoreMLCachedRecognition: Equatable, Sendable { let text: String; let confidence: Double }
struct NativeCoreMLRecognitionRegion: Sendable {
    let sourceIndex: Int
    let polygon: [CGPoint]
    var samplingPolygon: [CGPoint]? = nil
    var minimumSequenceWidth = 0
}
enum NativeCoreMLRecognitionAuditEvent: Sendable {
    case requested(requestID: String, region: NativeCoreMLRecognitionRegion)
    case decoded(requestID: String, region: NativeCoreMLRecognitionRegion,
                 text: String, confidence: Double, threshold: Double, cacheHit: Bool)
}
final class Sink: @unchecked Sendable {
    let lock = NSLock()
    var snapshots: [NativeCoreMLRecognitionExecutionSnapshot] = []
    var lines: [Data] = []
    func append(_ snapshot: NativeCoreMLRecognitionExecutionSnapshot) { lock.withLock { snapshots.append(snapshot) } }
    func append(_ data: Data) { lock.withLock { lines.append(data) } }
}
func check(_ value: Bool, _ message: String) { precondition(value, message) }
'''
checks = r'''
// Compare membership, decoded confidence and exact recency against a simple
// oldest-first list across updates, duplicate reads, cold churn and purges.
for capacity in [0, 1, 3, 16, 512] {
    let actual = NativeCoreMLRecognitionCropCache(capacity: capacity)
    var order: [Int] = []
    var expected: [Int: NativeCoreMLCachedRecognition] = [:]
    var state: UInt64 = 19
    func nextID() -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(state >> 32) % max(7, capacity + capacity / 2)
    }
    for step in 0..<5000 {
        let id = nextID()
        let key = NativeCoreMLRecognitionCropFingerprint(id: id)
        let value = NativeCoreMLCachedRecognition(text: "crop-\(step)", confidence: Double(step) / 5000)
        if step.isMultiple(of: 1733) {
            let stale = actual.currentEpoch()
            actual.removeAll()
            actual.insert(value, for: key, ifCurrent: stale)
            expected.removeAll()
            order.removeAll()
        } else if step % 4 < 3 {
            actual.insert(value, for: key, ifCurrent: actual.currentEpoch())
            expected[id] = value
            order.removeAll { $0 == id }
            order.append(id)
            if order.count > capacity { expected.removeValue(forKey: order.removeFirst()) }
        } else {
            let ids = [id, nextID(), id]
            let hits = actual.values(for: ids.map { .init(id: $0) })
            check(hits == ids.map { expected[$0] }, "LRU reads match reference")
            for hit in ids where expected[hit] != nil {
                order.removeAll { $0 == hit }
                order.append(hit)
            }
        }
        let peek = [id, nextID(), nextID()]
        check(actual.peekValues(for: peek.map { .init(id: $0) }) == peek.map { expected[$0] },
              "non-touching speculative lookup matches reference")
    }
}
// Exercise the real LRU: a prior chunk's cold insert invalidates the next
// chunk's speculative cache hit, without any duplicate between cold misses.
private let cache = NativeCoreMLRecognitionCropCache(capacity: 1)
let a = NativeCoreMLRecognitionCropFingerprint(id: 1)
let b = NativeCoreMLRecognitionCropFingerprint(id: 2)
let c = NativeCoreMLRecognitionCropFingerprint(id: 3)
let epoch = cache.currentEpoch()
let read = NativeCoreMLCachedRecognition(text: "fixture", confidence: 0.8)
cache.insert(read, for: a, ifCurrent: epoch)
check(cache.values(for: [b]) == [nil], "predecessor must be cold")
let peek = cache.peekValues(for: [a, c])
check(peek == [read, nil], "lookahead sees one cached row")
let sink = Sink()
let execution = NativeCoreMLRecognitionExecutionCounters(requestID: "eviction", generation: 1,
    observer: { sink.append($0) })
execution.attempted(crops: 1, batchSlots: 1) // B, predecessor
execution.attempted(crops: 1, batchSlots: 1) // C, speculative lookahead
cache.insert(read, for: b, ifCurrent: epoch)
let real = cache.values(for: [a, c])
check(real == [nil, nil] && real != peek, "actual cache eviction invalidates peek")
execution.discardedLookahead(plannedCrops: 1, completedPredictions: 1, completedCrops: 1)
execution.attempted(crops: 2, batchSlots: 2) // Unchanged scheduler retries real A+C batch.
execution.finish(); execution.finish()
let snapshot = sink.snapshots[0]
check(sink.snapshots.count == 1 && snapshot.predictionAttempts == 3, "actual attempts, finish exactly once")
check(snapshot.attemptedCrops == 4 && snapshot.attemptedBatchSlots == 4, "real crops versus batch slots")
check(snapshot.discardedLookaheadChunks == 1 && snapshot.discardedCompletedCrops == 1,
    "discarded successful lookahead is visible")
// Updates racing with finish cannot publish late or mutate the final snapshot.
execution.attempted(crops: 4, batchSlots: 4)
check(sink.snapshots == [snapshot], "final accounting is immutable")
let concurrentSink = Sink()
let concurrent = NativeCoreMLRecognitionExecutionCounters(requestID: "second", generation: 2,
    observer: { concurrentSink.append($0) })
DispatchQueue.concurrentPerform(iterations: 1000) { _ in concurrent.attempted(crops: 3, batchSlots: 4) }
concurrent.finish()
check(concurrentSink.snapshots[0].predictionAttempts == 1000 && concurrentSink.snapshots[0].attemptedCrops == 3000
    && concurrentSink.snapshots[0].attemptedBatchSlots == 4000, "concurrent exact counts")
check(sink.snapshots[0].generation == 1 && concurrentSink.snapshots[0].generation == 2, "generation isolation")
let zeroSink = Sink()
let cancelledBeforePrediction = NativeCoreMLRecognitionExecutionCounters(requestID: "cancelled", generation: 3,
    observer: { zeroSink.append($0) })
cancelledBeforePrediction.finish()
check(zeroSink.snapshots[0].predictionAttempts == 0, "cancellation before invocation is not a prediction")
// The production TaskLocal audit accepts scalar summaries without detector/text
// binding, caps them separately, and retains its final byte/truncation contract.
let jsonSink = Sink()
let recorder = NativeCausalRawDecodeDiagnostics(enabled: true, sink: { jsonSink.append($0) })
recorder.recordExecution(snapshot)
recorder.finish(); recorder.recordExecution(snapshot); recorder.finish()
let rows = try jsonSink.lines.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
check(rows.count == 2 && rows[0]["event"] as? String == "recognition-execution", "existing sink integration")
check(rows[0]["predictionAttempts"] as? Int == 3 && rows[0]["discardedCompletedCrops"] as? Int == 1,
    "serialized actual attempts and discarded crops")
check(rows[1]["executionRows"] as? Int == 1 && rows[1]["truncated"] as? Bool == false, "summary includes execution count")
let disabledSink = Sink()
let disabled = NativeCausalRawDecodeDiagnostics(enabled: false, sink: { disabledSink.append($0) })
disabled.recordExecution(snapshot); disabled.finish()
check(disabledSink.lines.isEmpty, "disabled recorder emits nothing")
let boundedSink = Sink()
let bounded = NativeCausalRawDecodeDiagnostics(enabled: true, sink: { boundedSink.append($0) })
for _ in 0..<33 { bounded.recordExecution(snapshot) }
bounded.finish()
let summary = try JSONSerialization.jsonObject(with: boundedSink.lines.last!) as! [String: Any]
check(summary["executionRows"] as? Int == 32 && summary["droppedRows"] as? Int == 1
    && summary["truncated"] as? Bool == true, "bounded page budget is explicit")
print("PASS production LRU eviction+counters;1000 concurrent updates;generation/cancellation/sink bounds")
print("Scheduler calls are simulated; no CoreML prediction or native model execution")
'''
with tempfile.TemporaryDirectory(prefix="aidoku-rec-execution-") as folder:
    folder = Path(folder)
    main = folder / "main.swift"
    main.write_text(carriers + counters + cache + checks)
    started = time.monotonic()
    subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(folder / "modules"),
                    str(OCR / "NativeCausalRawDecodeDiagnostics.swift"), str(main), "-o", str(folder / "check")], check=True)
    built = time.monotonic()
    subprocess.run([str(folder / "check")], check=True)
    print(f"build={built - started:.3f}s tests={time.monotonic() - built:.3f}s;private synthetic-only")
