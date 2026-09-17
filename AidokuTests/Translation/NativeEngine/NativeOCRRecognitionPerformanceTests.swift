import CoreGraphics
import CryptoKit
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct NativeOCRRecognitionPerformanceTests {
    /// Opt-in real-image device workload; baseline tensors/results are never
    /// replaced by the verification run. No API requests are made.
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("OCRDeviceBenchmark/manifest.json").path)))
    func realPageDeviceRecognition() async throws {
        struct Fixture: Decodable {
            struct Line: Decodable { let polygon: [[CGFloat]] }
            let id: String
            let image: String
            let lines: [Line]
        }
        struct RecognizedOutput: Decodable {
            let index: Int
            let text: String
            let confidenceBits: String
            let polygon: [[String]]
        }
        let directory = URL.documentsDirectory.appendingPathComponent("OCRDeviceBenchmark")
        let fixtures = try JSONDecoder().decode([Fixture].self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let baselineURL = directory.appendingPathComponent("baseline.json")
        let reference: [String: String]?
        if FileManager.default.fileExists(atPath: baselineURL.path) {
            reference = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: baselineURL))
        } else {
            reference = nil
        }
        let recognizer = NativeCoreMLRecognizer(recognitionCacheCapacity: 0, maximumRecognitionWidth: 1600)
        var outputs: [String: String] = [:]
        var timings: [[String: Any]] = []
        for run in 0..<3 {
            for fixture in fixtures {
                let image = try #require(UIImage(contentsOfFile: directory.appendingPathComponent(fixture.image).path)?.cgImage)
                let frame = try #require(NativeOCRCGImageAdapter.makeRGBAFrame(from: image))
                let regions = fixture.lines.enumerated().map { index, line in
                    NativeCoreMLRecognitionRegion(sourceIndex: index,
                        polygon: line.polygon.map { CGPoint(x: $0[0], y: $0[1]) })
                }
                let result = try await recognizer.recognize(frame: frame, regions: regions)
                let payload: [[String: Any]] = result.regions.map { region in
                    ["index": region.sourceIndex, "text": region.text,
                     "confidenceBits": String(region.confidence.bitPattern),
                     "polygon": region.polygon.map { [String(Double($0.x).bitPattern), String(Double($0.y).bitPattern)] }]
                }
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                let key = "\(fixture.id)-\(run)"
                outputs[key] = data.base64EncodedString()
                if let reference {
                    let baselineData = try #require(reference[key].flatMap { Data(base64Encoded: $0) })
                    let expected = try JSONDecoder().decode([RecognizedOutput].self, from: baselineData)
                    let actual = try JSONDecoder().decode([RecognizedOutput].self, from: data)
                    #expect(actual.count == expected.count, "Region count differs for \(key)")
                    var maximumConfidenceDelta = 0.0
                    for (actualRegion, expectedRegion) in zip(actual, expected) {
                        #expect(actualRegion.index == expectedRegion.index)
                        #expect(actualRegion.text == expectedRegion.text, "Text differs for \(key)")
                        #expect(actualRegion.polygon == expectedRegion.polygon)
                        let actualBits = try #require(UInt64(actualRegion.confidenceBits))
                        let expectedBits = try #require(UInt64(expectedRegion.confidenceBits))
                        let delta = abs(Double(bitPattern: actualBits) - Double(bitPattern: expectedBits))
                        // Runtime specialization can change rounding without changing recognition.
                        #expect(delta <= 0.0001, "Confidence drift for \(key): \(delta)")
                        maximumConfidenceDelta = max(maximumConfidenceDelta, delta)
                    }
                    print("DEVICE_OCR_QUALITY key=\(key) confidence_delta=\(maximumConfidenceDelta)")
                }
                let d = result.diagnostics
                #expect(d.cacheHitRegions == 0)
                let timing: [String: Any] = ["key": key, "total": d.totalMilliseconds,
                    "prediction": d.predictionMilliseconds, "preparation": d.preprocessingMilliseconds,
                    "decoding": d.decodingMilliseconds, "loads": d.modelFunctionLoads,
                    "loadMilliseconds": d.modelFunctionLoadMilliseconds,
                    "functions": d.modelFunctionSequence, "thermal": ProcessInfo.processInfo.thermalState.rawValue]
                timings.append(timing)
                print("DEVICE_OCR key=\(key) total=\(d.totalMilliseconds) prediction=\(d.predictionMilliseconds) prep=\(d.preprocessingMilliseconds) loads=\(d.modelFunctionLoads) load_ms=\(d.modelFunctionLoadMilliseconds)")
            }
        }
        if reference == nil { try JSONEncoder().encode(outputs).write(to: baselineURL, options: .atomic) }
        try JSONEncoder().encode(outputs).write(to: directory.appendingPathComponent("outputs-latest.json"), options: .atomic)
        let name = reference == nil ? "timings-baseline.json" : "timings-verified.json"
        try JSONSerialization.data(withJSONObject: timings, options: [.sortedKeys]).write(to: directory.appendingPathComponent(name), options: .atomic)
        await recognizer.purgeResources()
    }

    /// A repeatable real-model workload. Crop caching is disabled so warm runs
    /// still measure recognition, rather than reuse of the preceding result.
    @Test @MainActor func bundledMediumDenseRecognition() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1_000, height: 1_000), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_000, height: 1_000))
            for index in 0..<24 {
                ("HELLO WORLD SAMPLE TEXT 123" as NSString).draw(
                    at: CGPoint(x: 8, y: index * 40),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black]
                )
            }
        }
        let pixels = try #require(image.cgImage)
        let frame = try #require(NativeOCRCGImageAdapter.makeRGBAFrame(from: pixels))
        let regions = (0..<24).map { index in
            let width = [200, 400, 800][index % 3]
            let y = index * 40
            return NativeCoreMLRecognitionRegion(sourceIndex: index, polygon: [
                CGPoint(x: 0, y: y), CGPoint(x: width, y: y),
                CGPoint(x: width, y: y + 32), CGPoint(x: 0, y: y + 32)
            ])
        }
        let recognizer = NativeCoreMLRecognizer(recognitionCacheCapacity: 0, maximumRecognitionWidth: 1_600)
        var reference: [NativeCoreMLRecognizedRegion]?
        for run in 0..<4 {
            let result = try await recognizer.recognize(frame: frame, regions: regions)
            #expect(result.regions.count == regions.count)
            #expect(result.regions.map(\.sourceIndex) == Array(0..<24))
            #expect(result.diagnostics.cacheHitRegions == 0)
            if let reference { #expect(result.regions == reference) } else { reference = result.regions }
            let digest = SHA256.hash(data: Data(result.regions.map(\.text).joined(separator: "\n").utf8))
                .map { String(format: "%02x", $0) }.joined()
            let diagnostic = result.diagnostics
            print("OCR_BENCH run=\(run) total_ms=\(diagnostic.totalMilliseconds) prep_ms=\(diagnostic.preprocessingMilliseconds) "
                  + "prediction_ms=\(diagnostic.predictionMilliseconds) digest=\(digest)")
        }
        await recognizer.purgeResources()
    }
}
