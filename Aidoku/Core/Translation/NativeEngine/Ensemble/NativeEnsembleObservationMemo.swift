import CoreGraphics
import Foundation

/// A page-scoped cache of completed observer VALUES, not pixel buffers or models.
/// promptVersion: technical-review-v1 + main-integration-v1.
///
/// Input contract v2 for the original-source palette and neutral-shell observers:
/// - NativeOriginalSourcePalette.observe reads immutable original CGImage,
///   exact sourceBounds and originalGeometry["sourcePolygon"] as? [[Double]].
/// - Ordinary ROI/neutral observers read no other geometry fields. Grouped
///   palette observations additionally require exact ordered member geometry,
///   identifiers and admission policy in opaqueDependencies (canonical bytes).
///   Failed polygon casts have the same nil fallback as absence.
/// - Viewport, text, display fill/stroke, restored pixels, RF and removal masks
///   are NOT inputs. Never cache Observation.display(...) with this contract.
/// - One instance serves ONE observer algorithm/configuration for ONE page.
///   Use separate typed instances for palette and optional neutral-shell values.
///   If a consumer starts reading another input, extend/version the key BEFORE
///   connecting it. Compute must be deterministic and return immutable/value-
///   semantic data; arbitrary reference-valued results are not deep-copied.
///
final class NativeEnsembleObservationMemo<Value> {
    static var inputContractVersion: String { "original-source-bounds-sourcePolygon-dependencies-v2" }

    private struct Key: Hashable {
        let original: ObjectIdentifier
        let bounds: [UInt64]
        let polygon: [[UInt64]]? // nil is distinct from any explicit polygon/order.
        let opaqueDependencies: Data?

        init?(original: CGImage, bounds: [Double], polygon: [[Double]]?, opaqueDependencies: Data?) {
            // Same admitted geometry domain as the frozen observers. Rejection
            // bypasses memoization ONLY; it never skips or changes compute().
            guard bounds.count == 4, bounds.allSatisfy(\.isFinite),
                  bounds[0] >= 0, bounds[1] >= 0, bounds[2] > 0, bounds[3] > 0,
                  bounds[0] + bounds[2] <= 1.000001,
                  bounds[1] + bounds[3] <= 1.000001 else { return nil }
            if let polygon {
                guard polygon.count >= 3,
                      polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return nil }
            }
            self.original = ObjectIdentifier(original)
            self.bounds = bounds.map(\.bitPattern)
            self.polygon = polygon.map { $0.map { $0.map(\.bitPattern) } }
            self.opaqueDependencies = opaqueDependencies
        }
    }

    // Boxing avoids Dictionary's optional-subscript deletion semantics when
    // Value itself is Optional and compute legitimately returns nil.
    private struct Entry { let value: Value }
    private let lock = NSRecursiveLock()
    private let enabled: Bool
    private var original: CGImage?
    private var entries: [Key: Entry] = [:]
    private var counts = ["requests": 0, "hits": 0, "misses": 0, "computeCalls": 0,
                          "disabledBypasses": 0, "foreignImageBypasses": 0,
                          "invalidKeyBypasses": 0, "closedBypasses": 0]

    init(original: CGImage, enabled: Bool) {
        self.original = original // Strong until close()/deinit; no identity recycling.
        self.enabled = enabled
    }

    /// Both main palette bridge and downstream painter must receive THIS SAME instance.
    /// No budgets, item filtering, fallback policy or prediction changes occur.
    /// Callback execution is serialized; thrown results are never stored.
    func value(original: CGImage, bounds: [Double], polygon: [[Double]]?,
               opaqueDependencies: Data? = nil,
               compute: () throws -> Value) rethrows -> Value {
        lock.lock(); defer { lock.unlock() }
        counts["requests", default: 0] += 1
        let bypass: String?
        if self.original == nil { bypass = "closedBypasses" }
        else if !enabled { bypass = "disabledBypasses" }
        else if self.original !== original { bypass = "foreignImageBypasses" }
        else { bypass = nil }
        if let bypass {
            counts[bypass, default: 0] += 1
            counts["computeCalls", default: 0] += 1
            return try compute()
        }
        guard let key = Key(original: original, bounds: bounds, polygon: polygon, opaqueDependencies: opaqueDependencies) else {
            counts["invalidKeyBypasses", default: 0] += 1
            counts["computeCalls", default: 0] += 1
            return try compute()
        }
        if let entry = entries[key] {
            counts["hits", default: 0] += 1
            return entry.value
        }
        counts["misses", default: 0] += 1
        counts["computeCalls", default: 0] += 1
        let result = try compute()
        // close() can be invoked from a callback; do not resurrect that scope.
        if self.original != nil { entries[key] = Entry(value: result) }
        return result
    }

    var statistics: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        var result = counts
        result["entries"] = entries.count
        result["retainedOriginal"] = original == nil ? 0 : 1
        result["enabled"] = enabled ? 1 : 0
        return result
    }

    /// Idempotent explicit release for a do/defer page scope. Escaped references
    /// subsequently compute uncached. Deallocation also releases image/results.
    func close() {
        lock.lock(); defer { lock.unlock() }
        original = nil
        entries.removeAll(keepingCapacity: false)
    }

    static func withPage<Result>(original: CGImage, enabled: Bool,
                                 _ body: (NativeEnsembleObservationMemo<Value>) throws -> Result) rethrows -> Result {
        let memo = NativeEnsembleObservationMemo(original: original, enabled: enabled)
        defer { memo.close() }
        return try body(memo)
    }
}


// Compatibility for existing independent component tests and integration call sites.
typealias Ensemble08ObservationMemo<Value> = NativeEnsembleObservationMemo<Value>
