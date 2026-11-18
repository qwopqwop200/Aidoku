import Foundation
import CoreGraphics
import ImageIO

/// Saved accepted-line evaluation. Used only in the explicit replay host mode.
final class HostSavedReaderTrace: @unchecked Sendable {
    static let shared = HostSavedReaderTrace()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var duplicates: [NativeFinalOutputDuplicateResolver.Alias] = []
    private var relations: [String: Any] = [:]
    private var relationDecisions: [[String: Any]] = []
    private var finalFilter: [NativeFinalOutputContentFilter.AuditRow] = []
    func recordFinalFilter(_ rows: [NativeFinalOutputContentFilter.AuditRow]) {
        lock.lock(); defer { lock.unlock() }; finalFilter = rows
    }
    func finalFilterAudit() -> [NativeFinalOutputContentFilter.AuditRow] {
        lock.lock(); defer { lock.unlock() }; return finalFilter
    }
    func recordRelationDecision(_ reason: String, _ ids: [String]) {
        lock.lock(); defer { lock.unlock() }; relationDecisions.append(["reason": reason, "ids": ids])
    }
    @available(macOS 15.0, *)
    func recordRelations(_ regions: [ReaderTranslationRegion], _ scopes: [NativeParagraphFragmentGrouping.TextScope]) {
        lock.lock(); defer { lock.unlock() }
        relations = ["regions": regions.map(HostSavedReaderPostprocess.region), "scopes": scopes.map {
            ["owner": $0.owner, "confidence": $0.confidence, "rect": HostSavedReaderPostprocess.rect($0.box)] as [String: Any]
        }]
    }
    func relationEvidence() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }; var result = relations; result["decisions"] = relationDecisions; return result
    }
    func recordDuplicates(_ result: NativeFinalOutputDuplicateResolver.Result) {
        lock.lock(); defer { lock.unlock() }; duplicates = result.aliases
    }
    func duplicateAliases() -> [NativeFinalOutputDuplicateResolver.Alias] {
        lock.lock(); defer { lock.unlock() }; return duplicates
    }
    func increment(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        counts[key, default: 0] += 1
    }
    func reset() { lock.lock(); defer { lock.unlock() }; counts = [:]; duplicates = []; relations = [:]; relationDecisions = []; finalFilter = [] }
    func snapshot() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
}

@available(macOS 15.0, *)
enum HostSavedReaderInput {
    struct Point: Decodable {
        let x: Double
        let y: Double
        var native: CGPoint { .init(x: x, y: y) }
    }
    struct Rect: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        var native: CGRect { .init(x: x, y: y, width: width, height: height) }
    }
    struct SourceLayout: Decodable {
        let layoutPolygon: [Point]?
        let detectorSignals: [Double]?
    }
    struct Line: Decodable {
        let polygon: [Point]
        let text: String
        let score: Double
        let orientation: String
        let orientationIsEstimated: Bool
        let sourceTileBounds: Rect?
        let erasurePolygons: [[Point]]
        let detectorSeedEvidence: [NativeOCRDetectorSeedEvidence]?
        let acceptedSource: SourceLayout?
        let deriveCurrentGeometry: Bool?
        var native: NativeCoreMLOCRLine {
            if deriveCurrentGeometry == true {
                let raw = polygon.map(\.native)
                let latin = NativeOCRScopeGeometry.isLatinWord(text)
                let latinQuad = latin ? NativeOCRScopeGeometry.alternateHorizontalQuad(raw) : nil
                let basis = NativeOCRDirectionGeometry.enabled("latin") && latin
                    ? (latinQuad ?? NativeOCRDirectionGeometry.directedQuad(raw, longAlong: false)) : latinQuad
                let orientation = basis.map { q -> BrowserOCRSourceOrientation in
                    let dx = q[1].x + q[2].x - q[0].x - q[3].x
                    let dy = q[1].y + q[2].y - q[0].y - q[3].y
                    return abs(dx) >= abs(dy) ? .horizontal : .vertical
                } ?? NativeCoreMLOCRPipeline.orientation(for: raw)
                let base = acceptedSource?.layoutPolygon?.map(\.native)
                let layout = base.map { latin ? (NativeOCRScopeGeometry.alternateHorizontalQuad($0) ?? $0)
                    : (NativeOCRScopeGeometry.canonicalQuad($0) ?? $0) }
                return .init(polygon: latinQuad ?? NativeOCRScopeGeometry.canonicalQuad(raw) ?? raw,
                    text: text, score: score, orientation: orientation, orientationIsEstimated: true,
                    sourceTileBounds: sourceTileBounds?.native, erasurePolygons: erasurePolygons.map { $0.map(\.native) },
                    detectorSeedEvidence: detectorSeedEvidence, acceptedSource: .init(layoutPolygon: layout, detectorSignals: acceptedSource?.detectorSignals))
            }
            return .init(polygon: polygon.map(\.native), text: text, score: score,
                  orientation: .init(tolerantRawValue: orientation),
                  orientationIsEstimated: orientationIsEstimated, sourceTileBounds: sourceTileBounds?.native,
                  erasurePolygons: erasurePolygons.map { $0.map(\.native) }, detectorSeedEvidence: detectorSeedEvidence,
                  acceptedSource:.init(layoutPolygon:acceptedSource?.layoutPolygon?.map(\.native),
                    detectorSignals:acceptedSource?.detectorSignals))
        }
    }
    struct Gap: Decodable {
        let line: Line
        let flanks: [[Point]]
        let edge: Bool
        var native: NativeCoreMLOCRGapLine {
            var value = NativeCoreMLOCRGapLine(line: line.native, flanks: flanks.map { $0.map(\.native) })
            value.edge = edge
            return value
        }
    }
    struct Payload: Decodable {
        let width: Int
        let height: Int
        let lines: [Line]
        let recoveryCandidates: [Line]
        let isolatedLines: [Line]
        let splitLines: [Line]
        let gapLines: [Gap]
        let frameConversionMilliseconds: Double
        let detectionMilliseconds: Double
        let recognitionMilliseconds: Double
        let totalMilliseconds: Double
        let stackedRowSplitMilliseconds: Double
        let unitMilliseconds: Double
        let unitLineCount: Int
    }
    struct Envelope: Decodable {
        let stage: String
        let value: Payload
    }
    struct Result {
        let payload: Payload
        var width: Int { payload.width }
        var height: Int { payload.height }
        var lines: [NativeCoreMLOCRLine] { payload.lines.map(\.native) }
        var recoveryCandidates: [NativeCoreMLOCRLine] { payload.recoveryCandidates.map(\.native) }
        var isolatedLines: [NativeCoreMLOCRLine] { payload.isolatedLines.map(\.native) }
        var splitLines: [NativeCoreMLOCRLine] { payload.splitLines.map(\.native) }
        var gapLines: [NativeCoreMLOCRGapLine] { payload.gapLines.map(\.native) }
        var frameConversionMilliseconds: Double { payload.frameConversionMilliseconds }
        var detectionMilliseconds: Double { payload.detectionMilliseconds }
        var recognitionMilliseconds: Double { payload.recognitionMilliseconds }
        var totalMilliseconds: Double { payload.totalMilliseconds }
        var stackedRowSplitMilliseconds: Double { payload.stackedRowSplitMilliseconds }
        var unitMilliseconds: Double { payload.unitMilliseconds }
        var unitLineCount: Int { payload.unitLineCount }
        // Used only by post-group evidence export, not the grouping decisions.
        var ensembleStageSnapshot: NativeOCREnsembleStageSnapshot? { nil }
    }
    static func load(image: CGImage) throws -> Result {
        guard let path = ProcessInfo.processInfo.environment["AIDOKU_SAVED_READER_INPUT"] else {
            throw HostError.message("Missing saved Reader input")
        }
        let decoder = HostSavedOCRReplay.decoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let envelope = try decoder.decode(Envelope.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard envelope.stage == "native-ocr", envelope.value.width == image.width,
              envelope.value.height == image.height else { throw HostError.message("Saved Reader frame mismatch") }
        HostSavedReaderTrace.shared.increment("saved_native_reads")
        return Result(payload: envelope.value)
    }
}

@available(macOS 15.0, *)
enum HostSavedReaderPostprocess {
    static func rect(_ value: CGRect) -> [String: Double] {
        ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
    }
    static func region(_ value: ReaderTranslationRegion) -> [String: Any] {
        var result: [String: Any] = ["id": value.id, "source": value.source, "rect": rect(value.rect),
            "sourceMemberPolygons": value.sourceMemberPolygons.map { $0.map { [Double($0.x),Double($0.y)] } },
            "polygon": value.polygon.map { [Double($0.x), Double($0.y)] },
            "unitMemberRects": value.unitMemberRects.map(rect), "confidence": value.confidence,
            "auxiliaryInkRects":value.auxiliaryInkRects.map(rect),
            "auxiliaryInkPolygons":value.auxiliaryInkPolygons.map { $0.map { [Double($0.x),Double($0.y)] } },
            "orientation": value.sourceOrientation.rawValue, "occluded_fine_print": value.isOccludedFinePrint]
        if let flag = value.sourceSingleVerticalColumn { result["single_vertical_column"] = flag }
        if let aspect = value.sourceImageAspectRatio { result["source_aspect_ratio"] = aspect }
        if let contour = value.balloonInterior {
            result["balloon_interior"] = ["rect": rect(contour.rect),
                "center": [Double(contour.center.x), Double(contour.center.y)], "spans": contour.spans,
                "verified": contour.contourVerified == true, "model_estimated": contour.modelEstimated == true]
        }
        if let member = value.acceptedSource.membership {
            result["body"] = member.body.sorted()
            result["readings"] = member.readings.sorted()
            result["unknown_dedup"] = member.unknownDedup.sorted()
            result["has_untracked_inputs"] = member.hasUntrackedInputs
            result["table_packet_count"] = member.table.packets.count
        } else { result["has_untracked_inputs"] = true }
        return result
    }
    @MainActor
    private static func recognize(service: ReaderOCRService, image: CGImage,
                                  configuration: ReaderOCRConfiguration) async throws -> [ReaderTranslationRegion] {
        try await NativeFinalOutputDuplicateResolver.$observer.withValue({ result in
            HostSavedReaderTrace.shared.recordDuplicates(result)
        }) {
            try await NativeParagraphFragmentGrouping.$relationObserver.withValue({ regions, scopes in
                HostSavedReaderTrace.shared.recordRelations(regions, scopes)
            }) {
                try await NativeParagraphFragmentGrouping.$relationDecisionObserver.withValue({ reason, ids in
                    HostSavedReaderTrace.shared.recordRelationDecision(reason, ids)
                }) {
                    try await NativeFinalOutputContentFilter.$observer.withValue({ rows in
                        HostSavedReaderTrace.shared.recordFinalFilter(rows)
                    }) {
                        try await service.recognize(image: image, configuration: configuration)
                    }
                }
            }
        }
    }

    @MainActor static func run(_ arguments: [String]) async -> Int32 {
        do {
            guard arguments.count == 3 else { throw HostError.message("Expected saved manifest and output path") }
            let rows = try JSONSerialization.jsonObject(with: Data(contentsOf:
                URL(fileURLWithPath: arguments[1]))) as! [[String: String]]
            let output = URL(fileURLWithPath: arguments[2])
            let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"]!)
            try HostEnvironment.load(root:root)
            try HostResources.prepare(root:root,tier:.manga)
            var reports: [[String: Any]] = []
            let service = ReaderOCRService()
            for row in rows {
                HostSavedReaderTrace.shared.reset()
                var report: [String: Any] = ["page": row["page"]!]
                do {
                    setenv("AIDOKU_SAVED_READER_INPUT", row["native"]!, 1)
                    let imageURL = URL(fileURLWithPath: row["image"]!)
                    guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        throw HostError.message("Saved Reader image decode failed")
                    }
                    let input = try JSONSerialization.jsonObject(with: Data(contentsOf:
                        URL(fileURLWithPath: row["configuration"]!))) as! [String: Any]
                    let configuration = try JSONDecoder().decode(ReaderOCRConfiguration.self,
                        from: JSONSerialization.data(withJSONObject: (input["value"] as! [String: Any])["configuration"]!))
                    let directory = URL(fileURLWithPath: row["directory"]!)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    // Scalar geometry/ownership output is sufficient for this
                    // comparison; avoid duplicating large source evidence stages.
                    let regions:[ReaderTranslationRegion]
                    if row["capture"] == "1" {
                        let dump = HostDumpContext(directory: directory, quiet: true)
                        regions = try await HostDump.$context.withValue(dump) {
                            try await recognize(service: service, image: image, configuration: configuration)
                        }
                        try dump.requireComplete()
                    } else {
                        regions = try await recognize(service: service, image: image, configuration: configuration)
                    }
                    report["regions"] = regions.map(region)
                    // Exercise the production batch-planning boundary without
                    // credentials, a provider request, or any translation call.
                    let plans = ReaderTranslationService.plans(regions: regions, settings: ReaderTranslationSettings())
                    report["preLLMInputIDs"] = plans.flatMap { $0.request.segments.map(\.id) }
                    report["preLLMFiltersEnabled"] = plans.allSatisfy { $0.request.filtersSFX == true && $0.request.filtersBackground == true }
                    report["phases"] = await service.lastPhaseMilliseconds
                } catch { report["error"] = String(describing: error) }
                report["trace"] = HostSavedReaderTrace.shared.snapshot()
                report["relationEvidence"] = HostSavedReaderTrace.shared.relationEvidence()
                report["finalFilter"] = try JSONSerialization.jsonObject(with:
                    JSONEncoder().encode(HostSavedReaderTrace.shared.finalFilterAudit()))
                report["duplicateAliases"] = try JSONSerialization.jsonObject(with:
                    JSONEncoder().encode(HostSavedReaderTrace.shared.duplicateAliases()))
                reports.append(report)
                try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys]).write(to: output, options: .atomic)
                print("Saved Reader page \(row["page"]!) \(report["error"] == nil ? "complete" : "failed")")
                fflush(stdout)
            }
            return 0
        } catch { fputs("Saved Reader replay failed: \(error)\n", stderr); return 1 }
    }
}
