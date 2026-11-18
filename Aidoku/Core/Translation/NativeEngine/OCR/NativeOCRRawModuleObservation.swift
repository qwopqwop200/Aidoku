import CoreGraphics
import Foundation

/// Opt-in source-only module transport. Nothing here predicts, extracts features,
/// changes admission, writes files or looks up GT. The caller owns persistence.
@available(iOS 18.0, *)
enum NativeOCRRawModuleObservation {
    typealias G = NativeOCRIndividualGeometryHypotheses
    static let schema = "native-ocr-raw-module-observation-v1"

    struct Metadata: Codable, Sendable {
        var sourceEncodedSHA256: String? = nil
        var configurationSHA256: String? = nil
        var producerSHA256: String? = nil
        var modelSHA256: [String: String] = [:]
    }
    struct Binding: Codable, Equatable, Sendable {
        let requestID: String
        let sourceImageIdentity: String
        let width: Int
        let height: Int
        let sourceAnchorMode: String
        let runtimePolicyVersion: String
    }
    enum Stage: String, Codable, CaseIterable, Sendable {
        case originalDetector, proposals, bboxAdmission, preRecognition
        case postRecognition, deduplication, acceptedMembership
    }
    enum CaptureFailure: String, Error, Codable, Sendable {
        case rowBudget, byteBudget, vertexBudget, invalidLimits, featureShape, membershipBinding
    }
    struct Limits: Sendable {
        var maximumRows = 16_384
        var maximumBytes = 64 * 1024 * 1024
        var maximumVertices = 1_048_576
    }

    /// Row-major binary64 little endian, including exact NaN payloads, infinities
    /// and signed zero. JSON numeric conversion/imputation is never involved.
    struct Float64Matrix: Sendable {
        let rows: Int
        let columns: Int
        let bytes: Data
        static let encoding = "ieee754-binary64-little-endian-row-major-v1"

        init(_ values: [[Double]], columns: Int, limits: Limits) throws {
            guard limits.maximumRows >= 0, limits.maximumBytes >= 0, limits.maximumVertices >= 0 else {
                throw CaptureFailure.invalidLimits
            }
            guard values.count <= limits.maximumRows else { throw CaptureFailure.rowBudget }
            guard columns > 0, values.allSatisfy({ $0.count == columns }) else { throw CaptureFailure.featureShape }
            if !values.isEmpty {
                guard columns <= limits.maximumBytes / 8,
                      values.count <= limits.maximumBytes / 8 / columns else { throw CaptureFailure.byteBudget }
            }
            var data = Data(count: values.count * columns * 8)
            data.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                var offset = 0
                for row in values {
                    for value in row {
                        var bits = value.bitPattern.littleEndian
                        withUnsafeBytes(of: &bits) { source in
                            UnsafeMutableRawBufferPointer(rebasing: target[offset..<(offset + 8)]).copyMemory(from: source)
                        }
                        offset += 8
                    }
                }
            }
            rows = values.count; self.columns = columns; bytes = data
        }
    }
    struct OutputMember: Sendable {
        let lineOrdinal: Int
        let tableOrdinal: Int?
        let body: Set<Int>
        let readings: Set<Int>
        let unknownDedup: Set<Int>
        let hasUntrackedInputs: Bool
    }
    struct MembershipArchive: Sendable {
        /// Actual immutable tables, not a new table built only from survivors.
        let tables: [NativeOCRAcceptedSource.PacketTable]
        let outputs: [OutputMember]
    }
    enum Payload: Sendable {
        /// Array offsets are the actual original detector indices. No ancestry
        /// is inferred from recognized/sampling/erasure polygon overlap.
        case originalDetector([NativeCoreMLDetectionBox])
        case proposals(G.Output)
        case bboxAdmission(bank: G.Output, report: NativeOCRBBoxConfidenceAdmission.Report)
        /// scheduled ordinal is the recognizer's supplied sourceIndex, NOT an
        /// invented original DET ID. input provenance authenticates original IDs.
        case preRecognition(input: G.Output, scheduled: G.Output, source165: Float64Matrix,
                            report: NativeOCRPreRecognitionFilter.Report?)
        case postRecognition(scheduled: G.Output, input: G.Output, reads: [NativeCoreMLRecognizedRegion],
                             source165Indices: [Int], accepted165: Float64Matrix, source166: Float64Matrix)
        case deduplication(input: G.Output, output: G.Output, report: NativeOCRPostRecognitionDeduplication.Report)
        case acceptedMembership(MembershipArchive)
        /// Never a truncated successful stage, and never an OCR error.
        case unavailable(stage: Stage, reason: CaptureFailure)
    }
    struct Event: Sendable {
        let binding: Binding
        /// Exporter-supplied attestation, not independently authenticated here.
        let metadata: Metadata
        let payload: Payload
    }
    struct Observer: Sendable {
        let metadata: Metadata
        var limits = Limits()
        let receive: @Sendable (Event) -> Void

        private func deliver(_ stage: Stage, binding: Binding, _ make: (inout Budget) throws -> Payload) {
            let payload: Payload
            do {
                var budget = try Budget(limits)
                payload = try make(&budget)
            } catch {
                payload = .unavailable(stage: stage, reason: error as? CaptureFailure ?? .byteBudget)
            }
            receive(.init(binding: binding, metadata: metadata, payload: payload))
        }
        func originalDetector(_ boxes: [NativeCoreMLDetectionBox], binding: Binding) {
            deliver(.originalDetector, binding: binding) { budget in
                try budget.rows(boxes.count)
                for box in boxes { try budget.detector(box) }
                return .originalDetector(boxes)
            }
        }
        func proposals(_ bank: G.Output, binding: Binding) {
            deliver(.proposals, binding: binding) { budget in
                try budget.bank(bank); return .proposals(bank)
            }
        }
        func bboxAdmission(_ value: NativeOCRBBoxConfidenceAdmission.Production, binding: Binding) {
            deliver(.bboxAdmission, binding: binding) { budget in
                try budget.bank(value.output); try budget.rows(value.report.rows.count)
                try budget.elements(value.report.rows.count, stride: 24)
                return .bboxAdmission(bank: value.output, report: value.report)
            }
        }
        func preRecognition(input: G.Output, scheduled: G.Output, source165: [[Double]],
                            report: NativeOCRPreRecognitionFilter.Report?, binding: Binding) {
            deliver(.preRecognition, binding: binding) { budget in
                guard source165.count == input.individuals.count,
                      report.map({ $0.inputCount == source165.count && $0.scores.count == source165.count }) ?? true else {
                    throw CaptureFailure.featureShape
                }
                try budget.bank(input); try budget.bank(scheduled)
                if let report {
                    try budget.rows(report.scores.count); try budget.elements(report.scores.count, stride: 16)
                    try budget.elements(report.keptIndices.count, stride: 8)
                    try budget.elements(report.missingEvidenceKeptIndices.count, stride: 8)
                }
                let matrix = try budget.matrix(source165, columns: 165)
                return .preRecognition(input: input, scheduled: scheduled, source165: matrix, report: report)
            }
        }
        func postRecognition(scheduled: G.Output, input: G.Output, reads: [NativeCoreMLRecognizedRegion],
                             source165Indices: [Int], accepted165: [[Double]], source166: [[Double]], binding: Binding) {
            deliver(.postRecognition, binding: binding) { budget in
                let n = input.individuals.count
                guard reads.count == n, source165Indices.count == n, accepted165.count == n, source166.count == n else {
                    throw CaptureFailure.featureShape
                }
                try budget.bank(scheduled); try budget.bank(input); try budget.rows(reads.count)
                try budget.elements(source165Indices.count, stride: 8)
                for read in reads {
                    try budget.points(read.polygon.count); try budget.string(read.text)
                    try budget.rows(read.tokenObservations.count)
                    for token in read.tokenObservations { try budget.string(token.text); try budget.bytes(64) }
                }
                let prefix = try budget.matrix(accepted165, columns: 165)
                let matrix = try budget.matrix(source166, columns: 166)
                return .postRecognition(scheduled: scheduled, input: input, reads: reads,
                    source165Indices: source165Indices, accepted165: prefix, source166: matrix)
            }
        }
        func deduplication(input: G.Output, result: NativeOCRPostRecognitionDeduplication.Result, binding: Binding) {
            deliver(.deduplication, binding: binding) { budget in
                try budget.bank(input); try budget.bank(result.output)
                try budget.rows(result.report.replacements.count)
                try budget.elements(result.report.replacements.count, stride: 24)
                try budget.elements(result.report.keptIndices.count, stride: 8)
                return .deduplication(input: input, output: result.output, report: result.report)
            }
        }
        func acceptedMembership(_ lines: [NativeCoreMLOCRLine], binding: Binding) {
            deliver(.acceptedMembership, binding: binding) { budget in
                try budget.rows(lines.count)
                var tables = [NativeOCRAcceptedSource.PacketTable](), outputs = [OutputMember]()
                var ordinals = [ObjectIdentifier: Int]()
                for (index, line) in lines.enumerated() {
                    guard let member = line.acceptedSource.membership else {
                        outputs.append(.init(lineOrdinal: index, tableOrdinal: nil, body: [], readings: [],
                            unknownDedup: [], hasUntrackedInputs: true))
                        continue
                    }
                    let table = member.table
                    guard table.width == binding.width, table.height == binding.height,
                          member.body.union(member.readings).union(member.unknownDedup).allSatisfy(table.packets.indices.contains) else {
                        throw CaptureFailure.membershipBinding
                    }
                    let key = ObjectIdentifier(table)
                    let ordinal: Int
                    if let old = ordinals[key] { ordinal = old }
                    else {
                        ordinal = tables.count; ordinals[key] = ordinal; tables.append(table)
                        try budget.rows(table.packets.count)
                        for packet in table.packets {
                            try budget.points(packet.polygon.count); try budget.string(packet.text)
                            try budget.polygons(packet.erasurePolygons)
                            if let polygon = packet.layoutPolygon { try budget.points(polygon.count) }
                            if let seeds = packet.detectorSeedEvidence {
                                try budget.rows(seeds.count)
                                for seed in seeds { try budget.seed(seed) }
                            }
                            try budget.elements(packet.detectorSignals?.count ?? 0, stride: 8)
                        }
                    }
                    try budget.elements(member.body.count + member.readings.count + member.unknownDedup.count, stride: 8)
                    outputs.append(.init(lineOrdinal: index, tableOrdinal: ordinal, body: member.body, readings: member.readings,
                        unknownDedup: member.unknownDedup, hasUntrackedInputs: member.hasUntrackedInputs))
                }
                return .acceptedMembership(.init(tables: tables, outputs: outputs))
            }
        }
    }

    private struct Budget {
        let limits: Limits
        var remainingBytes: Int
        var remainingVertices: Int
        init(_ limits: Limits) throws {
            guard limits.maximumRows >= 0, limits.maximumBytes >= 0, limits.maximumVertices >= 0 else {
                throw CaptureFailure.invalidLimits
            }
            self.limits = limits; remainingBytes = limits.maximumBytes; remainingVertices = limits.maximumVertices
        }
        func rows(_ count: Int) throws {
            guard count <= limits.maximumRows else { throw CaptureFailure.rowBudget }
        }
        mutating func bytes(_ count: Int) throws {
            guard count <= remainingBytes else { throw CaptureFailure.byteBudget }
            remainingBytes -= count
        }
        mutating func elements(_ count: Int, stride: Int) throws {
            guard count <= remainingBytes / stride else { throw CaptureFailure.byteBudget }
            try bytes(count * stride)
        }
        mutating func points(_ count: Int) throws {
            guard count <= remainingVertices else { throw CaptureFailure.vertexBudget }
            remainingVertices -= count; try elements(count, stride: 16)
        }
        mutating func polygons(_ polygons: [[CGPoint]]) throws {
            try rows(polygons.count)
            for polygon in polygons { try points(polygon.count) }
        }
        mutating func string(_ value: String) throws { try bytes(value.utf8.count) }
        mutating func component(_ value: NativeOCRDetectorSeedEvidence.Component) throws {
            try elements(value.runs.count, stride: 24); try bytes(32)
        }
        mutating func seed(_ value: NativeOCRDetectorSeedEvidence) throws {
            try string(value.ownerID); try string(value.provenance); try bytes(128)
            if let roi = value.sourceProbabilityROI { try bytes(roi.upperBounds.count); try string(roi.sourceDigest) }
            try rows(value.components.count)
            for c in value.components { try component(c) }
            if let ambiguous = value.ambiguousComponents {
                try rows(ambiguous.count)
                for c in ambiguous { try component(c) }
            }
            if let candidates = value.candidateComponents {
                try rows(candidates.count)
                for c in candidates {
                    try component(c.component); try rows(c.competingOwnerIDs.count)
                    for owner in c.competingOwnerIDs { try string(owner) }
                    try elements(c.outsideCompetingCells.count, stride: 8)
                }
            }
        }
        mutating func detector(_ box: NativeCoreMLDetectionBox) throws {
            try bytes(128); try points(box.polygon.count); try polygons(box.erasurePolygons)
            if let q = box.recognitionPolygon { try points(q.count) }
            if let q = box.alternateRecognitionPolygon { try points(q.count) }
            try polygons(box.finePrintRetryPolygons)
            if let seed = box.detectorSeedEvidence { try self.seed(seed) }
            if let columns = box.recognitionColumnEvidence {
                try polygons(columns.polygons); try string(columns.provenance)
                try elements(columns.componentPixels.count, stride: 8)
                try elements(columns.meanProbabilities.count, stride: 8)
                try elements(columns.componentSeeds.count, stride: 8); try rows(columns.cellRuns.count)
                for runs in columns.cellRuns { try elements(runs.count, stride: 24) }
                if let clearance = columns.recognitionClearance {
                    try polygons(clearance.polygons); try string(clearance.provenance)
                    try elements(clearance.supportedCells.count, stride: 8)
                    try elements(clearance.maximumPaddingFractions?.count ?? 0, stride: 8)
                }
            }
        }
        mutating func record(_ record: G.Record) throws {
            try points(record.polygon.count); try string(record.requestID); try string(record.alternativeID)
            try elements(record.sourceMembers.count, stride: 8); try bytes(64)
        }
        mutating func bank(_ bank: G.Output) throws {
            try rows(bank.individuals.count); try rows(bank.events.count)
            try elements(bank.events.count, stride: 64)
            for event in bank.events { try string(event.alternativeID) }
            for row in bank.individuals {
                try bytes(64); try points(row.polygon.count)
                try rows(row.provenance.count); try rows(row.refinements.count)
                for proof in row.provenance { try record(proof) }
                for refinement in row.refinements { try record(refinement.record) }
            }
        }
        mutating func matrix(_ values: [[Double]], columns: Int) throws -> Float64Matrix {
            let result = try Float64Matrix(values, columns: columns,
                limits: .init(maximumRows: limits.maximumRows, maximumBytes: remainingBytes, maximumVertices: remainingVertices))
            try bytes(result.bytes.count)
            return result
        }
    }
}
