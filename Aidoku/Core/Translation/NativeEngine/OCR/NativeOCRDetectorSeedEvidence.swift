import Foundation

/// Sparse, measured DB cells. Coordinates are in the full detector grid,
/// never polygon-filled source pixels. Identity is local to one source image.
struct NativeOCRDetectorSeedEvidence: Codable, Equatable, Sendable {
    struct Run: Codable, Equatable, Sendable { let y: Int; let x: Int; let count: Int }
    struct Component: Codable, Equatable, Sendable {
        let seed: Int
        let pixelCount: Int
        let meanProbability: Double
        let runs: [Run]
    }
    struct Candidate: Codable, Equatable, Sendable {
        let component: Component
        let competingOwnerIDs: [String]
        let outsideCompetingCells: [Int]
    }
    let ownerID: String
    let parentBoxIndex: Int
    let provenance: String
    let threshold: Double
    let mapOriginX: Int
    let mapOriginY: Int
    let mapFullWidth: Int
    let mapFullHeight: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let components: [Component]
    var sourceProbabilityROI: NativeOCRSourceROIProbabilityEvidence? = nil
    var ownershipVersion: Int? = nil
    var completeCCScan: Bool? = nil
    var ambiguousComponents: [Component]? = nil
    var candidateComponents: [Candidate]? = nil
}

extension NativeOCRDetectorSeedEvidence {
    /// Validate persisted provenance before allocating any original-pixel mask.
    var isValid: Bool {
        guard !ownerID.isEmpty, ownerID.utf8.count <= 160, parentBoxIndex >= 0, parentBoxIndex < 4096,
              (provenance == "db-4connected-original-cells-v1" || provenance == "db-complete-cc-candidates-v2"), threshold == 0.9,
              mapFullWidth > 0, mapFullHeight > 0, mapFullWidth <= 32768, mapFullHeight <= 32768,
              sourceWidth > 0, sourceHeight > 0, sourceWidth <= 131072, sourceHeight <= 131072,
              mapOriginX >= 0, mapOriginX < mapFullWidth, mapOriginY >= 0, mapOriginY < mapFullHeight,
              components.count <= 256 else { return false }
        if let roi = sourceProbabilityROI {
            guard roi.isValid, roi.sourceWidth == sourceWidth, roi.sourceHeight == sourceHeight,
                  roi.detector.fullWidth == mapFullWidth, roi.detector.fullHeight == mapFullHeight,
                  roi.detector.originX == mapOriginX, roi.detector.originY == mapOriginY else { return false }
        }
        let version2 = ownershipVersion == 2
        if version2 {
            guard provenance == "db-complete-cc-candidates-v2", completeCCScan == true,
                  ambiguousComponents != nil, candidateComponents != nil else { return false }
        } else {
            guard ownershipVersion == nil, provenance == "db-4connected-original-cells-v1",
                  completeCCScan == nil, ambiguousComponents == nil, candidateComponents == nil else { return false }
        }
        let candidates = candidateComponents ?? []
        let all = components + (ambiguousComponents ?? []) + candidates.map(\.component)
        guard !all.isEmpty, all.count <= 256 else { return false }
        for candidate in candidates {
            guard !candidate.competingOwnerIDs.isEmpty, candidate.competingOwnerIDs.count <= 64,
                  candidate.competingOwnerIDs.count == candidate.outsideCompetingCells.count,
                  Set(candidate.competingOwnerIDs).count == candidate.competingOwnerIDs.count,
                  candidate.competingOwnerIDs.allSatisfy({ !$0.isEmpty && $0 != ownerID && $0.utf8.count <= 160 }),
                  candidate.outsideCompetingCells.allSatisfy({ $0 > 0 && $0 < candidate.component.pixelCount }) else { return false }
        }
        var runCount = 0
        var pixels = 0
        var seeds = Set<Int>()
        for component in all {
            guard component.seed >= 0, component.seed < mapFullWidth * mapFullHeight,
                  seeds.insert(component.seed).inserted,
                  component.pixelCount > 0, component.pixelCount <= 262144,
                  component.meanProbability.isFinite,
                  component.meanProbability >= threshold, component.meanProbability <= 1,
                  !component.runs.isEmpty, component.runs.count <= 4096 else { return false }
            var previousY = -1, previousEnd = -1, count = 0
            for run in component.runs {
                guard run.y >= mapOriginY, run.y < mapFullHeight, run.x >= mapOriginX,
                      run.x < mapFullWidth, run.count > 0, run.count <= mapFullWidth - run.x,
                      run.y > previousY || (run.y == previousY && run.x >= previousEnd) else { return false }
                previousY = run.y; previousEnd = run.x + run.count
                count += run.count; runCount += 1
                guard count <= 262144, runCount <= 4096 else { return false }
            }
            guard count == component.pixelCount,
                  let first = component.runs.first,
                  component.seed == first.y * mapFullWidth + first.x else { return false }
            pixels += count
            guard pixels <= 262144 else { return false }
        }
        return true
    }
}

extension NativeOCRDetectorSeedEvidence {
    /// Page-local only. Grid metadata cannot establish identity across images.
    /// Missing or contradictory ownership invalidates the entire union.
    static func preservingUnion(_ groups: [[Self]?]) -> [Self]? {
        guard !groups.isEmpty, groups.count <= 64 else { return nil }
        var owners: [String: Self] = [:]
        var seeds: [Int: Component] = [:]
        var reference: Self?
        var totalRuns = 0, totalPixels = 0
        var probabilityBytes = 0
        var probabilityDigest: String?
        for group in groups {
            guard let group, !group.isEmpty, group.count <= 64 else { return nil }
            for owner in group {
                guard owner.isValid else { return nil }
                if let first = reference {
                    guard owner.provenance == first.provenance, owner.threshold == first.threshold,
                          owner.ownershipVersion == first.ownershipVersion, owner.completeCCScan == first.completeCCScan,
                          owner.mapOriginX == first.mapOriginX, owner.mapOriginY == first.mapOriginY,
                          owner.mapFullWidth == first.mapFullWidth, owner.mapFullHeight == first.mapFullHeight,
                          owner.sourceWidth == first.sourceWidth, owner.sourceHeight == first.sourceHeight else { return nil }
                } else { reference = owner }
                if let prior = owners[owner.ownerID] {
                    guard prior == owner else { return nil }
                    continue
                }
                guard owners.count < 64 else { return nil }
                if let probability = owner.sourceProbabilityROI {
                    if let digest = probabilityDigest, digest != probability.sourceDigest { return nil }
                    probabilityDigest = probability.sourceDigest
                    guard probability.upperBounds.count <= NativeOCRSourceROIProbabilityEvidence.maximumPageBytes - probabilityBytes else { return nil }
                    probabilityBytes += probability.upperBounds.count
                }
                for component in owner.components + (owner.ambiguousComponents ?? []) + (owner.candidateComponents ?? []).map(\.component) {
                    if let previous = seeds[component.seed] {
                        guard owner.ownershipVersion == 2, previous == component else { return nil }
                    } else { seeds[component.seed] = component }
                    totalRuns += component.runs.count
                    totalPixels += component.pixelCount
                    guard totalRuns <= 4096, totalPixels <= 262144 else { return nil }
                }
                owners[owner.ownerID] = owner
            }
        }
        return owners.values.sorted { $0.ownerID < $1.ownerID }
    }
}
