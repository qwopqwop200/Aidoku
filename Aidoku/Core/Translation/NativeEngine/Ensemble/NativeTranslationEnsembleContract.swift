import CoreGraphics
import Foundation

/// Runtime evidence only. Evaluation labels and page identifiers never enter this contract.
struct Ensemble100RFRegion {
    let queryID: Int
    let classID: Int // RF native taxonomy: text0, soundEffect1, balloon2, frame3.
    let confidence: Double
    let bounds: CGRect // Original-image normalized top-left coordinates.
    let exterior: [CGPoint]
    let holes: [[CGPoint]]
    /// Optional runtime observation; never supplies placement or merge geometry.
    let sourcePixelMask: Ensemble100RFSourcePixelMask?

    init(queryID: Int, classID: Int, confidence: Double, bounds: CGRect,
         exterior: [CGPoint], holes: [[CGPoint]], sourcePixelMask: Ensemble100RFSourcePixelMask? = nil) {
        self.queryID = queryID
        self.classID = classID
        self.confidence = confidence
        self.bounds = bounds
        self.exterior = exterior
        self.holes = holes
        self.sourcePixelMask = sourcePixelMask
    }
}

/// Type-erased native model observation in upright source pixels. No detector
/// dependency, bbox clipping, raster allocation or ground-truth authority.
struct Ensemble100RFSourcePixelMask {
    let sourceIdentity: String
    let queryID: Int
    let sourceWidth: Int
    let sourceHeight: Int
    private let sample: (Int, Int) -> Bool

    init(sourceIdentity: String, queryID: Int, sourceWidth: Int, sourceHeight: Int,
         sample: @escaping (Int, Int) -> Bool) {
        self.sourceIdentity = sourceIdentity
        self.queryID = queryID
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.sample = sample
    }

    /// Nil is unobserved (wrong source or outside its canvas), not negative evidence.
    func contains(sourceX: Int, sourceY: Int, sourceIdentity: String) -> Bool? {
        guard sourceIdentity == self.sourceIdentity,
              sourceX >= 0, sourceY >= 0, sourceX < sourceWidth, sourceY < sourceHeight else { return nil }
        return sample(sourceX, sourceY)
    }
}

struct Ensemble100Page {
    let sourceSHA256: String
    let original: CGImage
    let restored: CGImage
    let removalMask: CGImage
    let viewport: CGSize
    let items: [[String: Any]]
    let rfRegions: [Ensemble100RFRegion]
    let savedEvidence: [String: Any]
}

struct Ensemble100Proposal {
    var items: [[String: Any]]
    var replacementMask: CGImage? = nil
    var requiresRestoration: Bool = false
    var audit: [String: Any] = [:]
}

protocol Ensemble100Candidate {
    static var defaults: [String: Double] { get }
    static func apply(_ page: Ensemble100Page, parameters: [String: Double]) throws -> Ensemble100Proposal
}
