import CoreGraphics
import CryptoKit
import Foundation

/// Model-free regression: authenticated synthetic source observations -> actual
/// production mandatory raster. No corpus IDs, GT, font/model files or images.
@main enum NativeSourceWhiteCoreGuardSmoke {
    static func main() throws {
        let expectedDiagnostic = CommandLine.arguments[1] == "1"
        var checks = 0
        func check(_ value: Bool, _ reason: String) {
            precondition(value, reason); checks += 1
        }
        let source: [String: Any] = [
            "sourceOnly": true, "inferenceUsesGT": false,
            "fill": ["rgb": [252.0, 252.0, 252.0]],
            "outline": ["present": true, "rgb": [100.0, 160.0, 40.0], "widthPx": 2.0],
            "shadow": ["present": false, "probability": 0.05],
            "background": ["rgb": [240.0, 240.0, 240.0]],
            "pixelRoleEvidence": ["GTAtInference": false,
                "featureContextPolicy": "source-independent-paint-feature-context-v1", "samples": 512,
                "roles": ["fill": ["confidentSamples": 96,
                    "observedColours": [["rgb": [252.0, 252.0, 252.0], "observedMass": 0.9]]]]]
        ]
        let binding = Dictionary(uniqueKeysWithValues: NativeOperationalAppearance.bindingKeys.map {
            ($0, String(repeating: "a", count: 64))
        })
        let packet: [String: Any] = ["schema": "aidoku-live-source-appearance-v1", "binding": binding,
            "sourceOnly": true, "freshInference": true, "GTAtInference": false,
            "cachedPredictionsRead": false, "prediction": source]
        var raw = try NativeOperationalAppearance.apply(packet: JSONSerialization.data(withJSONObject: packet),
            expectedBinding: binding, to: ["id": "synthetic-title", "text": "sample", "fontSize": 20.0])
        raw["sourceFontSize"] = 20.0
        check(NativeOperationalAppearance.sourceContourOnlyDiagnosticEnabled == expectedDiagnostic, "shared diagnostic gate")
        check(NativeOperationalAppearance.sourceContourOnly(raw) == expectedDiagnostic, "authenticated producer gate")
        let chosen = [252.0, 252.0, 252.0]
        func certified(_ color: [Double], _ prediction: [String: Any]?) -> Bool {
            NativeExplicitDisplayStrokePolicy.certifiedWhiteSourceCoreWithBand(chosenFillRGB: color, sourceAppearance: prediction)
        }
        check(certified(chosen, source), "positive owned white body")
        check(!certified(chosen, nil), "missing source is not evidence")
        var white255 = source
        white255["fill"] = ["rgb": [255.0, 255.0, 255.0]]
        check(certified([255, 255, 255], white255), "valid upper RGB boundary")
        check(!certified([258, 258, 258], white255), "255 source plus tolerance cannot admit258")
        check(!certified([.nan, 255, 255], white255), "nonfinite chosen fill")
        check(!certified([255, 255], white255), "invalid chosen geometry")
        var noBand = source; noBand["outline"] = ["present": false, "rgb": [0.0, 0.0, 0.0], "widthPx": 0.0]
        check(!certified(chosen, noBand), "absence certificate stays independent")
        var unsafe = source; unsafe["inferenceUsesGT"] = true
        check(!certified(chosen, unsafe), "GT packet cannot certify")
        unsafe = source; unsafe["sourceOnly"] = false
        check(!certified(chosen, unsafe), "non-source packet cannot certify")
        for mass in [0.79, Double.nan, 1.01] {
            var bad = source, evidence = source["pixelRoleEvidence"] as! [String: Any]
            evidence["roles"] = ["fill": ["confidentSamples": 96,
                "observedColours": [["rgb": chosen, "observedMass": mass]]]]
            bad["pixelRoleEvidence"] = evidence
            check(!certified(chosen, bad), "observed body mass must qualify")
        }
        for support in [31, 513] {
            var bad = source, evidence = source["pixelRoleEvidence"] as! [String: Any]
            evidence["roles"] = ["fill": ["confidentSamples": support,
                "observedColours": [["rgb": chosen, "observedMass": 0.9]]]]
            bad["pixelRoleEvidence"] = evidence
            check(!certified(chosen, bad), "body support must be bounded")
        }
        check(!NativeExplicitDisplayStrokePolicy.certifiedWhiteSourceCoreWithBand(chosenFillRGB: chosen,
            sourceAppearance: source, minimumBlackContrast: 22), "caller contrast floor remains mandatory")

        var bytes = [UInt8](repeating: 0, count: 16 * 16 * 4)
        for y in 5..<11 { for x in 4..<12 {
            let offset = (y * 16 + x) * 4
            for channel in 0..<3 { bytes[offset + channel] = 252 }; bytes[offset + 3] = 255
        }}
        let fill = try NativeMandatoryDisplayStroke.image(bytes, width: 16, height: 16)
        let background = try NativeMandatoryDisplayStroke.image([UInt8](repeating: 255, count: 64 * 64 * 4), width: 64, height: 64)
        let sourceBefore = try JSONSerialization.data(withJSONObject: source, options: .sortedKeys)
        func prepare(_ prediction: [String: Any]?) throws -> NativeMandatoryDisplayStroke.Prepared {
            try NativeMandatoryDisplayStroke.prepare(fill: fill, restored: background, fontOutputPixels: 20,
                outwardEm: 0.035, fillFrame: CGRect(x: 20, y: 20, width: 16, height: 16),
                forcedEndpoint: 0, sourceAppearance: prediction, sourceContourOnly: false)
        }
        let result = try prepare(source), fallback = try prepare(nil)
        check(result.endpoint == 0 && result.outwardPixels >= 2 && result.addedAlphaPixels > 0, "nonzero black guard")
        check(result.endpointDecision["whiteFillOverride"] as? Bool == false, "source core was retained")
        check(result.endpointDecision["sourceBandWhiteFillPreserved"] as? Bool == true, "positive evidence receipt")
        check(fallback.endpointDecision["whiteFillOverride"] as? Bool == true, "uncertified fallback unchanged")
        let actualFill = try NativeMandatoryDisplayStroke.rgba(result.fill)
        let opaque = stride(from: 0, to: actualFill.count, by: 4).filter { actualFill[$0 + 3] > 0 }
        check(opaque.count == 48, "fill is complete")
        check(opaque.allSatisfy { index in (0..<3).allSatisfy { actualFill[index + $0] == 252 } }, "source RGB retained")
        func alpha(_ image: CGImage) throws -> [UInt8] {
            let rgba = try NativeMandatoryDisplayStroke.rgba(image)
            return stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
        }
        let fillAlpha = try alpha(result.fill), oldFillAlpha = try alpha(fallback.fill)
        let haloAlpha = try alpha(result.halo), oldHaloAlpha = try alpha(fallback.halo)
        check(fillAlpha == oldFillAlpha && haloAlpha == oldHaloAlpha, "exact retained alpha geometry")
        check(result.frame == fallback.frame && result.outwardPixels == fallback.outwardPixels, "exact retained frame and radius")
        check(CGRect(x: 0, y: 0, width: 64, height: 64).contains(result.frame), "page containment")
        let sourceAfter = try JSONSerialization.data(withJSONObject: source, options: .sortedKeys)
        check(sourceAfter == sourceBefore, "source bands/predictions immutable")
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        NativeMandatoryDisplayStroke.paint([result], in: context)
        let painted = try NativeMandatoryDisplayStroke.rgba(context.makeImage()!)
        let black = stride(from: 0, to: painted.count, by: 4).filter {
            painted[$0] == 0 && painted[$0 + 1] == 0 && painted[$0 + 2] == 0 && painted[$0 + 3] == 255
        }.count
        check(black > 0, "BW guard remains visible after actual fill compositing")
        let projection: [String: Any] = ["inputSHA256": "synthetic-source", "engine": "same-binary",
            "sourceContourOnlyDiagnostic": NativeOperationalAppearance.sourceContourOnlyDiagnosticEnabled]
        let data = try JSONSerialization.data(withJSONObject: projection, options: .sortedKeys)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        print(String(data: try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks,
            "diagnosticEnabled": expectedDiagnostic, "resumeProjectionSHA256": digest,
            "visibleBlackGuardPixels": black, "modelRuns": 0, "corpusFilesRead": 0]), encoding: .utf8)!)
    }
}
