#!/usr/bin/env swift
// macOS launcher: compiles the current production engine, then forwards CLI arguments.
import Foundation
import CryptoKit
import Darwin

let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let sources = root.appendingPathComponent("Aidoku/Core/Translation")
let support = root.appendingPathComponent("Scripts/image-translation")
// A frozen paired experiment may still be using the default binary. An explicit
// fixed private cache lets a new causal candidate compile without replacing it.
let privateCache = ProcessInfo.processInfo.environment["AIDOKU_IMAGE_HOST_CACHE"]
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
let cache = privateCache.map { URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL }
    ?? root.appendingPathComponent("build/image-translation-host")
let manager = FileManager.default
func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
func slice(_ text: String, _ start: String, _ end: String) throws -> String {
    guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex) else {
        throw NSError(domain: "ImageTranslation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Production source boundary changed: \(start) / \(end)"])
    }
    return String(text[a.lowerBound..<b.lowerBound])
}
@discardableResult
func run(_ command: String, _ args: [String], environment: [String: String]? = nil) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = args
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

// This launcher cannot import the host module. Keep this canonical producer
// encoding byte-identical to HostModuleBankBootstrap.producerDigest; its inputs
// are ACTUAL frozen compile paths and bytes, not their unadapted originals.
enum FrozenModuleBankProducer {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func canonicalDigest(_ files: [String: String]) -> String {
        func quoted(_ value: String) -> String {
            var result = "\""
            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 34: result += "\\\""
                case 92: result += "\\\\"
                case 8: result += "\\b"
                case 9: result += "\\t"
                case 10: result += "\\n"
                case 12: result += "\\f"
                case 13: result += "\\r"
                case 32...126: result.unicodeScalars.append(scalar)
                case 0...0xffff: result += String(format: "\\u%04x", scalar.value)
                default:
                    let code = scalar.value - 0x10000
                    result += String(format: "\\u%04x\\u%04x", 0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff))
                }
            }
            return result + "\""
        }
        let keys = files.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        return digest(Data(("{" + keys.map { quoted($0) + ":" + quoted(files[$0]!) }.joined(separator: ",") + "}").utf8))
    }
    static func capture(_ files: [URL]) throws -> [String: String] {
        guard !files.isEmpty, Set(files.map(\.lastPathComponent)).count == files.count,
              Set(files.map(\.path)).count == files.count else {
            throw NSError(domain: "FrozenModuleBankProducer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Duplicate compiled source path/basename"])
        }
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.path, digest(try Data(contentsOf: $0))) })
    }
    static func schemas(_ files: [URL]) throws -> [String: String] {
        guard let observation = files.first(where: { $0.lastPathComponent == "NativeOCRRawModuleObservation.swift" }) else {
            throw NSError(domain: "FrozenModuleBankProducer", code: 2)
        }
        let text = try String(contentsOf: observation, encoding: .utf8)
        let expression = try NSRegularExpression(pattern: #"static let schema\s*=\s*"([^"]+)""#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range)
        guard matches.count == 1, let schemaRange = Range(matches[0].range(at: 1), in: text) else {
            throw NSError(domain: "FrozenModuleBankProducer", code: 3)
        }
        let schema = String(text[schemaRange])
        var result = Dictionary(uniqueKeysWithValues: ["originalDetector", "proposals", "bboxAdmission",
            "preRecognition", "postRecognition", "deduplication", "acceptedMembership"].map { ($0, schema) })
        result["recRequested"] = "native-rec-observation-v1"
        result["recDecoded"] = "native-rec-observation-v1"
        return result
    }
    static func manifest(fingerprint: String, files: [String: String], schemas: [String: String]) -> [String: Any] {
        ["schema": "aidoku-module-bank-producer-v1", "pipelineFingerprint": fingerprint,
         "producerSHA256": canonicalDigest(files), "compiledSourceSHA256": files, "stageSchemas": schemas]
    }
    static func valid(_ url: URL, fingerprint: String, files: [String: String], schemas: [String: String]) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return value["schema"] as? String == "aidoku-module-bank-producer-v1" &&
            value["pipelineFingerprint"] as? String == fingerprint &&
            value["compiledSourceSHA256"] as? [String: String] == files &&
            value["producerSHA256"] as? String == canonicalDigest(files) &&
            value["stageSchemas"] as? [String: String] == schemas
    }
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args.contains("--help") || args.contains("-h") {
        print(try read(support.appendingPathComponent("help.txt")))
        exit(0)
    }
    guard #available(macOS 15.0, *) else { fatalError("Requires macOS 15 or newer.") }
    try manager.createDirectory(at: cache, withIntermediateDirectories: true)
    let lockDescriptor = open(cache.appendingPathComponent("build.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX) == 0 else { throw NSError(domain: "BuildLock", code: 1) }
    var holdsBuildLock = true
    defer { if holdsBuildLock { flock(lockDescriptor, LOCK_UN); close(lockDescriptor) } }
    if args.first == "--admitted-aot-request" {
        guard args.count == 2 else { throw NSError(domain: "Arguments", code: 1) }
        let routeFiles = ["NativeAOTResidentModel.swift", "NativeAdmittedAOTPageRoute.swift"].map {
            sources.appendingPathComponent("NativeEngine/Overlay/" + $0)
        } + [support.appendingPathComponent("HostAdmittedAOT.swift")]
        let directory = cache.appendingPathComponent("admitted-aot", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("image-admitted-aot")
        let stamp = directory.appendingPathComponent("fingerprint")
        let digest = SHA256.hash(data: try routeFiles.reduce(into: Data("admitted-aot-compiler-v1".utf8)) {
            $0.append(try Data(contentsOf: $1))
        }).map { String(format: "%02x", $0) }.joined()
        if (try? read(stamp)) != digest || !manager.fileExists(atPath: binary.path) {
            // Fixed cache and per-file output map retain incremental build state.
            var map: [String: [String: String]] = ["": ["swift-dependencies": directory.appendingPathComponent("master.swiftdeps").path]]
            for file in routeFiles {
                let name = file.deletingPathExtension().lastPathComponent
                map[file.path] = ["object": directory.appendingPathComponent(name + ".o").path,
                    "swift-dependencies": directory.appendingPathComponent(name + ".swiftdeps").path]
            }
            let mapURL = directory.appendingPathComponent("output-map.json")
            try JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]).write(to: mapURL, options: .atomic)
            let status = try run("/usr/bin/xcrun", ["swiftc", "-O", "-incremental", "-enable-batch-mode", "-j1",
                "-parse-as-library", "-module-name", "AdmittedAOTHost", "-target", "arm64-apple-macos15.0",
                "-output-file-map", mapURL.path] + routeFiles.map(\.path) + ["-o", binary.path])
            guard status == 0 else { exit(status) }
            try digest.write(to: stamp, atomically: true, encoding: .utf8)
        }
        if ProcessInfo.processInfo.environment["AIDOKU_HOST_BUILD_ONLY"] == "1" { exit(0) }
        flock(lockDescriptor, LOCK_UN); close(lockDescriptor); holdsBuildLock = false
        exit(try run(binary.path, [URL(fileURLWithPath: args[1]).standardizedFileURL.path]))
    }
    if args.first == "--visualize-run" {
        guard args.count == 2 else { throw NSError(domain: "Arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: --visualize-run RUN_OR_IMAGE_DIRECTORY"]) }
        let analysisFiles = ["HostAnalysis.swift", "AnalysisMain.swift"].map { support.appendingPathComponent($0) }
        let digest = SHA256.hash(data: try analysisFiles.reduce(into: Data()) { $0.append(try Data(contentsOf: $1)) }).map { String(format: "%02x", $0) }.joined()
        let binary = cache.appendingPathComponent("image-analysis")
        let stamp = cache.appendingPathComponent("analysis-fingerprint")
        if (try? read(stamp)) != digest || !manager.fileExists(atPath: binary.path) {
            let status = try run("/usr/bin/xcrun", ["swiftc", "-O", "-parse-as-library",
                "-module-cache-path", cache.appendingPathComponent("module-cache").path]
                + analysisFiles.map(\.path) + ["-o", binary.path])
            guard status == 0 else { exit(status) }
            try digest.write(to: stamp, atomically: true, encoding: .utf8)
        }
        flock(lockDescriptor, LOCK_UN); close(lockDescriptor); holdsBuildLock = false
        exit(try run(binary.path, [URL(fileURLWithPath: args[1]).standardizedFileURL.path, root.path]))
    }
    var generated = "import Foundation\nimport CoreGraphics\nimport AppKit\nimport CoreText\nimport os\n"
    let observedReaderReplay = ProcessInfo.processInfo.environment["AIDOKU_HOST_OBSERVED_READER_REPLAY"] == "1"
    let savedReaderReplay = observedReaderReplay || ProcessInfo.processInfo.environment["AIDOKU_HOST_SAVED_READER_REPLAY"] == "1"
    generated += "enum HostBuildMode { static let savedReaderReplay = " +
        (savedReaderReplay ? "true" : "false") + " }\n"
    let settings = try read(sources.appendingPathComponent("ReaderTranslationSettings.swift"))
    generated += try slice(settings, "enum IPhoneOCRModelTier", "struct ReaderCustomTranslationSettings")
    let reader = try read(sources.appendingPathComponent("ReaderTranslationService.swift"))
    generated += try slice(reader, "struct ReaderTranslationRegion:", "enum ReaderTranslationGeometry")
    var ocr = try slice(reader, "actor ReaderOCRService", "actor ReaderTranslationService")
    // Host-only protocol injection; absent probe context delegates to normal models.
    let probeFactoryAnchor = "let created = NativeCoreMLOCRPipeline("
    guard ocr.components(separatedBy: probeFactoryAnchor).count == 2 else {
        throw NSError(domain: "FirstPassProbeFactoryAdapter", code: 1)
    }
    ocr = ocr.replacingOccurrences(of: probeFactoryAnchor,
        with: "let created = HostFirstPassGeometryProbe.makePipeline(")
    // Explicit evaluation mode: replay the full production Reader grouping on
    // saved accepted lines. Normal OCR and the iOS source remain unchanged.
    if savedReaderReplay {
        let start = "        let result = try await pipeline.recognize("
        let end = "        try Task.checkCancellation()\n        ReaderTranslationDiagnostics.record(\"ocr_end\""
        guard let a = ocr.range(of:start), let b = ocr.range(of:end,range:a.upperBound..<ocr.endIndex) else {
            throw NSError(domain:"SavedReaderReplayAdapter",code:1)
        }
        let ingress = observedReaderReplay
            ? "HostObservedReaderInput.load(image: image, configuration: configuration)"
            : "HostSavedReaderInput.load(image: image)"
        ocr.replaceSubrange(a.lowerBound..<b.lowerBound, with: "        let result = try \(ingress)\n")
    }
    let groupingTraceAnchor = "            let before = joined.count\n            joined = NativeParagraphFragmentGrouping.reconcilingObservations"
    guard ocr.components(separatedBy:groupingTraceAnchor).count == 2 else {
        throw NSError(domain:"HostGroupingTraceAdapter",code:1)
    }
    ocr = ocr.replacingOccurrences(of:groupingTraceAnchor,with:"""
                if ProcessInfo.processInfo.environment["AIDOKU_OCR_GROUPING_AUDIT"] == "1" {
                    HostDump.capture("paragraph-grouping-input",joined)
                    HostDump.capture("paragraph-grouping-scopes",auxiliaryLayout.primitives.filter { $0.semanticClass == .text })
                }
                let before = joined.count
                joined = NativeParagraphFragmentGrouping.reconcilingObservations
    """)
    ocr = ocr.replacingOccurrences(of:"            lastPhaseMilliseconds[\"reconciledSourceObservations\"] = Double(before - joined.count)",with:"""
                lastPhaseMilliseconds["reconciledSourceObservations"] = Double(before - joined.count)
                if ProcessInfo.processInfo.environment["AIDOKU_OCR_GROUPING_AUDIT"] == "1" {
                    HostDump.capture("paragraph-grouping-output",joined)
                }
    """)
    let pipelineConstruction = "existingDetector: existingDetector\n"
    guard ocr.components(separatedBy: pipelineConstruction).count == 2 else {
        throw NSError(domain: "ModelBundleAdapter", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected one OCR pipeline detector handoff"])
    }
    ocr = ocr.replacingOccurrences(of: pipelineConstruction, with: "existingDetector: existingDetector, bundle: HostResources.bundle\n")
    // Platform-only resource bridge for the cold DET-only lifecycle; same fixed model.
    guard ocr.components(separatedBy: "NativeCoreMLDetector(modelResourceName:profile.detectorResourceName,").count == 2 else {
        throw NSError(domain: "DetectorBundleAdapter", code: 1)
    }
    ocr = ocr.replacingOccurrences(of:"NativeCoreMLDetector(modelResourceName:profile.detectorResourceName,",
        with:"NativeCoreMLDetector(bundle:HostResources.bundle,modelResourceName:profile.detectorResourceName,")
    ocr = ocr.replacingOccurrences(of: "let postprocessStartedAt =", with: "HostDump.capture(\"native-ocr\", result)\n        let postprocessStartedAt =")
    let packetPublication = "                try NativeMainEnsembleEvidenceStore.shared.register(ocr: packet, original: image, source: evidenceSource)"
    guard ocr.components(separatedBy: packetPublication).count == 2 else {
        throw NSError(domain: "HostCurrentOCRPacketAdapter", code: 1)
    }
    ocr = ocr.replacingOccurrences(of: packetPublication,
        with: packetPublication + "\n                HostDump.context?.captureOCR(packet)")
    ocr = ocr.replacingOccurrences(of: "NSValue(cgRect:", with: "NSValue(rect:")
    let rfProducerURL = "producer.modelURL()"
    guard ocr.components(separatedBy: rfProducerURL).count == 2 else {
        throw NSError(domain: "RFModelBundleAdapter", code: 1)
    }
    ocr = ocr.replacingOccurrences(of: rfProducerURL, with: "producer.modelURL(bundle: HostResources.bundle)")
    // Save compact auxiliary evidence, never all mask logits. This links the
    // actual selected model output to source ownership decisions for auditing.
    let rfTraceAnchor = "        var lines = NativeOCRAcceptedSource.bindingPrimary("
    guard ocr.components(separatedBy: rfTraceAnchor).count == 2 else {
        throw NSError(domain: "RFLayoutTraceAdapter", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Expected exactly one accepted-source binding for RF evidence trace"])
    }
    ocr = ocr.replacingOccurrences(of: rfTraceAnchor, with: """
        if let auxiliaryLayout {
            if NativeRFRawCachePolicy.enabled {
                HostDump.capture("rf-raw-cache-ocr", NativeRFRawCacheDiagnostics.snapshot(sourceIdentity: auxiliaryLayout.imageIdentity))
            }
            HostDump.capture("rf-layout-evidence", [
                "imageIdentity": auxiliaryLayout.imageIdentity,
                "sourceWidth": auxiliaryLayout.sourceWidth,
                "sourceHeight": auxiliaryLayout.sourceHeight,
                "computeUnits": auxiliaryLayout.computeUnits,
                "strictStockDeviceParityPassed": auxiliaryLayout.strictStockDeviceParityPassed,
                "maskQueriesOmittedByBudget": auxiliaryLayout.maskQueriesOmittedByBudget,
                "primitives": auxiliaryLayout.primitives.map { primitive -> [String: Any] in
                    ["queryID": primitive.queryID, "class": primitive.semanticClass.canonicalClassID,
                     "confidence": primitive.confidence, "sourceBounds": primitive.sourceBounds,
                     "maskAvailable": primitive.mask != nil]
                }
            ])
        }
    """ + "\n" + rfTraceAnchor)
    let acceptedSourceAnchor = "        let lineCount = lines.count +"
    guard ocr.components(separatedBy: acceptedSourceAnchor).count == 2 else {
        throw NSError(domain: "RFGapTraceAdapter", code: 1)
    }
    ocr = ocr.replacingOccurrences(of: acceptedSourceAnchor,
        with: """
        HostDump.capture("accepted-source-output", lines.map { line -> [String: Any] in
            ["text": line.text, "polygon": line.polygon.map { [Double($0.x), Double($0.y)] },
             "score": line.score, "orientation": line.orientation.rawValue,
             "erasurePolygonCount": line.erasurePolygons.count]
        })
    """ + "\n" + acceptedSourceAnchor)
    let rfOwnershipAnchor = "        var phases: [String: Double]"
    ocr = ocr.replacingOccurrences(of: rfOwnershipAnchor, with: """
        if let layoutOwnership {
            HostDump.capture("rf-source-ownership", [
                "imageIdentity": layoutOwnership.imageIdentity,
                "verifiedPixelTests": layoutOwnership.verifiedPixelTests,
                "owners": layoutOwnership.owners.map { owner -> [String: Any] in
                    ["sourceBounds": owner.sourceBounds, "queryID": owner.queryID as Any,
                     "fullyOutsideQueries": owner.fullyOutsideQueries.sorted()]
                }
            ])
        }
    """ + "\n" + rfOwnershipAnchor)
    ocr = ocr.replacingOccurrences(of: "        return joined", with: "        HostDump.capture(\"ocr-phases\", lastPhaseMilliseconds)\n        HostDump.capture(\"grouped-regions\", joined)\n        return joined")
    for (anchor, name, value) in [
        ("        joined = group(lines)", "initial-grouping", "joined"),
        ("            joined = grouped.regions", "simple-paragraph-output", "joined"),
        ("        let balloonStart =", "recovery-input", "result.recoveryCandidates"),
        ("        lastPhaseMilliseconds[\"balloonMerge\"]", "after-recovery", "joined"),
        ("        let countBeforeChromaticJoin = joined.count", "balloon-interiors", "joined"),
        ("        // A colored contour", "chromatic-grouping", "joined")
    ] {
        guard ocr.contains(anchor) else {
            throw NSError(domain: "HostAssembly", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing production trace anchor: \(name)"])
        }
        if name == "initial-grouping" || name == "simple-paragraph-output" {
            ocr = ocr.replacingOccurrences(of: anchor, with: anchor + "\n        HostDump.capture(\"" + name + "\", " + value + ")")
        } else {
            ocr = ocr.replacingOccurrences(of: anchor, with: "        HostDump.capture(\"" + name + "\", " + value + ")\n" + anchor)
        }
    }
    generated += ocr
    let rotation = try read(sources.appendingPathComponent("NativeEngine/Overlay/BrowserOverlayRotation.swift"))
    generated += rotation.replacingOccurrences(of: "import UIKit", with: "import AppKit")
    let overlay = try read(sources.appendingPathComponent("NativeEngine/Overlay/BrowserOverlayView.swift"))
    generated += try slice(reader, "enum ReaderTranslationGeometry", "@available(iOS 18.0, *)")
    let background = try read(root.appendingPathComponent("Aidoku/Features/Reader/Translation/ReaderTranslationBackgroundImage.swift"))
    generated += background.replacingOccurrences(of: "import UIKit", with: "import AppKit")
    let exporter = try read(root.appendingPathComponent("Aidoku/Features/Reader/Translation/ReaderTranslationImageExporter.swift"))
    generated += "enum HostProductionExportSizing {\n" + (try slice(exporter, "    static func outputSize(for pixels:", "    static func render(image:")) + "}\n"
    generated += "enum HostProductionExporter {\n" + (try slice(exporter, "    struct ExportLayers:", "    /// Core Image contexts")) + "}\n"

    // The compatibility name is retained for saved CLI payload callers; geometry
    // comes directly from the same typed native layout planner as the reader.
    generated += """
    enum HostProductionLayout {
        static func layoutPayload(items: [BrowserOverlayItem], imageSize: CGSize, sourceRect: CGRect,
                                  settings: IPhoneOverlaySettings, targetLanguage: String, viewport: CGSize,
                                  measurementCache: BrowserOverlayTextMeasurementCache? = BrowserOverlayTextMeasurementCache()) -> [[String: Any]] {
            NativeTranslationLayoutPlanner.payload(items: items, imageSize: imageSize, sourceRect: sourceRect,
                settings: settings, targetLanguage: targetLanguage, viewport: viewport, measurementCache: measurementCache)
        }
    }
    """
    generated += "\n"
    generated += try slice(overlay, "struct BrowserOverlayItem:", "struct BrowserOverlayVisibility")
    generated += try slice(overlay, "struct BrowserOverlayTextMeasurementCacheStatistics", "struct BrowserOverlayPositionedLayoutCacheInput")
    generated += try slice(overlay, "struct BrowserOverlayTextFlow", "struct BrowserSidePanelSessionHistory")
    generated += try slice(overlay, "enum BrowserOverlayFont", "private struct OverlayPalette")
    generated += "enum ReaderTranslationService {\n" +
        (try slice(reader, "    private static func mandatoryPageSettings(", "    typealias Progress")) + "}\n"
    // Reuse the actual progressive and persistence boundaries in saved-response
    // evaluation; do not maintain host-only copies of their decisions.
    guard let progressStart = reader.range(of: "actor ReaderTranslationProgress {") else {
        throw NSError(domain: "ReaderProgressAdapter", code: 1)
    }
    generated += String(reader[progressStart.lowerBound...])
    let diskCache = try read(sources.appendingPathComponent("ReaderTranslationDiskCache.swift"))
    generated += try slice(diskCache, "struct ReaderTranslationStoredRegion:", "/// Persistent global settings only:")
    let service = try read(sources.appendingPathComponent("NativeEngine/Translation/TranslationService.swift"))
    generated += try slice(service, "enum TranslationPerformanceDiagnostics", "enum MetadataTranslationPriority")
    generated += try slice(service, "enum MetadataTranslationPriority", "actor TranslationService")
    // Compile the actual app actor, including canonical IDs, exact cache,
    // in-flight sharing and page single-attempt policy; no host copy.
    generated += try slice(service, "actor TranslationService", "enum BoundedTranslationBatchExecutor")
    let log = try read(root.appendingPathComponent("Aidoku/Features/Reader/Translation/TranslationPerformanceFileLog.swift"))
    generated += try slice(log, "enum TranslationPerformanceFileLog", "    private static let sink")
    generated += "static func record(_ event: Event, fields: [Field: Double]) { HostDump.capture(\"metric-\" + event.rawValue, fields.reduce(into: [String: Double]()) { $0[$1.key.rawValue] = $1.value }) }\n}\n"
    let credential = try read(sources.appendingPathComponent("NativeEngine/Translation/KeychainTranslationCredentialStore.swift"))
    generated += try slice(credential, "protocol TranslationCredentialProviding", "protocol TranslationCredentialManaging")
    // Discover every OCR Swift source, including source-paint wrapper and all four family helpers.
    var files = try manager.contentsOfDirectory(at: sources.appendingPathComponent("NativeEngine/OCR"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ReaderSupplementalOCR.swift" }.sorted { $0.path < $1.path }
    files += try manager.contentsOfDirectory(at: sources.appendingPathComponent("NativeEngine/Layout"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    for name in ["ReaderTranslationEnclosedBackground", "ReaderTranslationBalloonMerger", "ReaderTranslationStaggeredQuoteMerger",
                 "ReaderTranslationQuotedStack", "ReaderTranslationOrderedSourceRoute",
                 "NativeJapaneseLexicalContinuationGrouping", "NativeOverlappingSourceUnitGrouping", "NativeSourceDotRailOwnership",
                 "NativeFinalOutputDuplicateResolver", "NativeFinalOutputDuplicateResolver+Pipeline",
                 "NativeFinalOutputContentFilter", "NativeFinalOutputContentFilter+Pipeline",
                 "NativePostLLMContentReclassifier", "NativePostMergeSignalFilter",
                 "ReaderTranslationCacheCodec",
                 "NativeParagraphFragmentGrouping", "NativeSimpleParagraphGrouping",
                 "NativeParagraphFragmentGrouping+Simple", "NativeParagraphFragmentGrouping+Pipeline",
                 "ReaderTranslationLobedRequestMerger", "ReaderTranslationChromaticBalloon", "ReaderTranslationWhiteRimBalloon",
                 "ReaderTranslationNonContentText", "ReaderTranslationPanelOrder", "ReaderTranslationLanguageFilter"] {
        files.append(sources.appendingPathComponent(name + ".swift"))
    }
    for name in ["TranslationModels", "TranslationCache", "NativeTranslationReuseIdentity", "NativeTranslationBatchPlanner", "AutomaticSourceLanguageDetector",
                 "TranslationBackgroundRolePolicy", "NativeTranslationRoleEvidence",
                 "TranslationSFXEvidencePolicy", "TranslationRoleVerificationPlanner",
                 "TranslationHTTPCodec", "TranslationEndpointPolicy", "TranslationStreamDecoder", "TranslationImageSupport",
                 "BoundedURLSessionTransport", "ExactHTTPStageCacheTransport", "RemoteTranslationClient"] {
        files.append(sources.appendingPathComponent("NativeEngine/Translation/" + name + ".swift"))
    }
    for name in ["IPhoneOverlaySettings", "BrowserOverlayColumnLayout", "BrowserOverlayBalloonUnitLayout",
                 "BrowserOverlayCollisionGeometry", "BrowserOverlayTypography", "BrowserSourceInkCleanup"] {
        files.append(sources.appendingPathComponent("NativeEngine/Overlay/" + name + ".swift"))
    }
    // Compile production rendering algorithms in full, including the worker's
    // Core Graphics source-canvas compositor shared with native host rendering.
    files += try manager.contentsOfDirectory(at: sources.appendingPathComponent("NativeEngine/Overlay"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent.hasPrefix("Native") }.sorted { $0.path < $1.path }
    files += try manager.contentsOfDirectory(at: sources.appendingPathComponent("NativeEngine/Ensemble"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    // Explicit fixed-font recovery dependency. Ensemble discovery normally
    // includes it; this named closure remains unique if discovery is refactored.
    for name in ["NativeFixedFontRecovery", "NativeTerminalRoundedSourcePaint"] {
        let file=sources.appendingPathComponent("NativeEngine/Ensemble/"+name+".swift")
        if !files.contains(where:{$0.standardizedFileURL==file.standardizedFileURL}) {files.append(file)}
    }
    // Diagnostics are injected only into generated copies; app sources stay untouched.
    if let index = files.firstIndex(where: { $0.lastPathComponent == "NativeCoreMLOCRPipeline.swift" }) {
        var pipeline = try read(files[index])
        let geometryOutputAnchor = "            var admittedDetectorSignals: [Int: [Double]] = [:]"
        guard pipeline.components(separatedBy: geometryOutputAnchor).count == 2 else {
            throw NSError(domain: "IndividualCorrectedGeometryOutput", code: 1)
        }
        pipeline = pipeline.replacingOccurrences(of: geometryOutputAnchor, with: """
                    HostIndividualGeometry.captureCorrected(individualGeometryOutput, admissionProof: learnedBoundaryAdmissionProof, sourceRailProof: sourceRailProof, sourcePaintProof: sourcePaintProof, bboxConfidenceProof: bboxConfidenceProof, geometryDeduplicationProof: geometryDeduplicationProof, representativeProof: geometryRepresentatives?.report, signalAdmissionProof: geometrySignalAdmission?.report, witnessAdmissionProof: geometryWitnessAdmission?.report, portfolioAdmissionProof: geometryPortfolioAdmission?.report, rfSemanticAdmissionProof: geometryRFSemanticAdmission?.report, physicalPaintAdmissionProof: geometryPhysicalPaintAdmission?.report, boundaryModesAdmissionProof: geometryPhysicalBoundaryModesAdmission?.report, sharedLineAdmissionProof: geometrySharedLineAdmission?.report)
        \(geometryOutputAnchor)
        """)
        let blankGrowthAuditAnchor = "                    let replacements = Dictionary(uniqueKeysWithValues: fitted.map { ($0.index, $0.polygon) })"
        guard pipeline.components(separatedBy: blankGrowthAuditAnchor).count == 2 else {
            throw NSError(domain: "BlankGrowthGeometryAudit", code: 1)
        }
        pipeline = pipeline.replacingOccurrences(of: blankGrowthAuditAnchor, with: """
                            if HostModelRefresh.recordsAllControls {
                                HostDump.capture("blank-growth-geometry-changes", fitted)
                            }
        \(blankGrowthAuditAnchor)
        """)
        let individualGeometryAnchor = "            var recognition: NativeCoreMLRecognitionResult?"
        guard pipeline.components(separatedBy: individualGeometryAnchor).count == 2 else {
            throw NSError(domain: "IndividualGeometryOutput", code: 1)
        }
        pipeline = pipeline.replacingOccurrences(of: individualGeometryAnchor, with: """
                    if let geometryResult = HostIndividualGeometry.result(requestID: requestID,
                        detection: detection, regions: regions, originals: sourceDetectionBoxes,
                        frameConversionMilliseconds: frameConversionMilliseconds) {
                        return geometryResult
                    }
        \(individualGeometryAnchor)
        """)
        let contourAuditAnchor = "                    let start=(firstPassRegions.map(\\.sourceIndex).max() ?? -1)+1\n                    let regions=contours.enumerated()"
        guard pipeline.components(separatedBy: contourAuditAnchor).count == 2 else {
            throw NSError(domain: "ModelRefreshContourAudit", code: 1)
        }
        pipeline = pipeline.replacingOccurrences(of: contourAuditAnchor, with: """
                            if HostModelRefresh.recordsAllControls {
                                HostDump.capture("endpoint-glyph-contour-proposals", contours)
                            }
        \(contourAuditAnchor)
        """)
        let contourAcceptedAnchor = "                    firstReads.append(accepted)\n                    if familyWordPreserved"
        guard pipeline.components(separatedBy: contourAcceptedAnchor).count == 2 else {
            throw NSError(domain: "ModelRefreshContextAdmissionAudit", code: 1)
        }
        pipeline = pipeline.replacingOccurrences(of: contourAcceptedAnchor, with: """
                            firstReads.append(accepted)
                            if HostModelRefresh.recordsAllControls {
                                HostDump.capture("context-admission", ["proposal": entry.proposal,
                                    "indices": entry.indices, "prior": prior as Any, "accepted": accepted] as [String: Any])
                            }
                            if familyWordPreserved
        """)
        pipeline = pipeline.replacingOccurrences(of:
            "excluding:acceptedContext.union(proposals.map(\\.parent)),layout:rfLayout,groups:rfPrimary.groups,\n                        terminalCapParents:shortPointWords)",
            with: """
            excluding:acceptedContext.union(proposals.map(\\.parent)),layout:rfLayout,groups:rfPrimary.groups,
            audit:{ index,message in
                if ProcessInfo.processInfo.environment["AIDOKU_OCR_GROUPING_AUDIT"] == "1" {
                    HostDump.capture("point-tail-audit",["sourceIndex":index,"message":message])
                }
            },terminalCapParents:shortPointWords)
            """)
        pipeline = pipeline.replacingOccurrences(of: "            guard detection.requestID == requestID else {",
            with: "            HostDump.capture(\"detector-output\", detection)\n            guard detection.requestID == requestID else {")
        pipeline = pipeline.replacingOccurrences(of: "            let recognitionMilliseconds =",
            with: "            HostModelRefresh.flushObservations()\n            HostDump.capture(\"recognizer-output\", recognition as Any)\n            HostDump.capture(\"rejected-reads\", rejectedReads)\n            let recognitionMilliseconds =")
        let observerAnchor = "maximumRecognitionWidth: recognizerMaximumWidth ?? IPhoneOCRSettings.maximumRecognizerWidth(for: modelTier)"
        guard pipeline.components(separatedBy: observerAnchor).count == 2 else {
            throw NSError(domain: "ModelRefreshRecognitionObserver", code: 1)
        }
        pipeline = pipeline.replacingOccurrences(of: observerAnchor, with: observerAnchor + ",\n                auditObserver: { HostModelRefresh.observe($0) }")
        let prerecAnchor = "            if NativeOCRRFPrimaryEnsemble.mainMangaEndpointPolicy {\n                regions.removeAll(where:rejectsPrimaryInput)"
        guard pipeline.components(separatedBy: prerecAnchor).count == 2 else {
            throw NSError(domain: "ModelRefreshBeforeRecognition", code: 1)
        }
        pipeline = pipeline.replacingOccurrences(of: prerecAnchor, with: """
                    let hostRefreshPrimaryKeep = HostModelRefresh.capturePreRecognition(stage:"pre-rec-training-input",regions:regions,
                        boxes:sourceDetectionBoxes,layout:rfLayout,references:endpointBases,parents:[:],
                        keep:regions.map { !rejectsPrimaryInput($0) })
        """ + "\n" + prerecAnchor)
        pipeline = pipeline.replacingOccurrences(of: "regions.removeAll(where:rejectsPrimaryInput)",
            with: "regions.removeAll { region in hostRefreshPrimaryKeep.flatMap { $0[region.sourceIndex] }.map { !$0 } ?? rejectsPrimaryInput(region) }")
        let alternativesAnchor = "            if NativeOCRRFPrimaryEnsemble.mainMangaEndpointPolicy {\n                firstPassRegions.removeAll(where:rejectsPrimaryInput)"
        guard pipeline.components(separatedBy: alternativesAnchor).count == 2 else {
            throw NSError(domain: "ModelRefreshRecognitionAlternatives", code: 1)
        }
        pipeline = pipeline.replacingOccurrences(of: alternativesAnchor, with: """
                    var hostRefreshParents=Dictionary(endpointFirstControls.map { ($0.index,$0.parent) } +
                        endpointFirstAlternatives.map { ($0.value.index,$0.key) },uniquingKeysWith:{ first,_ in first })
                    var hostRefreshDiagnosticControls=Set<Int>()
                    if HostModelRefresh.recordsAllControls {
                        var next=(firstPassRegions.map(\\.sourceIndex).max() ?? detection.boxes.count)+1
                        for (index,box) in sourceDetectionBoxes.enumerated() {
                            if firstPassRegions.contains(where:{ $0.polygon == box.polygon && $0.samplingPolygon == box.recognitionPolygon }) {continue}
                            firstPassRegions.append(.init(sourceIndex:next,polygon:box.polygon,
                                samplingPolygon:box.recognitionPolygon))
                            hostRefreshParents[next]=index
                            hostRefreshDiagnosticControls.insert(next)
                            next += 1
                        }
                    }
                    let hostRefreshAlternativeKeep = HostModelRefresh.capturePreRecognition(stage:"pre-rec-alternative-training-input",regions:firstPassRegions,
                        boxes:sourceDetectionBoxes,layout:rfLayout,references:endpointBases,
                        parents:hostRefreshParents,
                        keep:firstPassRegions.map { !rejectsPrimaryInput($0) })
        """ + "\n" + alternativesAnchor)
        pipeline = pipeline.replacingOccurrences(of:"firstPassRegions.removeAll(where:rejectsPrimaryInput)",
            with:"firstPassRegions.removeAll { region in !hostRefreshDiagnosticControls.contains(region.sourceIndex) && (hostRefreshAlternativeKeep.flatMap { $0[region.sourceIndex] }.map { !$0 } ?? rejectsPrimaryInput(region)) }")
        pipeline = pipeline.replacingOccurrences(of:"            if strongRegions.isEmpty {",
            with:"            if strongRegions.isEmpty && !(HostModelRefresh.recordsAllControls && !firstPassRegions.isEmpty) {")
        // A fitted stage1 ensemble can be replayed explicitly in the host.
        // This never changes the app's admitted production-policy gate.
        let stage1AdmissionAnchor = "model.isAvailable, model.isAdmittedSignalFilter, let current = recognition, let layout = rfLayout"
        guard pipeline.components(separatedBy: stage1AdmissionAnchor).count == 2 else {
            throw NSError(domain: "ModelRefreshStage1Admission", code: 1)
        }
        pipeline = pipeline.replacingOccurrences(of: stage1AdmissionAnchor,
            with: "model.isAvailable, (model.isAdmittedSignalFilter || HostModelRefresh.allowsStage1Replay(model)), let current = recognition, let layout = rfLayout")
        let stage1FeatureAnchor = "let decisions = zip(boxFeatureRows, featureRows).map { model.evaluate(boxFeatures: $0.0, maskFeatures: $0.1) }"
        guard pipeline.components(separatedBy: stage1FeatureAnchor).count == 2 else {
            throw NSError(domain: "ModelRefreshStage1Features", code: 1)
        }
        pipeline = pipeline.replacingOccurrences(of: stage1FeatureAnchor, with: """
        let hostStage1Replay = HostModelRefresh.allowsStage1Replay(model)
                        let decisions = zip(boxFeatureRows, featureRows).map {
                            hostStage1Replay ? model.evaluate(features: $0.1) : model.evaluate(boxFeatures: $0.0, maskFeatures: $0.1)
                        }
        """)
        let stage1SelectionAnchor = "let selector = premergeCandidateSelection.flatMap { $0.usesOnlyFixedConfidenceAndIoU ? $0 : nil }"
        guard pipeline.components(separatedBy: stage1SelectionAnchor).count == 2 else {
            throw NSError(domain: "ModelRefreshStage1Selection", code: 1)
        }
        pipeline = pipeline.replacingOccurrences(of: stage1SelectionAnchor,
            with: "let selector = (current.regions.count <= 512 ? HostModelRefresh.stage1ReplaySelection : nil) ?? (hostStage1Replay ? nil : premergeCandidateSelection.flatMap { $0.usesOnlyFixedConfidenceAndIoU ? $0 : nil })")
        let stage1AutomaticAnchor = "if premergeAutoPolicy?.isAvailable == true || premergeCombinationPolicy?.isAvailable == true {"
        guard pipeline.components(separatedBy: stage1AutomaticAnchor).count == 2 else {
            throw NSError(domain: "ModelRefreshStage1Automatic", code: 1)
        }
        pipeline = pipeline.replacingOccurrences(of: stage1AutomaticAnchor,
            with: "if !hostStage1Replay && (premergeAutoPolicy?.isAvailable == true || premergeCombinationPolicy?.isAvailable == true) {")
        let learnedBoundaryAnchor = "            var admittedDetectorSignals: [Int: [Double]] = [:]"
        guard pipeline.components(separatedBy: learnedBoundaryAnchor).count == 2 else {
            throw NSError(domain: "LearnedBoundaryStageCapture", code: 1)
        }
        pipeline = pipeline.replacingOccurrences(of: learnedBoundaryAnchor, with: """
                    if !learnedBoundary.decisions.isEmpty {
                        let encoder = JSONEncoder()
                        if let bytes = try? encoder.encode(learnedBoundary.decisions),
                           let decisions = try? JSONSerialization.jsonObject(with: bytes) {
                            HostDump.captureJSONObject("learned-boundary-decisions", [
                                "schema": "actual-learned-boundary-decisions-v1", "rows": decisions,
                                "addedCorrectedRecords": learnedBoundary.records.count, "GTAtInference": false,
                                "baselineRows": baselineIndividualGeometryOutput.individuals.count])
                        }
                    }
                    if !learnedBoundaryV2.decisions.isEmpty {
                        let encoder = JSONEncoder()
                        if let bytes = try? encoder.encode(learnedBoundaryV2.decisions),
                           let decisions = try? JSONSerialization.jsonObject(with: bytes),
                           let proofBytes = try? encoder.encode(learnedBoundaryV2.sourceContextProof),
                           let contextProof = try? JSONSerialization.jsonObject(with: proofBytes, options: [.fragmentsAllowed]) {
                            HostDump.captureJSONObject("learned-boundary-v2-decisions", [
                                "schema": "actual-learned-boundary-decisions-v2", "rows": decisions,
                                "sourceContextProof": contextProof,
                                "addedCorrectedRecords": learnedBoundaryV2.records.count, "GTAtInference": false,
                                "baselineRows": baselineIndividualGeometryOutput.individuals.count])
                        }
                    }
                    if !closedContourGeometry.proofs.isEmpty {
                        let encoder = JSONEncoder()
                        if let bytes = try? encoder.encode(closedContourGeometry.proofs),
                           let proofs = try? JSONSerialization.jsonObject(with: bytes) {
                            HostDump.captureJSONObject("closed-contour-geometry", [
                                "schema": "actual-source-closed-contour-v1", "proofs": proofs,
                                "addedRefinements": closedContourGeometry.refinements.count,
                                "GTAtInference": false, "recognitionAcceptanceGate": false])
                        }
                    }
                    if !learnedBoundary376.decisions.isEmpty {
                        let encoder = JSONEncoder()
                        if let bytes = try? encoder.encode(learnedBoundary376.decisions),
                           let decisions = try? JSONSerialization.jsonObject(with: bytes),
                           let contextBytes = try? encoder.encode(learnedBoundary376.sourceContextProof),
                           let contextProof = try? JSONSerialization.jsonObject(with: contextBytes, options: [.fragmentsAllowed]) {
                            HostDump.captureJSONObject("learned-boundary-376-decisions", [
                                "schema": "actual-learned-boundary-decisions-376-v1", "rows": decisions,
                                "sourceContextProof": contextProof,
                                "addedCorrectedRecords": learnedBoundary376.records.count,
                                "baselineRows": baselineIndividualGeometryOutput.individuals.count,
                                "GTAtInference": false, "utilityInvoked": false])
                        }
                    }
        """ + "\n" + learnedBoundaryAnchor)
        let sourceCalibrationAnchor = "                let residualGroups = Dictionary(uniqueKeysWithValues: rfPrimary.groups.map { ($0.index, $0.members) })"
        guard pipeline.components(separatedBy: sourceCalibrationAnchor).count == 2 else {
            throw NSError(domain: "SourceCalibrationStageCapture", code: 1)
        }
        pipeline = pipeline.replacingOccurrences(of: sourceCalibrationAnchor, with: """
                        if sourceCalibrationAudit.enabled {
                            let fields: Set<String> = ["family", "sourceIndex", "reason", "status", "unavailableReason",
                                "sourceUtility435", "selectedKey", "selectedScore", "outputOrGraphMutated",
                                "polygon", "actualPreviousPrior"]
                            HostDump.captureJSONObject("source-utility435-stage", [
                                "schema": "current-source-utility435-stage-v1",
                                "families": sourceCalibrationAudit.families,
                                "enabled": sourceCalibrationAudit.enabled,
                                "raw435": sourceCalibrationAudit.requestsRawRegression435,
                                "all8": sourceCalibrationAudit.requestsSourceUtility435All8,
                                "modelAvailable": SourceBoundaryRegression435Calibration.bundle != nil,
                                "all8ModelAvailable": SourceUtility435All8Calibration.model != nil,
                                "GTAtInference": false,
                                "rows": residualAdjusted.records.map { row in row.filter { fields.contains($0.key) } }])
                        }
        """ + "\n" + sourceCalibrationAnchor)
        let trainingAnchor = "                let retained = current.regions.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }"
        guard pipeline.components(separatedBy:trainingAnchor).count == 2 else {
            throw NSError(domain:"ModelRefreshTrainingCapture",code:1)
        }
        pipeline = pipeline.replacingOccurrences(of:trainingAnchor,with:"""
                        HostModelRefresh.capture(regions:current.regions,layout:layout,
                            boxFeatures:boxFeatureRows,maskFeatures:featureRows,
                            detectorBoxes:sourceDetectionBoxes,references:endpointBases,keep:keep)
        """ + "\n" + trainingAnchor)
        pipeline = pipeline.replacingOccurrences(of: "            var recognition: NativeCoreMLRecognitionResult?",
            with: """
                        if independentLaneResult != nil || ["1", "db", "pixel"].contains(ProcessInfo.processInfo.environment["AIDOKU_OCR_RF_ENDPOINT_COMPLETION"] ?? "") {
                            HostDump.capture("recognition-input", regions.map { region -> [String: Any] in
                                ["sourceIndex": region.sourceIndex, "polygon": region.polygon,
                                 "samplingPolygon": region.samplingPolygon as Any]
                            })
                        }
                        var recognition: NativeCoreMLRecognitionResult?
            """)
        pipeline = pipeline.replacingOccurrences(of: "            NativeCausalRawDecodeDiagnostics.current?.bindDetectors(requestID: requestID,",
            with: """
                        if NativeOCRRFPrimaryEnsemble.refinesEndpointInk {
                            HostDump.capture("recognition-first-pass-input", firstPassRegions.map { region -> [String: Any] in
                                ["sourceIndex": region.sourceIndex,
                                 "sourceParent": endpointFirstControls.first(where: { $0.index == region.sourceIndex })?.parent ?? endpointFirstAlternatives.first(where: { $0.value.index == region.sourceIndex })?.key ?? region.sourceIndex,
                                 "polygon": region.polygon, "samplingPolygon": region.samplingPolygon as Any]
                            })
                        }
                        NativeCausalRawDecodeDiagnostics.current?.bindDetectors(requestID: requestID,
            """)
        pipeline = pipeline.replacingOccurrences(of: "                        let contextDecoded=try await recognizer.recognize(", with: """
                            HostDump.capture("recognition-context-controls", firstReads.map { region -> [String: Any] in
                                ["sourceIndex":region.sourceIndex,"text":region.text,"confidence":region.confidence,"polygon":region.polygon,
                                 "inkColours":endpointInkStyles.flatMap { $0.indices.contains(region.sourceIndex) ? $0[region.sourceIndex]?.colors:nil } ?? []]
                            })
                            HostDump.capture("recognition-context-input", contextRegions.map { region -> [String: Any] in
                                ["sourceIndex":region.sourceIndex,
                                 "sourceParent":contextLateCrops.first(where:{$0.indices.contains(region.sourceIndex)})?.proposal.parent ?? region.sourceIndex,
                                 "polygon":region.polygon,"samplingPolygon":region.samplingPolygon as Any]
                            })
                            let contextDecoded=try await recognizer.recognize(
            """)
        pipeline = pipeline.replacingOccurrences(of: "                        let ordered=contextLateCrops.sorted", with: """
                            HostDump.capture("recognition-context-decoded", contextDecoded.regions.map { read -> [String:Any] in
                                ["sourceIndex":read.sourceIndex,"text":read.text,"confidence":read.confidence,
                                 "tokens":read.tokenObservations.count,
                                 "tokenObservations":read.tokenObservations.map { ["text":$0.text,"confidence":$0.confidence] }]
                            })
                            HostDump.capture("recognition-context-proposals", contextLateCrops.map { entry -> [String:Any] in
                                ["parent":entry.proposal.parent,"indices":entry.indices,"polygon":entry.proposal.polygon,
                                 "pointTail":entry.proposal.pointTailOnly,"measuredTrim":entry.proposal.measuredTrimOnly,
                                 "normalTrim":entry.proposal.measuredNormalOnly,"terminalOnly":entry.proposal.measuredTerminalOnly,
                                 "symbolicTerminal":entry.proposal.symbolicTerminalOnly,
                                 "immutableExpansionTrim":entry.proposal.immutableExpansionTrim,
                                 "sourceFamilyTrim":entry.proposal.sourceFamilyTrim,
                                 "observedWeakTerminal":entry.proposal.observedWeakTerminal,
                                 "sourceAxis":entry.proposal.measuredSourceAxis,
                                 "sourceHeadCompletion":entry.proposal.sourceHeadCompletion,
                                 "sourceTailCompletion":entry.proposal.sourceTailCompletion,
                                 "sourceTerminalProof":entry.proposal.sourceTerminalProof as Any,
                                 "sourceTerminalInk":entry.proposal.sourceTerminalInk,
                                 "axisComponents":entry.proposal.measuredAxisComponents.map { r in
                                     ["x":r.minX,"y":r.minY,"width":r.width,"height":r.height]
                                 }]
                            })
                            let ordered=contextLateCrops.sorted
            """)
        pipeline = pipeline.replacingOccurrences(of: "                        for entry in ordered { admitContext(entry,from:contextDecoded.regions) }",
            with: "                        for entry in ordered { admitContext(entry,from:contextDecoded.regions) }\n                        HostDump.capture(\"recognition-context-accepted\", acceptedContext.sorted())")
        pipeline = pipeline.replacingOccurrences(of:"                    if !regions.isEmpty {\n                        let measured=try await recognizer.recognize(frame:frame,regions:regions",with:"""
                            HostDump.capture("recognition-glyph-contour-proposals", contours.enumerated().map { offset,p -> [String:Any] in
                                ["parent":p.parent,"polygon":p.polygon,"samplings":p.samplings,
                                 "indices":[start+offset*2,start+offset*2+1],
                                 "head":p.sourceHeadCompletion,"tail":p.sourceTailCompletion,
                                 "retainedWord":p.retainedGlyphWordConfirmation]
                            })
                            if !regions.isEmpty {
                                let measured=try await recognizer.recognize(frame:frame,regions:regions
            """)
        pipeline = pipeline.replacingOccurrences(of:"                        guard measured.requestID==requestID else {throw CancellationError()}",with:"""
                                guard measured.requestID==requestID else {throw CancellationError()}
                                HostDump.capture("recognition-glyph-contour-decoded", measured.regions.map { r -> [String:Any] in
                                    ["sourceIndex":r.sourceIndex,"text":r.text,"confidence":r.confidence,
                                     "tokens":r.tokenObservations.map { ["text":$0.text,"confidence":$0.confidence] }]
                                })
            """)
        pipeline = pipeline.replacingOccurrences(of:"                        firstPassRegions+=regions",with:"""
                                firstPassRegions+=regions
                                HostDump.capture("recognition-glyph-contour-accepted", acceptedContext.sorted())
                                HostDump.capture("recognition-glyph-contour-admission", contextAdmissionTrace.filter { $0["glyphContour"] as? Bool == true })
            """)
        pipeline = pipeline.replacingOccurrences(of: "            let rfPrimary = recognitionScopes == nil ?", with: """
                        if let lanes = independentLaneResult {
                            HostDump.capture("independent-lane-output", [
                                "policy": NativeOCRIndependentLanes.policyVersion,
                                "width": detection.width, "height": detection.height,
                                "boxes": lanes.boxes, "changed": lanes.changed.sorted(), "added": lanes.added.sorted()
                            ])
                        }
                        let rfPrimary = recognitionScopes == nil ?
            """)
        if let first = pipeline.range(of: "                func admitContext("),
           let last = pipeline.range(of: "                if mangaSiblingRecovery,recognitionScopes == nil {", range:first.upperBound..<pipeline.endIndex) {
            var admission = String(pipeline[first.lowerBound..<last.lowerBound])
            admission = admission.replacingOccurrences(of: "                    let reads=entry.indices.compactMap", with: """
                                var admissionCheckpoint="pair-and-kind"
                                var admissionSucceeded=false
                                defer { contextAdmissionTrace.append([
                                    "parent":entry.proposal.parent,"indices":entry.indices,
                                    "checkpoint":admissionCheckpoint,"accepted":admissionSucceeded,
                                    "symbolicTerminal":entry.proposal.symbolicTerminalOnly,
                                    "terminalOnly":entry.proposal.measuredTerminalOnly,
                                    "glyphContour":entry.proposal.measuredGlyphContourOnly]) }
                                let reads=entry.indices.compactMap
                """)
            let checkpoints:[(String,String)] = [
                ("                    if entry.proposal.measuredSourceAxis,", "source-axis"),
                ("                    if entry.proposal.measuredNormalOnly {", "normal-proof"),
                ("                    if entry.proposal.pointTailOnly {", "point-tail-proof"),
                ("                    if entry.proposal.measuredTerminalOnly {", "terminal-proof"),
                ("                        for group in rfPrimary.groups where group.members.contains(parent) {", "retained-group"),
                ("                    if entry.proposal.measuredTrimOnly {", "trim-proof"),
                ("                    for peer in firstReads where peer.sourceIndex != parent && acceptedContext.contains", "private-peer-ink"),
                ("                    if !peerOverlap.isEmpty {", "peer-text"),
                ("                    if let prior,prior.confidence >= threshold,", "prior-geometry"),
                ("                    if (prior?.confidence ?? 0) < threshold {", "low-confidence-prior"),
                ("                    if let prior,prior.confidence >= threshold {", "prior-core")
            ]
            for (anchor,label) in checkpoints {
                admission = admission.replacingOccurrences(of:anchor,with:"                    admissionCheckpoint=\""+label+"\"\n"+anchor)
            }
            admission = admission.replacingOccurrences(of:"                    acceptedContext.insert(parent)",
                with:"                    admissionSucceeded=true\n                    admissionCheckpoint=\"accepted\"\n                    acceptedContext.insert(parent)")
            admission = admission.replacingOccurrences(of:"                            guard shared || boundary else { continue }", with:"""
                                        contextAdmissionTrace.append([
                                            "parent":parent,"child":child.sourceIndex,"checkpoint":"boundary-alias",
                                            "shared":shared,"boundary":boundary,
                                            "terminalProof":endpointTerminalProofs[child.sourceIndex] ?? []])
                                        guard shared || boundary else { continue }
                """)
            pipeline.replaceSubrange(first.lowerBound..<last.lowerBound,
                with:"                var contextAdmissionTrace:[[String:Any]]=[]\n"+admission)
            pipeline = pipeline.replacingOccurrences(of:"HostDump.capture(\"recognition-context-accepted\", acceptedContext.sorted())",
                with:"HostDump.capture(\"recognition-context-accepted\", acceptedContext.sorted())\n                        HostDump.capture(\"recognition-context-admission\", contextAdmissionTrace)")
        }
        let adaptedURL = cache.appendingPathComponent("NativeCoreMLOCRPipeline.swift")
        if (try? read(adaptedURL)) != pipeline { try pipeline.write(to: adaptedURL, atomically: true, encoding: .utf8) }
        files[index] = adaptedURL
    }
    if let index = files.firstIndex(where: { $0.lastPathComponent == "NativeCoreMLDetector.swift" }) {
        var detector = try read(files[index])
        let marker = "                    let result = try NativeOCRDirectionGeometry.$mainMangaPolicy.withValue(directionPolicy) {"
        guard detector.contains(marker) else { throw NSError(domain: "DetectorTraceAdapter", code: 1) }
        detector = detector.replacingOccurrences(of: "        let issuedGeneration = generation.begin()", with: "        let hostDumpContext = HostDump.context\n        let directionReplay = HostDirectionReplay.current\n        let issuedGeneration = generation.begin()")
        let replayAnchor = "            guard let canvas = canvasSelector(frame.width, frame.height)"
        guard detector.components(separatedBy: replayAnchor).count == 2 else { throw NSError(domain:"DirectionReplayAdapter",code:1) }
        detector = detector.replacingOccurrences(of:replayAnchor,with:"""
                    if let replay = try HostDirectionReplay.detection(frame:frame,requestID:requestID,
                        configuration:configuration,probabilityObserver:probabilityObserver) { return replay }
        """ + "\n" + replayAnchor)
        detector = detector.replacingOccurrences(of: marker, with: "                    try directionReplay?.record(map,originX:region.x,originY:region.y,fullWidth:prepared.resizedWidth,fullHeight:prepared.resizedHeight)\n                    HostDump.captureProbabilityMap(map.values, width: map.width, height: map.height, originX: region.x, originY: region.y, fullWidth: prepared.resizedWidth, fullHeight: prepared.resizedHeight, context: hostDumpContext)\n" + marker)
        let copy = cache.appendingPathComponent("NativeCoreMLDetector.swift")
        if (try? read(copy)) != detector { try detector.write(to: copy, atomically: true, encoding: .utf8) }
        files[index] = copy
    }
    if let index = files.firstIndex(where: { $0.lastPathComponent == "NativeRFDETRLayoutDetector.swift" }) {
        var detector = try read(files[index])
        detector = detector.replacingOccurrences(of:"try NativeRFDETRLayoutTensorContract.validate(model: model)",
            with:"try HostModelRefresh.validate(model: model)")
        let anchor = "        return try await detectSource(decode)"
        guard detector.components(separatedBy: anchor).count == 2 else { throw NSError(domain: "RFReplayAdapter", code: 1) }
        detector = detector.replacingOccurrences(of: anchor, with: """
                if HostRFRawReplay.enabled {
                    return try await detectSource(decode)
                }
                if let replay = try HostRFLayoutReplay.read(image: image, maximumMasks: maximumMaskQueries) { return replay }
                if HostFirstPassGeometryProbe.current != nil {
                    throw HostFirstPassGeometryProbe.Failure.replayRequired
                }
                let result = try await detectSource(decode)
                return try HostRFLayoutReplay.store(result, maximumMasks: maximumMaskQueries)
        """)
        let rawStart = "        let revision = generation\n        let maximumMasks = maximumMaskQueries"
        guard detector.components(separatedBy: rawStart).count == 2 else { throw NSError(domain:"RFV2Preflight",code:1) }
        detector = detector.replacingOccurrences(of: rawStart,
            with: "        try HostRFRawReplay.preflight()\n" + rawStart)
        let rawMiss = "                    let predictionStart = ProcessInfo.processInfo.systemUptime"
        guard detector.components(separatedBy: rawMiss).count == 2 else { throw NSError(domain:"RFV2RawMiss",code:1) }
        detector = detector.replacingOccurrences(of: rawMiss, with: """
                            if HostRFRawReplay.enabled {
                                return try HostRFRawReplay.snapshot(input: input, source: prepared.0, key: key, preprocessingMS: preprocessMS) {
                                    let began = ProcessInfo.processInfo.systemUptime
                                    NativeRFRawCacheDiagnostics.event(key, "actualPredictionCalls")
                                    let output = try handle.predict(provider)
                                    return (output, (ProcessInfo.processInfo.systemUptime - began) * 1_000)
                                }
                            }
        """ + "\n" + rawMiss)
        let decoded = "                NativeRFRawCacheDiagnostics.event(key, \"decoderMaterializations\")"
        guard detector.components(separatedBy: decoded).count == 2 else { throw NSError(domain:"RFV2Decode",code:1) }
        detector = detector.replacingOccurrences(of: decoded, with: decoded + "\n                if HostRFRawReplay.enabled { try HostRFRawReplay.observe(result, key: key, maximumMasks: maximumMasks, retainAll: allQueryMasks) }")
        let copy = cache.appendingPathComponent("NativeRFDETRLayoutDetector.swift")
        if (try? read(copy)) != detector { try detector.write(to: copy, atomically: true, encoding: .utf8) }
        files[index] = copy
    }
    if let index = files.firstIndex(where: { $0.lastPathComponent == "NativeFinalOutputContentFilter+Pipeline.swift" }) {
        var filtering = try read(files[index])
        let stage2Anchor = "let finalSignalKeep = keep(features, policy: defaultPolicy, detectorFeatures: detectorFeatures)"
        guard filtering.components(separatedBy: stage2Anchor).count == 2 else {
            throw NSError(domain: "ModelRefreshStage2Admission", code: 1)
        }
        filtering = filtering.replacingOccurrences(of: stage2Anchor,
            with: "let finalSignalKeep = (HostModelRefresh.stage2Keep(features: features, detectorFeatures: detectorFeatures) ?? keep(features, policy: defaultPolicy, detectorFeatures: detectorFeatures))")
        let copy = cache.appendingPathComponent("NativeFinalOutputContentFilter+Pipeline.swift")
        if (try? read(copy)) != filtering { try filtering.write(to: copy, atomically: true, encoding: .utf8) }
        files[index] = copy
    }
    if let index = files.firstIndex(where: { $0.lastPathComponent == "NativePostLLMContentReclassifier.swift" }) {
        var reclassifier = try read(files[index])
        let roleDeclaration = "enum NativePostLLMContentReclassifier {"
        guard reclassifier.components(separatedBy: roleDeclaration).count == 2 else {
            throw NSError(domain: "ModelRefreshRoleHookDeclaration", code: 1)
        }
        reclassifier = reclassifier.replacingOccurrences(of: roleDeclaration,
            with: roleDeclaration + "\n    static let hostRoleReplayHook = true")
        let roleReplayAnchor = "        guard let role = segment.textRole else { return nil }"
        guard reclassifier.components(separatedBy: roleReplayAnchor).count == 2 else {
            throw NSError(domain: "ModelRefreshRoleAdmission", code: 1)
        }
        reclassifier = reclassifier.replacingOccurrences(of: roleReplayAnchor, with: """
                if selectedPolicy == .established, let replay = HostModelRefresh.roleReplayDecision(segment, evidence: evidence) {
                    return replay.action
                }
        """ + "\n" + roleReplayAnchor)
        let copy = cache.appendingPathComponent("NativePostLLMContentReclassifier.swift")
        if (try? read(copy)) != reclassifier { try reclassifier.write(to: copy, atomically: true, encoding: .utf8) }
        files[index] = copy
    }
    // Bind raw preprocessing separately from decoder/consumer implementation.
    let nativeRF = try read(root.appendingPathComponent("Aidoku/Core/Translation/NativeEngine/Layout/NativeRFDETRLayoutDetector.swift"))
    let constants = try slice(nativeRF, "    static let mean:", "    static let thresholds:")
    let shape = try slice(nativeRF, "    static let inputShape", "    static let outputShapes")
    let resizing = try slice(nativeRF, "    private struct Filter", "    static func decode(")
    let preprocessingSHA = SHA256.hash(data: Data((constants + shape + resizing).utf8)).map { String(format:"%02x",$0) }.joined()
    var decoderBytes = Data()
    for name in ["NativeRFDETRLayoutDetector.swift", "NativeRFDETRLayoutModels.swift", "NativeRFDETRSemanticGrid.swift", "NativeRFDETRSourceSupportGrid.swift", "NativeRFSharedRawCache.swift"] {
        decoderBytes.append(Data(name.utf8))
        decoderBytes.append(try Data(contentsOf:root.appendingPathComponent("Aidoku/Core/Translation/NativeEngine/Layout/" + name)))
    }
    let decoderSHA = SHA256.hash(data: decoderBytes).map { String(format:"%02x",$0) }.joined()
    let replayCode = try read(support.appendingPathComponent("HostRFRawReplay.swift"))
        .replacingOccurrences(of:"__RF_V2_PREPROCESS_CODE_SHA__",with:preprocessingSHA)
        .replacingOccurrences(of:"__RF_V2_DECODER_CODE_SHA__",with:decoderSHA)
    let replayURL = cache.appendingPathComponent("HostRFRawReplay.swift")
    if (try? read(replayURL)) != replayCode { try replayCode.write(to:replayURL,atomically:true,encoding:.utf8) }
    files.append(replayURL)
    files.append(support.appendingPathComponent("HostRFLayoutReplay.swift"))
    files.append(support.appendingPathComponent("HostModelRefresh.swift"))
    files.append(support.appendingPathComponent("HostIndividualGeometry.swift"))
    files.append(support.appendingPathComponent("HostRawBoundaryFeatures.swift"))
    files.append(support.appendingPathComponent("HostRawCanonicalGeometry.swift"))
    files.append(support.appendingPathComponent("HostPreRecognitionFilter.swift"))
    files.append(support.appendingPathComponent("HostPostRecognitionFilter.swift"))
    files.append(support.appendingPathComponent("HostPostMergeSignalFilter.swift"))
    files.append(support.appendingPathComponent("HostBBoxConfidenceAdmission.swift"))
    files.append(support.appendingPathComponent("HostEnsembleEvidence.swift"))
    files.append(support.appendingPathComponent("HostDBProbability.swift"))
    files.append(support.appendingPathComponent("HostRemovalShadow.swift"))
    files.append(support.appendingPathComponent("HostOperationalAppearance.swift"))
    files += ["HostModuleBank.swift", "HostModuleBankBootstrap.swift", "HostSourceInputBank.swift",
        "HostSourceSegmentationBank.swift", "HostSourceBankCapture.swift"].map { support.appendingPathComponent($0) }
    files.append(root.appendingPathComponent("Aidoku/Extensions/Foundation/NSLocalizedString.swift"))
    files += [support.appendingPathComponent("HostNativeGraphics.swift"), support.appendingPathComponent("HostTypographyBridge.swift"), support.appendingPathComponent("HostLetterFonts.swift"), support.appendingPathComponent("HostTranslationParity.swift"), support.appendingPathComponent("HostRenderGeometry.swift"), support.appendingPathComponent("HostExportCompositor.swift"), support.appendingPathComponent("HostRenderProvenance.swift"), support.appendingPathComponent("HostSupport.swift"), support.appendingPathComponent("HostEnvironment.swift"), support.appendingPathComponent("HostSavedOCRReplay.swift"), support.appendingPathComponent("HostTaggedObservationDecoder.swift"), support.appendingPathComponent("HostObservedOCRReplay.swift"), support.appendingPathComponent("HostSealedLLMStage.swift"), support.appendingPathComponent("PipelineMain.swift"), support.appendingPathComponent("HostAnalysis.swift")]
    files.append(support.appendingPathComponent("HostMangaDetectorSearch.swift"))
    files.append(support.appendingPathComponent("HostCapturedGroupedOwners.swift"))
    files.append(support.appendingPathComponent("HostObservedReaderInput.swift"))
    files.append(support.appendingPathComponent("HostObservedReaderStage.swift"))
    files.append(support.appendingPathComponent("HostObservedChangedOCRReplay.swift"))
    files.append(support.appendingPathComponent("HostMatchedLLMFilterReplay.swift"))
    files.append(support.appendingPathComponent("HostMatchedRenderPlan.swift"))
    files.append(support.appendingPathComponent("HostMatchedReaderRender.swift"))
    files.append(support.appendingPathComponent("HostCanaryRawArchive.swift"))
    files.append(support.appendingPathComponent("HostMinimalSourceArm.swift"))
    files.append(support.appendingPathComponent("HostRFParameterSearch.swift"))
    files.append(support.appendingPathComponent("HostDirectionAudit.swift"))
    files.append(support.appendingPathComponent("HostDirectionReplay.swift"))
    files.append(support.appendingPathComponent("HostSourceRepairControls.swift"))
    files.append(support.appendingPathComponent("HostNativeAdmission425Controls.swift"))
    files.append(support.appendingPathComponent("HostSupplementalBodyLoss424Controls.swift"))
    files.append(support.appendingPathComponent("HostFeasibleDeep433Controls.swift"))
    files.append(support.appendingPathComponent("HostRawRegression435Controls.swift"))
    files.append(support.appendingPathComponent("AuxiliaryForwardQualifiedObservation432.swift"))
    files.append(support.appendingPathComponent("HostSourceWitness436.swift"))
    files.append(support.appendingPathComponent("HostSupplementalBodyLoss426Controls.swift"))
    files.append(support.appendingPathComponent("HostFirstPassGeometryProbe.swift"))
    files.append(support.appendingPathComponent("HostSavedReaderPostprocess.swift"))
    files.append(support.appendingPathComponent("HostSavedLLMEvaluation.swift"))
    files.append(support.appendingPathComponent("HostSavedPostLLMEvaluation.swift"))
    files.append(support.appendingPathComponent("HostRolePromptContract.swift"))
    files.append(support.appendingPathComponent("HostRawTextRender.swift"))
    let snapshotDirectory = cache.appendingPathComponent("sources")
    try manager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
    guard Set(files.map(\.lastPathComponent)).count == files.count else {
        throw NSError(domain: "FrozenModuleBankProducer", code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Duplicate sources would overwrite a compiled snapshot"])
    }
    files = try files.map { file in
        let copy = snapshotDirectory.appendingPathComponent(file.lastPathComponent)
        var raw = try read(file)
        if file.lastPathComponent == "NativeTranslationTypography.swift" {
            let lookup = "Bundle.main.url(forResource: \"AidokuSerifKR-Bold\", withExtension: \"woff2\")"
            guard raw.contains(lookup) else { throw NSError(domain: "NativeFontResourceAdapter", code: 1) }
            raw = raw.replacingOccurrences(of: lookup,
                with: "HostLetterFonts.resourceURL(name: \"AidokuSerifKR-Bold\", extension: \"woff2\")")
        }
        let data = Data(raw.replacingOccurrences(of: "import UIKit", with: "import AppKit").utf8)
        if (try? Data(contentsOf: copy)) != data { try data.write(to: copy, options: .atomic) }
        return copy
    }
    // Native original Rust kernels are linked through the same public C ABI as
    // the iOS target. Include the resulting library in the executable identity.
    var kernelEnvironment = ProcessInfo.processInfo.environment
    kernelEnvironment["PLATFORM_NAME"] = "macosx"
    kernelEnvironment["ARCHS"] = "arm64"
    kernelEnvironment["DERIVED_FILE_DIR"] = root.appendingPathComponent("build/native-overlay-kernels-host").path
    let kernelStatus = try run("/usr/bin/env", ["python3", root.appendingPathComponent("Scripts/overlay-kernels/native/build.py").path], environment: kernelEnvironment)
    guard kernelStatus == 0 else { exit(kernelStatus) }
    // Build and link the source-feature ABI used by the shared native font,
    // appearance and segmentation implementations. Reuse the fixed host cache.
    var sourceEnvironment = kernelEnvironment
    sourceEnvironment["DERIVED_FILE_DIR"] = root.appendingPathComponent("build/native-source-cv-host").path
    let sourceStatus = try run("/usr/bin/env", ["python3", root.appendingPathComponent("Scripts/native-source-cv/build.py").path], environment: sourceEnvironment)
    guard sourceStatus == 0 else { exit(sourceStatus) }
    let sourceDirectory = root.appendingPathComponent("build/native-source-cv-host")
    let sourceInclude = root.appendingPathComponent("Vendor/NativeSourceCV/include")
    let kernelLibrary = root.appendingPathComponent("build/native-overlay-kernels-host/libAidokuOverlayKernels.a")
    var hash = SHA256()
    hash.update(data: try Data(contentsOf: kernelLibrary))
    for name in ["libAidokuSourceCV.a", "libAidokuOpenCV.a", "libAidokuFreeType.a"] {
        hash.update(data: try Data(contentsOf: sourceDirectory.appendingPathComponent(name)))
    }
    for name in ["AidokuNativeCV.h", "AidokuAllSourceSignals.h", "AidokuSourceFeatures.h", "module.modulemap"] {
        hash.update(data: try Data(contentsOf: sourceInclude.appendingPathComponent(name)))
    }
    hash.update(data: try Data(contentsOf: root.appendingPathComponent("Scripts/overlay-kernels/native/kernels.h")))
    hash.update(data: try Data(contentsOf: root.appendingPathComponent("Scripts/overlay-kernels/native/module.modulemap")))
    hash.update(data: Data(generated.utf8))
    for file in files { hash.update(data: try Data(contentsOf: file)) }
    hash.update(data: Data((try read(URL(fileURLWithPath: #filePath))).utf8))
    let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
    let binary = cache.appendingPathComponent("image-translation")
    let stamp = cache.appendingPathComponent("fingerprint")
    let generatedURL = cache.appendingPathComponent("ProductionAdapters.swift")
    let adapted = generated.replacingOccurrences(of: "@available(iOS 18.0, *)", with: "@available(macOS 15.0, *)")
        .replacingOccurrences(of: "secondaryMode = variant.lineBreakMode", with: "secondaryMode = Int(variant.lineBreakMode")
        .replacingOccurrences(of: "measurementCache: self).rawValue", with: "measurementCache: self).rawValue)")
        .replacingOccurrences(of: "primaryBreakMode: variant.lineBreakMode", with: "primaryBreakMode: Int(variant.lineBreakMode")
    if (try? read(generatedURL)) != adapted { try adapted.write(to: generatedURL, atomically: true, encoding: .utf8) }
    let allFiles = [generatedURL] + files
    let compiledSourceHashes = try FrozenModuleBankProducer.capture(allFiles)
    let stageSchemas = try FrozenModuleBankProducer.schemas(allFiles)
    let producerManifest = cache.appendingPathComponent("module-bank-producer.json")
    // A matching old fingerprint alone cannot attest compilation. Missing or
    // invalid frozen provenance forces an ordinary incremental build first.
    if (try? read(stamp)) != fingerprint || !manager.fileExists(atPath: binary.path) ||
        !FrozenModuleBankProducer.valid(producerManifest, fingerprint: fingerprint,
            files: compiledSourceHashes, schemas: stageSchemas) {
        // Reuse object files; no clean or whole-module rebuild.
        func stableOutputMap(files: [URL], cache: URL, previous: [String: [String: String]]) -> [String: [String: String]] {
            var result: [String: [String: String]] = ["": ["swift-dependencies": cache.appendingPathComponent("master.swiftdeps").path]]
            for file in files {
                // Preserve existing object identities when a new helper shifts source order.
                // New sources use their path, so future insertion/removal cannot renumber them.
                if let existing = previous[file.path], existing["object"] != nil, existing["swift-dependencies"] != nil {
                    result[file.path] = existing
                } else {
                    let identity = SHA256.hash(data: Data(file.path.utf8)).map { String(format: "%02x", $0) }.joined()
                    let base = cache.appendingPathComponent("object-path-" + identity).path
                    result[file.path] = ["object": base + ".o", "swift-dependencies": base + ".swiftdeps"]
                }
            }
            return result
        }
        let map = cache.appendingPathComponent("output-map.json")
        let previousMap = (try? Data(contentsOf: map)).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: [String: String]]
        } ?? [:]
        let outputMap = stableOutputMap(files: allFiles, cache: cache, previous: previousMap)
        try JSONSerialization.data(withJSONObject: outputMap, options: [.sortedKeys]).write(to: map)
        fputs("Building current Swift pipeline (incremental, -O)…\n", stderr)
        let traceBuild = ProcessInfo.processInfo.environment["AIDOKU_HOST_BUILD_TRACE"] == "1"
        let compiler = traceBuild ? "/usr/bin/time" : "/usr/bin/xcrun"
        let prefix = traceBuild ? ["-l", "/usr/bin/xcrun"] : []
        let diagnostics = traceBuild ? ["-v", "-driver-show-incremental"] : []
        // A frozen inference run can keep one binary while another candidate
        // reuses its absolute compiler-module cache. Only one build may use it.
        let moduleCache = ProcessInfo.processInfo.environment["AIDOKU_HOST_MODULE_CACHE"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL }
            ?? cache.appendingPathComponent("module-cache", isDirectory: true)
        try manager.createDirectory(at: moduleCache, withIntermediateDirectories: true)
        // Parallel compilation does not change the optimized runtime policy.
        // Explicit jobs=1 remains available for low-load sessions.
        let compilerJobs = max(1, min(4, Int(ProcessInfo.processInfo.environment["AIDOKU_HOST_COMPILER_JOBS"] ?? "4") ?? 4))
        // Never overwrite a binary still mapped by an active frozen experiment.
        // The build lock serializes writers; rename publishes only a successful link.
        let linkedBinary = cache.appendingPathComponent("image-translation.next")
        let code = try run(compiler, prefix + ["swiftc", "-O", "-incremental", "-enable-batch-mode", "-j", String(compilerJobs), "-parse-as-library",
            "-module-name", "ImageTranslationHost", "-target", "arm64-apple-macos15.0", "-output-file-map", map.path,
            "-module-cache-path", moduleCache.path,
            "-I", root.appendingPathComponent("Scripts/overlay-kernels/native").path,
            "-L", root.appendingPathComponent("build/native-overlay-kernels-host").path, "-lAidokuOverlayKernels",
            "-I", sourceInclude.path, "-L", sourceDirectory.path,
            "-lAidokuSourceCV", "-lAidokuOpenCV", "-lAidokuFreeType", "-lc++", "-lz",
            "-framework", "CoreText", "-framework", "Accelerate"]
            + allFiles.map(\.path) + ["-o", linkedBinary.path] + diagnostics)
        guard code == 0 else { exit(code) }
        guard try FrozenModuleBankProducer.capture(allFiles) == compiledSourceHashes,
              try FrozenModuleBankProducer.schemas(allFiles) == stageSchemas else {
            throw NSError(domain: "FrozenModuleBankProducer", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Compiled source bytes changed during build; refusing publication"])
        }
        guard rename(linkedBinary.path, binary.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try fingerprint.write(to: stamp, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: FrozenModuleBankProducer.manifest(
            fingerprint: fingerprint, files: compiledSourceHashes, schemas: stageSchemas),
            options: [.sortedKeys, .withoutEscapingSlashes]).write(to: producerManifest, options: .atomic)
    }
    // Compile-only mode keeps native composition outside the measured build interval.
    if ProcessInfo.processInfo.environment["AIDOKU_HOST_BUILD_ONLY"] == "1" { exit(0) }
    var environment = ProcessInfo.processInfo.environment
    environment["AIDOKU_PIPELINE_ROOT"] = root.path
    environment["AIDOKU_PIPELINE_FINGERPRINT"] = fingerprint
    environment["AIDOKU_MODULE_BANK_PRODUCER_MANIFEST"] = producerManifest.path
    flock(lockDescriptor, LOCK_UN)
    close(lockDescriptor)
    holdsBuildLock = false
    exit(try run(binary.path, args, environment: environment))
} catch {
    fputs("image-translation: \(error)\n", stderr)
    exit(1)
}
