import CoreGraphics
import Foundation

/// Opt-in diagnostics ONLY. Never changes thresholds, predictions or ownership.
/// One instance per host page; bind its observer explicitly for that page so a
/// reused recognizer cannot send a later page's text to an earlier page's sink.
/// Activation: set AIDOKU_OCR_RAW_DECODE_AUDIT=1, construct a recorder with a
/// thread-safe JSONL sink, and await $current.withValue(recorder) around that
/// page's OCR. Bind known detector rows before recognition and defer finish()
/// until the scoped OCR completes (including failure/cancellation). The main
/// recognizer dispatches automatically; do not also pass observe as its explicit
/// auditObserver, which would record each event twice. The environment flag alone
/// creates no recorder or output. Tests may explicitly override enabled.
@available(iOS 18.0, *)
final class NativeCausalRawDecodeDiagnostics: @unchecked Sendable {
    @TaskLocal static var current: NativeCausalRawDecodeDiagnostics?

    /// The reused recognizer holds this dispatcher, NOT a first-page recorder.
    /// Decoder callbacks currently run in the calling recognition task; a future
    /// detached decoder must explicitly carry the recorder (never guess a page).
    static func observe(_ event: NativeCoreMLRecognitionAuditEvent) { current?.record(event) }
    static var runtimeEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_OCR_RAW_DECODE_AUDIT"] == "1"
    }
    struct Limits {
        var requestedRows = 256
        var decodedRows = 512
        var bytes = 1_048_576
        var textUTF8Bytes = 1024
    }
    struct Detector {
        let sourceIndex: Int
        let ownerID: String?
        let polygon: [CGPoint]
    }

    private let enabled: Bool
    private let limits: Limits
    private let sink: @Sendable (Data) -> Void
    private let lock = NSLock()
    private var requested = 0, decoded = 0, emittedBytes = 0, ordinal = 0
    private var executionRows = 0
    private var dropped = 0, invalid = 0, bindingRejected = 0
    private var detectors: [String: [Int: Detector]] = [:]
    private var detectorCount = 0
    private var finished = false

    /// Sink receives compact JSONL Data, NOT HostDump reflection of event/region.
    init(enabled: Bool = NativeCausalRawDecodeDiagnostics.runtimeEnabled,
         limits: Limits = .init(), sink: @escaping @Sendable (Data) -> Void) {
        self.enabled = enabled
        // Fixed hard ceilings remain even when a caller requests larger budgets.
        self.limits = .init(requestedRows: min(256, max(0, limits.requestedRows)),
                            decodedRows: min(512, max(0, limits.decodedRows)),
                            bytes: min(1_048_576, max(1024, limits.bytes)),
                            textUTF8Bytes: min(1024, max(0, limits.textUTF8Bytes)))
        self.sink = sink
    }

    /// Bind the actual detection request, BEFORE its recognizer call. Never map
    /// synthetic recovery sourceIndex values by guessing an original box index.
    /// No evidence/probability/frame objects are accepted by this API.
    func bindDetectors(requestID: String, rows: [Detector]) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        guard !finished, validID(requestID), rows.count <= 4096,
              detectors[requestID] == nil, detectors.count < 32,
              rows.count <= 4096 - detectorCount,
              Set(rows.map(\.sourceIndex)).count == rows.count,
              rows.allSatisfy({ validPolygon($0.polygon) && ($0.ownerID?.utf8.count ?? 0) <= 256 }) else {
            bindingRejected += 1; return
        }
        detectors[requestID] = Dictionary(uniqueKeysWithValues: rows.map { ($0.sourceIndex, $0) })
        detectorCount += rows.count
    }

    func record(_ event: NativeCoreMLRecognitionAuditEvent) {
        guard enabled else { return }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let requestID: String, region: NativeCoreMLRecognitionRegion
        var row: [String: Any]
        let isDecoded: Bool
        switch event {
        case let .requested(id, r):
            requestID = id; region = r; isDecoded = false
            row = ["event": "requested"]
        case let .decoded(id, r, text, confidence, threshold, cacheHit):
            requestID = id; region = r; isDecoded = true
            let clipped = boundedText(text)
            row = ["event": "decoded", "text": clipped,
                   "textTruncated": clipped != text, "empty": text.isEmpty,
                   "confidence": confidence.isFinite ? confidence as Any : NSNull(),
                   "threshold": threshold.isFinite ? threshold as Any : NSNull(),
                   "belowRecognizerFloor": confidence.isFinite && threshold.isFinite ? (confidence < threshold) as Any : NSNull(),
                   "cacheHit": cacheHit]
        }
        guard validID(requestID), validPolygon(region.polygon),
              region.samplingPolygon.map(validPolygon) ?? true else {
            invalid += 1; lock.unlock(); return
        }
        guard isDecoded ? decoded < limits.decodedRows : requested < limits.requestedRows else {
            dropped += 1; lock.unlock(); return
        }
        row["version"] = 1
        row["ordinal"] = ordinal
        row["requestID"] = requestID
        row["sourceIndex"] = region.sourceIndex
        row["polygon"] = region.polygon.map { [Double($0.x), Double($0.y)] }
        row["samplingPolygon"] = region.samplingPolygon.map { $0.map { [Double($0.x), Double($0.y)] } as Any } ?? NSNull()
        row["minimumSequenceWidth"] = region.minimumSequenceWidth
        if let detector = detectors[requestID]?[region.sourceIndex], detector.polygon == region.polygon {
            row["detectorBinding"] = "exact-request-index-polygon"
            row["detectorIndex"] = detector.sourceIndex
            row["detectorOwnerID"] = detector.ownerID as Any? ?? NSNull()
        } else {
            row["detectorBinding"] = "unbound-or-recovery-geometry"
            row["detectorIndex"] = NSNull()
            row["detectorOwnerID"] = NSNull()
        }
        guard let json = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              json.count + 1 <= limits.bytes - 1024 - emittedBytes else {
            dropped += 1; lock.unlock(); return
        }
        var data = json; data.append(10)
        emittedBytes += data.count; ordinal += 1
        if isDecoded { decoded += 1 } else { requested += 1 }
        lock.unlock()
        // No sink under lock. Ordinal allows deterministic joining if concurrent
        // callbacks reach a thread-safe host sink in a different delivery order.
        sink(data)
    }

    /// One scalar summary per observed recognizer generation, also on failure
    /// or cancellation. These attempted/discarded counts never replace the
    /// pipeline's existing committed-result diagnostics.
    func recordExecution(_ value: NativeCoreMLRecognitionExecutionSnapshot) {
        guard enabled else { return }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard validID(value.requestID), executionRows < 32 else {
            dropped += 1; lock.unlock(); return
        }
        let row: [String: Any] = ["version": 1, "event": "recognition-execution", "ordinal": ordinal,
            "requestID": value.requestID, "generation": value.generation,
            "predictionAttempts": value.predictionAttempts, "attemptedCrops": value.attemptedCrops,
            "attemptedBatchSlots": value.attemptedBatchSlots,
            "discardedLookaheadChunks": value.discardedLookaheadChunks,
            "discardedPlannedCrops": value.discardedPlannedCrops,
            "discardedCompletedPredictions": value.discardedCompletedPredictions,
            "discardedCompletedCrops": value.discardedCompletedCrops,
            "scope": "actual-invocations-and-stale-lookahead;not-success-or-cancellation-waste"]
        guard let json = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              json.count + 1 <= limits.bytes - 1024 - emittedBytes else {
            dropped += 1; lock.unlock(); return
        }
        var data = json; data.append(10)
        emittedBytes += data.count; ordinal += 1; executionRows += 1
        lock.unlock()
        sink(data)
    }

    /// Call AFTER awaiting this page's complete OCR (also defer on failure).
    /// Reserved budget makes truncation visible instead of implying zero reads.
    func finish() {
        guard enabled else { return }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let value: [String: Any] = ["version": 1, "event": "summary", "requestedRows": requested,
            "decodedRows": decoded, "dataBytes": emittedBytes, "droppedRows": dropped,
            "executionRows": executionRows,
            "invalidRows": invalid, "rejectedBindings": bindingRejected,
            "truncated": dropped > 0 || invalid > 0 || bindingRejected > 0,
            "maximumDataAndSummaryBytes": limits.bytes]
        var data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        data.append(10)
        detectors.removeAll(keepingCapacity: false); detectorCount = 0
        lock.unlock()
        sink(data)
    }

    private func boundedText(_ text: String) -> String {
        var result = "", bytes = 0
        for scalar in text.unicodeScalars {
            let count = scalar.utf8.count
            guard count <= limits.textUTF8Bytes - bytes else { break }
            result.unicodeScalars.append(scalar); bytes += count
        }
        return result
    }
    private func validID(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= 256 }
    private func validPolygon(_ points: [CGPoint]) -> Bool {
        points.count == 4 && points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }
}
