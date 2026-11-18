import Foundation

/// Bounded global parameters selected offline with grouped train/calibration/test.
/// Runtime reads no targets, IDs, text, image pixels or corpus-derived lookup tables.
struct NativeOCRPremergeAutoPolicy: Sendable {
    static var featureNames: [String] {
        NativeOCRPremergeSpatialEvidence.featureNames + NativeOCRPremergeDetectorAgreement.featureNames.enumerated().map {
            $0.offset < 3 ? $0.element + "Fraction" : $0.element
        }
    }
    private struct Parameters: Decodable, Sendable {
        let sfxCoverage: Double
        let sfxShare: Double
        let sfxConfidence: Double
        let rawTextVeto: Double
        let rawTextShareVeto: Double
        let minimumRawTextForShareVeto: Double
        let dominance: Double
        let margin: Double
        let textOnlyVeto: Double
        let conflictVeto: Double
        let balloonProtection: Double
        let boundaryProtection: Double
        let frameInteriorProtection: Double
        let independentDetectorVeto: Double
        let independentDetectorNames: [String]
    }
    private struct Payload: Decodable {
        let schema: String
        let family: String
        let params: Parameters
        let requiredSupplementalNames: [String]
        let GTAtInference: Bool
        let IDsAtInference: Bool
    }
    private let params: Parameters?
    var isAvailable: Bool { params != nil }

    init(data: Data?) {
        guard let data, !data.isEmpty, data.count <= 65_536,
              let decoded = try? JSONDecoder().decode(Payload.self, from: data),
              decoded.schema == "rf-monotone-rule-list-v2", decoded.family == "supplemental",
              !decoded.GTAtInference, !decoded.IDsAtInference else { params = nil; return }
        let p = decoded.params
        let fractions = [p.sfxCoverage, p.sfxShare, p.sfxConfidence, p.rawTextVeto, p.rawTextShareVeto,
            p.minimumRawTextForShareVeto, p.margin, p.textOnlyVeto, p.conflictVeto,
            p.balloonProtection, p.boundaryProtection, p.frameInteriorProtection, p.independentDetectorVeto]
        let allowed = ["detOriginal_secondSupport", "detOriginal_secondConfidence", "detOriginal_bestSecondIoU"]
        guard fractions.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              p.sfxCoverage > 0, p.sfxShare > 0, p.sfxConfidence > 0,
              p.dominance.isFinite, (1...10).contains(p.dominance),
              !p.independentDetectorNames.isEmpty, p.independentDetectorNames.count <= 3,
              p.independentDetectorNames.allSatisfy({ allowed.contains($0) }),
              Set(p.independentDetectorNames).count == p.independentDetectorNames.count,
              Set(decoded.requiredSupplementalNames) == Set(NativeOCRPremergeSpatialEvidence.featureNames + p.independentDetectorNames)
        else { params = nil; return }
        params = p
    }

    init(contentsOf url: URL) {
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { self.init(data: nil); return }
        defer { try? handle.close() }
        self.init(data: try? handle.read(upToCount: 65_537))
    }

    /// Invalid or incomplete new evidence cannot add rejection to the baseline.
    func rejects(features: [Double]?, supplemental: [Double]?) -> Bool {
        guard let p = params, let f = features, f.count == 55, let s = supplemental, s.count == Self.featureNames.count,
              s.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              [8, 9, 10, 13, 17, 18, 20, 21, 29].allSatisfy({ f[$0].isFinite && (0...1.000001).contains(f[$0]) }),
              f[8] == 1, f[29] == 1 else { return false }
        guard s[4] >= p.sfxCoverage, s[7] >= p.sfxShare, s[9] >= p.sfxConfidence,
              s[1] >= p.dominance * s[0] + p.margin else { return false }
        if s[0] >= p.rawTextVeto || (s[2] >= p.rawTextShareVeto && s[0] >= p.minimumRawTextForShareVeto) ||
            s[3] >= p.textOnlyVeto || s[5] >= p.conflictVeto || s[10] >= p.balloonProtection ||
            s[11] >= p.boundaryProtection || s[13] >= p.boundaryProtection ||
            (s[12] >= p.frameInteriorProtection && s[0] >= p.minimumRawTextForShareVeto) { return false }
        for name in p.independentDetectorNames {
            guard let index = Self.featureNames.firstIndex(of: name) else { return false }
            if s[index] >= p.independentDetectorVeto { return false }
        }
        return true
    }
}
