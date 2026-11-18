import CryptoKit
import Foundation
import ImageIO

/// Source-only feature capture for the canonical raw-detector generator.
/// Requests contain no recognized rows, old candidate bank, or label coordinates.
enum HostRawBoundaryFeatures {
    private struct Page: Decodable {
        let page: String
        let source: String
        let sourceSHA256: String
        let width: Int
        let height: Int
        let originals: [HostIndividualGeometry.SavedBox]
        let rfPrimitives: [NativeOCRRawBoundaryFeatures.RFPrimitive]
    }

    static func capture(output: URL) async throws -> Int32 {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let binary = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))
        let binarySHA = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
        var seen = Set<String>()
        let allowed: Set<String> = ["page", "source", "sourceSHA256", "width", "height", "originals", "rfPrimitives"]
        while let line = readLine() {
            guard let bytes = line.data(using: .utf8), bytes.count <= 32_000_000,
                  let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(object.keys) == allowed else {
                throw HostError.message("Raw feature request must contain only source detector/RF inputs")
            }
            let page = try decoder.decode(Page.self, from: bytes)
            guard page.page.count == 4, page.page.allSatisfy(\.isNumber), seen.insert(page.page).inserted,
                  page.originals.count <= 4096, page.rfPrimitives.count <= 4096 else {
                throw HostError.message("Invalid raw source feature request")
            }
            let imageBytes = try Data(contentsOf: URL(fileURLWithPath: page.source))
            guard SHA256.hash(data: imageBytes).map({ String(format: "%02x", $0) }).joined() == page.sourceSHA256,
                  let source = CGImageSourceCreateWithData(imageBytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == page.width, image.height == page.height,
                  let decoded = NativeOCRV2SourcePixelDecoder.decode(image),
                  let frame = NativeOCRRGBAFrame(width: decoded.width, height: decoded.height,
                    bytesPerRow: decoded.bytesPerRow, bytes: decoded.bytes) else {
                throw HostError.message("Raw feature source identity mismatch")
            }
            var rows: [[String: Any]] = []
            for (index, original) in page.originals.enumerated() {
                let seed = try original.detectorSeedEvidence.map {
                    try decoder.decode(NativeOCRRawBoundaryFeatures.DBEvidence.self, from: encoder.encode($0))
                }
                let measured = NativeOCRRawBoundaryFeatures.extract(rawPolygon: original.polygon,
                    frame: frame, detectorSeed: seed, rfPrimitives: page.rfPrimitives)
                rows.append(["rawIndex": index, "polygon": original.polygon,
                    "features": measured?.features.map(Double.init) ?? [],
                    "available": measured != nil, "pixelAvailable": measured?.pixelAvailable ?? false])
            }
            let document: [String: Any] = ["schema": "raw-source-boundary-native126-capture-v1",
                "page": page.page, "sourceSHA256": page.sourceSHA256,
                "inputSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                "binarySHA256": binarySHA, "featureABI": NativeOCRRawBoundaryFeatures.abi,
                "pixelDecoderABI": NativeOCRV2SourcePixelDecoder.abi,
                "featureNames": NativeOCRRawBoundaryFeatures.names, "rows": rows,
                "GTAtRuntime": false, "OCRRead": false, "correctedRowsRead": false,
                "detectorCalls": 0, "recognizerCalls": 0, "RFModelCalls": 0]
            try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
                .write(to: output.appendingPathComponent(page.page + ".json"), options: [.atomic])
            let ack: [String: Any] = ["page": page.page, "rows": rows.count, "features": 126]
            print(String(decoding: try JSONSerialization.data(withJSONObject: ack, options: [.sortedKeys]), as: UTF8.self))
            fflush(stdout)
        }
        return 0
    }
}
