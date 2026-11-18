import CoreGraphics
import Foundation

/// Call before sealing the retained raster. Input contains ONLY translated fill,
/// never the restored page. No source-colour estimation or layout mutation here.
enum NativeMandatoryDisplayStroke {
    struct Prepared {
        let pageHeight: Int
        let fill: CGImage
        let halo: CGImage
        /// Pixel coordinates in the supplied restored image.
        let frame: CGRect
        let outwardPixels: CGFloat
        let endpoint: UInt8
        let addedAlphaPixels: Int
        let opaqueFillPixels: Int
        let touchesPageEdge: Bool
        let endpointDecision: [String: Any]
        var sourceContourOnly: Bool = false
    }

    enum Failure: Error { case invalidInput, allocation, emptyFill }

    static func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard ok else { throw Failure.allocation }
        return bytes
    }

    static func image(_ bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw Failure.allocation }
        return result
    }

    /// Raster fallback also handles fonts without CGPaths, vertical text and PDF
    /// fallback glyphs. The producer supplies its final fill geometry unchanged.
    static func prepare(fill: CGImage, restored: CGImage, fontOutputPixels: CGFloat,
                        outwardEm: CGFloat = 0.20, fillFrame: CGRect? = nil, forcedEndpoint: UInt8? = nil,
                        recheckFinalEndpoint: Bool = false, minimumFillStrokeContrast: Double = 3,
                        minimumCoverageGain: Double = 0.05,
                        sourceAppearance: [String:Any]? = nil,
                        sourceContourOnly: Bool = false) throws -> Prepared {
        let inputFrame = fillFrame ?? CGRect(x: 0, y: 0, width: fill.width, height: fill.height)
        guard inputFrame.origin.x.isFinite, inputFrame.origin.y.isFinite,
              inputFrame == inputFrame.integral,
              inputFrame.width == CGFloat(fill.width), inputFrame.height == CGFloat(fill.height),
              CGRect(x: 0, y: 0, width: restored.width, height: restored.height).contains(inputFrame),
              fontOutputPixels.isFinite, fontOutputPixels > 0,
              outwardEm.isFinite, outwardEm > 0,
              forcedEndpoint == nil || forcedEndpoint == 0 || forcedEndpoint == 255 else { throw Failure.invalidInput }
        let w = fill.width, h = fill.height
        if sourceContourOnly {
            guard w <= 16_384, h <= 16_384, w <= 8_000_000 / h else { throw Failure.invalidInput }
        }
        let bytes = try rgba(fill)
        var left = w, top = h, right = -1, bottom = -1
        var fillSum = [Double](repeating: 0, count: 3), alphaSum = 0.0
        for y in 0..<h { for x in 0..<w {
            let p = (y * w + x) * 4
            if bytes[p + 3] > 0 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
                alphaSum += Double(bytes[p + 3])
                for c in 0..<3 { fillSum[c] += Double(bytes[p + c]) }
            }
        }}
        guard right >= left else { throw Failure.emptyFill }
        // Eligibility is resolved by the authenticated producer. Keep the raw
        // raster, including every AA sample, rather than estimating its colour.
        // Source bands are painted and independently admitted by the caller.
        if sourceContourOnly {
            let ink = fillSum.map { Int(($0 / max(1, alphaSum) * 255).rounded()) }
            let opaque = stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] == 255 }.count
            return Prepared(pageHeight: restored.height, fill: fill,
                halo: try image([UInt8](repeating: 0, count: bytes.count), width: w, height: h),
                frame: inputFrame, outwardPixels: 0, endpoint: forcedEndpoint ?? 0,
                addedAlphaPixels: 0, opaqueFillPixels: opaque,
                touchesPageEdge: inputFrame.minX + CGFloat(left) <= 0 || inputFrame.minY + CGFloat(top) <= 0 ||
                    inputFrame.minX + CGFloat(right + 1) >= CGFloat(restored.width) ||
                    inputFrame.minY + CGFloat(bottom + 1) >= CGFloat(restored.height),
                endpointDecision: ["paintMode": "source-contour-only", "guardPainted": false,
                    "enabled": false, "changed": false, "decodedRestoredPixels": 0,
                    "selectedFillRGB": ink, "displayFillRGB": ink, "whiteFillOverride": false,
                    "fillRGBAPreserved": true, "finalEndpoint": NSNull(),
                    "authority": "producer-resolved source contour; actual fill retained without BW guard"],
                sourceContourOnly: true)
        }
        let radius = max(2, fontOutputPixels * outwardEm)
        let margin = Int(ceil(radius)) + (recheckFinalEndpoint ? 10 : 1)
        let ox = Int(inputFrame.minX), oy = Int(inputFrame.minY)
        let x0 = max(-ox, left - margin), y0 = max(-oy, top - margin)
        let x1 = min(restored.width - 1 - ox, right + margin)
        let y1 = min(restored.height - 1 - oy, bottom + margin)
        let cw = x1 - x0 + 1, ch = y1 - y0 + 1
        let frame = CGRect(x: x0 + ox, y: y0 + oy, width: cw, height: ch)
        var paddedFill = [UInt8](repeating: 0, count: cw * ch * 4)
        var alphaPlane = [UInt8](repeating: 0, count: cw * ch)
        for y in 0..<ch { for x in 0..<cw {
            let sx = x + x0, sy = y + y0
            if sx >= 0, sx < w, sy >= 0, sy < h {
                let src = (sy*w+sx)*4, dst = (y*cw+x)*4
                for c in 0..<4 { paddedFill[dst+c] = bytes[src+c] }
                alphaPlane[y*cw+x] = bytes[src+3]
            }
        }}
        let ink = fillSum.map { $0 / max(1, alphaSum) }
        // Display policy only: keep the upstream source/palette estimates intact.
        // Include washed-out white/cream predictions, not just RGB >=230.
        // Saturated pale yellow and coloured emphasis remain coloured.
        let nearWhite = ink.min()! * 255 >= 180 && (ink.max()! - ink.min()!) * 255 <= 64
            && (ink[0] * 0.2126 + ink[1] * 0.7152 + ink[2] * 0.0722) * 255 >= 190
        // A valid forced endpoint with recheck disabled cannot use background
        // scores. Do not decode/copy restored pixels for that ordinary path.
        var bg = [UInt8]()
        var bgSum = [Double](repeating: 0, count: 3)
        if forcedEndpoint == nil || recheckFinalEndpoint || nearWhite {
            guard let background = restored.cropping(to: frame) else { throw Failure.invalidInput }
            bg = try rgba(background)
            for i in stride(from: 0, to: bg.count, by: 4) {
                for c in 0..<3 { bgSum[c] += Double(bg[i + c]) / Double(cw * ch) / 255 }
            }
        }
        func luminance(_ rgb: [Double]) -> Double {
            let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        func score(_ endpoint: Double) -> Double {
            contrast(luminance(ink), endpoint) * 0.85 + contrast(luminance(bgSum), endpoint) * 0.15
        }
        let priorEndpoint: UInt8 = forcedEndpoint ?? (score(1) > score(0) ? 255 : 0)
        var endpoint = priorEndpoint
        var endpointDecision: [String: Any] = ["enabled": recheckFinalEndpoint,
            "requestedEndpoint": Int(priorEndpoint), "changed": false,
            "decodedRestoredPixels": bg.count/4,
            "authority": recheckFinalEndpoint
                ? "actual final translated fill raster and restored pixels; visibility proxy, not readability gold"
                : (forcedEndpoint != nil ? "upstream requested BW endpoint; final background visibility not measured"
                    : "legacy automatic fill/box-average contrast; final glyph visibility not measured")]
        var halo = [UInt8](repeating: 0, count: cw * ch * 4)
        var added = 0, opaque = 0
        let dilated = NativeDiskAlphaMaximum.antialiased(alphaPlane, width: cw, height: ch, radius: radius)
        // Classify the restored surface under the actual glyph+halo footprint,
        // not the bounding box or visible-only contrast score. A dark coloured
        // balloon or a small black island is not a genuinely black surface.
        var support = 0.0, blackSupport = 0.0
        if nearWhite {
            for i in 0..<(cw * ch) where dilated[i] > 0 {
                let weight = Double(dilated[i]) / 255
                let channels = (0..<3).map { Int(bg[i * 4 + $0]) }
                let high = channels.max()!, low = channels.min()!
                support += weight
                if high <= 56 && high - low <= 20 { blackSupport += weight }
            }
        }
        let blackFraction = support > 0 ? blackSupport / support : 0
        let sourceGuardRatio = NativeExplicitDisplayStrokePolicy.sourceAwareGuardRatio(
            chosenFillRGB:ink.map { $0 * 255 },sourceAppearance:sourceAppearance)
        let sourceAbsenceFillCertified = sourceGuardRatio < 0.20 && outwardEm <= sourceGuardRatio + 1e-6
        let sourceBandWhiteFillCertified = NativeExplicitDisplayStrokePolicy.certifiedWhiteSourceCoreWithBand(
            chosenFillRGB: ink.map { $0 * 255 }, sourceAppearance: sourceAppearance,
            minimumBlackContrast: minimumFillStrokeContrast)
        let sourceFillCertified = sourceAbsenceFillCertified || sourceBandWhiteFillCertified
        let forceBlackFill = nearWhite && blackFraction < 0.85 && !sourceFillCertified
        if forceBlackFill {
            for i in 0..<(cw * ch) {
                for c in 0..<3 { paddedFill[i * 4 + c] = 0 }
            }
            endpoint = 255
            endpointDecision["selectionSeconds"] = 0.0
            endpointDecision["status"] = "forced-black-fill-white-stroke-nonblack-surface"
        } else if nearWhite {
            endpoint = 0
            endpointDecision["selectionSeconds"] = 0.0
            endpointDecision["status"] = sourceFillCertified
                ? (sourceBandWhiteFillCertified ? "retained-source-white-fill-certified-positive-body-and-band"
                    : "retained-source-white-fill-certified-contrast-and-absent-outline")
                : "retained-white-fill-black-stroke-genuine-black-surface"
        } else if recheckFinalEndpoint {
            let start = Date()
            let decision = NativeRenderedStrokeSelection.select(fill: paddedFill, alpha: alphaPlane,
                dilated: dilated, background: bg, width: cw, height: ch, radius: Double(radius),
                preferredEndpoint: forcedEndpoint)
            endpoint = decision.0
            endpointDecision.merge(decision.1) { _, value in value }
            endpointDecision["changed"] = endpoint != priorEndpoint
            endpointDecision["selectionSeconds"] = Date().timeIntervalSince(start)
            endpointDecision["status"] = "compared-black-white-final-rendered-boundaries"
            // Historical coverage thresholds have different units; never silently
            // reinterpret them as score-margin/legibility thresholds.
            endpointDecision["legacyCoverageThresholdsUsed"] = false
        }
        endpointDecision["whiteFillPolicy"] = "pale-min180-spread64-luma190-black-max56-spread20-coverage85-v2"
        endpointDecision["selectedFillRGB"] = ink.map { Int(($0 * 255).rounded()) }
        endpointDecision["displayFillRGB"] = forceBlackFill ? [0, 0, 0] : ink.map { Int(($0 * 255).rounded()) }
        endpointDecision["whiteFillOverride"] = forceBlackFill
        endpointDecision["sourceAbsentOutlineFillPreserved"] = sourceAbsenceFillCertified
        endpointDecision["sourceBandWhiteFillPreserved"] = sourceBandWhiteFillCertified
        endpointDecision["blackSurfaceFraction"] = nearWhite ? blackFraction : NSNull()
        endpointDecision["changed"] = endpoint != priorEndpoint
        endpointDecision["finalEndpoint"] = Int(endpoint)
        let croppedFill = try image(paddedFill, width: cw, height: ch)
        for i in 0..<(cw*ch) {
            let alpha = dilated[i], original = alphaPlane[i], p = i*4
            if Int(alpha) - Int(original) >= 8 { added += 1 }
            if original == 255 { opaque += 1 }
            for c in 0..<3 { halo[p+c] = endpoint == 255 ? alpha : 0 }
            halo[p+3] = alpha
        }
        return Prepared(pageHeight: restored.height, fill: croppedFill, halo: try image(halo, width: cw, height: ch), frame: frame,
            outwardPixels: radius, endpoint: endpoint, addedAlphaPixels: added, opaqueFillPixels: opaque,
            touchesPageEdge: left + ox < margin || top + oy < margin || right + ox + margin >= restored.width || bottom + oy + margin >= restored.height,
            endpointDecision: endpointDecision)
    }

    /// Context uses CGImage pixel coordinates. Paint ALL halos before ANY fill,
    /// so neighbouring halos cannot obscure already retained glyph interiors.
    static func paint(_ layers: [Prepared], in context: CGContext) {
        context.saveGState()
        context.setBlendMode(.normal)
        context.setAlpha(1)
        func quartzFrame(_ layer: Prepared) -> CGRect {
            CGRect(x: layer.frame.minX, y: CGFloat(layer.pageHeight) - layer.frame.maxY,
                width: layer.frame.width, height: layer.frame.height)
        }
        for layer in layers { context.draw(layer.halo, in: quartzFrame(layer)) }
        for layer in layers { context.draw(layer.fill, in: quartzFrame(layer)) }
        context.restoreGState()
    }
}
