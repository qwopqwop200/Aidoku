import AidokuNativeCV
import Foundation
#if os(iOS)
import os
#endif

/// Measurements must use immutable page inputs and private crop scratch. Each lane
/// owns its result until the join, then the caller consumes errors and values in source order.
enum NativeSourceOwnerMeasurements {
    enum Mode {
        case style, base4, serial, sourcePreparation

        func mayPair(owner: Int) -> Bool {
            switch self {
            case .style, .sourcePreparation: true
            // Finish the first crop's font authentication before another crop
            // can map the same cold system fonts.
            case .base4: owner > 0
            case .serial: false
            }
        }
    }

    static func allowsPairing(processors: Int, physicalMemory: UInt64, availableMemory: UInt64) -> Bool {
        let gibibyte: UInt64 = 1_024 * 1_024 * 1_024
        return processors >= 4 && physicalMemory >= 7 * gibibyte && availableMemory >= 2 * gibibyte
    }

    private static var availableMemory: UInt64 {
        #if os(iOS)
        UInt64(os_proc_available_memory())
        #else
        .max
        #endif
    }

    private final class Lane<Value>: @unchecked Sendable {
        let operation: () throws -> Value
        var result: Result<Value, Error>?

        init(_ operation: @escaping () throws -> Value) { self.operation = operation }

        func run() { result = Result { try autoreleasepool(invoking: operation) } }
    }

    // The BASE4 bridge authenticates one set of font faces at a time. Keep
    // both outer lanes serial internally, and bound the simultaneous scratch
    // by the allowed pixel area of one source crop.
    static func allowsIndependentPageStages(largestCrop: Int) -> Bool {
        let p = ProcessInfo.processInfo
        return allowsIndependentPageStages(largestCrop: largestCrop, processors: p.activeProcessorCount,
                                           physicalMemory: p.physicalMemory, availableMemory: availableMemory)
    }

    static func allowsIndependentPageStages(largestCrop: Int, processors: Int,
                                            physicalMemory: UInt64, availableMemory: UInt64) -> Bool {
        largestCrop > 0 && largestCrop <= 1_500_000 / 2 &&
            allowsPairing(processors: processors, physicalMemory: physicalMemory, availableMemory: availableMemory)
    }

    static func pair<Value>(_ first: @escaping () throws -> Value, _ second: @escaping () throws -> Value)
        throws -> (Value, Value) {
        try Task.checkCancellation()
        let lanes = [Lane(first), Lane(second)]
        DispatchQueue.concurrentPerform(iterations: 2) { lanes[$0].run() }
        try Task.checkCancellation()
        return (try lanes[0].result!.get(), try lanes[1].result!.get())
    }

    static func map<Value>(count: Int, pixels: (Int) -> Int, mode: Mode = .style,
                           measure: @escaping (Int) throws -> Value) throws -> [Value] {
        var output: [Value] = []
        output.reserveCapacity(count)
        let process = ProcessInfo.processInfo
        let processors = process.activeProcessorCount, physicalMemory = process.physicalMemory
        // Two small crops share a 512×512 pixel scratch budget. Large crops run alone.
        let pairLimit = 262_144
        var i = 0
        while i < count {
            try Task.checkCancellation()
            if i + 1 < count, mode.mayPair(owner: i), pixels(i) <= pairLimit, pixels(i + 1) <= pairLimit - pixels(i),
               allowsPairing(processors: processors, physicalMemory: physicalMemory, availableMemory: availableMemory) {
                let first = i, second = i + 1
                let values = try pair({ try measure(first) }, { try measure(second) })
                output.append(values.0)
                output.append(values.1)
                i += 2
            } else {
                output.append(try autoreleasepool { try measure(i) })
                i += 1
            }
        }
        try Task.checkCancellation()
        return output
    }
}

/// One existing 297714-byte BODY classifier, not the full accepted weight graph.
/// Its source measurements use the ORIGINAL constructor prior. No accepted
/// font estimator, PCA, prototype bank, residual262, paired48, bands112 or image
/// rescue policy is constructed by this object.
final class NativeSingleBodyWeightInference {
    static let revision = "single-body180-original-prior-weight-v1"
    static let threshold = 0.025
    static let modelIdentity = "font-weight/complete-complementary/body/model"
    static let modelSHA256 = "5322ae3c5fe520234eb3b39a39ebd60bed9024befe798b6e12b925b79fc421de"
    static let rawFeatureCount = 597
    static let pageFeatureCount = 1791
    enum Failure: Error { case invalid(String), extraction(String) }
    enum MeasurementABI: String {
        case genericAdmission = "dedicated-raw597-generic-admission-v1"
        case base4 = "raw597-base4-v1"
    }
    private let model: NativeFrozenSourceModel
    private let measurementSpec: [String: Any]
    private let measurementABI: MeasurementABI
    private struct BodyObservation {
        let width: Int
        let height: Int
        let rgb: [UInt8]
        let ownMask: [UInt8]
        let bbox: CGRect
        let fontPriorSourcePixels: Double
        let sourceIdentity: String
        let sourceText: String
        let memberPolygons: [[CGPoint]]
    }

    convenience init(heads: NativeAppearanceModelHeads, measurementSpec: [String: Any],
        measurementABI: MeasurementABI = .genericAdmission) throws {
        try self.init(directory: heads.directory, measurementSpec: measurementSpec, measurementABI: measurementABI,
            loadModel: { _ in try heads.model(Self.modelIdentity) })
    }

    /// Compact registry and pinned BODY asset only. No appearance-head manager
    /// or appearance metadata is constructed or parsed by this path.
    convenience init(directory: URL, measurementSpec: [String: Any],
        measurementABI: MeasurementABI = .genericAdmission) throws {
        try self.init(directory: directory, measurementSpec: measurementSpec, measurementABI: measurementABI,
            loadModel: { try $0.model(Self.modelIdentity) })
    }

    private init(directory: URL, measurementSpec: [String: Any], measurementABI: MeasurementABI,
        loadModel: (NativeFrozenSourceModel.Registry) throws -> NativeFrozenSourceModel) throws {
        // The compact index authenticates the selected asset without parsing
        // font graph metadata or initializing any font model/prototype bank.
        let index = try NativeFrozenSourceModel.Registry(directory: directory)
        guard let record = index.heads[Self.modelIdentity], record.sha256 == Self.modelSHA256,
              record.featureCount == Self.pageFeatureCount, record.kind == "forest" else {
            throw Failure.invalid("single BODY model binding")
        }
        let model = try loadModel(index)
        guard model.featureCount == Self.pageFeatureCount, model.classes == [0, 1],
              model.forests.count == 1, model.forests[0].trees.count == 180,
              !model.forests[0].float32Input else {
            throw Failure.invalid("single BODY Double forest contract")
        }
        self.model = model
        self.measurementSpec = measurementSpec
        self.measurementABI = measurementABI
    }

    /// The caller supplies the whole actual source-owner cohort for this page,
    /// in its observed order. Do not reduce the context using GT correspondence.
    func estimate(_ inputs: [SourceNativeInput], styles: [[String: Any]]) throws -> [[String: Any]] {
        try estimateObservations(inputs.map { input in
            BodyObservation(width: input.width, height: input.height, rgb: input.rgb, ownMask: input.ownMask,
                bbox: input.bbox, fontPriorSourcePixels: input.fontPriorSourcePixels, sourceIdentity: input.sourceIdentity,
                sourceText: input.sourceText, memberPolygons: input.memberPolygons)
        }, styles: styles)
    }

    /// Actual p-only DTOs remain p-only: never manufacture rich q/RF/OCR data.
    /// Primary is validated by the DTO, but is not a raw597 numeric input.
    func estimate(_ inputs: [NativeMinimalSourceStyleInput], styles: [[String: Any]]) throws -> [[String: Any]] {
        guard inputs.count == styles.count, inputs.count <= 4096,
              Set(inputs.map(\.sourceIdentity)).count <= 1 else { throw Failure.invalid("single BODY page cohort") }
        for input in inputs { try input.validate() }
        return try estimateMinimal(inputs, styles: styles)
    }

    func estimateBase4(_ inputs: [NativeMinimalSourceStyleInput]) throws -> [[String: Any]] {
        guard measurementABI == .base4 else { throw Failure.invalid("single BODY BASE4 bridge") }
        for input in inputs { try input.validate() }
        return try estimateMinimal(inputs, styles: nil, serial: true)
    }

    private func estimateMinimal(_ inputs: [NativeMinimalSourceStyleInput], styles: [[String: Any]]?,
                                 serial: Bool = false) throws -> [[String: Any]] {
        return try estimateObservations(inputs.map { input in
            BodyObservation(width: input.width, height: input.height, rgb: input.rgb, ownMask: input.ownMask,
                bbox: input.bbox, fontPriorSourcePixels: input.fontPriorSourcePixels, sourceIdentity: input.sourceIdentity,
                sourceText: input.sourceText, memberPolygons: input.memberPolygons)
        }, styles: styles, serial: serial)
    }

    private func estimateObservations(_ inputs: [BodyObservation], styles: [[String: Any]]?, serial: Bool = false) throws -> [[String: Any]] {
        guard (styles.map { $0.count == inputs.count } ?? (measurementABI == .base4)), inputs.count <= 4096,
              Set(inputs.map(\.sourceIdentity)).count <= 1 else { throw Failure.invalid("single BODY page cohort") }
        if inputs.isEmpty { return [] }
        let raw = try NativeSourceOwnerMeasurements.map(count: inputs.count, pixels: { inputs[$0].ownMask.count },
            mode: !serial && measurementABI == .base4 ? .base4 : .serial) { [self] index in
            let input = inputs[index]
            try Task.checkCancellation()
            guard input.width > 0, input.height > 0, input.width <= 1_500_000 / input.height,
                  input.rgb.count == input.width * input.height * 3,
                  input.ownMask.count == input.width * input.height,
                  input.fontPriorSourcePixels.isFinite, input.fontPriorSourcePixels > 0 else {
                throw Failure.invalid("single BODY actual crop")
            }
            // Dedicated raw597 bridge skips unused direct7/fill71 arithmetic.
            // Generic admission retains real prior/sourceEm, style/ownership
            // and pinned4/8/4 for actual legacy callers. Explicit BASE4 sends
            // only the numeric raw inputs; no fake legacy fields/banks exist.
            var request: [String: Any] = ["width": input.width, "height": input.height,
                "rgb": Data(input.rgb),
                "bbox": [input.bbox.minX, input.bbox.minY, input.bbox.width, input.bbox.height].map(Double.init),
                "prior": input.fontPriorSourcePixels, "text": input.sourceText,
                "GTMaskUsed": false, "inferenceUsesGT": false]
            if measurementABI == .base4 {
                guard let fonts = measurementSpec["fonts"] as? [[String: Any]], fonts.count == 4 else {
                    throw Failure.invalid("single BODY BASE4 descriptor count")
                }
                request["measurementABI"] = measurementABI.rawValue
                request["measurementSpec"] = ["fonts": fonts]
            } else {
                request["ownership"] = Data(input.ownMask)
                request["sourceEm"] = input.fontPriorSourcePixels
                guard let styles else { throw Failure.invalid("single BODY styles") }
                request["style"] = styles[index]
                request["measurementSpec"] = measurementSpec
                request["memberPolygons"] = input.memberPolygons.map { $0.map { [Double($0.x), Double($0.y)] } }
            }
            return try Self.extractRaw597(packet: request, measurementABI: measurementABI)
        }
        return try predict(raw597: raw)
    }

    /// The production native dispatch and result contract, shared with app-hosted tests.
    static func extractRaw597(packet: [String: Any], measurementABI: MeasurementABI) throws -> [Double] {
        var error: NSError?
        let extracted = measurementABI == .base4 ? AIDExtractSourceWeightRaw597Base4(packet, &error)
            : AIDExtractSourceWeightRaw597(packet, &error)
        if measurementABI == .base4, let extracted,
           extracted["measurementABI"] as? String != measurementABI.rawValue {
            throw Failure.invalid("single BODY BASE4 bridge ABI binding")
        }
        guard let values = extracted,
              let vector = values["raw597"] as? [Double] else {
            throw Failure.extraction(error?.localizedDescription ?? "single BODY raw597 extraction")
        }
        guard vector.count == Self.rawFeatureCount, vector.allSatisfy(\.isFinite),
              vector.prefix(6).allSatisfy({ $0 == 0 }) else {
            throw Failure.invalid("single BODY original-prior raw597 ABI")
        }
        return vector
    }

    /// Numeric-only path for exact actual-input replay. Original Double values
    /// and whole-page medians/IQR are retained; no Float32 batch conversion.
    func predict(raw597: [[Double]]) throws -> [[String: Any]] {
        guard raw597.count <= 4096, raw597.allSatisfy({ $0.count == Self.rawFeatureCount && $0.allSatisfy(\.isFinite) &&
            $0.prefix(6).allSatisfy({ $0 == 0 }) }) else { throw Failure.invalid("single BODY raw batch") }
        if raw597.isEmpty { return [] }
        let page = try NativeSourceWeightGraph.pageContext(raw597)
        guard page.allSatisfy({ $0.count == Self.pageFeatureCount && $0.allSatisfy(\.isFinite) }) else {
            throw Failure.invalid("single BODY page context")
        }
        let probabilities = try model.predictProbability(page)
        guard probabilities.count == raw597.count else { throw Failure.invalid("single BODY output count") }
        return try probabilities.map { row -> [String: Any] in
            guard row.count == 2, row.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw Failure.invalid("single BODY probability")
            }
            let bold = row[1] >= Self.threshold, label = bold ? "bold" : "regular"
            return ["sourceWeight": label, "renderWeight": label, "renderBold": bold,
                "bodyScore": row[1], "threshold": Self.threshold,
                "requiresTranslationSpanAlignment": false, "translatedStyleRuns": [[String: Any]](),
                "sourceOnly": true, "GTAtInference": false, "version": Self.revision,
                "modelIdentity": Self.modelIdentity, "modelSHA256": Self.modelSHA256,
                "rawFeatureCount": Self.rawFeatureCount, "pageFeatureCount": Self.pageFeatureCount,
                "weightModelRoleCount": 1, "acceptedFontHeadUsed": false,
                "PCAUsed": false, "prototypeBanksUsed": false,
                "sourceEMAuthority": "original-constructor-prior; not accepted-font-head output",
                "physicalGlyphMetricsRetained": true,
                "raw597OnlyBridge": true,
                "measurementABI": measurementABI.rawValue,
                "fontDescriptorAdmission": measurementABI == .base4 ? "BASE4-only per-crop; initializer resource closure declared separately"
                    : "legacy pinned4/8/4/style/ownership validation",
                "genericBridgeExtraMeasurements": measurementABI == .base4 ? "none; explicit BASE4 raw597 intrinsic inputs only"
                    : "none; dedicated raw597 only; required pinned4/8/4/style/ownership validation retained"]
        }
    }
}
