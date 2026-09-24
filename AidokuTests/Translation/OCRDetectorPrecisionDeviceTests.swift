import CoreML
import Foundation
import ImageIO
import Testing
@testable import Aidoku

/// Device-only experiment: compares the bundled fp16 Medium detector against
/// an optional fp32 reference copied to
/// Documents/OCRPrecision/PP-OCRv6-Medium-DetShapes-fp32.mlmodelc (baseline
/// when present), plus alternative compute units. The test loads models with
/// the production load options and runs the production preprocessing, float32
/// map materialization, and DB decoder.
@Suite(.serialized)
struct OCRDetectorPrecisionDeviceTests {
    private static var fixtures: URL { URL.documentsDirectory.appendingPathComponent("OptimizationFixtures") }

    private struct Variant {
        let name: String
        let url: URL
        let units: MLComputeUnits
        let lowPrecision: Bool
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: URL.documentsDirectory
        .appendingPathComponent("OptimizationFixtures").path)))
    func detectorPrecisionVariantsOnRealPages() async throws {
        guard #available(iOS 18.0, *) else { return }
        let bundled = try #require(Bundle.main.url(forResource: "PP-OCRv6-Medium-DetShapes", withExtension: "mlmodelc"))
        let fp32 = URL.documentsDirectory.appendingPathComponent("OCRPrecision/PP-OCRv6-Medium-DetShapes-fp32.mlmodelc")
        var variants: [Variant] = []
        // The first available variant is the comparison baseline; its name
        // always describes the resource actually loaded.
        if FileManager.default.fileExists(atPath: fp32.path) {
            variants.append(Variant(name: "fp32-all", url: fp32, units: .all, lowPrecision: false))
            variants.append(Variant(name: "fp32-cpuGPU", url: fp32, units: .cpuAndGPU, lowPrecision: false))
        }
        variants.append(Variant(name: "bundled-fp16-all",
                                url: bundled, units: .all, lowPrecision: false))
        variants.append(Variant(name: "bundled-fp16-cpuGPU", url: bundled, units: .cpuAndGPU, lowPrecision: false))
        let baselineName = try #require(variants.first?.name)
        var models: [String: MLModel] = [:]
        for variant in variants {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = variant.units
            configuration.allowLowPrecisionAccumulationOnGPU = variant.lowPrecision
            configuration.optimizationHints.reshapeFrequency = .frequent
            configuration.optimizationHints.specializationStrategy = .fastPrediction
            models[variant.name] = try await MLModel.load(contentsOf: variant.url, configuration: configuration)
        }
        let files = try FileManager.default.contentsOfDirectory(at: Self.fixtures, includingPropertiesForKeys: nil)
            .filter { ["png", "jpg", "jpeg", "webp"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let repeats = 3
        var rows: [[String: Any]] = []
        for file in files {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let frame = NativeOCRCGImageAdapter.makeRGBAFrame(from: image),
                  let canvas = NativeCoreMLDetectionCanvas.exact(
                      sourceWidth: frame.width, sourceHeight: frame.height,
                      maximumSide: IPhoneOCRSettings.defaultDetectorMaximumSide)
            else { continue }
            let prepared = try await NativeCoreMLDetectionPreprocessor.prepare(frame: frame, canvas: canvas)
            let input = await prepared.values()
            var baseline: NativeCoreMLDetectionMap?
            var baselineBoxes: [NativeCoreMLDetectionBox] = []
            var timings: [String: [Double]] = [:]
            // Round 0 specializes each variant for this shape and captures
            // outputs; later rounds are interleaved timings.
            for round in 0...repeats {
                await Self.waitForCoolDevice()
                for variant in round % 2 == 0 ? variants : variants.reversed() {
                    let model = try #require(models[variant.name])
                    let tensor = MLTensor(shape: canvas.inputShape, scalars: input)
                    let started = ContinuousClock.now
                    let outputs = try await withMLTensorComputePolicy(.init(variant.units)) {
                        try await model.prediction(from: [NativeCoreMLDetector.inputFeatureName: tensor])
                    }
                    let output = try #require(outputs[NativeCoreMLDetector.outputFeatureName])
                    // Production materializes with shapedArray(of: Float.self).
                    #expect(output.scalarType == Float.self)
                    let map = try await NativeCoreMLDetectionOutput.makeMap(
                        output: output, width: prepared.resizedWidth, height: prepared.resizedHeight,
                        expectedShape: canvas.outputShape)
                    let elapsed = Self.milliseconds(started)
                    if round > 0 {
                        timings[variant.name, default: []].append(elapsed)
                        continue
                    }
                    let boxes = try NativeCoreMLDBPostprocessor.decode(
                        map: map, sourceWidth: frame.width, sourceHeight: frame.height,
                        configuration: .production, allowsWeakBridgeSplit: true).boxes
                    var row: [String: Any] = [
                        "file": file.lastPathComponent, "variant": variant.name,
                        "baselineVariant": baselineName,
                        "boxes": boxes.map { ["s": $0.score, "p": $0.polygon.flatMap { [Double($0.x), Double($0.y)] }] },
                    ]
                    if variant.name == baselineName {
                        baseline = map
                        baselineBoxes = boxes
                    } else if let baseline {
                        var maximum: Float = 0
                        var flips = 0
                        for index in 0..<map.values.count {
                            maximum = max(maximum, abs(map.values[index] - baseline.values[index]))
                            if (map.values[index] > 0.3) != (baseline.values[index] > 0.3) { flips += 1 }
                        }
                        row["mapMax"] = Double(maximum)
                        row["flips03"] = flips
                        row["boxDelta"] = boxes.count - baselineBoxes.count
                        print("OCR_PRECISION \(file.lastPathComponent) \(variant.name) mapMax=\(maximum) flips=\(flips) boxes=\(baselineBoxes.count)->\(boxes.count)")
                    }
                    rows.append(row)
                }
            }
            for (name, values) in timings {
                let median = values.sorted()[values.count / 2]
                rows.append(["file": file.lastPathComponent, "variant": name, "medianMS": median, "samples": values])
                print("OCR_PRECISION_TIME \(file.lastPathComponent) \(name) medianMS=\(median)")
            }
        }
        let output = Self.fixtures.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            .write(to: output.appendingPathComponent("ocr-detector-precision.json"))
    }

    /// Every bundled fp16 detector tier must load with the production
    /// configuration and return float32 output through the production pipeline.
    @Test func bundledFloat16DetectorsRunThroughProductionPipeline() async throws {
        guard #available(iOS 18.0, *) else { return }
        let width = 800, height = 1_100
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        // Dark horizontal strokes resembling a text line.
        for row in 500..<530 { for column in 200..<600 where column % 40 < 28 {
            let offset = row * width * 4 + column * 4
            bytes[offset] = 0; bytes[offset + 1] = 0; bytes[offset + 2] = 0
        } }
        let frame = try #require(NativeOCRRGBAFrame(width: width, height: height, bytesPerRow: width * 4, bytes: bytes))
        for tier in IPhoneOCRModelTier.allCases {
            let profile = NativeCoreMLOCRModelProfile.profile(for: tier)
            let detector = NativeCoreMLDetector(modelResourceName: profile.detectorResourceName,
                                                maximumSide: IPhoneOCRSettings.defaultDetectorMaximumSide)
            let result = try await detector.detect(frame: frame, requestID: "fp16-\(tier.rawValue)",
                                                   configuration: profile.postprocessConfiguration)
            #expect(result.width == width && result.height == height)
            print("OCR_PRECISION_TIER \(tier.rawValue) boxes=\(result.boxes.count) ms=\(result.diagnostics.totalMilliseconds)")
            await detector.purgeResources()
        }
    }

    private static func waitForCoolDevice() async {
        for _ in 0..<60 {
            let state = ProcessInfo.processInfo.thermalState
            if state == .nominal || state == .fair { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }
}
