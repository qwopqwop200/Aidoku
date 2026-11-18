import Foundation

/// Frozen predictors are injected by the model registry. Trees are tree-major.
/// No file, image, training-label or stored cohort access exists in this layer.
struct NativeSourceFontModelAccess {
    let predict: (String, [[Double]]) throws -> [Double]
    let proba: (String, [[Double]]) throws -> [[Double]]
    let trees: (String, [[Double]]) throws -> [[Double]]
    let classes: (String) throws -> [Double]
}

enum NativeSourceFontGraphError: Error {
    case invalid(String)
}

enum NativeSourceFontGraphMath {
    typealias Matrix = [[Double]]
    struct Prepared {
        var records: [[Int]]
        var anchors: [Double]
        var old: [Double]
        var pages: [[Int]]
    }

    static func clip(_ x: Double, _ low: Double, _ high: Double) -> Double { min(high, max(low, x)) }
    static func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
    static func std(_ values: [Double]) -> Double {
        let average = mean(values)
        return sqrt(mean(values.map { ($0 - average) * ($0 - average) }))
    }
    static func quantile(_ values: [Double], _ q: Double) -> Double {
        quantile(sorted: values.sorted(), q)
    }
    static func quantile(sorted ordered: [Double], _ q: Double) -> Double {
        guard !ordered.isEmpty else { return 0 }
        let position = clip(q, 0, 1) * Double(ordered.count - 1)
        let low = Int(floor(position)), high = Int(ceil(position))
        // NumPy's linear lerp changes arithmetic when fraction >= 0.5.
        let fraction = position - Double(low), difference = ordered[high] - ordered[low]
        return fraction >= 0.5 ? ordered[high] - difference * (1 - fraction) : ordered[low] + difference * fraction
    }
    static func quantiles(_ values: [Double], _ qs: [Double]) -> [Double] { qs.map { quantile(values, $0) } }
    static func median(_ values: [Double]) -> Double {
        median(sorted: values.sorted())
    }
    static func median(sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let center = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[center - 1] + sorted[center]) / 2 : sorted[center]
    }
    static func pooled(_ rows: Matrix, _ qs: [Double] = [0.2, 0.5, 0.8]) -> [Double] {
        guard let first = rows.first else { return [] }
        let columns = first.indices.map { j in rows.map { $0[j] } }
        return qs.flatMap { q in columns.map { quantile($0, q) } }
    }
    static func columnMean(_ rows: Matrix) -> [Double] {
        guard let first = rows.first else { return [] }
        return first.indices.map { j in mean(rows.map { $0[j] }) }
    }
    static func summary(_ rows: Matrix) -> [Double] {
        guard let first = rows.first else { return [] }
        return pooled(rows) + columnMean(rows) + first.indices.map { j in std(rows.map { $0[j] }) }
    }
    static func weightedMedian(_ values: [Double], _ weights: [Double]) -> Double {
        let ids = values.indices.filter { values[$0] > 0 && weights[$0] > 0 }.sorted {
            values[$0] == values[$1] ? $0 < $1 : values[$0] < values[$1]
        }
        guard !ids.isEmpty else { return 0 }
        let half = ids.reduce(0) { $0 + weights[$1] } / 2
        var cumulative = 0.0
        for i in ids {
            cumulative += weights[i]
            if cumulative >= half { return values[i] }
        }
        return values[ids.last!]
    }
    static func arange(_ start: Double, _ stop: Double, _ step: Double = 0.5) -> [Double] {
        guard step > 0, stop > start else { return [] }
        // np.arange computes the representable step from its first two entries.
        let count = Int(ceil((stop - start) / step)), delta = (start + step) - start
        return (0..<count).map { start + Double($0) * delta }
    }
    static func interp(_ x: Double, _ xp: [Double], _ fp: [Double], left: Double = 0, right: Double = 0) -> Double {
        guard !xp.isEmpty else { return 0 }
        if x < xp[0] { return left }
        if x > xp[xp.count - 1] { return right }
        var low = 0, high = xp.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if xp[middle] <= x { low = middle } else { high = middle - 1 }
        }
        if low == xp.count - 1 || x == xp[low] { return fp[low] }
        return fp[low] + (x - xp[low]) * ((fp[low + 1] - fp[low]) / (xp[low + 1] - xp[low]))
    }
    static func argmax(_ values: [Double]) -> Int {
        var best = 0
        for i in values.indices where values[i] > values[best] { best = i }
        return best
    }
    static func value(_ dictionary: [String: Any], _ path: String) throws -> Any {
        if let direct = dictionary[path] { return direct }
        var current: Any = dictionary
        for key in path.split(separator: ".") {
            guard let next = (current as? [String: Any])?[String(key)] else {
                throw NativeSourceFontGraphError.invalid("Missing source signal \(path)")
            }
            current = next
        }
        return current
    }
    static func matrix(_ dictionary: [String: Any], _ path: String) throws -> Matrix {
        guard let result = try value(dictionary, path) as? Matrix else {
            throw NativeSourceFontGraphError.invalid("Expected matrix \(path)")
        }
        return result
    }
    static func vector(_ dictionary: [String: Any], _ path: String) throws -> [Double] {
        let raw = try value(dictionary, path)
        if let result = raw as? [Double] { return result }
        if let result = raw as? [Int] { return result.map(Double.init) }
        throw NativeSourceFontGraphError.invalid("Expected vector \(path)")
    }
    static func modelID(_ value: Any?) -> String? {
        if let identity = value as? String { return identity }
        return (value as? [String: Any])?["modelID"] as? String
    }
    static func isNull(_ value: Any?) -> Bool { value == nil || value is NSNull }
    static func number(_ p: [String: Any], _ key: String, _ fallback: Double = 0) -> Double {
        (p[key] as? NSNumber)?.doubleValue ?? fallback
    }
    static func integer(_ p: [String: Any], _ key: String, _ fallback: Int = 0) -> Int {
        (p[key] as? NSNumber)?.intValue ?? fallback
    }
    static func string(_ p: [String: Any], _ key: String, _ fallback: String = "") -> String { p[key] as? String ?? fallback }
    static func flag(_ p: [String: Any], _ key: String, _ fallback: Bool = false) -> Bool { p[key] as? Bool ?? fallback }
    static func validate(_ rows: Matrix, width: Int, count: Int, name: String) throws {
        guard rows.count == count, rows.allSatisfy({ $0.count == width && $0.allSatisfy(\.isFinite) }) else {
            throw NativeSourceFontGraphError.invalid("Invalid \(name) dimensions or values")
        }
    }
    static func groupRows(_ groups: [String]) -> [[Int]] {
        Set(groups).sorted().map { group in groups.indices.filter { groups[$0] == group } }
    }
    static func prepare(before: [Double], native: Matrix, groups: [String]) -> Prepared {
        var result = Prepared(records: [], anchors: [], old: [], pages: [])
        for ids in groupRows(groups) {
            let start = result.records.count
            for value in Set(ids.map { before[$0] }).sorted() {
                let members = ids.filter { before[$0] == value }
                result.records.append(members)
                result.anchors.append(median(members.map { exp(native[$0][0]) }))
                result.old.append(value)
            }
            result.pages.append(Array(start..<result.records.count))
        }
        return result
    }
    static func apply(_ before: [Double], _ prepared: Prepared, _ proposed: [Double],
                      weights: [Double], clip: Double, quantum: Double) -> [Double] {
        var values = prepared.old.indices.map { i -> Double in
            let value = prepared.old[i] * exp(Self.clip(weights[i] * log(proposed[i] / prepared.old[i]), -clip, clip))
            return max(quantum, (value / quantum).rounded(.toNearestOrEven) * quantum)
        }
        for page in prepared.pages where Set(page.map { values[$0] }).count != page.count {
            for i in page { values[i] = prepared.old[i] }
        }
        var result = before
        for (i, ids) in prepared.records.enumerated() { for id in ids { result[id] = values[i] } }
        return result
    }
}
