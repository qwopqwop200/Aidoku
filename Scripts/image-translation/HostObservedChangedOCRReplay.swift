import CoreGraphics
import Foundation

/// Explicit, incident-qualified actual NEW-quad REC bank. Never constructs a
/// changed crop's 165-vector or borrows an old polygon, text, confidence or 15.
@available(macOS 15.0, *)
enum HostObservedChangedOCRReplay {
    typealias G = NativeOCRIndividualGeometryHypotheses
    enum Failure: Error { case binding, unsupported, admission, geometry, emptyEvidence }
    struct Reference: Codable, Sendable { let path: String; let SHA256: String }
    private struct Entry: Decodable, Sendable {
        let pageID: String
        let path: String
        let SHA256: String
        let source: String
        let sourceEncodedSHA256: String
        let width: Int
        let height: Int
        let originalModuleBank: String
        let originalModuleBankSHA256: String
        let expectedOriginalContract: HostModuleBank.Contract
        let decodedRows: Int
        let API03AdmittedRows: Int
        let preclaimIncident: Bool
    }
    private struct Manifest: Decodable, Sendable {
        let schema: String
        let pages: [Entry]
        let modelScopeSHA256: String
        let scope: String
        let scopeSHA256: String
        let resources: [String: String]
        let sourceDecoderABI: String
        let COMPLETE: String
        let COMPLETE_SHA256: String
        let preclaimIncident: Bool
        let rawObservation: Bool
        let policyParameterization: String
        let originalSourceFactoryStatusNotOverridden: Bool
        let newModelCalls: Int
    }
    private struct GeometryManifest: Decodable {
        let schema: String
        let pages: [GeometryEntry]
        let GTAtInference: Bool
        let TESTUsed: Bool
    }
    private struct GeometryEntry: Decodable, Sendable {
        let id: String
        let sourceSHA256: String
        let moduleBankSHA256: String
        let expectedOriginalContract: HostModuleBank.Contract
        let fitCutoff: Double
    }
    private struct Point: Decodable, Sendable {
        let x: Double; let y: Double
        var cg: CGPoint { .init(x: x, y: y) }
    }
    private struct Token: Decodable, Sendable {
        let text: String
        let confidence: Double
        let emissionSpan: Span?
        struct Span: Decodable, Sendable {
            let steps: Steps; let timeStepCount: Int; let precedingBlankSteps: Int
            struct Steps: Decodable, Sendable { let lowerBound: Int; let upperBound: Int }
        }
        func native() throws -> NativeCoreMLCTCTokenObservation {
            let span: NativeCoreMLCTCEmissionSpan?
            if let s = emissionSpan {
                guard s.steps.lowerBound >= 0, s.steps.upperBound >= s.steps.lowerBound,
                      s.timeStepCount >= s.steps.upperBound, s.precedingBlankSteps >= 0 else { throw Failure.binding }
                span = .init(steps: s.steps.lowerBound..<s.steps.upperBound,
                    timeStepCount: s.timeStepCount, precedingBlankSteps: s.precedingBlankSteps)
            } else { span = nil }
            return .init(text: text, confidence: confidence, emissionSpan: span)
        }
    }
    private struct Row: Decodable, Sendable {
        struct Agreement: Decodable, Sendable { let rfSupport: Double; let detectorAgreement: Double }
        struct Provenance: Decodable, Sendable { let kind: String; let manifestSHA256: String }
        let sourceIndex: Int
        let polygon: [Point]
        let recognitionAgreement: Agreement
        let agreementProvenance: Provenance
        let tensorIdentity: String
        let modelScopeSHA256: String
        let finalText: String
        let finalConfidence: Double
        let tokenObservations: [Token]
        let admitted: Bool
        let reason: String
        let preclaimIncident: Bool
        func native() throws -> NativeCoreMLRecognizedRegion {
            .init(sourceIndex: sourceIndex, polygon: polygon.map(\.cg), text: finalText,
                confidence: finalConfidence, tokenObservations: try tokenObservations.map { try $0.native() })
        }
    }
    private struct PageFile: Decodable {
        let schema: String
        let pageID: String
        let rows: [Row]
        let rawObservation: Bool
        let preclaimIncident: Bool
        let newModelCallsDuringJoin: Int
    }
    struct Replay: Sendable {
        let lines: [NativeCoreMLOCRLine]
        let geometry: G.Output
        let reads: [NativeCoreMLRecognizedRegion]
        let admission: NativeSimpleRecognitionAdmission.Report?
        let deduplication: NativeOCRPostRecognitionDeduplication.Report
        /// Table ordinal -> NEW bank scheduled sourceIndex, NOT old packet ordinal.
        let tableScheduledSourceIndices: [Int]
        let correction: NativeSimpleOCRBoundaryExpansion.Report
        let receipt: Data
    }
    final class Bank: Sendable {
        private let manifest: Manifest
        private let entries: [String: Entry]
        private let geometryEntries: [String: GeometryEntry]
        let reference: Reference
        let geometryReference: Reference
        init(reference: Reference, geometryReference: Reference) throws {
            let bytes = try Self.checked(reference)
            let m = try JSONDecoder().decode(Manifest.self, from: bytes)
            guard m.schema == "source-bound-actual-REC-cohort-v3-incident", m.pages.count == 685,
                  Set(m.pages.map(\.pageID)).count == 685, m.preclaimIncident, !m.rawObservation,
                  m.newModelCalls == 0, m.originalSourceFactoryStatusNotOverridden,
                  m.sourceDecoderABI == "native-cgimage-opaque-srgb-white-rgba8-v2",
                  m.modelScopeSHA256 == "3d47dd8d8fc872260d8f7aca6de655bf63d2fb1a4e79d396083b0b8c8a6a9430",
                  m.COMPLETE_SHA256 == "fc31624239e58f51bec515e27c26804ff58d7069db3365c4b0a1769ac9695346" else { throw Failure.unsupported }
            let complete = try Self.object(Self.checked(.init(path: m.COMPLETE, SHA256: m.COMPLETE_SHA256)))
            guard complete["preclaimIncident"] as? Bool == true,
                  complete["pages"] as? Int == 685, complete["rows"] as? Int == 11902,
                  let incident = complete["incident"] as? [String: Any],
                  incident["rootAcceptedQualifiedIncidentJoin"] as? Bool == true,
                  incident["preclaimAtLaunch"] as? Bool == false else { throw Failure.binding }
            _ = try Self.checked(.init(path: m.scope, SHA256: m.scopeSHA256))
            guard geometryReference.SHA256 == "8a8dad741a2efa26eb2f782972a9010c0ad1c4fe8b6222d596f0b3e173fc5bdb" else { throw Failure.binding }
            let g = try JSONDecoder().decode(GeometryManifest.self, from: Self.checked(geometryReference))
            guard g.schema == "frozen-directional-candidate-source-bound-REC-v1", !g.GTAtInference, !g.TESTUsed,
                  g.pages.count == 685, Set(g.pages.map(\.id)).count == 685 else { throw Failure.binding }
            manifest = m; entries = Dictionary(uniqueKeysWithValues: m.pages.map { ($0.pageID, $0) })
            geometryEntries = Dictionary(uniqueKeysWithValues: g.pages.map { ($0.id, $0) })
            self.reference = reference
            self.geometryReference = geometryReference
        }
        private static func checked(_ reference: Reference) throws -> Data {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: reference.path))
            guard HostModuleBank.digest(bytes) == reference.SHA256 else { throw Failure.binding }
            return bytes
        }
        private static func object(_ bytes: Data) throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.binding }
            return object
        }

        func replay(pageID: String, original: HostObservedOCRReplay.Page, expectedOriginalModuleSHA256: String,
                    recognitionAdmission: NativeSimpleRecognitionAdmission.Configuration?,
                    deduplication: NativeSimpleOCRDedup.Configuration) throws -> Replay {
            guard let e = entries[pageID], let g = geometryEntries[pageID], e.preclaimIncident,
                  e.expectedOriginalContract == original.contract,
                  g.expectedOriginalContract == original.contract,
                  g.sourceSHA256 == e.sourceEncodedSHA256, g.moduleBankSHA256 == expectedOriginalModuleSHA256,
                  e.originalModuleBankSHA256 == expectedOriginalModuleSHA256,
                  e.sourceEncodedSHA256 == original.contract.sourceEncodedSHA256,
                  e.width == original.contract.width, e.height == original.contract.height,
                  URL(fileURLWithPath: e.source).resolvingSymlinksInPath() == original.originalSourceURL.resolvingSymlinksInPath(),
                  manifest.resources["pprecTreeSHA256"] == original.contract.modelSHA256["ppocr-rec"],
                  original.observedSource165Indices == Array(original.postBBox.individuals.indices) else { throw Failure.binding }
            // Original measured boundary4 only chooses geometry. No full165 is
            // attached to the changed output or used for its admission/packets.
            let signals = try original.source165.map { row -> NativeSimpleOCRBoundaryExpansion.BoundarySignals in
                guard row.count == 165 else { throw Failure.binding }
                return .init(edge01: row[61], edge12: row[82], edge23: row[103], edge30: row[124])
            }
            let boundary = try NativeSimpleOCRBoundaryExpansion.apply(original.postBBox, signals: signals,
                configuration: .init(threshold: g.fitCutoff, margin: 0.025))
            _ = try Self.checked(.init(path: e.originalModuleBank, SHA256: expectedOriginalModuleSHA256))
            let bytes = try Self.checked(.init(path: e.path, SHA256: e.SHA256))
            let object = try Self.object(bytes)
            let p = try HostTaggedObservationDecoder.decode(PageFile.self, value: object, blob: { _ in throw Failure.binding })
            guard p.schema == "changed-quad-rematerialized-REC-v1", p.pageID == pageID,
                  p.preclaimIncident, !p.rawObservation, p.newModelCallsDuringJoin == 0,
                  p.rows.count == e.decodedRows,
                  p.rows.map(\.sourceIndex) == Array(original.observedScheduled.individuals.indices),
                  p.rows.filter(\.admitted).count == e.API03AdmittedRows else { throw Failure.binding }
            if p.rows.isEmpty {
                guard let empty = object["observedEmptyEvidence"] as? [String: Any],
                      empty["status"] as? String == "observed-empty" else { throw Failure.emptyEvidence }
            }
            for row in p.rows {
                guard row.preclaimIncident, row.modelScopeSHA256 == manifest.modelScopeSHA256,
                      row.tensorIdentity.count == 64,
                      row.agreementProvenance.kind == "actual-new-outputquad-extracted2",
                      row.agreementProvenance.manifestSHA256 == geometryReference.SHA256,
                      row.polygon.count == 4, row.polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                      row.polygon.map({ G.Point(x: $0.x, y: $0.y) }) == boundary.output.individuals[original.observedSource165Indices[row.sourceIndex]].polygon else { throw Failure.geometry }
                let keep = !row.finalText.isEmpty && row.finalConfidence.isFinite && row.finalConfidence >= 0.3
                let reason = row.finalText.isEmpty ? "empty" : !row.finalConfidence.isFinite ? "nonFiniteConfidence" : row.finalConfidence < 0.3 ? "belowThreshold" : "accepted"
                guard keep == row.admitted, reason == row.reason else { throw Failure.admission }
            }
            var reads = try p.rows.filter(\.admitted).map { try $0.native() }
            let admission: NativeSimpleRecognitionAdmission.Report?
            if let configuration = recognitionAdmission {
                let agreement = p.rows.map { NativeOCRPreRecognitionFeatures.RecognitionAgreement(
                    rfSupport: $0.recognitionAgreement.rfSupport, detectorAgreement: $0.recognitionAgreement.detectorAgreement) }
                let result = try NativeSimpleRecognitionAdmission.apply(reads, agreement: agreement,
                    source165Indices: Array(p.rows.indices), configuration: configuration)
                reads = result.reads; admission = result.report
            } else { admission = nil }
            let geometry = G.selecting(boundary.output, indices: reads.map { original.observedSource165Indices[$0.sourceIndex] })
            let result = try NativeSimpleOCRDedup.apply(geometry, reads: reads, configuration: deduplication)
            let packets = try NativeSimpleOCRBoundaryExpansionRuntime.packets(reads: reads,
                originalAnchors: original.postBBox, source165Indices: original.observedSource165Indices,
                originals: original.originalDetectors, preserveOriginalMetadata: true)
            let bound = NativeOCRAcceptedSource.bindingPrimary(packets, width: e.width, height: e.height)
            let lines = result.report.keptIndices.map { index -> NativeCoreMLOCRLine in
                var line = bound[index]
                if let m = line.acceptedSource.membership {
                    let aliases = Set(result.report.replacements.filter { $0.retainedIndex == index }.map(\.inputIndex))
                    line.acceptedSource = .init(.init(table: m.table, body: m.body, readings: m.readings,
                        unknownDedup: aliases, hasUntrackedInputs: false), detectorSignals: line.acceptedSource.detectorSignals)
                }
                return line
            }
            let receipt = try JSONSerialization.data(withJSONObject: ["bank": ["path": reference.path, "SHA256": reference.SHA256],
                "page": ["path": e.path, "SHA256": e.SHA256], "COMPLETE_SHA256": manifest.COMPLETE_SHA256,
                "modelScopeSHA256": manifest.modelScopeSHA256, "preclaimIncident": true,
                "geometryManifest": ["path": geometryReference.path, "SHA256": geometryReference.SHA256],
                "incident": object["incident"] ?? NSNull(), "policyParameterization": manifest.policyParameterization,
                "packetOrdinalDomain": "new-actual-rec-after-optional-gate-before-nms",
                "originalModuleManifestSHA256": expectedOriginalModuleSHA256,
                "newCorePredictions": 0, "old165UsedForNewGeometry": false], options: [.sortedKeys, .withoutEscapingSlashes])
            return .init(lines: lines, geometry: result.output, reads: reads, admission: admission,
                deduplication: result.report, tableScheduledSourceIndices: reads.map(\.sourceIndex),
                correction: boundary.report, receipt: receipt)
        }
    }
}
