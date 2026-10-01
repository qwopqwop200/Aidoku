import Foundation

@main
struct ResidualProofMain {
    struct Input: Decodable {
        let rgba: [UInt8]
        let width: Int
        let height: Int
        let mask: [UInt8]
        let blocked: [UInt8]?
        let foreground: [Double]?
        let glyphSize: Double?
        let operation: String?
    }
    static func main() throws {
        let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
        var options = NativeResidualProof.Options()
        options.excludedMask = input.blocked
        options.sourceForeground = input.foreground
        options.glyphSize = input.glyphSize ?? 0
        let result = input.operation == "certified"
            ? NativeResidualProof.certifiedSurfaceFill(rgba: input.rgba, width: input.width, height: input.height,
                mask: input.mask, blocked: input.blocked ?? input.mask.map { _ in 0 }, options: options)
            : NativeResidualProof.forcedDonorFill(rgba: input.rgba, width: input.width, height: input.height, mask: input.mask, options: options)
        let report: [String: Any]
        if let result {
            let q = result.quality
            var quality: [String: Any] = ["safe": q.safe, "erased": q.erased, "noDonor": q.noDonor, "continuous": q.continuous,
                    "seams": q.seams, "wide": q.wide, "wideDiscordant": q.wideDiscordant, "maxSpan": q.maxSpan,
                    "continuityRatio": q.continuityRatio, "residualSourceInk": q.residualSourceInk,
                    "whiteHaloFractionInner": q.whiteHaloFractionInner, "whiteHaloFractionOuter": q.whiteHaloFractionOuter,
                    "whiteHaloPixels": q.whiteHaloPixels, "whiteHaloRadius": q.whiteHaloRadius,
                    "edgeRelaxationIterations": q.edgeRelaxationIterations]
            if let surface = q.surface {
                var value: [String: Any] = ["safe": surface.safe, "reason": surface.reason, "samples": surface.samples]
                if surface.rmse.isFinite { value["rmse"] = surface.rmse }; if surface.outliers.isFinite { value["outliers"] = surface.outliers }
                if let coefficients = surface.coefficients { value["coefficients"] = coefficients }
                if surface.localRMSE.isFinite { value["localSamples"] = surface.localSamples; value["localRMSE"] = surface.localRMSE; value["edgeFraction"] = surface.edgeFraction }
                quality["surface"] = value
            }
            if let support = q.supportSides { quality["supportSides"] = support }
            report = ["rgba": result.rgba as Any? ?? NSNull(), "method": result.method, "failure": result.failure,
                "residualMask": result.residualMask as Any? ?? NSNull(),
                "quality": quality]
        } else { report = ["missing": true] }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
    }
}
