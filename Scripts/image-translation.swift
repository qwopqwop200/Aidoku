#!/usr/bin/env swift
// macOS launcher for the V2 page-translation host (Docs/translation-v2.md).
// Compiles Aidoku/Core/Translation/V2, its explicit production compile closure and
// Scripts/image-translation-v2 into one incremental binary, then forwards the CLI
// arguments. Usage: swift Scripts/image-translation.swift --help
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
    var v2Cache = ProcessInfo.processInfo.environment["AIDOKU_V2_CACHE"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL }
        ?? root.appendingPathComponent("build/image-translation-v2")
    try manager.createDirectory(at: v2Cache, withIntermediateDirectories: true)
    // One canonical spelling (/tmp vs /private/tmp): clang modules record their cache path.
    v2Cache = v2Cache.resolvingSymlinksInPath()
    let v2Lock = open(v2Cache.appendingPathComponent("build.lock").path, O_CREAT | O_RDWR, 0o600)
    guard v2Lock >= 0, flock(v2Lock, LOCK_EX) == 0 else { throw NSError(domain: "BuildLock", code: 2) }
    let v2Files = try manager.contentsOfDirectory(at: sources.appendingPathComponent("V2"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    let hostFiles = try manager.contentsOfDirectory(at: root.appendingPathComponent("Scripts/image-translation-v2"),
        includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    // Production compile closure of the V2 stages outside Translation/V2 (detector,
    // recognizer, translation client, simple grouping, painters). Found by iterative
    // typecheck; update it when these app files move or are split.
    let closure = [
        "Extensions/Foundation/NSLocalizedString.swift",
        "Core/Translation/NativeSimpleParagraphGrouping.swift",
        "Core/Translation/ReaderTranslationPanelOrder.swift",
    ] + ["NativeTranslationFontFitSearch", "NativeCTFontHorizontalFillPainter", "NativeCTFontStrokePainter"]
        .map { "Core/Translation/NativeEngine/Overlay/\($0).swift" }
      + ["NativeCoreMLDetector", "NativeCoreMLRecognizer", "BrowserOCRSourceOrientation", "NativeOCRLocalCoordinates",
         "NativeCoreMLDBPostprocessor", "NativeCoreMLModelStore", "NativeOCRCGImageAdapter", "NativeOCRFrameTypes",
         "NativeMangaNGram", "NativeOCRScopeGeometry"].map { "Core/Translation/NativeEngine/OCR/\($0).swift" }
      + ["RemoteTranslationClient", "TranslationHTTPCodec", "BoundedURLSessionTransport",
         "KeychainTranslationCredentialStore", "TranslationImageSupport", "TranslationModels",
         "TranslationRoleVerificationPlanner", "TranslationStreamDecoder", "TranslationBackgroundRolePolicy",
         "TranslationSFXEvidencePolicy", "TranslationEndpointPolicy"].map { "Core/Translation/NativeEngine/Translation/\($0).swift" }
      + ["Core/Translation/IPhoneOCRSettings.swift"]
    let closureFiles = closure.map { root.appendingPathComponent("Aidoku/" + $0) }
    let allV2 = v2Files + hostFiles + closureFiles
    var v2Hash = SHA256()
    v2Hash.update(data: Data("v2-host-2".utf8))
    for file in allV2 {
        v2Hash.update(data: Data(file.path.utf8))
        v2Hash.update(data: try Data(contentsOf: file))
    }
    let v2Fingerprint = v2Hash.finalize().map { String(format: "%02x", $0) }.joined()
    let v2Binary = v2Cache.appendingPathComponent("image-translation-v2")
    let v2Stamp = v2Cache.appendingPathComponent("fingerprint")
    if (try? read(v2Stamp)) != v2Fingerprint || !manager.fileExists(atPath: v2Binary.path) {
        var map: [String: [String: String]] = ["": ["swift-dependencies": v2Cache.appendingPathComponent("master.swiftdeps").path]]
        for file in allV2 {
            let identity = SHA256.hash(data: Data(file.path.utf8)).map { String(format: "%02x", $0) }.joined()
            let base = v2Cache.appendingPathComponent("object-" + identity).path
            map[file.path] = ["object": base + ".o", "swift-dependencies": base + ".swiftdeps"]
        }
        let mapURL = v2Cache.appendingPathComponent("output-map.json")
        try JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]).write(to: mapURL, options: .atomic)
        fputs("Building V2 pipeline (incremental, -O)…\n", stderr)
        let jobs = max(1, min(8, Int(ProcessInfo.processInfo.environment["AIDOKU_HOST_COMPILER_JOBS"] ?? "4") ?? 4))
        let status = try run("/usr/bin/xcrun", ["swiftc", "-O", "-incremental", "-enable-batch-mode", "-j", String(jobs),
            "-parse-as-library", "-module-name", "ImageTranslationV2Host", "-target", "arm64-apple-macos15.0",
            "-output-file-map", mapURL.path, "-module-cache-path", v2Cache.appendingPathComponent("module-cache").path,
            "-framework", "CoreText", "-framework", "Accelerate"] + allV2.map(\.path) + ["-o", v2Binary.path])
        guard status == 0 else { exit(status) }
        try v2Fingerprint.write(to: v2Stamp, atomically: true, encoding: .utf8)
    }
    flock(v2Lock, LOCK_UN)
    close(v2Lock)
    if ProcessInfo.processInfo.environment["AIDOKU_HOST_BUILD_ONLY"] == "1" { exit(0) }
    var environment = ProcessInfo.processInfo.environment
    environment["AIDOKU_PIPELINE_ROOT"] = root.path
    environment["AIDOKU_V2_CACHE"] = v2Cache.path
    exit(try run(v2Binary.path, args, environment: environment))
} catch {
    fputs("image-translation: \(error)\n", stderr)
    exit(1)
}
