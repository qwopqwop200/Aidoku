import Foundation
import CoreGraphics
import CryptoKit

/// Thin live adapter. The caller supplies its CURRENT canonical opaque-sRGB
/// frame and every original source box. No files, GT, reads or model invocation.
/// Parent owns the explicit flag and distinct .closedContour head integration.
@available(iOS 18.0, *)
enum NativeOCRSourceClosedContourGeometry {
    typealias SourceFrame = NativeOCRRGBAFrame
    typealias Helper = NativeOCRClosedContourGeometry
    typealias Geometry = NativeOCRIndividualGeometryHypotheses
    typealias SpanHelper = NativeOCRClosedContourComponentSpanGeometry
    enum AdmissionPolicy: String, Codable, Sendable { case strictOnly, strictThenComponentSpan }
    enum SelectedAdmission: String, Codable, Sendable { case strict, componentSpanFallback }
    static let requiredSourcePixelABI = "native-cgimage-opaque-srgb-white-rgba8-v2"
    static let producerABI = "source-closed-contour-v1"
    static let componentSpanProducerABI = "source-closed-component-span-v1"

    struct SourceSeedProof: Codable, Equatable, Sendable {
        let sourceIndex: Int
        /// Exact original packet, including all per-owner ROI and uncertainty.
        let evidence: NativeOCRDetectorSeedEvidence
    }
    struct Proof: Codable, Equatable, Sendable {
        let requestID: String
        let producerABI: String
        /// Caller guarantees canonical decode and immutable source-operation binding.
        let requiredSourcePixelABI: String
        let frameWidth: Int
        let frameHeight: Int
        let cropBounds: Helper.Rect
        let tightlyPackedRGBSHA256: String
        let refinement: Geometry.Refinement
        let assessment: Helper.Assessment
        let sourceSeed: SourceSeedProof
        let recognitionIndependent: Bool
        let configuredPolicy: AdmissionPolicy
        let selectedAdmission: SelectedAdmission
        /// assessment remains the exact OLD strict helper return. It may have
        /// no candidate when the separately recorded span fallback is selected.
        let componentSpanAssessment: SpanHelper.Assessment?
    }
    struct Production: Sendable {
        let proofs: [Proof]
        let decisions: [Helper.Assessment]
        let reasons: [String]
        let componentSpanDecisions: [SpanHelper.Assessment]
        var refinements: [Geometry.Refinement] { proofs.map(\.refinement) }
    }

    /// Preserve array order and every uncertain/unread/zero-score source as a barrier.
    static func makeSources(_ originals: [NativeCoreMLDetectionBox]) -> [Helper.Source] {
        originals.map { box in
            .init(polygon: box.polygon.map { .init(x: Double($0.x), y: Double($0.y)) },
                  detectorSeedEvidence: box.detectorSeedEvidence)
        }
    }

    /// Copy only the helper-required ROI; strip row padding, never rescale or
    /// recompose a noncanonical frame. Canonical decoder supplies alpha255.
    static func cropRGB(frame: SourceFrame, rect: Helper.Rect,
                        cancellationCheck: () throws -> Void = {}) throws -> Helper.RGBROI? {
        try cancellationCheck()
        guard frame.width > 0, frame.height > 0, frame.width <= 16_384, frame.height <= 16_384,
              frame.width <= 16_777_216 / frame.height,
              rect.x >= 0, rect.y >= 0, rect.x <= frame.width, rect.y <= frame.height,
              rect.width > 0, rect.height > 0,
              rect.width <= frame.width - rect.x, rect.height <= frame.height - rect.y,
              rect.width <= 1_000_000 / rect.height else { return nil }
        var rgb = [UInt8](repeating: 0, count: rect.width * rect.height * 3)
        for y in 0..<rect.height {
            if y.isMultiple(of: 32) { try cancellationCheck() }
            let sourceRow = (rect.y + y) * frame.bytesPerRow + rect.x * 4
            let destinationRow = y * rect.width * 3
            for x in 0..<rect.width {
                let source = sourceRow + x * 4, destination = destinationRow + x * 3
                guard frame.bytes[source + 3] == 255 else { return nil }
                rgb[destination] = frame.bytes[source]
                rgb[destination + 1] = frame.bytes[source + 1]
                rgb[destination + 2] = frame.bytes[source + 2]
            }
        }
        try cancellationCheck()
        return .init(sourceWidth: frame.width, sourceHeight: frame.height, rect: rect, bytes: rgb)
    }

    /// Explicitly disabled by default. At most one source-owned result per raw
    /// anchor, always before recognition admission. Cancellation discards partial work.
    static func measure(requestID: String, frame: SourceFrame,
                        originals: [NativeCoreMLDetectionBox], enabled: Bool = false,
                        policy: AdmissionPolicy = .strictOnly,
                        cancellationCheck: () throws -> Void = {}) throws -> Production {
        func abstain(_ reason: String) -> Production { .init(proofs: [], decisions: [], reasons: [reason], componentSpanDecisions: []) }
        guard enabled else { return abstain("disabled") }
        try cancellationCheck()
        guard !requestID.isEmpty, requestID.utf8.count <= 256, originals.count <= 4096,
              frame.width > 0, frame.height > 0, frame.width <= 16_384, frame.height <= 16_384,
              frame.width <= 16_777_216 / frame.height else { return abstain("invalid-source-frame-or-budget") }
        let sources = makeSources(originals)
        let spanSources: [SpanHelper.Source] = policy == .strictThenComponentSpan ? sources.map {
            .init(polygon: $0.polygon.map { .init(x: $0.x, y: $0.y) }, detectorSeedEvidence: $0.detectorSeedEvidence)
        } : []
        var proofs: [Proof] = [], decisions: [Helper.Assessment] = [], reasons: [String] = []
        var spanDecisions: [SpanHelper.Assessment] = []
        for index in sources.indices {
            try cancellationCheck()
            guard let rect = Helper.requiredROI(original: sources[index], width: frame.width, height: frame.height) else {
                decisions.append(.init(sourceIndex: index, reason: "source-ROI-budget-or-invalid-quad",
                    cropBounds: nil, sourceOwnedPixels: 0, acceptedEdgeRegions: 0,
                    sourceOwnedCoverage: nil, borderVetoes: 0, foreignVetoes: 0, candidate: nil))
                continue
            }
            guard let rgb = try cropRGB(frame: frame, rect: rect, cancellationCheck: cancellationCheck) else {
                decisions.append(.init(sourceIndex: index, reason: "invalid-or-noncanonical-source-ROI",
                    cropBounds: rect, sourceOwnedPixels: 0, acceptedEdgeRegions: 0,
                    sourceOwnedCoverage: nil, borderVetoes: 0, foreignVetoes: 0, candidate: nil))
                continue
            }
            try cancellationCheck()
            let assessment = Helper.measure(anchor: index, originals: sources, roi: rgb)
            try cancellationCheck()
            decisions.append(assessment)
            var selectedPolygon: [Geometry.Point]?, selectedPhase: SelectedAdmission = .strict
            var spanAssessment: SpanHelper.Assessment?
            if let candidate = assessment.candidate {
                // Old strict FIRST: do not run or select another helper for an
                // already accepted owner; old records and producer IDs unchanged.
                guard candidate.anchorSourceIndex == index, candidate.sourceParent == index,
                      candidate.sourceMembers == [index], candidate.recognitionIndependent,
                      candidate.nativeSeedPacketUnchanged else {
                    reasons.append("source-\(index)-candidate-lineage-unresolved"); continue
                }
                selectedPolygon = candidate.polygon.map { .init(x: $0.x, y: $0.y) }
            } else if policy == .strictThenComponentSpan {
                try cancellationCheck()
                let converted = SpanHelper.RGBROI(sourceWidth: rgb.sourceWidth, sourceHeight: rgb.sourceHeight,
                    rect: .init(x: rect.x, y: rect.y, width: rect.width, height: rect.height), bytes: rgb.bytes)
                let span = SpanHelper.measure(anchor: index, originals: spanSources, roi: converted)
                try cancellationCheck()
                spanDecisions.append(span); spanAssessment = span
                guard let candidate = span.candidate else { continue }
                guard candidate.anchorSourceIndex == index, candidate.sourceParent == index,
                      candidate.sourceMembers == [index], candidate.recognitionIndependent,
                      candidate.nativeSeedPacketUnchanged else {
                    reasons.append("source-\(index)-span-lineage-unresolved"); continue
                }
                selectedPolygon = candidate.polygon.map { .init(x: $0.x, y: $0.y) }
                selectedPhase = .componentSpanFallback
            }
            guard let polygon = selectedPolygon, let seed = originals[index].detectorSeedEvidence else { continue }
            let selectedProducer = selectedPhase == .strict ? producerABI : componentSpanProducerABI
            let record = Geometry.Record(requestID: requestID, sourceIndex: index, sourceParent: index,
                sourceMembers: [index], alternativeID: "\(selectedProducer)/raw/\(index)",
                origin: .sourceRefinement, originalDetectorIndex: index,
                polygon: polygon)
            let refinement = Geometry.Refinement(head: .closedContour, record: record)
            proofs.append(.init(requestID: requestID, producerABI: selectedProducer,
                requiredSourcePixelABI: requiredSourcePixelABI, frameWidth: frame.width, frameHeight: frame.height,
                cropBounds: rect,
                tightlyPackedRGBSHA256: SHA256.hash(data: Data(rgb.bytes)).map { String(format: "%02x", $0) }.joined(),
                refinement: refinement, assessment: assessment,
                sourceSeed: .init(sourceIndex: index, evidence: seed), recognitionIndependent: true,
                configuredPolicy: policy, selectedAdmission: selectedPhase, componentSpanAssessment: spanAssessment))
        }
        try cancellationCheck()
        return .init(proofs: proofs, decisions: decisions, reasons: reasons, componentSpanDecisions: spanDecisions)
    }

}
