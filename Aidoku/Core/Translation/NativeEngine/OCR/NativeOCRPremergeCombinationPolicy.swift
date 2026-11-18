import Foundation

/// At most three global AND rules combined with OR. Every condition is a
/// confidence or evidence-overlap comparison; missing data abstains.
struct NativeOCRPremergeCombinationPolicy: Sendable {
    struct Condition: Decodable, Sendable {
        let feature: String
        let op: String
        let threshold: Double
    }
    struct Rule: Decodable, Sendable { let conditions: [Condition] }
    private struct Payload: Decodable {
        let schema: String
        let featureNames: [String]
        let rules: [Rule]
        let GTAtInference: Bool
        let IDsAtInference: Bool
    }
    static var supplementalNames: [String] { NativeOCRPremergeAutoPolicy.featureNames + NativeOCRPremergeQueryRelations.featureNames }
    static var featureNames: [String] { Array(NativeOCRPremergeCandidateModel.featureNames[8...30]) + supplementalNames }
    private let rules: [Rule]?
    var isAvailable: Bool { rules != nil }

    init(data: Data?) {
        guard let data, data.count <= 65_536,
              let p = try? JSONDecoder().decode(Payload.self, from: data),
              p.schema == "premerge-evidence-combination-v3", !p.GTAtInference, !p.IDsAtInference,
              p.rules.count <= 3, Set(p.featureNames).count == p.featureNames.count,
              Set(p.featureNames).isSubset(of: Set(Self.featureNames)),
              p.rules.allSatisfy({ rule in
                  !rule.conditions.isEmpty && rule.conditions.count <= 16 && rule.conditions.allSatisfy {
                      p.featureNames.contains($0.feature) && ["le", "ge"].contains($0.op) &&
                      $0.threshold.isFinite && (0...1).contains($0.threshold)
                  }
              }) else { rules = nil; return }
        self.rules = p.rules
    }
    init(contentsOf url: URL) {
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { self.init(data: nil); return }
        defer { try? handle.close() }
        self.init(data: try? handle.read(upToCount: 65_537))
    }
    func rejects(features: [Double]?, supplemental: [Double]?) -> Bool {
        guard let rules, let f = features, f.count == 55, let s = supplemental, s.count == Self.supplementalNames.count else { return false }
        func value(_ name: String) -> Double? {
            if let index = NativeOCRPremergeCandidateModel.featureNames.firstIndex(of: name), (8...30).contains(index) { return f[index] }
            if let index = Self.supplementalNames.firstIndex(of: name) { return s[index] }
            return nil
        }
        for rule in rules {
            for c in rule.conditions {
                guard let v = value(c.feature), v.isFinite, (0...1.000001).contains(v) else { return false }
            }
        }
        return rules.contains { rule in
            rule.conditions.allSatisfy { c in
                guard let v = value(c.feature) else { return false }
                return c.op == "le" ? v <= c.threshold : v >= c.threshold
            }
        }
    }
}
