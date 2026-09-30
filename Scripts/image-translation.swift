#!/usr/bin/env swift
// macOS launcher: compiles the current production engine, then forwards CLI arguments.
import Foundation
import CryptoKit
import Darwin

let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let sources = root.appendingPathComponent("Aidoku/Core/Translation")
let support = root.appendingPathComponent("Scripts/image-translation")
let cache = root.appendingPathComponent("build/image-translation-host")
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
    if args.first == "--visualize-run" {
        guard args.count == 2 else { throw NSError(domain: "Arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: --visualize-run RUN_OR_IMAGE_DIRECTORY"]) }
        let analysisFiles = ["HostAnalysis.swift", "AnalysisMain.swift"].map { support.appendingPathComponent($0) }
        let digest = SHA256.hash(data: try analysisFiles.reduce(into: Data()) { $0.append(try Data(contentsOf: $1)) }).map { String(format: "%02x", $0) }.joined()
        let binary = cache.appendingPathComponent("image-analysis")
        let stamp = cache.appendingPathComponent("analysis-fingerprint")
        if (try? read(stamp)) != digest || !manager.fileExists(atPath: binary.path) {
            let status = try run("/usr/bin/xcrun", ["swiftc", "-O", "-parse-as-library"] + analysisFiles.map(\.path) + ["-o", binary.path])
            guard status == 0 else { exit(status) }
            try digest.write(to: stamp, atomically: true, encoding: .utf8)
        }
        flock(lockDescriptor, LOCK_UN); close(lockDescriptor); holdsBuildLock = false
        exit(try run(binary.path, [URL(fileURLWithPath: args[1]).standardizedFileURL.path, root.path]))
    }
    var generated = "import Foundation\nimport CoreGraphics\nimport AppKit\nimport CoreText\nimport os\n"
    let settings = try read(sources.appendingPathComponent("ReaderTranslationSettings.swift"))
    generated += try slice(settings, "enum IPhoneOCRModelTier", "struct ReaderCustomTranslationSettings")
    let reader = try read(sources.appendingPathComponent("ReaderTranslationService.swift"))
    generated += try slice(reader, "struct ReaderTranslationRegion:", "enum ReaderTranslationGeometry")
    var ocr = try slice(reader, "actor ReaderOCRService", "actor ReaderTranslationService")
    guard ocr.contains("recognizerMaximumWidth: configuration.recognizerMaximumWidth\n") else { throw NSError(domain: "ModelBundleAdapter", code: 1) }
    ocr = ocr.replacingOccurrences(of: "recognizerMaximumWidth: configuration.recognizerMaximumWidth\n", with: "recognizerMaximumWidth: configuration.recognizerMaximumWidth, bundle: HostResources.bundle\n")
    ocr = ocr.replacingOccurrences(of: "let postprocessStartedAt =", with: "HostDump.capture(\"native-ocr\", result)\n        let postprocessStartedAt =")
    ocr = ocr.replacingOccurrences(of: "NSValue(cgRect:", with: "NSValue(rect:")
    ocr = ocr.replacingOccurrences(of: "        return joined", with: "        HostDump.capture(\"ocr-phases\", lastPhaseMilliseconds)\n        HostDump.capture(\"grouped-regions\", joined)\n        return joined")
    for (anchor, name, value) in [
        ("        var joined = group(lines)", "initial-grouping", "joined"),
        ("        let balloonStart =", "recovery-input", "result.recoveryCandidates"),
        ("        lastPhaseMilliseconds[\"balloonMerge\"]", "after-recovery", "joined"),
        ("        let countBeforeChromaticJoin = joined.count", "balloon-interiors", "joined"),
        ("        // A colored contour", "chromatic-grouping", "joined")
    ] {
        guard ocr.contains(anchor) else { throw NSError(domain: "HostAssembly", code: 1) }
        if anchor == "        var joined = group(lines)" {
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
    let background = try read(root.appendingPathComponent("Aidoku/Features/Reader/Translation/ReaderTranslationOverlayView.swift"))
    generated += try slice(background, "enum ReaderTranslationBackgroundImage", "    /// Live and export overlays") + "}\n"
    let exporter = try read(root.appendingPathComponent("Aidoku/Features/Reader/Translation/ReaderTranslationImageExporter.swift"))
    generated += "enum HostProductionExportSizing {\n" + (try slice(exporter, "    static func outputSize(for pixels:", "    static func render(image:")) + "}\n"
    generated += "enum HostProductionExporter {\n" + (try slice(exporter, "    struct ExportLayers:", "    /// Core Image contexts")) + "}\n"

    generated += "enum HostProductionLayout {\n" + (try slice(overlay, "    nonisolated static func layoutPayload(", "    func clear(")) + "}\n"
    generated += "enum HostProductionRenderer {\n"
    generated += try slice(overlay, "    static let releaseResourcesScript", "    static let clearScript")
    generated += try slice(overlay, "    static let renderScript =", "struct BrowserOverlayItem").replacingOccurrences(of: "BrowserOverlayTypography.script +", with: "BrowserOverlayTypography.script + HostSegmentationTrace.script +")
        .replacingOccurrences(of: "BrowserSourceInkCleanup.script +", with: "BrowserSourceInkCleanup.script.replacingOccurrences(of: \"const aidokuSourceInkMask =\", with: \"let aidokuSourceInkMask =\") +")
    generated += try slice(overlay, "struct BrowserOverlayItem:", "struct BrowserOverlayVisibility")
    generated += try slice(overlay, "struct BrowserOverlayTextMeasurementCacheStatistics", "struct BrowserOverlayPositionedLayoutCacheInput")
    generated += try slice(overlay, "struct BrowserOverlayTextFlow", "struct BrowserSidePanelSessionHistory")
    generated += try slice(overlay, "enum BrowserOverlayFont", "private struct OverlayPalette")
    generated += "enum ReaderTranslationService {\n" + (try slice(reader, "    static func plans(", "    typealias Progress")) + "}\n"
    let service = try read(sources.appendingPathComponent("NativeEngine/Translation/TranslationService.swift"))
    generated += try slice(service, "enum TranslationPerformanceDiagnostics", "enum MetadataTranslationPriority")
    generated += try slice(service, "enum MetadataTranslationPriority", "actor TranslationService")
    let log = try read(root.appendingPathComponent("Aidoku/Features/Reader/Translation/TranslationPerformanceFileLog.swift"))
    generated += try slice(log, "enum TranslationPerformanceFileLog", "    private static let sink")
    generated += "static func record(_ event: Event, fields: [Field: Double]) { HostDump.capture(\"metric-\" + event.rawValue, fields.reduce(into: [String: Double]()) { $0[$1.key.rawValue] = $1.value }) }\n}\n"
    let credential = try read(sources.appendingPathComponent("NativeEngine/Translation/KeychainTranslationCredentialStore.swift"))
    generated += try slice(credential, "protocol TranslationCredentialProviding", "protocol TranslationCredentialManaging")
    var files = try manager.contentsOfDirectory(at: sources.appendingPathComponent("NativeEngine/OCR"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ReaderSupplementalOCR.swift" }.sorted { $0.path < $1.path }
    for name in ["ReaderTranslationEnclosedBackground", "ReaderTranslationBalloonMerger", "ReaderTranslationChromaticBalloon",
                 "ReaderTranslationNonContentText", "ReaderTranslationPanelOrder", "ReaderTranslationLanguageFilter"] {
        files.append(sources.appendingPathComponent(name + ".swift"))
    }
    for name in ["TranslationModels", "NativeTranslationReuseIdentity", "NativeTranslationBatchPlanner", "AutomaticSourceLanguageDetector",
                 "TranslationHTTPCodec", "TranslationEndpointPolicy", "TranslationStreamDecoder", "TranslationImageSupport",
                 "BoundedURLSessionTransport", "RemoteTranslationClient"] {
        files.append(sources.appendingPathComponent("NativeEngine/Translation/" + name + ".swift"))
    }
    for name in ["IPhoneOverlaySettings", "BrowserOverlayColumnLayout", "BrowserOverlayBalloonUnitLayout", "BrowserOverlayCollisionGeometry", "BrowserOverlayTypography", "BrowserSourceInkCleanup", "BrowserSourceTextColor", "BrowserSourcePanelRestoration",
                 "BrowserSourceGlyphConservative", "BrowserSourceGlyphSegmentation", "BrowserForcedInpaintQuality",
                 "BrowserForcedSourceInpainting", "BrowserForcedComponentInpainting", "BrowserSlantedSourceRestoration"] {
        files.append(sources.appendingPathComponent("NativeEngine/Overlay/" + name + ".swift"))
    }
    // Diagnostics are injected only into generated copies; app sources stay untouched.
    if let index = files.firstIndex(where: { $0.lastPathComponent == "NativeCoreMLOCRPipeline.swift" }) {
        var pipeline = try read(files[index])
        pipeline = pipeline.replacingOccurrences(of: "            guard detection.requestID == requestID else {",
            with: "            HostDump.capture(\"detector-output\", detection)\n            guard detection.requestID == requestID else {")
        pipeline = pipeline.replacingOccurrences(of: "            let recognitionMilliseconds =",
            with: "            HostDump.capture(\"recognizer-output\", recognition as Any)\n            HostDump.capture(\"rejected-reads\", rejectedReads)\n            let recognitionMilliseconds =")
        let adaptedURL = cache.appendingPathComponent("NativeCoreMLOCRPipeline.swift")
        if (try? read(adaptedURL)) != pipeline { try pipeline.write(to: adaptedURL, atomically: true, encoding: .utf8) }
        files[index] = adaptedURL
    }
    if let index = files.firstIndex(where: { $0.lastPathComponent == "NativeCoreMLDetector.swift" }) {
        var detector = try read(files[index])
        let marker = "                    let result = try NativeCoreMLDBPostprocessor.decode("
        guard detector.contains(marker) else { throw NSError(domain: "DetectorTraceAdapter", code: 1) }
        detector = detector.replacingOccurrences(of: "        let issuedGeneration = generation.begin()", with: "        let hostDumpContext = HostDump.context\n        let issuedGeneration = generation.begin()")
        detector = detector.replacingOccurrences(of: marker, with: "                    HostDump.captureProbabilityMap(map.values, width: map.width, height: map.height, originX: region.x, originY: region.y, fullWidth: prepared.resizedWidth, fullHeight: prepared.resizedHeight, context: hostDumpContext)\n" + marker)
        let copy = cache.appendingPathComponent("NativeCoreMLDetector.swift")
        if (try? read(copy)) != detector { try detector.write(to: copy, atomically: true, encoding: .utf8) }
        files[index] = copy
    }
    files.append(root.appendingPathComponent("Aidoku/Extensions/Foundation/NSLocalizedString.swift"))
    files += [support.appendingPathComponent("HostTypographyBridge.swift"), support.appendingPathComponent("HostLetterFonts.swift"), support.appendingPathComponent("HostTranslationParity.swift"), support.appendingPathComponent("HostRenderGeometry.swift"), support.appendingPathComponent("HostExportCompositor.swift"), support.appendingPathComponent("HostSupport.swift"), support.appendingPathComponent("HostEnvironment.swift"), support.appendingPathComponent("PipelineMain.swift"), support.appendingPathComponent("HostAnalysis.swift"), support.appendingPathComponent("HostSegmentationTrace.swift")]
    let snapshotDirectory = cache.appendingPathComponent("sources")
    try manager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
    files = try files.map { file in
        let copy = snapshotDirectory.appendingPathComponent(file.lastPathComponent)
        let raw = try read(file)
        let data = Data(raw.replacingOccurrences(of: "import UIKit", with: "import AppKit").utf8)
        if (try? Data(contentsOf: copy)) != data { try data.write(to: copy, options: .atomic) }
        return copy
    }
    var hash = SHA256()
    hash.update(data: Data(generated.utf8))
    for file in files { hash.update(data: try Data(contentsOf: file)) }
    hash.update(data: Data((try read(URL(fileURLWithPath: #filePath))).utf8))
    let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
    let binary = cache.appendingPathComponent("image-translation")
    let stamp = cache.appendingPathComponent("fingerprint")
    if (try? read(stamp)) != fingerprint || !manager.fileExists(atPath: binary.path) {
        let generatedURL = cache.appendingPathComponent("ProductionAdapters.swift")
        let adapted = generated.replacingOccurrences(of: "@available(iOS 18.0, *)", with: "@available(macOS 15.0, *)")
            .replacingOccurrences(of: "secondaryMode = variant.lineBreakMode", with: "secondaryMode = Int(variant.lineBreakMode")
            .replacingOccurrences(of: "measurementCache: self).rawValue", with: "measurementCache: self).rawValue)")
            .replacingOccurrences(of: "primaryBreakMode: variant.lineBreakMode", with: "primaryBreakMode: Int(variant.lineBreakMode")
        if (try? read(generatedURL)) != adapted { try adapted.write(to: generatedURL, atomically: true, encoding: .utf8) }
        // Reuse object files; no clean or whole-module rebuild.
        let allFiles = [generatedURL] + files
        var outputMap: [String: [String: String]] = ["": ["swift-dependencies": cache.appendingPathComponent("master.swiftdeps").path]]
        for (index, file) in allFiles.enumerated() {
            let base = cache.appendingPathComponent("object-\(index)").path
            outputMap[file.path] = ["object": base + ".o", "swift-dependencies": base + ".swiftdeps"]
        }
        let map = cache.appendingPathComponent("output-map.json")
        try JSONSerialization.data(withJSONObject: outputMap, options: [.sortedKeys]).write(to: map)
        fputs("Building current Swift pipeline (incremental, -O)…\n", stderr)
        let code = try run("/usr/bin/xcrun", ["swiftc", "-O", "-incremental", "-enable-batch-mode", "-parse-as-library",
            "-module-name", "ImageTranslationHost", "-target", "arm64-apple-macos15.0", "-output-file-map", map.path]
            + allFiles.map(\.path) + ["-o", binary.path])
        guard code == 0 else { exit(code) }
        try fingerprint.write(to: stamp, atomically: true, encoding: .utf8)
    }
    var environment = ProcessInfo.processInfo.environment
    environment["AIDOKU_PIPELINE_ROOT"] = root.path
    environment["AIDOKU_PIPELINE_FINGERPRINT"] = fingerprint
    flock(lockDescriptor, LOCK_UN)
    close(lockDescriptor)
    holdsBuildLock = false
    exit(try run(binary.path, args, environment: environment))
} catch {
    fputs("image-translation: \(error)\n", stderr)
    exit(1)
}
