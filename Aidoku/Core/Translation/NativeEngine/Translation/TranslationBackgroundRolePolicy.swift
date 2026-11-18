import Foundation
import CryptoKit

/// Source-bound input geometry, not an output role or erasure authorization.
typealias NativeTranslationRoleEvidence = TranslationBackgroundRolePolicy.Evidence

/// Provider guidance only; never a role override, filter toggle, or erasure authority.
enum TranslationBackgroundRolePolicy {
    static let version = "background-v15-explicit-objects-and-screens"
    static let instructions = """
    background=writing on depicted objects or screens, including partial signs and labels; not balloons or overlays.
    """

    struct Contour: Sendable {
        let bounds: [Double] // Normalized top-left x,y,width,height.
        let spans: [Double] // Equal-height bands, normalized full-image left/right.
        let verified: Bool?
        let modelEstimated: Bool?
    }

    struct RFSupport: Sendable {
        let imageIdentity: String
        let maskOwnerQuery: Int?
        let ownerResolution: String
        let balloonConfidence: Double?
        let balloonBBoxCoverage: Double?
        let textConfidence: Double?
        let textBBoxCoverage: Double?
        let sfxConfidence: Double?
        let sfxBBoxCoverage: Double?
        var balloonBounds: [Double]? = nil
    }

    struct Evidence: Codable, Hashable, Sendable {
        let policyVersion: String
        let imageIdentity: String
        let sourceTextSHA256: String
        let sourceBounds: [Double]
        let contourBounds: [Double]?
        let contourVerified: Bool?
        let contourModelEstimated: Bool?
        let contourBBoxCoverage: Double?
        let rfMaskOwnerQuery: Int?
        let rfOwnerResolution: String?
        let rfBalloonConfidence: Double?
        let rfBalloonBBoxCoverage: Double?
        let rfTextConfidence: Double?
        let rfTextBBoxCoverage: Double?
        let rfSFXConfidence: Double?
        let rfSFXBBoxCoverage: Double?
        let conflicts: [String]
        let sourceContourAndRFMaskAgree: Bool
        var rfBalloonBounds: [Double]? = nil

        func isBound(source: String, bounds: [Double], imageIdentity: String) -> Bool {
            policyVersion == TranslationBackgroundRolePolicy.version && self.imageIdentity == imageIdentity &&
                sourceBounds == bounds && sourceTextSHA256 == TranslationBackgroundRolePolicy.digest(source) &&
                validMeasurements
        }

        private var validMeasurements: Bool {
            let hex = CharacterSet(charactersIn: "0123456789abcdef")
            return TranslationBackgroundRolePolicy.validBounds(sourceBounds) &&
                (contourBounds.map(TranslationBackgroundRolePolicy.validBounds) ?? true) &&
                (rfBalloonBounds.map(TranslationBackgroundRolePolicy.validBounds) ?? true) &&
                imageIdentity.count == 64 && imageIdentity.unicodeScalars.allSatisfy(hex.contains) &&
                sourceTextSHA256.count == 64 && sourceTextSHA256.unicodeScalars.allSatisfy(hex.contains) &&
                [contourBBoxCoverage, rfBalloonConfidence, rfBalloonBBoxCoverage, rfTextConfidence,
                 rfTextBBoxCoverage, rfSFXConfidence, rfSFXBBoxCoverage].allSatisfy { value in
                    value.map { $0.isFinite && (0...1).contains($0) } ?? true
                } && (rfMaskOwnerQuery.map { $0 >= 0 && $0 < 300 } ?? true) &&
                (rfOwnerResolution?.utf8.count ?? 0) <= 64 && conflicts.count <= 2 &&
                conflicts.allSatisfy { ["nativeContourOverlapsRFSFXPrediction", "contourAlsoModelEstimated"].contains($0) }
        }
    }

    static func make(source: String, bounds: [Double], imageIdentity: String,
                     contour: Contour?, rf: RFSupport?) -> Evidence? {
        guard !source.isEmpty, !imageIdentity.isEmpty, validBounds(bounds),
              contour.map({ validBounds($0.bounds) && $0.spans.count >= 2 &&
                  $0.spans.count <= 512 && $0.spans.count.isMultiple(of: 2) &&
                  $0.spans.allSatisfy(\.isFinite) }) ?? true,
              rf.map({ $0.imageIdentity == imageIdentity &&
                  ($0.balloonBounds.map(validBounds) ?? true) &&
                  [$0.balloonConfidence, $0.balloonBBoxCoverage, $0.textConfidence, $0.textBBoxCoverage,
                   $0.sfxConfidence, $0.sfxBBoxCoverage].allSatisfy { value in
                      value.map { $0.isFinite && (0...1).contains($0) } ?? true
                  } &&
                  ($0.maskOwnerQuery.map { $0 >= 0 } ?? true) }) ?? true else { return nil }
        let coverage = contour.map { bboxCoverage(bounds, contour: $0) }
        let resolutionAccepted = rf.map { ["exact", "ieeePixelEdge", "compositeEnvelope"].contains($0.ownerResolution) } ?? false
        let agree = contour?.verified == true && contour?.modelEstimated == false &&
            (coverage ?? 0) >= 0.9 && resolutionAccepted && rf?.maskOwnerQuery != nil &&
            (rf?.balloonConfidence ?? 0) >= 0.5 && (rf?.balloonBBoxCoverage ?? 0) >= 0.9 &&
            !((rf?.sfxConfidence ?? 0) >= 0.5 && (rf?.sfxBBoxCoverage ?? 0) > 0)
        var conflicts: [String] = []
        if contour?.verified == true && (rf?.sfxConfidence ?? 0) >= 0.5 && (rf?.sfxBBoxCoverage ?? 0) > 0 {
            conflicts.append("nativeContourOverlapsRFSFXPrediction")
        }
        if contour?.verified == true && contour?.modelEstimated == true {
            conflicts.append("contourAlsoModelEstimated")
        }
        return Evidence(policyVersion: version, imageIdentity: imageIdentity, sourceTextSHA256: digest(source),
            sourceBounds: bounds, contourBounds: contour?.bounds, contourVerified: contour?.verified,
            contourModelEstimated: contour?.modelEstimated, contourBBoxCoverage: coverage,
            rfMaskOwnerQuery: rf?.maskOwnerQuery, rfOwnerResolution: rf?.ownerResolution,
            rfBalloonConfidence: rf?.balloonConfidence, rfBalloonBBoxCoverage: rf?.balloonBBoxCoverage,
            rfTextConfidence: rf?.textConfidence, rfTextBBoxCoverage: rf?.textBBoxCoverage,
            rfSFXConfidence: rf?.sfxConfidence, rfSFXBBoxCoverage: rf?.sfxBBoxCoverage, conflicts: conflicts,
            sourceContourAndRFMaskAgree: agree, rfBalloonBounds: rf?.balloonBounds)
    }

    private static func digest(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func validBounds(_ bounds: [Double]) -> Bool {
        bounds.count == 4 && bounds.allSatisfy(\.isFinite) && bounds[0] >= 0 && bounds[1] >= 0 &&
            bounds[2] > 0 && bounds[3] > 0 && bounds[0] + bounds[2] <= 1 && bounds[1] + bounds[3] <= 1
    }

    /// Exact band/bbox intersection, not glyph coverage or a new segmentation mask.
    private static func bboxCoverage(_ box: [Double], contour: Contour) -> Double {
        let bands = contour.spans.count / 2
        let bandHeight = contour.bounds[3] / Double(bands)
        var area = 0.0
        for i in 0..<bands {
            let left = contour.spans[2 * i], right = contour.spans[2 * i + 1]
            guard left >= 0, right > left, right <= 1 else { continue }
            let top = contour.bounds[1] + Double(i) * bandHeight
            let height = max(0, min(box[1] + box[3], top + bandHeight) - max(box[1], top))
            let width = max(0, min(box[0] + box[2], right) - max(box[0], left))
            area += width * height
        }
        return min(1, max(0, area / (box[2] * box[3])))
    }
}
