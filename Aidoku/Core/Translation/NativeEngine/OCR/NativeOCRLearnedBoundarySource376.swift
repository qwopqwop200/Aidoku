import Foundation

/// Private feature composition only; CURRENT raw/full-seed authority and numeric
/// page are constructed from the SAME originals. No query-provenance overload.
enum NativeOCRLearnedBoundarySource376 {
    typealias Owner = NativeOCRDBRawProducerOwnerResolution
    typealias Kernel = NativeOCRDBOwnedNormal32V2
    typealias G = NativeOCRIndividualGeometryHypotheses
    enum Failure: Error { case contextBindingMismatch, numericABIMismatch, sourceContextUnavailable }
    struct PreparedContext: Sendable {
        let contextID: String
        let frame: Owner.FrameBinding
        let originalCount: Int
        let actualRefinementCount: Int
        private let ownerIndex: Owner.Index
        private let numericPage: Kernel.PreparedPage
        fileprivate init(ownerIndex: Owner.Index, numericPage: Kernel.PreparedPage) {
            self.contextID = ownerIndex.contextID
            self.frame = ownerIndex.frame
            self.originalCount = ownerIndex.originalCount
            self.actualRefinementCount = ownerIndex.refinementCount
            self.ownerIndex = ownerIndex
            self.numericPage = numericPage
        }
        fileprivate func extract(_ quad: [[Double]]) throws -> (Owner.Resolution, Kernel.Output) {
            let resolution = Owner.resolve(queryQuad: quad, index: ownerIndex)
            guard resolution.contextID == contextID,
                  resolution.authABI == NativeOCRLearnedBoundaryGenerator376.sourceOwnerResolutionABI,
                  resolution.stageABI == NativeOCRLearnedBoundaryGenerator376.sourceOwnerContextStage,
                  resolution.fullOwnerSeeds.count == resolution.ownerIndices.count else {
                throw Failure.contextBindingMismatch
            }
            // The only source of these indices is the bound CURRENT owner index.
            // A caller cannot inject an arbitrary index list or another page's Resolution.
            return (resolution, Kernel.extract(quad: quad, page: numericPage,
                authenticatedOwnerIndices: resolution.ownerIndices))
        }
    }
    struct Output: Sendable {
        let features: [Double]
        let ownership: Owner.Resolution
        let numericReason: String?
    }
    private struct NumericWire: Encodable {
        let width: Int
        let height: Int
        let boxes: [Owner.Original]
    }
    static func prepare(originals: [Owner.Original], width: Int, height: Int,
                        actualPrecomputedRefinements: [G.Refinement]?,
                        frame: Owner.FrameBinding) throws -> PreparedContext {
        guard Kernel.abi == NativeOCRLearnedBoundaryGenerator376.sourceDBNormalABI else {
            throw Failure.numericABIMismatch
        }
        guard let actualPrecomputedRefinements else { throw Failure.sourceContextUnavailable }
        let sourceRecords = actualPrecomputedRefinements.map { refinement in
            Owner.Refinement(head: refinement.head.rawValue,
                record: .init(requestID: refinement.record.requestID,
                    origin: refinement.record.origin.rawValue,
                    polygon: refinement.record.polygon.map { [$0.x, $0.y] },
                    sourceMembers: refinement.record.sourceMembers.sorted(),
                    originalDetectorIndex: refinement.record.originalDetectorIndex))
        }
        let index = try Owner.prepare(originals: originals, width: width, height: height,
            actualPrecomputedRefinements: sourceRecords, frame: frame)
        guard width > 0, height > 0, index.frameOperationBound, index.producerContextAvailable else {
            throw Failure.sourceContextUnavailable
        }
        // Lossless typed transport to the numeric-only wire, from the SAME full raw objects.
        // Full native seed objects remain retained by the independent owner authority.
        let wire = try JSONEncoder().encode(NumericWire(width: width, height: height, boxes: originals))
        let numericRaw = try JSONDecoder().decode(Kernel.RawPage.self, from: wire)
        return .init(ownerIndex: index, numericPage: Kernel.prepare(numericRaw))
    }
    /// source344 MUST be the frozen V3 features for this SAME queryQuad. No per-row
    /// model selection: missing ownership still returns a full376 vector with zero32.
    static func extract(source344: [Double], queryQuad: [[Double]],
                        context: PreparedContext) throws -> Output? {
        guard source344.count == 344, source344.allSatisfy(\.isFinite) else { return nil }
        let (resolution, block) = try context.extract(queryQuad)
        guard block.features.count == 32, block.features.allSatisfy(\.isFinite) else { return nil }
        return .init(features: source344 + block.features, ownership: resolution, numericReason: block.reason)
    }
}
