import Foundation

/// Calibrated original/source width for actual fixed-M1 masks and predicted
/// outline colour. This does not alter the legacy selected-mask calibration.
enum NativeM1SourceWidth {
    static let revision = "actual-m1-p9-outline-q25-TRAIN506-v1"
    static let fitScope = "f63f811d5e64d38017f71f638fe215c9b48fa126cbdcf39d01730678c9598d22"
    enum Calibration: String, CaseIterable, Sendable {
        case m1p9Rounds32 = "actual-M1-physical35-p9"
        case m1p9Rounds64 = "actual-M1-physical35-p9-rounds64"

        fileprivate var parameters: (scale: Double, bias: Double, priorScale: Double, priorBias: Double) {
            switch self {
            case .m1p9Rounds32: (0.9043605236945009, 2.4457978369829045, 0.041168856039578525, 2.4400887609297217)
            case .m1p9Rounds64: (0.9103920196823622, 2.4270301151464233, 0.041107388403746684, 2.443794555225862)
            }
        }

        var fitArtifactSHA256: String {
            switch self {
            case .m1p9Rounds32: "b066274a6445183a5cd8074da25e95af5421153bbbe50ae082bbf02c352184c4"
            case .m1p9Rounds64: "1e6fc0a581b219dd5f093ea748cc78ba8f8eed8597d4ef485edd2dcd9ba50fde"
            }
        }

        var sourceStyleFreezeSHA256: String {
            switch self {
            case .m1p9Rounds32: "f83cb6c76c31cc11129898997f33326e2b6d1ccde84b47b68596a257cef5e641"
            case .m1p9Rounds64: "4e1ce501417794a6d4e57488d42f381aca6134bd09ca062330207d4dfe95cd8f"
            }
        }

        var identity: String {
            let p = parameters
            return "\(NativeM1SourceWidth.revision):\(rawValue):fit-\(fitArtifactSHA256):source-\(sourceStyleFreezeSHA256)"
                + ":q25-\(p.scale),\(p.bias):prior-\(p.priorScale),\(p.priorBias)"
        }
    }

    enum Failure: Error { case dimensions, invalidObservation }
    struct Result {
        let widthPx: Double
        let measurementEvidence: [String: Any]
    }

    /// Caller supplies the actual fixed M1 mask (.25/.01/r2/closing1), never a
    /// selected-mask substitute. Calibration choice is mandatory, not inferred.
    static func estimate(rgb: [UInt8], width: Int, height: Int, mask: [UInt8],
        outlineRGB: [Double], outlinePresent: Bool, fontPrior: Double, calibration: Calibration) throws -> Result {
        guard width > 0, height > 0, width <= 1_500_000 / height,
              rgb.count == width * height * 3, mask.count == width * height else { throw Failure.dimensions }
        guard fontPrior.isFinite, fontPrior > 0,
              mask.allSatisfy({ $0 == 0 || $0 == 1 || $0 == 255 }) else { throw Failure.invalidObservation }
        var evidence: [String: Any] = ["version": revision, "sourceColourCandidateID": calibration.rawValue,
            "widthCalibrationIdentity": calibration.identity,
            "sourceStyleFreezeSHA256": calibration.sourceStyleFreezeSHA256,
            "fitArtifactSHA256": calibration.fitArtifactSHA256, "fitScope": fitScope,
            "sourceOnly": true, "GTAtInference": false, "modelHeadsCalled": 0,
            "displayOutlineMayBeOmitted": false, "sourceWidthIsCalibratedPrediction": true,
            "maskContract": "caller-supplied actual M1 .25/.01/r2/closing1; no selected-mask coefficient transfer"]
        if !outlinePresent {
            evidence["source"] = "actual-source-role-head-predicts-absent"
            return Result(widthPx: 0, measurementEvidence: evidence)
        }
        guard outlineRGB.count == 3, outlineRGB.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else {
            throw Failure.invalidObservation
        }
        let colour = outlineRGB.map(Float.init)
        var selected = [UInt8](repeating: 0, count: mask.count), pixels = 0
        for i in mask.indices where mask[i] != 0 {
            let j = i * 3, r = Float(rgb[j]) - colour[0]
            let g = Float(rgb[j + 1]) - colour[1], b = Float(rgb[j + 2]) - colour[2]
            let rg = r * r + g * g
            if (rg + b * b).squareRoot() <= 32 { selected[i] = 1; pixels += 1 }
        }
        var ridges: [Float] = []
        if pixels > 0 {
            let distance = NativePhysicalAcceptedBodyMath.distances(selected, width: width, height: height)
            for y in 0..<height { for x in 0..<width where selected[y * width + x] != 0 {
                let value = distance[y * width + x]
                var maximum: Float = 0
                for yy in max(0, y - 1)...min(height - 1, y + 1) {
                    for xx in max(0, x - 1)...min(width - 1, x + 1) {
                        maximum = max(maximum, distance[yy * width + xx])
                    }
                }
                if value >= maximum - 0.000001 { ridges.append(value) }
            } }
        }
        ridges.sort()
        let radius: Double?
        if ridges.isEmpty { radius = nil }
        else {
            let at = Double(ridges.count - 1) * 0.25
            let lo = Int(at), hi = min(ridges.count - 1, Int(at.rounded(.up)))
            let fraction = at - Double(lo), difference = Double(ridges[hi]) - Double(ridges[lo])
            radius = fraction >= 0.5 ? Double(ridges[hi]) - difference * (1 - fraction)
                : Double(ridges[lo]) + difference * fraction
        }
        let p = calibration.parameters
        let predicted = radius.map { p.scale * $0 + p.bias } ?? (p.priorScale * fontPrior + p.priorBias)
        let value = min(256, max(0.25, predicted))
        guard value.isFinite else { throw Failure.invalidObservation }
        evidence.merge(["source": radius == nil ? "TRAIN-original-prior-fallback-physical-stat-unavailable" : "actual-M1-known-outline-ridge-q25-affine",
            "physicalMeasurementAvailable": radius != nil, "ridgeRadiusQ25": radius.map { $0 as Any } ?? NSNull(),
            "ridgeSamples": ridges.count, "observedColourPixels": pixels, "sourceConstructorPrior": fontPrior,
            "distanceABI": "float32-RGB-norm<=32;exact-Euclidean-exterior0;local-max3x3-epsilon1e-6;q25-linear"],
            uniquingKeysWith: { _, value in value })
        return Result(widthPx: value, measurementEvidence: evidence)
    }
}
