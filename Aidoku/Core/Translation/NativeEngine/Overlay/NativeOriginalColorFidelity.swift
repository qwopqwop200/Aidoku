import Foundation

/// Prediction-to-active-paint-parameter integrity, not an executed raster observation.
/// Callers omit colors of disabled panel/outline paint. Source accuracy stays unknown.
enum NativeOriginalColorFidelity {
    /// A role replacement must not inherit confidence scores of the replaced
    /// RGB pair. Keep them as raw history; absence of calibration is not zero.
    static func sourceRoleConfidenceAudit(_ prediction: [String: Any]?) -> [String: Any]? {
        guard let prediction else { return nil }
        let raw = prediction["confidence"] as? [String: Any]
        guard let evidence = prediction["nativeTopologyRoleEvidence"] as? [String: Any],
              evidence["conditionalSupport"] as? Bool == true else { return raw }
        return ["foreground": NSNull(), "stroke": NSNull(),
            "background": raw?["background"] as Any? ?? NSNull(),
            "rawLegacyRoleConfidence": raw as Any? ?? NSNull(),
            "foregroundConfidenceAuthority": "new topology pair has no calibrated probability; raw score belongs to previous RGB",
            "strokeConfidenceAuthority": "new topology pair has no calibrated probability; raw score belongs to previous RGB",
            "reason": "native AND cross-scale conditional role evidence; not inherited calibration"]
    }

    /// Sample-space band observations are not calibrated full source pen widths.
    static func sourceBandAudit(finalRole: Any?, preRole: Any?) -> [String: Any] {
        func observed(_ value: Any?) -> [String: Any]? {
            guard let value = value as? [String: Any],
                  let band = (value["samplePixels"] as? NSNumber)?.doubleValue,
                  let glyph = (value["glyphPixels"] as? NSNumber)?.doubleValue,
                  let ratio = (value["relativeToGlyph"] as? NSNumber)?.doubleValue,
                  band.isFinite, band > 0, glyph.isFinite, glyph > 0,
                  ratio.isFinite, ratio >= 0 else { return nil }
            var output: [String: Any] = ["samplePixels": band, "glyphPixels": glyph, "relativeToGlyph": ratio]
            if let scale = (value["sampleScale"] as? NSNumber)?.doubleValue, scale.isFinite, scale > 0 {
                output["sampleScale"] = scale
            }
            if let method = value["method"] as? String { output["method"] = String(method.prefix(512)) }
            return output
        }
        let final = observed(finalRole), prior = observed(preRole)
        return ["finalRoleBand": final as Any? ?? NSNull(), "preRoleBand": prior as Any? ?? NSNull(),
                "finalRoleMeasured": final != nil, "preRoleMeasured": prior != nil,
                "sourceFullPenWidthPixels": NSNull(), "sourceWidthAccuracy": NSNull(),
                "authority": "sample-space band model observation; not calibrated full pen width or source ground truth"]
    }

    static func evaluate(panelPrediction: [Double]?, foregroundPrediction: [Double]?, strokePrediction: [Double]?,
                         panelPaint: [Double]?, foregroundPaint: [Double]?, strokePaint: [Double]?) -> [String: Any] {
        func valid(_ rgb: [Double]?) -> Bool {
            guard let rgb, rgb.count == 3 else { return false }
            return rgb.allSatisfy { $0.isFinite && (0...255).contains($0) }
        }
        var measured = 0, mismatched = 0
        func observation(_ prediction: [Double]?, _ paint: [Double]?) -> [String: Any] {
            guard valid(prediction), valid(paint), let prediction, let paint else {
                return ["state": "unmeasured", "maxRGBChannelError": NSNull(),
                        "predictionAvailable": valid(prediction), "paintAvailable": valid(paint)]
            }
            measured += 1
            let error = zip(prediction, paint).map { abs($0 - $1) }.max()!
            if error > 0.000001 { mismatched += 1 }
            return ["state": "measured", "maxRGBChannelError": error,
                    "predictionAvailable": true, "paintAvailable": true]
        }
        let panel = observation(panelPrediction, panelPaint)
        let foreground = observation(foregroundPrediction, foregroundPaint)
        let stroke = observation(strokePrediction, strokePaint)
        return ["authority": "original source model forecast versus active prepared paint parameters; not raster or source ground truth",
                "rasterMeasurement": NSNull(),
                "panel": panel, "foreground": foreground, "stroke": stroke,
                "measuredColorCount": measured, "unmeasuredColorCount": 3 - measured,
                "mismatchedColorCount": mismatched, "sourceAccuracy": NSNull()]
    }
}
