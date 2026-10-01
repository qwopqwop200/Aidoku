import CoreGraphics
import Foundation

/// Native counterpart of the frozen renderer's dormant appendSourceCleanup policy.
/// This capability remains callable without enabling a historically unused render pass.
/// Its page budget, flat-paper admission and lexical colored retry are independent of inpainting.
final class NativeSourceInkCleanup {
    struct Audit: Equatable {
        let reason: String
        let erased: Int
        let haloAdded: Int
    }
    struct Pixels {
        let rgba: [UInt8]?
        let count: Int
        let dense: Bool
        let audit: Audit?
    }
    struct Prepared {
        let image: CGImage
        let rect: CGRect
        let width: Int
        let height: Int
        let pixels: Pixels
    }

    let image: CGImage
    let reader: NativeSourcePixelReader
    var cleanupBudget = 2_000_000
    var coloredBudget = 262_144
    private(set) var cleanedPixels = 0
    private(set) var cleanupCount = 0
    private(set) var coloredAudit: [(String, Int, Audit)] = []
    private(set) var denseItems: Set<String> = []
    private var cache: [String: Pixels] = [:]
    private var order: [String] = []
    private var cachePixels = 0
    private var cacheBytes = 0
    private var retained: [String: (Int, Int)] = [:]

    init(image: CGImage, reader: NativeSourcePixelReader) {
        self.image = image
        self.reader = reader
    }

    func prepare(item: NativeTranslationLayoutItem, sample: [String: Any]?, opacity: CGFloat) -> Prepared? {
        guard item.rotation == 0 else { return nil }
        let cleanupSample = item.sourceCleanupLexical && item.sourceColorEligible ? sample : nil
        let background = cleanupSample.flatMap { NativeSourceColorSampler.rgb($0["background"]) }
        let coloredEligible = background.map {
            $0.max()! - $0.min()! > 12 || $0.max()! < 220 || cleanupSample?["stroke"] is [NSNumber]
        } ?? false
        let neutralFallback = item.sourceCleanup && (background?.max() ?? 255) < 250
        guard item.sourceCleanup || coloredEligible, opacity.isFinite, opacity > 0 else { return nil }
        let b = item.sourceBounds, frame = item.sourceFrame
        guard b.count == 4, frame.count == 4, b.allSatisfy(\.isFinite), frame.allSatisfy(\.isFinite),
              b[2] > 0, b[3] > 0, frame[2] > 0, frame[3] > 0 else { return nil }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let x = floor(b[0] * iw), y = floor(b[1] * ih)
        let right = ceil((b[0] + b[2]) * iw), bottom = ceil((b[1] + b[3]) * ih)
        let width = right - x + 5, height = bottom - y + 5
        guard x >= 2, y >= 2, right + 2 < iw, bottom + 2 < ih,
              width >= 14, height >= 14, width * height <= 262_144,
              width * height <= CGFloat(cleanupBudget) else { return nil }
        let w = Int(width), h = Int(height), pixels = w * h
        cleanupBudget -= pixels
        let coloredAllowed = (coloredEligible || neutralFallback) && pixels <= 131_072 && pixels <= coloredBudget
        let keyValue: [Any] = [x, y, w, h, item.sourceCleanup, item.sourceVertical, coloredAllowed, cleanupSample as Any? ?? NSNull()]
        let key = (try? JSONSerialization.data(withJSONObject: keyValue, options: [.sortedKeys])).map { $0.base64EncodedString() }
        let prepared: Pixels
        if let key, let cached = cache[key] { prepared = cached }
        else {
            guard let rgba = try? reader.read(x: Double(x - 2), y: Double(y - 2), sourceWidth: Double(w), sourceHeight: Double(h), width: w, height: h) else { return nil }
            prepared = Self.apply(rgba: rgba, width: w, height: h, white: item.sourceCleanup, vertical: item.sourceVertical,
                coloredAllowed: coloredAllowed, coloredEligible: coloredEligible, sample: cleanupSample)
            if let key { store(key: key, prepared: prepared, pixels: pixels) }
        }
        if coloredAllowed, let audit = prepared.audit {
            coloredBudget -= pixels
            coloredAudit.append((item.id, pixels, audit))
        }
        guard let rgba = prepared.rgba, let provider = CGDataProvider(data: Data(rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        if prepared.dense { denseItems.insert(item.id) }
        cleanedPixels += prepared.count
        cleanupCount += 1
        let rect = CGRect(x: frame[0] + (x - 2) / iw * frame[2], y: frame[1] + (y - 2) / ih * frame[3],
            width: width / iw * frame[2], height: height / ih * frame[3])
        return Prepared(image: bitmap, rect: rect, width: w, height: h, pixels: prepared)
    }

    static func apply(rgba: [UInt8], width: Int, height: Int, white: Bool, vertical: Bool,
                      coloredAllowed: Bool, coloredEligible: Bool, sample: [String: Any]?) -> Pixels {
        var neutral = white ? NativeSourceGlyphSegmentation.neutralSourceInkMask(rgba: rgba, width: width, height: height, vertical: vertical) : nil
        var mask = neutral?.mask
        var fill = [Double](repeating: 255, count: 3)
        var audit: Audit?
        if coloredAllowed && (coloredEligible || mask == nil) {
            let palette = NativeSourceGlyphSegmentation.Palette(
                foreground: NativeSourceColorSampler.rgb(sample?["foreground"]) ?? [],
                background: NativeSourceColorSampler.rgb(sample?["background"]),
                stroke: NativeSourceColorSampler.rgb(sample?["stroke"]))
            let colored = NativeSourceGlyphSegmentation.coloredSourceInkMask(rgba: rgba, width: width, height: height, palette: palette)
            audit = Audit(reason: colored.reason, erased: colored.erased, haloAdded: colored.haloAdded)
            if let coloredMask = colored.mask, let coloredFill = colored.fill {
                mask = coloredMask.map { $0 == 0 ? 0 : 255 }
                fill = coloredFill
                neutral = nil // Uint8Array.from drops the neutral mask's dense-recovery property.
            }
        }
        guard let mask, mask.count == width * height, fill.count == 3 else { return Pixels(rgba: nil, count: 0, dense: false, audit: audit) }
        var output = [UInt8](repeating: 0, count: width * height * 4), count = 0
        for i in mask.indices where mask[i] != 0 {
            for c in 0..<3 { output[i * 4 + c] = NativeRestorationPixels.clamp(fill[c]) }
            output[i * 4 + 3] = mask[i]
            count += 1
        }
        return Pixels(rgba: output, count: count, dense: neutral?.denseSurfaceRecovered ?? false, audit: audit)
    }

    private func store(key: String, prepared: Pixels, pixels: Int) {
        let bytes = prepared.rgba?.count ?? 0
        while !order.isEmpty && (cacheBytes + bytes > 16 * 1_024 * 1_024 || cachePixels + pixels > 4_194_304 || order.count >= 256) {
            let oldest = order.removeFirst()
            if let sizes = retained.removeValue(forKey: oldest) { cachePixels -= sizes.0; cacheBytes -= sizes.1 }
            cache.removeValue(forKey: oldest)
        }
        cache[key] = prepared
        retained[key] = (pixels, bytes)
        order.append(key)
        cachePixels += pixels
        cacheBytes += bytes
    }
}
