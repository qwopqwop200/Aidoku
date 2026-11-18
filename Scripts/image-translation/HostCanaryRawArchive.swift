import CoreGraphics
import Foundation
import ImageIO

/// Explicit host opt-in only. One actual raw tensor + its actual removal mask;
/// the existing strict archive independently rebuilds/compares all8MiB inputs.
@available(macOS 15.0, *)
final class HostCanaryRawArchive: @unchecked Sendable {
    enum Failure: Error { case request, binding, quota, duplicateCapture, noCapture }
    private let lock = NSLock()
    private let directory: URL, sourceFile: URL
    private let sourceSHA256: String
    let producerSHA256: String, producerConfigSHA256: String
    private let archive: NativeAOTRawPredictionArchive
    private let budget: Int
    private var retained: Int
    private var metadata: URL?
    private var binding: NativeAOTRawPredictionSnapshot.Binding?

    init(directory: URL, sourceFile: URL, expectedSourceEncodedSHA256: String,
         producerManifest: URL, producerConfig: Data, byteBudget: Int = 32 * 1024 * 1024) throws {
        guard directory.isFileURL, sourceFile.isFileURL, producerManifest.isFileURL,
              byteBudget > 0, byteBudget <= 32 * 1024 * 1024,
              !FileManager.default.fileExists(atPath: directory.path) else { throw Failure.request }
        let sourceData = try Data(contentsOf: sourceFile), manifest = try Data(contentsOf: producerManifest)
        guard NativeAOTRawPredictionSnapshot.sha(sourceData) == expectedSourceEncodedSHA256,
              (try JSONSerialization.jsonObject(with: manifest)) is [String: Any],
              (try JSONSerialization.jsonObject(with: producerConfig)) is [String: Any] else { throw Failure.binding }
        let overhead = manifest.count + producerConfig.count
        guard overhead + NativeAOTExactTensorCache.outputBytes < byteBudget else { throw Failure.quota }
        self.directory = directory; self.sourceFile = sourceFile
        self.sourceSHA256 = expectedSourceEncodedSHA256; self.budget = byteBudget; self.retained = overhead
        producerSHA256 = NativeAOTRawPredictionSnapshot.sha(manifest)
        producerConfigSHA256 = NativeAOTRawPredictionSnapshot.sha(producerConfig)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifest.write(to: directory.appendingPathComponent("producer-manifest.json"), options: .atomic)
        try producerConfig.write(to: directory.appendingPathComponent("producer-config.json"), options: .atomic)
        archive = try NativeAOTRawPredictionArchive(directory: directory.appendingPathComponent("raw"), byteBudget: byteBudget - overhead)
    }

    func configureCapture(backend: NativeMainAOTBackend = .shared) throws {
        try backend.configureRawPredictionCapture(producerSHA256: producerSHA256,
            producerConfigSHA256: producerConfigSHA256) { [self] snapshot in try append(snapshot) }
    }

    func append(_ snapshot: NativeAOTRawPredictionSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        guard snapshot.binding.producerSHA256 == producerSHA256,
              snapshot.binding.producerConfigSHA256 == producerConfigSHA256,
              let bytes = snapshot.capturedOriginalMask else { throw Failure.binding }
        if let record = metadata {
            let prior = try NativeAOTRawPredictionArchive.read(record)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(prior.snapshot.binding) == encoder.encode(snapshot.binding),
                  prior.snapshot.rawBytes == snapshot.rawBytes, prior.originalMask == bytes else { throw Failure.duplicateCapture }
            return // Exact repeated raw-cache hits retain the same immutable record.
        }
        let mask = try NativeAOTValidatedMask(validating: bytes, width: snapshot.binding.width,
            height: snapshot.binding.height, domain: .strict255)
        guard NativeAOTRawPredictionSnapshot.sha(mask.bytes) == snapshot.binding.originalMaskSHA256,
              let provider = CGDataProvider(data: Data(mask.bytes) as CFData),
              let image = CGImage(width: mask.width, height: mask.height, bitsPerComponent: 8,
                bitsPerPixel: 8, bytesPerRow: mask.width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.binding }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else { throw Failure.binding }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.binding }
        // Conservative JSON escaping/path overhead bounds the archive metadata
        // and index BEFORE writing even the mask. No silent quota truncation.
        let bindingBytes = try JSONEncoder().encode(snapshot.binding).count
        guard bindingBytes <= budget / 6 else { throw Failure.quota }
        let metadataAllowance = bindingBytes * 6 + sourceFile.path.utf8.count * 6 + directory.path.utf8.count * 12 + 4096
        guard encoded.length + NativeAOTExactTensorCache.outputBytes + metadataAllowance <= budget - retained else { throw Failure.quota }
        let maskFile = directory.appendingPathComponent("actual-original-mask.png")
        guard !FileManager.default.fileExists(atPath: maskFile.path) else { throw Failure.duplicateCapture }
        try (encoded as Data).write(to: maskFile, options: .atomic); retained += encoded.length
        let record = try archive.append(snapshot, sourceFile: sourceFile,
            expectedSourceEncodedSHA256: sourceSHA256, originalMaskFile: maskFile)
        // Full strict archive read again checks stored raw/reference corruption.
        _ = try NativeAOTRawPredictionArchive.read(record)
        metadata = record; binding = snapshot.binding
    }

    /// Call only after the render has completed. An empty capture is explicitly
    /// unobserved, never a fabricated one-record replay index.
    func finish() throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let record = metadata, let binding else { throw Failure.noCapture }
        _ = try NativeAOTRawPredictionArchive.read(record)
        let index: [String: Any] = ["schema": "attested-exact-AOT-raw-replay-index-v1",
            "producerSHA256": producerSHA256, "producerConfigSHA256": producerConfigSHA256,
            "compiledModelSHA256": binding.policy.installedModelSHA256,
            "records": [["metadataPath": record.standardizedFileURL.path,
                "metadataSHA256": NativeAOTRawPredictionSnapshot.sha(try Data(contentsOf: record))]]]
        let data = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys, .withoutEscapingSlashes])
        let indexFile = directory.appendingPathComponent("RAW-REPLAY-INDEX.json")
        guard !FileManager.default.fileExists(atPath: indexFile.path) else { throw Failure.duplicateCapture }
        let existing = try Self.totalBytes(directory)
        guard data.count <= budget - existing else { throw Failure.quota }
        try data.write(to: indexFile, options: .atomic)
        let digest = NativeAOTRawPredictionSnapshot.sha(data)
        _ = try NativeAOTRawPredictionReplay(indexFile: indexFile, expectedIndexSHA256: digest)
        return ["archiveDirectory": directory.path, "records": 1, "sourceEncodedSHA256": sourceSHA256,
            "producerManifestSHA256": producerSHA256, "producerConfigSHA256": producerConfigSHA256,
            "producerSHA256Kind": "SHA256 of copied actual compiled producer-manifest file bytes",
            "replayIndex": indexFile.path, "replayIndexSHA256": digest,
            "retainedBytes": try Self.totalBytes(directory), "byteBudget": budget,
            "inputTensorsRegeneratedAndBitVerifiedByStrictArchive": true,
            "freshPredictionCountClaim": "not inferred from capture; use process prediction-budget receipt"]
    }
    private static func totalBytes(_ directory: URL) throws -> Int {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            throw Failure.binding
        }
        var sum = 0
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { sum += values.fileSize ?? 0 }
        }
        return sum
    }
}
