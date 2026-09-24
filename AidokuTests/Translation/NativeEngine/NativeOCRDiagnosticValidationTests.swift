import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Explicit local diagnostic only: no network, credentials, source-image export,
/// supplemental OCR, or second inference pass. Remove the config to disable.
@Suite(.serialized) @MainActor
struct NativeOCRDiagnosticValidationTests {
    private nonisolated static var folder: URL { URL.documentsDirectory.appendingPathComponent("MangaQuality") }
    private nonisolated static var configURL: URL { folder.appendingPathComponent("ocr-diagnostic.json") }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: configURL.path)))
    func captureExistingPassBeforeThresholdAndAfterMerge() async throws {
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: Self.configURL))
        #expect(!config.fixtures.isEmpty)
        let suite = "AidokuTests.OCRDiagnostic.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = config.ocr ?? ReaderTranslationSettings(defaults: defaults).ocrConfiguration
        let profile = NativeCoreMLOCRModelProfile.profile(for: configuration.modelTier)
        let sink = DiagnosticAuditSink()
        let detector = DiagnosticDetector(base: NativeCoreMLDetector(
            modelResourceName: profile.detectorResourceName, maximumSide: configuration.detectorMaximumSide
        ))
        let recognizer = NativeCoreMLRecognizer(
            modelResourceName: profile.recognizerResourceName,
            dictionaryResourceName: profile.dictionaryResourceName,
            expectedDictionaryCharacterCount: profile.expectedDictionaryCharacterCount,
            maximumRecognitionWidth: configuration.recognizerMaximumWidth,
            auditObserver: { sink.append($0) }
        )
        let pipeline = NativeCoreMLOCRPipeline(
            detector: detector, recognizer: recognizer, postprocessConfiguration: profile.postprocessConfiguration
        )
        let output = Self.folder.appendingPathComponent("ocr-diagnostic-output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: output.appendingPathComponent("configuration.json"), options: .atomic)
        do {
            for fixture in config.fixtures {
                try Task.checkCancellation()
                let url = Self.folder.appendingPathComponent(fixture).standardizedFileURL
                guard url.path.hasPrefix(Self.folder.standardizedFileURL.path + "/") else {
                    throw CocoaError(.fileReadInvalidFileName)
                }
                let data = try Data(contentsOf: url)
                let image = try #require(UIImage(data: data)?.cgImage)
                let name = url.deletingPathExtension().lastPathComponent
                sink.reset()
                detector.reset()
                // This is the ONLY detector/recognizer call per fixture.
                let result = try await pipeline.recognize(
                    image: image, requestID: name, confidenceThreshold: configuration.confidenceThreshold,
                    detectorConfiguration: configuration.detectorPostprocessConfiguration
                )
                let detection = try #require(detector.lastResult)
                let raw: [String: Any] = [
                    "id": name, "width": image.width, "height": image.height,
                    "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    "lines": result.lines.enumerated().map { index, line -> [String: Any] in
                        ["index": index, "text": line.text, "score": line.score,
                         "polygon": line.polygon.map { [$0.x, $0.y] },
                         "orientation": line.orientation.rawValue, "estimated": line.orientationIsEstimated]
                    }
                ]
                try write(raw, to: output.appendingPathComponent(name + "-native.json"))
                let audit: [String: Any] = [
                    "requestID": name, "completed": true, "ocrPasses": 1,
                    "detectorModel": result.diagnostics.detectionModel,
                    "recognizerModel": result.diagnostics.recognitionModel,
                    "detectedBoxes": detection.boxes.enumerated().map { index, box -> [String: Any] in
                        ["sourceIndex": index, "polygon": box.polygon.map { [$0.x, $0.y] }, "score": box.score]
                    },
                    "events": sink.snapshot.map(Self.auditJSON),
                    "nativeMilliseconds": result.totalMilliseconds,
                    "predictedRegions": result.diagnostics.recognition?.predictedRegions ?? 0,
                    "skippedInvalidRegions": result.diagnostics.recognition?.skippedInvalidRegions ?? 0
                ]
                try write(audit, to: output.appendingPathComponent(name + "-audit.json"))
                // Replays the CURRENT ReaderOCRService postprocessing on the same accepted lines.
                let (regions, joined, phases) = try await mergeLikeReaderService(result: result, image: image)
                try encoder.encode(regions.map(ReaderTranslationStoredRegion.init))
                    .write(to: output.appendingPathComponent(name + "-pre-balloon.json"), options: .atomic)
                try encoder.encode(joined.map(ReaderTranslationStoredRegion.init))
                    .write(to: output.appendingPathComponent(name + "-merge-replay.json"), options: .atomic)
                try write(phases, to: output.appendingPathComponent(name + "-phases.json"))
            }
        } catch {
            await pipeline.purgeResources()
            throw error
        }
        await pipeline.purgeResources()
    }

    private struct Configuration: Decodable {
        let fixtures: [String]
        let ocr: ReaderOCRConfiguration?
    }

    private static func auditJSON(_ event: NativeCoreMLRecognitionAuditEvent) -> [String: Any] {
        switch event {
        case let .requested(requestID, region):
            ["stage": "requested", "requestID": requestID, "sourceIndex": region.sourceIndex,
             "polygon": region.polygon.map { [$0.x, $0.y] }]
        case let .decoded(requestID, region, text, confidence, threshold, cacheHit):
            ["stage": "decoded", "requestID": requestID, "sourceIndex": region.sourceIndex,
             "polygon": region.polygon.map { [$0.x, $0.y] }, "text": text,
             "confidence": confidence, "threshold": threshold, "cacheHit": cacheHit,
             "accepted": !text.isEmpty && confidence >= threshold]
        }
    }

    private func write(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }

    // Source mirrored from ReaderOCRService.recognizeSerial. Keep this diagnostic
    // in sync with that implementation; it deliberately performs no new OCR.
    private func mergeLikeReaderService(
        result: NativeCoreMLOCRResult, image: CGImage
    ) async throws -> ([ReaderTranslationRegion], [ReaderTranslationRegion], [String: Double]) {
        let lines = result.lines
        var phases: [String: Double] = ["native": result.totalMilliseconds, "ocrPasses": 1]
        let wordStart = ProcessInfo.processInfo.systemUptime
        let wordCandidates = NativeOCRTextLineMerger.latinWordCandidates(lines)
        let recognizedWords: Set<String>
        if wordCandidates.isEmpty {
            recognizedWords = []
        } else {
            recognizedWords = await ReaderOCRWordBoundaryResolver.recognizedWords(in: wordCandidates)
        }
        try Task.checkCancellation()
        phases["wordBoundary"] = (ProcessInfo.processInfo.systemUptime - wordStart) * 1000
        let mergeStart = ProcessInfo.processInfo.systemUptime
        let separator = lines.count >= 2 ? NativeOCRRegionSeparator(image: image) : nil
        try Task.checkCancellation()
        // Cache even inconclusive colour samples: each candidate rectangle is sampled once.
        var inkSamples: [NSValue: [Double]] = [:]
        func ink(_ rect: CGRect) -> [Double] {
            let key = NSValue(cgRect: rect)
            if let cached = inkSamples[key] { return cached }
            let sample = ReaderTranslationBalloonMerger.outlinedInk(in: image, rect: rect)
            let value = sample.map { [$0.0, $0.1, $0.2] } ?? []
            inkSamples[key] = value
            return value
        }
        let merged = NativeOCRTextLineMerger.merge(
            lines, imageWidth: image.width, imageHeight: image.height, recognizedLatinWords: recognizedWords,
            separationCheck: { a, b, orientation in
                if orientation == .vertical {
                    let first = ink(a), second = ink(b)
                    if first.count == 3, second.count == 3 {
                        if zip(first, second).contains(where: { abs($0 - $1) >= 70 }) { return true }
                        // Outlined captions on artwork have observable gutters,
                        // even when recognition drops every quotation mark.
                        let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
                        if gap >= min(a.width, b.width) * 0.3 { return true }
                    }
                }
                return separator?.separates(a, b, orientation: orientation) ?? false
            }
        )
        try Task.checkCancellation()
        phases["mergeAndSeparator"] = (ProcessInfo.processInfo.systemUptime - mergeStart) * 1000
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let regions: [ReaderTranslationRegion] = merged.enumerated().compactMap { index, line in
            let rect = line.boundingRect.intersection(imageBounds)
            let source = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rect.isNull, !rect.isEmpty, !source.isEmpty else { return nil }
            return ReaderTranslationRegion(
                id: "region-\(index)",
                rect: CGRect(
                    x: rect.minX / imageBounds.width, y: rect.minY / imageBounds.height,
                    width: rect.width / imageBounds.width, height: rect.height / imageBounds.height
                ),
                source: source,
                polygon: line.poly.map { CGPoint(x: $0.x / imageBounds.width, y: $0.y / imageBounds.height) },
                confidence: line.score, sourceImageAspectRatio: Double(image.width) / Double(image.height), sourceOrientation: line.sourceOrientation,
                sourceSingleVerticalColumn: line.singleVerticalColumn,
                auxiliaryInkRects: line.auxiliaryInkRects.map { $0.intersection(imageBounds) }.filter { !$0.isNull && !$0.isEmpty }.map {
                    CGRect(x: $0.minX / imageBounds.width, y: $0.minY / imageBounds.height,
                           width: $0.width / imageBounds.width, height: $0.height / imageBounds.height)
                },
                auxiliaryInkPolygons: line.auxiliaryInkPolygons.map { $0.map { CGPoint(x: $0.x / imageBounds.width, y: $0.y / imageBounds.height) } }
            )
        }
        let balloonStart = ProcessInfo.processInfo.systemUptime
        let joined = ReaderTranslationBalloonMerger.apply(regions, image: image, sourceLines: lines.map { .init(polygon: $0.polygon, text: $0.text, orientation: $0.orientation) })
        phases["balloonMerge"] = (ProcessInfo.processInfo.systemUptime - balloonStart) * 1000
        try Task.checkCancellation()
        return (regions, joined, phases)
    }
}

private final class DiagnosticAuditSink: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [NativeCoreMLRecognitionAuditEvent] = []
    var snapshot: [NativeCoreMLRecognitionAuditEvent] { lock.withLock { events } }
    func append(_ event: NativeCoreMLRecognitionAuditEvent) { lock.withLock { events.append(event) } }
    func reset() { lock.withLock { events.removeAll(keepingCapacity: true) } }
}

private final class DiagnosticDetector: NativeCoreMLDetecting, @unchecked Sendable {
    let base: NativeCoreMLDetector
    private let lock = NSLock()
    private var stored: NativeCoreMLDetectionResult?
    init(base: NativeCoreMLDetector) { self.base = base }
    var lastResult: NativeCoreMLDetectionResult? { lock.withLock { stored } }
    func reset() { lock.withLock { stored = nil } }
    func prepare(sourceWidth: Int, sourceHeight: Int) async throws {
        try await base.prepare(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    }
    func detect(
        frame: NativeOCRRGBAFrame, requestID: String,
        configuration: NativeCoreMLDBPostprocessConfiguration,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLDetectionResult {
        try await detect(frame: frame, requestID: requestID, configuration: configuration,
                         recognitionScopes: nil, cancellationCheck: cancellationCheck)
    }
    func detect(
        frame: NativeOCRRGBAFrame, requestID: String,
        configuration: NativeCoreMLDBPostprocessConfiguration, recognitionScopes: [CGRect]?,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLDetectionResult {
        let result = try await base.detect(frame: frame, requestID: requestID, configuration: configuration,
                                           recognitionScopes: recognitionScopes, cancellationCheck: cancellationCheck)
        lock.withLock { stored = result }
        return result
    }
    func cancelCurrent() { base.cancelCurrent() }
    func cancelPreparation() { base.cancelPreparation() }
    func purgeResources() async { await base.purgeResources() }
}
