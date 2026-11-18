import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// HOST-ONLY SOURCE arm. The only payload input is the actual pre-source019
/// caller trace;025 is opened AFTER inference, solely as a comparison target.
/// There is no DB/Reader/DET/REC/AOT/LLM/render operation in this helper.
@available(macOS 15.0, *)
enum HostMinimalSourceArm {
    enum Failure: Error { case request, binding, unavailableEvidence, RFReplay, cohort }
    struct Reference: Decodable { let path: String; let SHA256: String }
    struct Request: Decodable {
        let schema: String
        let pageID: String
        let split: String
        let source: Reference
        let preSourceCaller: Reference
        let sourceEvidenceAbsence: Reference
        let baselineSourceOutput: Reference
        let outputDirectory: String
    }
    private static func digest(_ data: Data) -> String { NativeFrozenSourceSHA256.hex(data) }
    private static func checked(_ r: Reference) throws -> Data {
        let data = try Data(contentsOf: URL(fileURLWithPath: r.path))
        guard digest(data) == r.SHA256 else { throw Failure.binding }
        return data
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.binding }
        return result
    }
    private static func write(_ value: [String: Any], to path: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            .write(to: path, options: .atomic)
    }

    @MainActor
    static func run(root: URL, arguments: [String]) async -> Int32 {
        var output: URL?
        var audit: [String: Any] = ["schema": "actual-minimal64-source-only-arm-v1", "DETCalls": 0,
            "AOTCalls": 0, "RECCalls": 0, "LLMCalls": 0, "DBRequested": false,
            "renderInvoked": false, "TESTPages": 0, "wholeOriginalVisualOpened": false,
            "singleCanaryOnly": true, "generalizationClaim": false]
        do {
            // This historical0636 arm stays frozen to legacy64. Reproduce it
            // explicitly with AIDOKU_SOURCE_INFERENCE_POLICY=minimal-m1-p9-body64-v1.
            // The presence95 policy must use its own reviewed activation path.
            guard arguments.count == 2, NativeSourceInferencePolicy.selected == .minimalM1P9Body64,
                  ProcessInfo.processInfo.environment["AIDOKU_HOST_RF_RAW_MODE"] == "replay-only",
                  NativeRFRawCachePolicy.enabled else { throw Failure.request }
            let requestBytes = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
            let request = try JSONDecoder().decode(Request.self, from: requestBytes)
            guard request.schema == "actual-minimal64-source-only-arm-request-v1",
                  request.pageID == "0636", request.split == "train" else { throw Failure.request }
            let caller = try object(checked(request.preSourceCaller))
            let absence = try object(checked(request.sourceEvidenceAbsence))
            guard caller["stage"] as? String == "render-payload", let value = caller["value"] as? [String: Any],
                  let items = value["items"] as? [[String: Any]], !items.isEmpty, items.count <= 16,
                  absence["stage"] as? String == "saved-source-context", let missing = absence["value"] as? [String: Any],
                  missing["status"] as? String == "unavailable-no-source-binding",
                  missing["legacyOCRProducerAttestationInvented"] as? Bool == false else { throw Failure.unavailableEvidence }
            // Keep literal source geometry/text/selection and actual target text
            // only for caller eligibility. No inherited font, style, prior,
            // appearance receipt, display geometry or native025 answer survives.
            let derived = Set(["fontSize", "sourceFontSize", "lineHeight", "rotationPlannedFontSize",
                "x", "y", "width", "height", "paddingLeft", "paddingRight", "paddingTop", "paddingBottom",
                "rotation", "nearUprightRotation", "fontScript", "wrappingScript", "columnLayout", "clipsText",
                "allowsAutomaticFontRecovery", "smallTextReference"])
            let derivedPrefixes = ["sourceFont", "sourceWeight", "sourceAppearance", "sourcePredictedStyle",
                "sourceRequestedDisplayFont", "sourceContourPaint", "renderSource", "ensemble"]
            var removed = Set<String>()
            let projected = try items.map { item -> [String: Any] in
                guard let text = item["sourceOriginalText"] as? String, !text.isEmpty,
                      item["sourceBounds"] as? [Double] != nil else { throw Failure.cohort }
                let keys = Set(item.keys.filter { key in derived.contains(key) || derivedPrefixes.contains(where: key.hasPrefix) })
                removed.formUnion(keys)
                return item.filter { !keys.contains($0.key) }
            }
            let sourceBytes = try checked(request.source)
            guard let decoder = CGImageSourceCreateWithData(sourceBytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(decoder, 0, nil) else { throw Failure.binding }
            let directory = URL(fileURLWithPath: request.outputDirectory, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw Failure.request }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); output = directory
            try write(["schema": "actual019-source-field-projection-v1", "sourceEncodedSHA256": request.source.SHA256,
                "callerSHA256": request.preSourceCaller.SHA256, "sourceEvidenceAbsenceSHA256": request.sourceEvidenceAbsence.SHA256,
                "items": projected, "removedDerivedFields": removed.sorted(),
                "projectionPolicy": "remove only explicit inherited font/style/target-layout fields; preserve every other literal019 caller field",
                "sourceEvidence": [String: Any](), "evidenceAuthority": "actual022 missing binding; no invented OCR producer or pixel evidence",
                "input025Read": false, "fontPriorAnswersRead": false, "styleAnswersRead": false,
                "fieldUnits": ["sourceBounds": "normalized original-source x,y,width,height",
                    "sourcePolygon": "normalized original-source polygon", "sourceMemberPolygons": "original-source pixels when present",
                    "unitMemberRects": "normalized original-source rectangles", "text": "actual approximate caller target; eligibility only",
                    "sourceOriginalText": "actual literal original source; Unicode prior/text measurement authority"]],
                to: directory.appendingPathComponent("SOURCE-INPUT-PROJECTION.json"))
            try HostRFRawReplay.preflight()
            let resources = root.appendingPathComponent("Aidoku/Resources/Translation")
            let dump = HostDumpContext(directory: directory, quiet: true, sourceURL: URL(fileURLWithPath: request.source.path))
            let start = ProcessInfo.processInfo.systemUptime
            let result = try HostDump.$context.withValue(dump) {
                let backend = try NativeOperationalSourceInference(bundle: HostResources.bundle,
                    modelDirectory: resources.appendingPathComponent("SourceModels"),
                    fontResources: resources.appendingPathComponent("SourceReferenceFonts.bundle"))
                return try backend.annotate(source: image, items: projected, sourceEvidence: [:])
            }
            let seconds = ProcessInfo.processInfo.systemUptime - start
            guard result.items.count == projected.count, let masks = result.sourceSegmentationMasks,
                  masks.entries.count == projected.count, let rf = result.sourceRF else { throw Failure.cohort }
            let replay = HostRFRawReplay.diagnostics(sourceIdentity: rf.sourceIdentity)
            guard let records = replay["rawRecords"] as? [[String: Any]], !records.isEmpty,
                  records.allSatisfy({ $0["disposition"] as? String == "disk-replay" }) else { throw Failure.RFReplay }
            var maskRows = [[String: Any]]()
            for (index, entry) in masks.entries.enumerated() {
                let bytes = Data(entry.mask), filename = String(format: "%03d.u8", index)
                try bytes.write(to: directory.appendingPathComponent(filename), options: .atomic)
                maskRows.append(["ownerIndex": index, "id": projected[index]["id"] ?? NSNull(),
                    "SHA256": digest(bytes), "file": filename, "width": Int(entry.crop.width), "height": Int(entry.crop.height),
                    "cropBounds": [entry.crop.minX, entry.crop.minY, entry.crop.maxX, entry.crop.maxY].map(Double.init),
                    "foregroundPixels": entry.mask.filter { $0 != 0 }.count])
            }
            // Actual new predictions are fixed before025 is opened. Compare
            // only by preserved source id/text/bounds; never use its derived
            // sourceMemberPolygons/font/style as fresh constructor evidence.
            let oldDocument = try object(checked(request.baselineSourceOutput))
            guard oldDocument["stage"] as? String == "live-source-appearance",
                  let oldValue = oldDocument["value"] as? [String: Any],
                  let oldItems = oldValue["items"] as? [[String: Any]], oldItems.count == result.items.count else { throw Failure.binding }
            var comparison = [[String: Any]]()
            for i in result.items.indices {
                let before = oldItems[i], after = result.items[i]
                guard before["id"] as? String == projected[i]["id"] as? String,
                      before["sourceOriginalText"] as? String == projected[i]["sourceOriginalText"] as? String,
                      before["sourceBounds"] as? [Double] == projected[i]["sourceBounds"] as? [Double] else { throw Failure.binding }
                comparison.append(["id": projected[i]["id"] ?? NSNull(),
                    "erasureSHA256Old": before["sourceErasureMaskSHA256"] ?? NSNull(), "erasureSHA256New": maskRows[i]["SHA256"]!,
                    "erasureSHA256Equal": before["sourceErasureMaskSHA256"] as? String == maskRows[i]["SHA256"] as? String,
                    "fontOld": before["sourceFontSize"] ?? NSNull(), "fontNew": after["sourceFontSize"] ?? NSNull(),
                    "fontGroupOld": before["sourceFontFitGroupID"] ?? NSNull(), "fontGroupNew": after["sourceFontFitGroupID"] ?? NSNull(),
                    "styleOld": before["sourcePredictedStyle"] ?? NSNull(), "styleNew": after["sourcePredictedStyle"] ?? NSNull(),
                    "BODYOld": before["sourceWeightEvidence"] ?? NSNull(), "BODYNew": after["sourceWeightEvidence"] ?? NSNull()])
            }
            audit.merge(["requestSHA256": digest(requestBytes), "sourceEncodedSHA256": request.source.SHA256,
                "sourceRGBIdentity": rf.sourceIdentity, "sourceWidth": image.width, "sourceHeight": image.height,
                "inputCallerSHA256": request.preSourceCaller.SHA256, "baseline025SHA256": request.baselineSourceOutput.SHA256,
                "baseline025UsedAsInput": false, "actualInputEvidenceAbsent": true,
                "policy": NativeSourceInferencePolicy.cacheProjection, "seconds": seconds,
                "consumerBinarySHA256": try HostRenderProvenance.fileSHA256(URL(fileURLWithPath: CommandLine.arguments[0])),
                "actualSourceOutputItems": result.items, "masks": maskRows, "comparison": comparison, "RFReplay": replay,
                "sourceRoleModels": "fresh actual primary62+5style+BODY; cached RF raw through current decoder",
                "fieldUnits": ["sourceFontSize": "original-source pixels", "fontSize": "current SOURCE assembly value in original-source pixels, not a new target layout measurement",
                    "sourcePredictedStyle.outline.widthPx": "calibrated original-source pixels", "mask": "full crop row-major UInt8 0/255; original-source pixels",
                    "sourceFontFitGroupID": "source-only same-page grouping identity"],
                "status": "actual-minimal64-source-only-completed"], uniquingKeysWith: { _, new in new })
            try write(audit, to: directory.appendingPathComponent("RESULT.json")); try dump.requireComplete()
            return 0
        } catch {
            audit["status"] = "failed-no-synthetic-success"; audit["error"] = String(describing: error)
            if let output { try? write(audit, to: output.appendingPathComponent("RESULT.json")) }
            fputs("Minimal SOURCE arm failed: \(error)\n", stderr)
            return 1
        }
    }
}
