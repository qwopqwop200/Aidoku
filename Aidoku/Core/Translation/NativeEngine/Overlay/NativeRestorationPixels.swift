import CoreGraphics
import Foundation

struct NativeRestorationRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    var channels: [Double] { [red, green, blue] }
    var minimum: Double { min(red, green, blue) }
    var maximum: Double { max(red, green, blue) }
    var cgColor: CGColor { CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red / 255, green / 255, blue / 255, 1])! }
    init(_ channels: [Double]) { red = channels[0]; green = channels[1]; blue = channels[2] }
    func distance(_ other: Self) -> Double { max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue)) }
}

/// Native counterparts of the bounded source restoration kernels. Floating point work uses
/// Float for harmonic/exemplar buffers and Double for tests, as the existing pixel kernels do.
struct NativeRestorationPixels {
    struct Palette {
        var foreground: NativeRestorationRGB
        var background: NativeRestorationRGB
        var stroke: NativeRestorationRGB?
        /// Keep display and original ink hypotheses distinct throughout restoration retries.
        var metadata: [String: Any] = [:]

        var foregroundConfidence: Double {
            (metadata["confidence"] as? [String: Any])?["foreground"] as? Double ?? (metadata.isEmpty ? 0.8 : 0)
        }
        var strokeConfidence: Double {
            (metadata["confidence"] as? [String: Any])?["stroke"] as? Double ?? (metadata.isEmpty && stroke != nil ? 0.9 : 0)
        }
        var backgroundConfidence: Double {
            (metadata["confidence"] as? [String: Any])?["background"] as? Double ?? (metadata.isEmpty ? 0.8 : 0)
        }
        var sourceInk: [String: Any]? { metadata["sourceInk"] as? [String: Any] }
        /// A partial sample can certify fill/stroke while its exterior backing is unresolved.
        /// The stored fallback RGB is never backing evidence in those policy branches.
        var verifiedForeground: NativeRestorationRGB? { metadata.isEmpty ? foreground : NativeRestorationPixels.rgb(metadata["foreground"]) }
        var verifiedBackground: NativeRestorationRGB? { metadata.isEmpty ? background : NativeRestorationPixels.rgb(metadata["background"]) }
        var widthEvidence: [String: Any]? { metadata["widthEvidence"] as? [String: Any] }
    }
    struct Component {
        let points: [Int]
        let rect: CGRect
        var touchesEdge: Bool
    }
    let width: Int
    let height: Int
    var rgba: [UInt8]
    var erasureComplete = false
    var sourceErasureVerified: Bool?
    var glyphsVerified = false
    /// Applied only after pixel completion; cannot authorize extra fringe erasure.
    var polygonGlyphsVerified = false
    // Bounded source-frame evidence, separate from every erasure certificate.
    var dottedFrameProtection: NativeDottedPaperFrame.Protection?
    var localProposal = false
    var sourceRemainingInk: Int?
    var sourceCorePixels: Int?
    var sourceFramePixels: Int?
    var preservedCore = 0
    var preservedPixels = 0
    var method: String?
    var surfaceQuality: [String: Any]?
    var discoveredOutline: NativeRestorationRGB?
    var observedFill: NativeRestorationRGB?
    var observedStroke: NativeRestorationRGB?
    var observedBacking: NativeRestorationRGB?
    var layoutSafe: [UInt8]?
    var readableRules: [UInt8]?
    var paperColor: NativeRestorationRGB?
    var count: Int { width * height }
    var paintedCount: Int { stride(from: 3, to: rgba.count, by: 4).reduce(0) { $0 + (rgba[$1] > 0 ? 1 : 0) } }

    init?(image: CGImage, width: Int, height: Int) {
        guard width > 0, height > 0, width * height <= 262_144 else { return nil }
        self.width = width; self.height = height
        rgba = [UInt8](repeating: 0, count: width * height * 4)
        let success = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { return nil }
    }

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        rgba = [UInt8](repeating: 0, count: width * height * 4)
    }

    func image() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    func color(_ index: Int) -> NativeRestorationRGB {
        NativeRestorationRGB([Double(rgba[index * 4]), Double(rgba[index * 4 + 1]), Double(rgba[index * 4 + 2])])
    }
    mutating func paint(_ index: Int, _ color: NativeRestorationRGB) {
        for channel in 0..<3 { rgba[index * 4 + channel] = Self.clamp(color.channels[channel]) }
        rgba[index * 4 + 3] = 255
    }
    static func clamp(_ value: Double) -> UInt8 {
        // Uint8ClampedArray uses round-to-nearest with ties-to-even.
        UInt8(min(255, max(0, value.rounded(.toNearestOrEven))))
    }
    mutating func clear(rect: CGRect) {
        for index in indices(rect) { rgba[index * 4 + 3] = 0 }
    }
    func indices(_ rect: CGRect) -> [Int] {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else { return [] }
        // Keep off-crop finite coordinates in floating point until bounded:
        // the source rectangles may exceed Int's representable range.
        let left = Int(max(0, min(CGFloat(width), floor(rect.minX))))
        let right = Int(max(0, min(CGFloat(width), ceil(rect.maxX))))
        let top = Int(max(0, min(CGFloat(height), floor(rect.minY))))
        let bottom = Int(max(0, min(CGFloat(height), ceil(rect.maxY))))
        guard left < right, top < bottom else { return [] }
        return (top..<bottom).flatMap { y in (left..<right).map { y * width + $0 } }
    }
    func neighbors(_ index: Int, diagonal: Bool = true) -> [Int] {
        let x = index % width, y = index / width
        if !diagonal {
            return [x > 0 ? index - 1 : -1, x + 1 < width ? index + 1 : -1,
                    y > 0 ? index - width : -1, y + 1 < height ? index + width : -1].filter { $0 >= 0 }
        }
        return (max(0, y - 1)...min(height - 1, y + 1)).flatMap { yy in
            (max(0, x - 1)...min(width - 1, x + 1)).map { yy * width + $0 }
        }
    }
    func components(_ on: [UInt8], diagonal: Bool = true) -> [Component] {
        var seen = [UInt8](repeating: 0, count: count)
        var result: [Component] = []
        for seed in 0..<count where on[seed] != 0 && seen[seed] == 0 {
            var queue = [seed], head = 0, x0 = width, y0 = height, x1 = 0, y1 = 0
            seen[seed] = 1
            while head < queue.count {
                let index = queue[head]; head += 1
                let x = index % width, y = index / width
                x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
                for next in neighbors(index, diagonal: diagonal) where on[next] != 0 && seen[next] == 0 {
                    seen[next] = 1; queue.append(next)
                }
            }
            result.append(Component(points: queue, rect: CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1),
                                    touchesEdge: x0 <= 2 || y0 <= 2 || x1 >= width - 3 || y1 >= height - 3))
        }
        return result
    }

    /// Sample the original crop through the same admission and source-color policy as the page stage.
    static func palette(_ p: Self, box: CGRect) -> Palette? {
        guard let image = p.image() else { return nil }
        let budget = NativeSourceColorSamplingStage.Budget()
        budget.remainingSamples = 1
        let sampler = NativeSourceColorSamplingStage(image: image, enabled: true, phase: "translation", budget: budget)
        let sample = sampler.sample(bounds: [Double(box.minX) / Double(p.width), Double(box.minY) / Double(p.height),
                                             Double(box.width) / Double(p.width), Double(box.height) / Double(p.height)])
        return sample.flatMap(palette)
    }

    static func palette(_ sample: [String: Any]) -> Palette? {
        guard rgb(sample["foreground"]) != nil || rgb(sample["background"]) != nil ||
            rgb((sample["sourceInk"] as? [String: Any])?["foreground"]) != nil else { return nil }
        let foreground = rgb(sample["foreground"]) ?? NativeRestorationRGB([255, 255, 255])
        return Palette(foreground: foreground, background: rgb(sample["background"]) ?? NativeRestorationRGB([255, 255, 255]), stroke: rgb(sample["stroke"]), metadata: sample)
    }

    static func rgb(_ value: Any?) -> NativeRestorationRGB? {
        guard let channels = value as? [NSNumber], channels.count == 3 else { return nil }
        let values = channels.map(\.doubleValue)
        guard values.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { return nil }
        return NativeRestorationRGB(values)
    }

    static func blend(_ pixel: NativeRestorationRGB, from: NativeRestorationRGB, to: NativeRestorationRGB, tolerance: Double = 24) -> Bool {
        let start = from.channels, end = to.channels, value = pixel.channels
        let delta = (0..<3).map { end[$0] - start[$0] }
        let length = delta.reduce(0) { $0 + $1 * $1 }
        guard length > 0 else { return false }
        let projection = (0..<3).reduce(0) { $0 + (value[$1] - start[$1]) * delta[$1] } / length
        let factor = min(1, max(0, projection))
        return (0..<3).map { abs(value[$0] - start[$0] - factor * delta[$0]) }.max()! <= tolerance
    }

    static func restore(_ p: Self, box: CGRect, auxiliary: [CGRect], excluded: [CGRect], palette: Palette?,
                        vertical: Bool, polygon: [CGPoint], slanted: Bool,
                        sourceOptions: NativeObservedRestoreOptions? = nil,
                        inferredRubyExclusions: [CGRect]? = nil) -> Self? {
        guard !Task.isCancelled else { return nil }
        var options = sourceOptions ?? NativeObservedRestoreOptions()
        options.auxiliary = auxiliary; options.excluded = excluded
        // Inference retains every original OCR descriptor even when separate
        // pixel ownership resolves a containing title's hard write exclusion.
        options.inferredRubyExclusions = inferredRubyExclusions ?? excluded
        options.vertical = vertical; options.slantedOwnership = slanted
        if !slanted {
            options.glyphOwnership = NativeObservedGlyphOwnership.make(width: p.width, height: p.height,
                box: box, polygon: polygon, auxiliary: auxiliary)
        }
        func protectedResult(_ candidate: Self?) -> Self? {
            var candidate = candidate
            // This late qualification leaves all restoration/fringe bytes intact.
            // Exclusion clipping still has the final authority to invalidate it.
            if candidate?.polygonGlyphsVerified == true { candidate?.glyphsVerified = true }
            return protectExclusions(candidate, original: p, box: box, auxiliary: auxiliary, excluded: excluded, palette: palette)
        }
        if !slanted, let grid = NativeSourceGlyphSegmentation.ruledGridRestore(rgba: p.rgba, width: p.width, height: p.height,
                box: box, vertical: vertical, auxiliary: auxiliary, excluded: excluded) {
            var result = Self(width: p.width, height: p.height); result.rgba = grid.rgba
            result.layoutSafe = grid.layoutSafe; result.erasureComplete = true; result.glyphsVerified = true
            result.readableRules = grid.readableRules; result.paperColor = NativeRestorationRGB(grid.paper)
            result.method = "ruled-grid"; result.surfaceQuality = ["safe": false, "reason": "ruled-grid"]
            return protectedResult(result)
        }
        var result = exactObservedRestore(p, box: box, palette: palette, options: options)
        if result == nil && !slanted {
            let paper = enclosedPaper(p, box: box, auxiliary: auxiliary, excluded: excluded)
            if var paper, paper.erasureComplete { paper.localProposal = true; result = paper }
        }
        if result == nil && !slanted {
            let local = nativeLocalComponentPaper(p, box: box, auxiliary: auxiliary, excluded: excluded)
            if var local, local.glyphsVerified { local.localProposal = true; result = local }
        }
        if var completed = result, !slanted {
            _ = NativeConnectedLettering.complete(original: p, box: box, restored: &completed, exclusions: excluded, vertical: vertical)
            result = completed
        }
        return protectedResult(result)
    }

    /// Foreign OCR bounds can overlap in empty paper between adjacent balloons.
    /// Preserve an existing proof only when immutable source pixels, including
    /// their immediate rim, independently certify that the overlap is paper.
    /// A transparent patch alone is insufficient: an earlier stage may already
    /// have clipped foreign or unresolved source ink out of that patch.
    static func protectExclusions(_ candidate: Self?, original: Self, box: CGRect, auxiliary: [CGRect],
                                  excluded: [CGRect], palette: Palette?) -> Self? {
        guard var candidate, candidate.width == original.width, candidate.height == original.height else { return nil }
        func paperOnly(_ overlap: CGRect) -> Bool {
            guard let background = palette?.verifiedBackground, background.minimum >= 248,
                  background.maximum - background.minimum <= 6 else { return false }
            let rim = overlap.insetBy(dx: -1, dy: -1)
            guard rim.minX >= 0, rim.minY >= 0, rim.maxX <= CGFloat(original.width),
                  rim.maxY <= CGFloat(original.height) else { return false }
            let samples = original.indices(rim)
            return !samples.isEmpty && samples.allSatisfy { index in
                let color = original.color(index)
                return original.rgba[index * 4 + 3] == 255 && color.maximum - color.minimum <= 6 &&
                    color.distance(background) <= 8
            }
        }
        let owned = [box] + auxiliary
        let background = candidate.observedBacking ?? palette?.verifiedBackground
        let sourceInk = [candidate.observedFill ?? palette?.verifiedForeground,
                         candidate.observedStroke ?? palette?.stroke].compactMap { $0 }
        func clipsObservedSourceInk(_ index: Int) -> Bool {
            let point = CGPoint(x: index % original.width, y: index / original.width)
            guard owned.contains(where: { $0.contains(point) }), let background else { return false }
            let color = original.color(index)
            // Match the existing page-erasure proof's original ink evidence.
            // A changed/background pixel alone is not an owned glyph certificate.
            return original.rgba[index * 4 + 3] == 255 && candidate.color(index).distance(color) > 24 &&
                color.distance(background) >= 40 && sourceInk.contains { color.distance($0) <= 36 }
        }
        var invalidated = false, observedInkClipped = false
        for rect in excluded {
            for index in candidate.indices(rect) {
                if candidate.rgba[index * 4 + 3] != 0 {
                    let pixel = CGRect(x: index % original.width, y: index / original.width, width: 1, height: 1)
                    if !paperOnly(pixel) {
                        invalidated = true
                        observedInkClipped = observedInkClipped || clipsObservedSourceInk(index)
                    }
                }
                candidate.rgba[index * 4 + 3] = 0
                candidate.layoutSafe?[index] = 0
            }
            for owned in [box] + auxiliary where owned.intersects(rect) {
                if !paperOnly(owned.intersection(rect)) { invalidated = true }
            }
        }
        if invalidated {
            candidate.erasureComplete = false
            candidate.glyphsVerified = false
        }
        // Preserve the independent source-erasure certificate established by
        // the producing algorithm. A foreign bounding-box intersection does
        // not prove that original owned lettering was clipped. Revoke this
        // certificate only when this operation actually clips observed source ink.
        if observedInkClipped { candidate.sourceErasureVerified = false }
        return candidate.paintedCount > 0 ? candidate : nil
    }

    /// Flood the page paper, then erase only its bounded OCR-owned holes. This retains
    /// black frame/rule pixels attached to the crop edge and checks every auxiliary box.
    static func enclosedPaper(_ p: Self, box: CGRect, auxiliary: [CGRect], excluded: [CGRect]) -> Self? {
        guard var output = nativeEnclosedPaper(p, box: box, auxiliary: auxiliary, excluded: excluded),
              let safe = output.layoutSafe else { return nil }
        let left = max(0, floor(box.minX)), top = max(0, floor(box.minY))
        let right = min(CGFloat(p.width), ceil(box.maxX)), bottom = min(CGFloat(p.height), ceil(box.maxY))
        let core = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        guard let finished = NativeEnclosedPaperFinish.finish(source: p.rgba, width: p.width, height: p.height,
                core: core, auxiliary: auxiliary, rgba: output.rgba, safe: safe) else { return nil }
        output.rgba = finished.rgba; output.layoutSafe = finished.safe
        output.erasureComplete = ([core] + auxiliary).flatMap(p.indices).allSatisfy { finished.safe[$0] != 0 }
        return output
    }
}
