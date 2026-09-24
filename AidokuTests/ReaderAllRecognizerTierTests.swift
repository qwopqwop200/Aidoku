import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct ReaderAllRecognizerTierTests {
    // Root supplies one real text crop from the fixed Lookahead fixture; this test never runs detector/API.
    // input.json: {"image":"comic.jpg","crop":[x,y,width,height]}; pixels in LookaheadDevice image.
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("Round2Recognizer/input.json").path)))
    func productionRecognizerEveryTierOneRealCrop() async throws {
        guard #available(iOS 18.0, *) else { return }
        struct Input: Decodable { let image: String; let crop: [Int] }
        let root = URL.documentsDirectory.appendingPathComponent("Round2Recognizer")
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: root.appendingPathComponent("input.json")))
        let fixtureRoot = URL.documentsDirectory.appendingPathComponent("LookaheadDevice")
        let imageURL = fixtureRoot.appendingPathComponent(input.image).standardizedFileURL
        try #require(imageURL.path.hasPrefix(fixtureRoot.standardizedFileURL.path + "/"))
        try #require(input.crop.count == 4)
        let box = input.crop
        try #require(box[0] >= 0 && box[1] >= 0 && box[2] > 0 && box[3] > 0 && box[2] <= 1024 && box[3] <= 1024)
        let sourceData = try Data(contentsOf: imageURL)
        let crop: CGImage = try autoreleasepool {
            let source = try #require(UIImage(data: sourceData)?.cgImage)
            try #require(box[0] <= source.width - box[2] && box[1] <= source.height - box[3])
            return try #require(source.cropping(to: CGRect(x: box[0], y: box[1], width: box[2], height: box[3])))
        }
        let frame = try #require(await NativeOCRCGImageAdapter.makeRGBAFrameOffMain(from: crop))
        let region = NativeCoreMLRecognitionRegion(sourceIndex: 0, polygon: [
            CGPoint(x: 0, y: 0), CGPoint(x: crop.width, y: 0),
            CGPoint(x: crop.width, y: crop.height), CGPoint(x: 0, y: crop.height)])
        let output = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let cropPNG = try #require(UIImage(cgImage: crop).pngData())
        try cropPNG.write(to: output.appendingPathComponent("input-crop.png"))
        try JSONEncoder().encode(NativeOCRFrameDigestBuilder.fingerprint(of: frame))
            .write(to: output.appendingPathComponent("input-pixels.json"))
        var rows: [[String: Any]] = []
        await ReaderOCRService.shared.purge()
        for tier in IPhoneOCRModelTier.allCases {
            let profile = NativeCoreMLOCRModelProfile.profile(for: tier)
            // Exactly the recognizer configuration used by NativeCoreMLOCRPipeline's tier initializer.
            let recognizer = NativeCoreMLRecognizer(modelResourceName: profile.recognizerResourceName,
                dictionaryResourceName: profile.dictionaryResourceName,
                expectedDictionaryCharacterCount: profile.expectedDictionaryCharacterCount,
                maximumRecognitionWidth: IPhoneOCRSettings.defaultRecognizerMaximumWidth)
            var reference: [NativeCoreMLRecognizedRegion]?
            do {
                for pass in 0..<2 {
                    let before = Self.memory()
                    let start = ProcessInfo.processInfo.systemUptime
                    let result = try await recognizer.recognize(frame: frame, regions: [region], confidenceThreshold: 0)
                    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    let after = Self.memory()
                    let payload: [[String: Any]] = result.regions.map { row in
                        ["sourceIndex": row.sourceIndex, "text": row.text,
                         "confidenceBits": String(row.confidence.bitPattern),
                         "polygonBits": row.polygon.map { [String(Double($0.x).bitPattern), String(Double($0.y).bitPattern)] }]
                    }
                    try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
                        .write(to: output.appendingPathComponent("\(tier.rawValue)-\(pass)-regions.json"))
                    if let reference { #expect(result.regions == reference) } else { reference = result.regions }
                    #expect(result.regions.count == 1, "Fixed crop must produce one accepted region; empty output is not model-quality success")
                    #expect(result.regions.first?.text.isEmpty == false)
                    let d = result.diagnostics
                    rows.append(["tier": tier.rawValue, "pass": pass, "phase": pass == 0 ? "cold" : "warm",
                        "milliseconds": elapsed, "model": d.modelName, "computeUnits": d.computeUnits,
                        "modelLoadMS": d.modelLoadMilliseconds, "functionLoadMS": d.modelFunctionLoadMilliseconds,
                        "preprocessingMS": d.preprocessingMilliseconds, "predictionMS": d.predictionMilliseconds,
                        "decodingMS": d.decodingMilliseconds, "cacheHits": d.cacheHitRegions,
                        "predictedRegions": d.predictedRegions, "rssBeforeMiB": before.rss,
                        "rssAfterMiB": after.rss, "footprintBeforeMiB": before.footprint,
                        "footprintAfterMiB": after.footprint])
                    try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])
                        .write(to: output.appendingPathComponent("samples.json"))
                }
            } catch {
                await recognizer.purgeResources()
                throw error
            }
            await recognizer.purgeResources()
            let purged = Self.memory()
            try JSONSerialization.data(withJSONObject: ["rssMiB": purged.rss, "footprintMiB": purged.footprint])
                .write(to: output.appendingPathComponent("\(tier.rawValue)-after-purge.json"))
        }
        let scope: [String: Any] = ["sourceSHA256": SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined(),
            "crop": box, "scope": "One identical real text crop, every production recognizer tier sequentially cold/warm, explicit purge each. Region confidence threshold zero for direct model diagnostic; detector/merger/reader acceptance/display are not exercised. Warm may be crop-cache hit: inspect predictedRegions/cacheHits. Memory is endpoint RSS/physical footprint only, not sampled or true peak. Compare full payload exactly within tier across builds; different tiers may legitimately differ. No device/Jetsam guarantee."]
        try JSONSerialization.data(withJSONObject: scope, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("scope.json"))
    }
    private static func memory() -> (rss: Double, footprint: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return (-1, -1) }
        return (Double(info.resident_size) / 1_048_576, Double(info.phys_footprint) / 1_048_576)
    }
}
