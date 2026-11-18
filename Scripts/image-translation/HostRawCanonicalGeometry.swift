import CryptoKit
import Foundation
import ImageIO

enum HostRawCanonicalGeometry {
    private struct RFGrid: Decodable {
        let imageIdentity: String
        let probabilities: [Float]
        let weightedMeanProbabilities: [Float]
        let native17Fields: [Float]?
    }
    private struct Page: Decodable {
        let page: String
        let source: String
        let sourceSHA256: String
        let width: Int
        let height: Int
        let originals: [HostIndividualGeometry.SavedBox]
        let rfPrimitives: [NativeOCRRawBoundaryFeatures.RFPrimitive]
        let rfGrid: RFGrid
        let auxiliaryOriginals: [HostIndividualGeometry.SavedBox]?
    }
    static func run(output: URL, modelURL: URL, auxiliaryModelURL: URL? = nil) throws -> Int32 {
        let modelData = try Data(contentsOf: modelURL)
        let model = try NativeOCRRawBoundaryGenerator.Model(data: modelData,
            expectedFeatureNames: NativeOCRRawCanonicalGeometry.featureNames)
        let hash: (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let modelSHA = hash(modelData)
        let auxiliaryModelData = try auxiliaryModelURL.map { try Data(contentsOf: $0) }
        let auxiliaryModel = try auxiliaryModelData.map {
            try NativeOCRRawBoundaryGenerator.Model(data: $0, expectedFeatureNames: NativeOCRRawCanonicalGeometry.featureNames)
        }
        let admissionURL = ProcessInfo.processInfo.environment["AIDOKU_OCR_RAW_SOURCE_SUPPORT_MODEL"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let admissionData = try admissionURL.map { try Data(contentsOf: $0) }
        let admissionModel = try admissionData.map { try NativeOCRRawSourceAdmission.Model(data: $0) }
        let binarySHA = hash(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0])))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let allowed: Set<String> = ["page", "source", "sourceSHA256", "width", "height", "originals", "rfPrimitives", "rfGrid"]
        var seen = Set<String>()
        while let line = readLine() {
            guard let data = line.data(using: .utf8), data.count <= 64_000_000,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == allowed || Set(object.keys) == allowed.union(["auxiliaryOriginals"]) else {
                throw HostError.message("Canonical raw geometry accepts only detector/RF/source inputs")
            }
            let page = try JSONDecoder().decode(Page.self, from: data)
            guard !object.keys.contains("auxiliaryOriginals") || page.auxiliaryOriginals != nil else {
                throw HostError.message("Auxiliary detector inventory must be an array")
            }
            guard page.page.count == 4, page.page.allSatisfy(\.isNumber), seen.insert(page.page).inserted,
                  page.originals.count <= 4096, (page.auxiliaryOriginals?.count ?? 0) <= 4096,
                  page.rfGrid.imageIdentity == page.sourceSHA256 else {
                throw HostError.message("Canonical raw input identity mismatch")
            }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: page.source))
            guard hash(bytes) == page.sourceSHA256,
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == page.width, image.height == page.height,
                  let decoded = NativeOCRV2SourcePixelDecoder.decode(image),
                  let frame = NativeOCRRGBAFrame(width: decoded.width, height: decoded.height,
                    bytesPerRow: decoded.bytesPerRow, bytes: decoded.bytes) else {
                throw HostError.message("Canonical raw source mismatch")
            }
            let grid = NativeRFDETRSemanticGrid(width: page.width, height: page.height, side: 162,
                probabilities: page.rfGrid.probabilities, imageIdentity: page.sourceSHA256,
                weightedMeanProbabilities: page.rfGrid.weightedMeanProbabilities)
            let admission = admissionModel.map { NativeOCRRawCanonicalGeometry.SourceAdmission(model: $0,
                rf: page.rfGrid.native17Fields.flatMap {
                    NativeOCRSourceSupportFeatures155.PreparedRF(width: page.width, height: page.height, native17Fields: $0)
                }, detectorConfidences: page.originals.map(\.score)) }
            if let auxiliaryModel {
                guard let auxiliaryOriginals = page.auxiliaryOriginals, admission != nil,
                      admission?.rf != nil else {
                    throw HostError.message("Combined generation requires auxiliary detector inventory and actual RF17 source admission")
                }
                let result = try NativeOCRRawCanonicalGeometry.produceCombined(requestID: page.page, frame: frame,
                    originals: page.originals.map { .init(polygon: $0.polygon, detectorSeedEvidence: $0.detectorSeedEvidence) },
                    auxiliaryOriginals: auxiliaryOriginals.map {
                        .init(polygon: $0.polygon, detectorSeedEvidence: $0.detectorSeedEvidence)
                    }, rfPrimitives: page.rfPrimitives, grid: grid, primaryModel: model,
                    auxiliaryModel: auxiliaryModel, sourceAdmission: admission, captureFeatures: true)
                let document: [String: Any] = ["schema": "raw-canonical-combined-source-only-native-v1", "page": page.page,
                    "sourceSHA256": page.sourceSHA256, "inputSHA256": hash(data), "binarySHA256": binarySHA,
                    "primaryModelSHA256": modelSHA, "auxiliaryModelSHA256": auxiliaryModelData.map { hash($0) as Any } ?? NSNull(),
                    "sourceAdmissionModelSHA256": admissionData.map { hash($0) as Any } ?? NSNull(),
                    "pixelDecoderABI": NativeOCRV2SourcePixelDecoder.abi,
                    "sourceFrameDecodes": 1, "rawInputCount": page.originals.count,
                    "auxiliaryInputCount": auxiliaryOriginals.count,
                    "primaryNumericPredictions": result.primary.numericPredictions,
                    "auxiliaryNumericPredictions": result.auxiliary.numericPredictions,
                    "materializedCandidateRecords": result.materializedRecords,
                    "generatedCandidateRecords": result.output.individuals.count,
                    "primaryQueryOrdinals": result.primary.queryOrdinals,
                    "auxiliaryQueryOrdinals": result.auxiliary.queryOrdinals,
                    "output": try JSONSerialization.jsonObject(with: encoder.encode(result.output)),
                    "primaryPhysicalContext": try JSONSerialization.jsonObject(with: encoder.encode(result.primary.physicalReport)),
                    "auxiliaryPhysicalContext": try JSONSerialization.jsonObject(with: encoder.encode(result.auxiliary.physicalReport)),
                    "primaryFeatures": result.primary.features, "auxiliaryFeatures": result.auxiliary.features,
                    "primaryResiduals": result.primary.residuals, "auxiliaryResiduals": result.auxiliary.residuals,
                    "contextPaintRecordsEmitted": 0, "GTAtRuntime": false, "OCRRead": false,
                    "correctedRowsRead": false, "cachedGeometryRead": false,
                    "detectorCalls": 0, "recognizerCalls": 0, "RFModelCalls": 0, "bboxAdmissionApplied": false]
                try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
                    .write(to: output.appendingPathComponent(page.page + ".json"), options: [.atomic])
                print("{\"page\":\"\(page.page)\",\"candidates\":\(result.output.individuals.count)}")
                fflush(stdout)
                continue
            }
            let result = try NativeOCRRawCanonicalGeometry.produce(requestID: page.page, frame: frame,
                originals: page.originals.map { .init(polygon: $0.polygon, detectorSeedEvidence: $0.detectorSeedEvidence) },
                rfPrimitives: page.rfPrimitives, grid: grid, model: model, captureFeatures: true,
                auxiliaryOriginals: page.auxiliaryOriginals?.map {
                    .init(polygon: $0.polygon, detectorSeedEvidence: $0.detectorSeedEvidence)
                }, sourceAdmission: admission)
            let outputJSON = try JSONSerialization.jsonObject(with: encoder.encode(result.output))
            let physicalJSON = try JSONSerialization.jsonObject(with: encoder.encode(result.physicalReport))
            let document: [String: Any] = ["schema": "raw-canonical-source-only-native-v1", "page": page.page,
                "sourceSHA256": page.sourceSHA256, "inputSHA256": hash(data), "binarySHA256": binarySHA,
                "modelSHA256": modelSHA, "pixelDecoderABI": NativeOCRV2SourcePixelDecoder.abi,
                "rawInputCount": result.rawInputCount, "numericPredictions": result.numericPredictions,
                "contextRawInputCount": result.contextRawInputCount,
                "auxiliaryOnlyEmission": page.auxiliaryOriginals != nil,
                "sourceAdmissionRequested": admissionModel != nil && page.auxiliaryOriginals == nil,
                "sourceAdmissionRF17Provided": page.rfGrid.native17Fields != nil,
                "sourceAdmissionModelSHA256": admissionData.map { hash($0) as Any } ?? NSNull(),
                "retiredSourceQueries": result.rawInputCount - result.numericPredictions,
                "queryOrdinals": result.queryOrdinals,
                "generatedCandidateRecords": result.output.individuals.count, "contextPaintRecordsEmitted": 0,
                "output": outputJSON, "physicalContext": physicalJSON,
                "features": result.features, "residuals": result.residuals,
                "GTAtRuntime": false, "OCRRead": false, "correctedRowsRead": false,
                "detectorCalls": 0, "recognizerCalls": 0, "RFModelCalls": 0, "bboxAdmissionApplied": false]
            try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
                .write(to: output.appendingPathComponent(page.page + ".json"), options: [.atomic])
            print("{\"page\":\"\(page.page)\",\"candidates\":\(result.output.individuals.count)}")
            fflush(stdout)
        }
        return 0
    }
}
