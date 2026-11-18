import CoreGraphics
import Foundation
import CryptoKit

/// Placement evidence is valid only in the current source/RF invocation. A saved
/// positive authority string is deliberately insufficient to recreate this scope.
enum NativeSupportedEstimatedContour {
    private struct Source: Sendable {
        let image: String
        let regions: String
        let invocation: String
    }
    @TaskLocal private static var source: Source?
    static let revision = "closed-original-rgb-domain-v1"
    static let receiptKey = "supportedEstimatedContourReceipt"

    static func withSource<Value>(sourceSHA256: String, regions: [Ensemble100RFRegion],
                                  operation: () throws -> Value) rethrows -> Value {
        let current = Source(image: sourceSHA256, regions: materialization(regions), invocation: UUID().uuidString)
        return try $source.withValue(current, operation: operation)
    }

    private static func digest(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func materialization(_ regions: [Ensemble100RFRegion]) -> String {
        digest(regions.map { region -> [String: Any] in
            ["query": region.queryID, "class": region.classID, "confidence": region.confidence,
             "bounds": [region.bounds.minX, region.bounds.minY, region.bounds.width, region.bounds.height],
             "exterior": region.exterior.map { [$0.x, $0.y] },
             "holes": region.holes.map { $0.map { [$0.x, $0.y] } }]
        }) ?? ""
    }

    private static func ownerDigest(_ raw: [String: Any]) -> String? {
        guard let id = raw["id"] as? String, !id.isEmpty,
              let bounds = raw["sourceBounds"] as? [Double], bounds.count == 4 else { return nil }
        // Bind an available source-appearance receipt too; moving the same owner
        // identifier between different source transactions must invalidate it.
        return digest(["id": id, "bounds": bounds,
                       "appearance": raw["sourceAppearanceBinding"] ?? NSNull()])
    }

    static func rasterDigest(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    static func receipt(raw: [String: Any], sourceSHA256: String, regionsSHA256: String,
                        rasterSHA256: String) -> [String: Any]? {
        guard let source, source.image == sourceSHA256, source.regions == regionsSHA256,
              sourceSHA256.count == 64, regionsSHA256.count == 64,
              rasterSHA256.count == 64,
              let owner = ownerDigest(raw), let body = raw["balloonInterior"] as? [String: Any],
              let contour = digest(body) else { return nil }
        return ["revision": revision, "sourceSHA256": sourceSHA256,
                "invocation": source.invocation,
                "rfMaterializationSHA256": regionsSHA256, "ownerSHA256": owner,
                "contourSHA256": contour,
                "workingRasterSHA256": rasterSHA256]
    }

    static func accepts(_ raw: [String: Any]) -> Bool {
        guard let source, source.image.count == 64, source.regions.count == 64,
              let receipt = raw[receiptKey] as? [String: Any],
              receipt["revision"] as? String == revision,
              receipt["invocation"] as? String == source.invocation,
              receipt["sourceSHA256"] as? String == source.image,
              receipt["rfMaterializationSHA256"] as? String == source.regions,
              receipt["ownerSHA256"] as? String == ownerDigest(raw),
              let body = raw["balloonInterior"] as? [String: Any],
              body["modelEstimated"] as? Bool == true, body["contourVerified"] as? Bool == false,
              body["nativeMaskSHA256"] == nil,
              receipt["contourSHA256"] as? String == digest(body),
              let raster = receipt["workingRasterSHA256"] as? String, raster.count == 64 else { return false }
        return true
    }
}

/// In-memory contour adapter. The native verified contour wins; model spans
/// remain estimates. No cached files, page identifiers or model inference.
/// This preserves the frozen raw painter's contour-consumption boundary.
enum NativeEnsembleLayoutContour {
    @TaskLocal private static var supportedEstimatedContourOverride: Bool?

    static func withSupportedEstimatedContour<Value>(_ enabled: Bool,
                                                     operation: () throws -> Value) rethrows -> Value {
        try $supportedEstimatedContourOverride.withValue(enabled, operation: operation)
    }

    static var supportedEstimatedContourEnabled: Bool {
        supportedEstimatedContourOverride ??
            (ProcessInfo.processInfo.environment["AIDOKU_SUPPORTED_ESTIMATED_CONTOUR"] == "1")
    }

    static func contour(raw: [String: Any], viewport: CGSize) -> NativeRawBalloonCapacity.Contour? {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return nil }
        guard let result = parsedContour(raw: raw, viewport: viewport),
              !supportedEstimatedContourEnabled || NativeRawBalloonCapacity.contour(raw: raw, viewport: viewport) != nil ||
                NativeSupportedEstimatedContour.accepts(raw),
              NativeRawBalloonCapacity.isConnected(result, raw: raw, viewport: viewport) else { return nil }
        return result
    }

    /// One invocation-bound RGB receipt supplies layout, placement and final
    /// halo admission. It remains an estimated placement domain, never a native
    /// removal-mask certificate. The operational default stays verified-only.
    static func estimatedPlacementConstraint(raw: [String: Any], viewport: CGSize) -> NativeRawBalloonCapacity.Contour? {
        guard supportedEstimatedContourEnabled,
              NativeSupportedEstimatedContour.accepts(raw),
              let result = contour(raw: raw, viewport: viewport),
              zip(result.spans, result.spans.dropFirst()).allSatisfy({
                  min($0.0.1, $0.1.1) > max($0.0.0, $0.1.0)
              }) else { return nil }
        return result
    }

    private static func parsedContour(raw: [String: Any], viewport: CGSize) -> NativeRawBalloonCapacity.Contour? {
        if let native = NativeRawBalloonCapacity.contour(raw: raw, viewport: viewport) { return native }
        guard let obj = raw["balloonInterior"] as? [String: Any], obj["modelEstimated"] as? Bool == true,
              let r = obj["rect"] as? [Double], r.count == 4,
              let s = obj["spans"] as? [Double], s.count >= 4, s.count <= 2048, s.count % 2 == 0,
              (r + s).allSatisfy(\.isFinite), r[2] > 0, r[3] > 0,
              CGRect(x: 0, y: 0, width: 1, height: 1).contains(CGRect(x: r[0], y: r[1], width: r[2], height: r[3])) else { return nil }
        var spans: [(CGFloat, CGFloat)] = []
        for i in stride(from: 0, to: s.count, by: 2) {
            guard s[i] >= r[0] - 1e-9, s[i + 1] <= r[0] + r[2] + 1e-9, s[i] < s[i + 1] else { return nil }
            spans.append((s[i] * viewport.width, s[i + 1] * viewport.width))
        }
        return .init(rect: CGRect(x: r[0] * viewport.width, y: r[1] * viewport.height,
            width: r[2] * viewport.width, height: r[3] * viewport.height), spans: spans)
    }
}
