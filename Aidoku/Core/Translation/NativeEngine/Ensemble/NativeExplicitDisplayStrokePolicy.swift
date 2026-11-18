import CoreGraphics
import Foundation

/// Invoke AFTER the caller's source topology/chroma decision, BEFORE shaping
/// or sealing. The chosen fill is an input, never estimated from background.
enum NativeExplicitDisplayStrokePolicy {
    /// Source-supported guard with an explicit zero rollback. The caller
    /// must supply its already authenticated source appearance, not GT or a
    /// background-derived replacement fill. This helper never mutates a packet.
    static func sourceAwareGuardRatio(chosenFillRGB: [Double], sourceAppearance: [String: Any]?,
                                     incumbentRatio: CGFloat = 0.20,
                                     enabled: Bool = ProcessInfo.processInfo.environment[
                                        "AIDOKU_SOURCE_AWARE_DISPLAY_GUARD"] != "0") -> CGFloat {
        func number(_ raw: Any?) -> Double? {
            guard let n = raw as? NSNumber,
                  CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        func rgb(_ raw: Any?) -> [Double]? {
            guard let values = raw as? [Any], values.count == 3 else { return nil }
            let valuesRGB = values.compactMap(number)
            guard valuesRGB.count == 3, valuesRGB.allSatisfy({ (0...255).contains($0) }) else { return nil }
            return valuesRGB
        }
        func luminance(_ c: [Double]) -> Double {
            let v = c.map { x -> Double in
                let a = x / 255
                return a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
            }
            return v[0] * 0.2126 + v[1] * 0.7152 + v[2] * 0.0722
        }
        guard enabled, incumbentRatio.isFinite, incumbentRatio > 0,
              let chosen = rgb(chosenFillRGB), let p = sourceAppearance,
              p["sourceOnly"] as? Bool == true,
              let fill = p["fill"] as? [String: Any], let original = rgb(fill["rgb"]),
              zip(chosen, original).allSatisfy({ abs($0 - $1) <= 3 }),
              let outline = p["outline"] as? [String: Any], outline["present"] as? Bool == false,
              let probability = number(outline["probability"]), (0...0.25).contains(probability),
              number(outline["widthPx"]) == 0,
              let shadow = p["shadow"] as? [String: Any], shadow["present"] as? Bool == false,
              let shadowProbability = number(shadow["probability"]), (0...0.1).contains(shadowProbability),
              let background = p["background"] as? [String: Any],
              background["representation"] as? String == "observed-context-palette",
              background["insufficientObservedContext"] as? Bool == false,
              let colours = background["colors"] as? [Any], !colours.isEmpty,
              let weights = background["observedContextWeights"] as? [Any], weights.count == colours.count
        else { return incumbentRatio }
        // Extend only the existing source-selected white core. Independent
        // original-pixel role support remains mandatory for the relaxed bounds.
        let strongWhitePixels: Bool = {
            guard chosen.min()! >= 245, chosen.max()! - chosen.min()! <= 16,
                  let pixels = p["pixelRoleEvidence"] as? [String: Any],
                  pixels["GTAtInference"] as? Bool == false,
                  pixels["featureContextPolicy"] as? String == "source-independent-paint-feature-context-v1",
                  let samples = number(pixels["samples"]), samples >= 256,
                  let roles = pixels["roles"] as? [String: Any],
                  let body = roles["fill"] as? [String: Any],
                  let count = number(body["confidentSamples"]), (32...samples).contains(count),
                  let edge = roles["outline"] as? [String: Any],
                  let edgeCount = number(edge["confidentSamples"]), (0...samples).contains(edgeCount),
                  edgeCount <= max(1, count * 0.01),
                  let edgeMean = number(edge["meanProbability"]), (0...0.02).contains(edgeMean),
                  let colours = body["observedColours"] as? [[String: Any]] else { return false }
            return colours.contains { row in
                guard let mass = number(row["observedMass"]), (0.8...1).contains(mass),
                      let observed = rgb(row["rgb"]) else { return false }
                return zip(chosen, observed).allSatisfy { abs($0 - $1) <= 5 }
            }
        }()
        guard probability <= (strongWhitePixels ? 0.25 : 0.15) else { return incumbentRatio }
        var measuredAbsence = false
        if let supplied = outline["measurementEvidence"] {
            guard let measurement = supplied as? [String:Any] else{return incumbentRatio}
            measuredAbsence = probability <= 0.05 && measurement["reliable"] as? Bool == true &&
                (number(measurement["usableRays"]) ?? 0) >= 32
        }
        if !measuredAbsence {
            // Ray measurements of a proposed outline are ancillary when no
            // outline was selected. Their presence must not suppress stronger
            // independent original-pixel absence/colour evidence. Without that
            // evidence, retain the stricter measured-only probability gate.
            guard let pixels=p["pixelRoleEvidence"] as? [String:Any],
                  pixels["GTAtInference"] as? Bool == false,
                  let samples=number(pixels["samples"]),samples>=256,
                  let roles=pixels["roles"] as? [String:Any],
                  let body=roles["fill"] as? [String:Any],
                  let fillSamples=number(body["confidentSamples"]),fillSamples>=32,fillSamples<=samples,
                  let edge=roles["outline"] as? [String:Any],
                  let edgeSamples=number(edge["confidentSamples"]),edgeSamples>=0,edgeSamples<=samples,
                  edgeSamples<=max(1,fillSamples*0.01),
                  let edgeProbability=number(edge["meanProbability"]),(0...0.02).contains(edgeProbability),
                  let colours=body["observedColours"] as? [[String:Any]],
                  colours.contains(where:{ colour in
                      guard let mass=number(colour["observedMass"]),(0.8...1).contains(mass),
                            let colour=rgb(colour["rgb"])else{return false}
                      return zip(chosen,colour).allSatisfy {abs($0-$1)<=5}
                  }) else{return incumbentRatio}
        }
        // Absence must be unambiguous; never discard a retained multi-band style.
        if let layers = outline["observedLayers"] {
            guard let bands = layers as? [Any], bands.isEmpty else { return incumbentRatio }
        }
        var total = 0.0, contrasting = 0.0
        let fillLuminance = luminance(chosen)
        for (colour, rawWeight) in zip(colours, weights) {
            guard let colour = rgb(colour), let weight = number(rawWeight), (0...1).contains(weight)
            else { return incumbentRatio }
            total += weight
            let backgroundLuminance = luminance(colour)
            let contrast = (max(fillLuminance, backgroundLuminance) + 0.05)
                / (min(fillLuminance, backgroundLuminance) + 0.05)
            if contrast >= 4.5 { contrasting += weight }
        }
        guard abs(total - 1) <= 0.001, contrasting / total >= (strongWhitePixels ? 0.94 : 0.95) else { return incumbentRatio }
        // Retain a visible guard, never enlarge a caller's smaller incumbent.
        // Consumers must keep the existing max(2px, fontPixels * ratio) floor.
        return min(incumbentRatio, 0.035)
    }

    struct Decision {
        let fill: CGColor
        let outline: CGColor
        let outwardOutputPixels: CGFloat
        let fullCoreTextLineWidth: CGFloat
        let paintStrokeBeforeFill = true
        let fitOnlyFillBody = true
        let backgroundSampleWasEmpty: Bool
    }

    enum Failure: Error { case invalidGeometry, invalidFill, allocation }

    static func decide(chosenFill: CGColor, restored: CGImage,
                       ownerOutputPixels: CGRect, fontOutputPixels: CGFloat,
                       outputPixelsPerLayoutPoint: CGFloat,
                       sourceAppearance: [String: Any]? = nil) throws -> Decision {
        guard fontOutputPixels.isFinite, fontOutputPixels > 0,
              outputPixelsPerLayoutPoint.isFinite, outputPixelsPerLayoutPoint > 0,
              [ownerOutputPixels.minX,ownerOutputPixels.minY,ownerOutputPixels.width,ownerOutputPixels.height].allSatisfy(\.isFinite),
              ownerOutputPixels.width > 0, ownerOutputPixels.height > 0 else { throw Failure.invalidGeometry }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let fill = chosenFill.converted(to: space, intent: .defaultIntent, options: nil),
              let channels = fill.components, channels.count == 4,
              channels.allSatisfy(\.isFinite), channels[3] > 0 else { throw Failure.invalidFill }
        let page = CGRect(x:0,y:0,width:restored.width,height:restored.height)
        let sample = ownerOutputPixels.integral.intersection(page)
        var median: [Double]? = nil
        if !sample.isNull, !sample.isEmpty, let crop = restored.cropping(to:sample) {
            var rgba = [UInt8](repeating:0,count:5*5*4)
            let ok = rgba.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data:bytes.baseAddress,width:5,height:5,bitsPerComponent:8,
                    bytesPerRow:20,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .medium
                context.draw(crop,in:CGRect(x:0,y:0,width:5,height:5))
                return true
            }
            guard ok else { throw Failure.allocation }
            median = (0..<3).map { c in (0..<25).map { Double(rgba[$0*4+c])/255 }.sorted()[12] }
        }
        func luminance(_ rgb:[Double]) -> Double {
            let linear=rgb.map{$0<=0.04045 ? $0/12.92 : pow(($0+0.055)/1.055,2.4)}
            return linear[0]*0.2126+linear[1]*0.7152+linear[2]*0.0722
        }
        let fillLuminance=luminance(channels.prefix(3).map(Double.init))
        func contrast(_ a:Double,_ b:Double) -> Double {(max(a,b)+0.05)/(min(a,b)+0.05)}
        func score(_ endpoint:Double) -> Double {
            contrast(fillLuminance,endpoint)*0.85 + (median.map{contrast(luminance($0),endpoint)*0.15} ?? 0)
        }
        // An off-page/empty reconstructed sample remains explicit uncertainty;
        // fill/edge contrast still produces a compulsory pure BW outline.
        let endpoint:CGFloat
        if median != nil { endpoint=score(1)>score(0) ? 1 : 0 }
        else { endpoint=contrast(fillLuminance,1)>contrast(fillLuminance,0) ? 1 : 0 }
        let ratio = median == nil ? CGFloat(0.20) : sourceAwareGuardRatio(
            chosenFillRGB: channels.prefix(3).map { Double($0) * 255 }, sourceAppearance: sourceAppearance)
        let radius=max(2,fontOutputPixels*ratio)
        return Decision(fill:chosenFill,outline:CGColor(gray:endpoint,alpha:1),
            outwardOutputPixels:radius,fullCoreTextLineWidth:2*radius/outputPixelsPerLayoutPoint,
            backgroundSampleWasEmpty:median == nil)
    }
}

extension NativeExplicitDisplayStrokePolicy {
    /// Positive owned-body evidence, independent of the region outline head.
    /// Preserves a source-white core only when a real BW guard is still painted.
    /// No prediction, source band, alpha mask, or model weight is rewritten.
    static func certifiedWhiteSourceCoreWithBand(chosenFillRGB:[Double],sourceAppearance:[String:Any]?,
                                                minimumBlackContrast:Double=3)->Bool {
        func number(_ raw:Any?)->Double? {
            guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{return nil}
            return n.doubleValue
        }
        func flag(_ raw:Any?,_ value:Bool)->Bool {
            guard let n=raw as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{return false}
            return n.boolValue==value
        }
        func rgb(_ raw:Any?)->[Double]? {
            guard let a=raw as? [Any],a.count==3 else{return nil}
            let v=a.compactMap(number)
            return v.count==3 && v.allSatisfy({(0...255).contains($0)}) ? v:nil
        }
        guard chosenFillRGB.count==3,chosenFillRGB.allSatisfy({$0.isFinite && (0...255).contains($0)}),chosenFillRGB.min()!>=245,
              chosenFillRGB.max()!-chosenFillRGB.min()!<=16,
              minimumBlackContrast.isFinite,minimumBlackContrast>0,
              let p=sourceAppearance,flag(p["sourceOnly"],true),flag(p["inferenceUsesGT"],false),
              let fill=p["fill"] as? [String:Any],let source=rgb(fill["rgb"]),
              zip(source,chosenFillRGB).allSatisfy({abs($0-$1)<=3}),
              let outline=p["outline"] as? [String:Any],flag(outline["present"],true),
              let width=number(outline["widthPx"]),width>0,width<=256,rgb(outline["rgb"]) != nil,
              let evidence=p["pixelRoleEvidence"] as? [String:Any],flag(evidence["GTAtInference"],false),
              evidence["featureContextPolicy"] as? String=="source-independent-paint-feature-context-v1",
              let samples=number(evidence["samples"]),samples>=256,
              let roles=evidence["roles"] as? [String:Any],let body=roles["fill"] as? [String:Any],
              let support=number(body["confidentSamples"]),support>=32,support<=samples,
              let colors=body["observedColours"] as? [[String:Any]] else{return false}
        let linear=chosenFillRGB.map {value -> Double in
            let s=value/255;return s<=0.04045 ? s/12.92:pow((s+0.055)/1.055,2.4)
        }
        let blackContrast=(linear[0]*0.2126+linear[1]*0.7152+linear[2]*0.0722+0.05)/0.05
        guard blackContrast>=minimumBlackContrast else{return false}
        return colors.contains {row in
            guard let mass=number(row["observedMass"]),(0.8...1).contains(mass),let observed=rgb(row["rgb"]) else{return false}
            return zip(observed,source).allSatisfy({abs($0-$1)<=5})
        }
    }
}
