#!/usr/bin/env swift
// macOS launcher: compiles the pipeline, its app closure and Scripts/image-translation-host into one
// incremental binary, then runs it with the CLI arguments. Usage: swift Scripts/image-translation.swift --help
import Foundation
import CryptoKit
import Darwin

let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let sources = root.appendingPathComponent("Aidoku/Core/Translation")
let support = root.appendingPathComponent("Scripts/image-translation")
let manager = FileManager.default
func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
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
    var pipelineCache = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_CACHE"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL }
        ?? root.appendingPathComponent("build/image-translation-host")
    try manager.createDirectory(at: pipelineCache, withIntermediateDirectories: true)
    // One canonical spelling (/tmp vs /private/tmp): clang modules record their cache path.
    pipelineCache = pipelineCache.resolvingSymlinksInPath()
    let pipelineLock = open(pipelineCache.appendingPathComponent("build.lock").path, O_CREAT | O_RDWR, 0o600)
    guard pipelineLock >= 0, flock(pipelineLock, LOCK_EX) == 0 else { throw NSError(domain: "BuildLock", code: 2) }
    let pipelineFiles = try manager.contentsOfDirectory(at: sources.appendingPathComponent("Pipeline"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    let hostFiles = try manager.contentsOfDirectory(at: root.appendingPathComponent("Scripts/image-translation-host"),
        includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    // App files the pipeline needs outside Translation/Pipeline; update when they move or split.
    let closure = [
        "Extensions/Foundation/NSLocalizedString.swift",
        "Core/Translation/ReaderTranslationPanelOrder.swift",
    ] + ["NativeTranslationFontFitSearch", "NativeCTFontHorizontalFillPainter", "NativeCTFontStrokePainter"]
        .map { "Core/Translation/NativeEngine/Overlay/\($0).swift" }
      + ["NativeCoreMLDetector", "NativeCoreMLRecognizer", "BrowserOCRSourceOrientation", "NativeOCRLocalCoordinates",
         "NativeCoreMLDBPostprocessor", "NativeCoreMLModelStore", "NativeOCRCGImageAdapter", "NativeOCRFrameTypes",
         "NativeMangaNGram"].map { "Core/Translation/NativeEngine/OCR/\($0).swift" }
      + ["RemoteTranslationClient", "TranslationHTTPCodec", "BoundedURLSessionTransport",
         "KeychainTranslationCredentialStore", "TranslationImageSupport", "TranslationModels",
         "TranslationStreamDecoder", "TranslationEndpointPolicy"].map { "Core/Translation/NativeEngine/Translation/\($0).swift" }
      + ["Core/Translation/IPhoneOCRSettings.swift"]
    let closureFiles = closure.map { root.appendingPathComponent("Aidoku/" + $0) }
    let allPipeline = pipelineFiles + hostFiles + closureFiles
    var pipelineHash = SHA256()
    pipelineHash.update(data: Data("pipeline-host-2".utf8))
    for file in allPipeline {
        pipelineHash.update(data: Data(file.path.utf8))
        pipelineHash.update(data: try Data(contentsOf: file))
    }
    let pipelineFingerprint = pipelineHash.finalize().map { String(format: "%02x", $0) }.joined()
    let pipelineBinary = pipelineCache.appendingPathComponent("image-translation-host")
    let pipelineStamp = pipelineCache.appendingPathComponent("fingerprint")
    if (try? read(pipelineStamp)) != pipelineFingerprint || !manager.fileExists(atPath: pipelineBinary.path) {
        var map: [String: [String: String]] = ["": ["swift-dependencies": pipelineCache.appendingPathComponent("master.swiftdeps").path]]
        for file in allPipeline {
            let identity = SHA256.hash(data: Data(file.path.utf8)).map { String(format: "%02x", $0) }.joined()
            let base = pipelineCache.appendingPathComponent("object-" + identity).path
            map[file.path] = ["object": base + ".o", "swift-dependencies": base + ".swiftdeps"]
        }
        let mapURL = pipelineCache.appendingPathComponent("output-map.json")
        try JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]).write(to: mapURL, options: .atomic)
        fputs("Building pipeline (incremental, -O)…\n", stderr)
        let jobs = max(1, min(8, Int(ProcessInfo.processInfo.environment["AIDOKU_HOST_COMPILER_JOBS"] ?? "4") ?? 4))
        let status = try run("/usr/bin/xcrun", ["swiftc", "-O", "-incremental", "-enable-batch-mode", "-j", String(jobs),
            "-parse-as-library", "-module-name", "ImageTranslationPipelineHost", "-target", "arm64-apple-macos15.0",
            "-output-file-map", mapURL.path, "-module-cache-path", pipelineCache.appendingPathComponent("module-cache").path,
            "-framework", "CoreText", "-framework", "Accelerate"] + allPipeline.map(\.path) + ["-o", pipelineBinary.path])
        guard status == 0 else { exit(status) }
        try pipelineFingerprint.write(to: pipelineStamp, atomically: true, encoding: .utf8)
    }
    flock(pipelineLock, LOCK_UN)
    close(pipelineLock)
    if ProcessInfo.processInfo.environment["AIDOKU_HOST_BUILD_ONLY"] == "1" { exit(0) }
    var environment = ProcessInfo.processInfo.environment
    environment["AIDOKU_PIPELINE_ROOT"] = root.path
    environment["AIDOKU_PIPELINE_CACHE"] = pipelineCache.path
    exit(try run(pipelineBinary.path, args, environment: environment))
} catch {
    fputs("image-translation: \(error)\n", stderr)
    exit(1)
}
