import CoreGraphics
import Foundation
import Accelerate

/// Immutable ACTUAL mask snapshot, not a caller-asserted validation flag.
/// The only initializer checks the complete current byte domain/dimensions.
/// Swift Array value/COW ownership preserves this snapshot on caller mutation;
/// no mutable pointer or unchecked constructor is exposed.
struct NativeAOTValidatedMask: Sendable {
    enum Domain: Sendable { case strict255, logical01Or255 }
    enum Failure: Error { case dimensions, binary }
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let foregroundCount: Int
    var hasForeground: Bool { foregroundCount != 0 }

    init(validating bytes: [UInt8], width: Int, height: Int, domain: Domain) throws {
        guard width > 0, height > 0, width <= 32_000_000 / height,
              bytes.count == width * height else { throw Failure.dimensions }
        var foreground = 0
        for value in bytes {
            if value == 0 { continue }
            guard value == 255 || (domain == .logical01Or255 && value == 1) else { throw Failure.binary }
            foreground += 1
        }
        self.bytes = bytes; self.width = width; self.height = height
        foregroundCount = foreground
    }
}

/// Alpha boundary only: no resize, mask generation, model call, I/O or shared cache.
/// Canonical CG pixels match NativeResidentAOT's existing sRGB/premultipliedLast/RGBA8 decode.
/// White matting is in sRGB code values, not linear light. The original-resolution binary
/// mask alone authorizes replacement: outside retains canonical source RGBA; inside takes
/// inferred RGB with alpha=255. Deliberately no alpha feather or retained source alpha inside.
enum NativeAOTAlphaComposition {
    static let policyVersion = "aot-white-srgb-outside-rgba-inside-opaque-v1"

    enum Encoding: String { case premultipliedRGBA8, straightRGBA8 }
    enum Failure: Error {
        case dimensions, allocation, invalidPremultiplication, invalidMask, restoredDimensions
        case opaqueOutsideMismatch
    }

    struct Source {
        let width: Int
        let height: Int
        let canonicalRGBA: [UInt8]
        let encoding: Encoding
        let inferenceRGB: [UInt8]
        let hasTransparency: Bool

        fileprivate init(width: Int, height: Int, canonicalRGBA: [UInt8], encoding: Encoding,
                         inferenceRGB: [UInt8], hasTransparency: Bool) {
            self.width = width; self.height = height; self.canonicalRGBA = canonicalRGBA
            self.encoding = encoding; self.inferenceRGB = inferenceRGB; self.hasTransparency = hasTransparency
        }
    }

    /// Replaces the existing resident RGBA decode and opaque-only RGB extraction, not the
    /// source CGImage held by the renderer/cache. No orientation transform is introduced.
    static func prepare(source: CGImage) throws -> Source {
        let w = source.width, h = source.height
        try validateDimensions(width: w, height: h)
        var rgba = [UInt8](repeating: 0, count: w*h*4)
        try rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw Failure.allocation }
            context.setBlendMode(.copy)
            context.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // For actual opaque canonical pixels, white-matte arithmetic is an
        // identity and every UInt8 channel is valid premultiplication. Strip
        // alpha with an exact byte-pack instead of per-channel scalar checks.
        // ANY nonopaque pixel retains the ORIGINAL scalar white-matte route on
        // this SAME actual canonical buffer, never a second CGContext decode.
        var opaque = true
        for p in 0..<w*h where rgba[p*4+3] != 255 { opaque = false; break }
        if opaque {
            var rgb = [UInt8](repeating: 0, count: w*h*3)
            try rgba.withUnsafeBytes { sourceBytes in
                try rgb.withUnsafeMutableBytes { destinationBytes in
                    var sourceBuffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: sourceBytes.baseAddress!),
                        height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w*4)
                    var destinationBuffer = vImage_Buffer(data: destinationBytes.baseAddress!,
                        height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w*3)
                    guard vImageConvert_RGBA8888toRGB888(&sourceBuffer, &destinationBuffer,
                        vImage_Flags(kvImageNoFlags)) == kvImageNoError else { throw Failure.allocation }
                }
            }
            return Source(width: w, height: h, canonicalRGBA: rgba, encoding: .premultipliedRGBA8,
                inferenceRGB: rgb, hasTransparency: false)
        }
        return try prepare(canonicalRGBA: rgba, width: w, height: h, encoding: .premultipliedRGBA8)
    }

    /// Explicit buffer seam for already-canonical pixels and no-model tests. Never guess
    /// whether channels are straight or premultiplied from pixel values or image metadata.
    static func prepare(canonicalRGBA rgba: [UInt8], width w: Int, height h: Int, encoding: Encoding) throws -> Source {
        try validateDimensions(width: w, height: h)
        guard rgba.count == w*h*4 else { throw Failure.dimensions }
        var rgb = [UInt8](repeating: 0, count: w*h*3), hasTransparency = false
        for p in 0..<w*h {
            let alpha = Int(rgba[p*4+3])
            hasTransparency = hasTransparency || alpha != 255
            for c in 0..<3 {
                let channel = Int(rgba[p*4+c])
                let associated: Int
                switch encoding {
                case .premultipliedRGBA8:
                    guard channel <= alpha else { throw Failure.invalidPremultiplication }
                    associated = channel // Already multiplied: never multiply or unpremultiply again.
                case .straightRGBA8:
                    associated = (channel*alpha+127)/255 // Nearest integer, one multiplication only.
                }
                rgb[p*3+c] = UInt8(associated+255-alpha)
            }
        }
        return Source(width: w, height: h, canonicalRGBA: rgba, encoding: encoding,
                      inferenceRGB: rgb, hasTransparency: hasTransparency)
    }

    /// `restoredRGB` is the existing NativeResidentAOT.composePixels result at SOURCE size,
    /// not a 1024 tensor or padded raster. Its values outside the mask are ignored here.
    /// Returning a new value preserves Source's immutable backing storage (Swift COW).
    static func compositeRGBA(source: Source, restoredRGB: [UInt8], originalMask: [UInt8]) throws -> [UInt8] {
        let snapshot = try validatedCompositionMask(source: source, rgb: restoredRGB, mask: originalMask)
        return try compositeRGBA(source: source, restoredRGB: restoredRGB, validatedMask: snapshot)
    }

    static func compositeRGBA(source: Source, restoredRGB: [UInt8], validatedMask: NativeAOTValidatedMask) throws -> [UInt8] {
        try validateComposition(source: source, rgb: restoredRGB, validatedMask: validatedMask)
        let originalMask = validatedMask.bytes
        var out = source.canonicalRGBA
        for p in 0..<source.width*source.height where originalMask[p] != 0 {
            for c in 0..<3 { out[p*4+c] = restoredRGB[p*3+c] }
            out[p*4+3] = 255 // Opaque inferred pixels are valid in both alpha representations.
        }
        return out
    }

    /// Final resident result image. Opaque input keeps the EXACT old RGB24 descriptor and
    /// bytes; no extra inference. Transparent input uses RGBA without a second CGContext
    /// blend, avoiding dark fringes/double premultiplication. Decode this image to the same
    /// canonical RGBA format when checking outside identity, not to lossy RGB24.
    static func makeImage(source: Source, restoredRGB: [UInt8], originalMask: [UInt8]) throws -> CGImage {
        let snapshot = try validatedCompositionMask(source: source, rgb: restoredRGB, mask: originalMask)
        return try makeImage(source: source, restoredRGB: restoredRGB, validatedMask: snapshot)
    }

    static func makeImage(source: Source, restoredRGB: [UInt8], validatedMask: NativeAOTValidatedMask) throws -> CGImage {
        try validateComposition(source: source, rgb: restoredRGB, validatedMask: validatedMask)
        let originalMask = validatedMask.bytes
        if !source.hasTransparency {
            try validateOpaqueOutside(source: source, rgb: restoredRGB, mask: originalMask)
            return try image(bytes: restoredRGB, width: source.width, height: source.height, alpha: nil)
        }
        let rgba = try compositeRGBA(source: source, restoredRGB: restoredRGB, validatedMask: validatedMask)
        return try image(bytes: rgba, width: source.width, height: source.height, alpha: source.encoding)
    }

    /// Current backend cache canonicalizes to RGB24 and cannot preserve source alpha.
    /// Reject registration/hits if EITHER canonical source or restored image is nonopaque.
    /// Opaque RGBA (all A=255) remains eligible, so metadata alone never adds model calls.
    /// A future alpha cache must instead bind this policyVersion + canonical RGBA + exact
    /// source/mask lineage, and verify source RGBA outside / alpha=255 inside before reuse.
    static func legacyRGB24CacheCompatible(source: Source, restored: Source) -> Bool {
        source.width == restored.width && source.height == restored.height &&
            !source.hasTransparency && !restored.hasTransparency
    }

    /// Registration adapter for parent-owned backend; clear old entry BEFORE this check.
    /// False means uncached normal restore, never dropped output or a fabricated cache hit.
    static func legacyRGB24CacheCompatible(source: CGImage, restored: CGImage) throws -> Bool {
        guard source.width == restored.width, source.height == restored.height else { return false }
        let original = try prepare(source: source)
        guard !original.hasTransparency else { return false }
        return try legacyRGB24CacheCompatible(source: original, restored: prepare(source: restored))
    }

    /// Registration uses each actual image's canonical decode exactly once.
    /// Reuse the restored decode for RGB24 normalization instead of decoding it
    /// again through a second image adapter. Outside the original mask must
    /// match the source byte-for-byte; invalid handoffs fall back to fresh AOT.
    /// This proves pixel safety only, not the caller's inside-mask model lineage.
    static func legacyRGB24CacheImage(source: CGImage, restored: CGImage,
                                     originalMask: [UInt8]) throws -> CGImage? {
        guard let rgb = try legacyRGB24CachePixels(source: source, restored: restored,
            originalMask: originalMask) else { return nil }
        // Decoded RGBA/source scratch ends in the pixel helper before allocating
        // the final CGDataProvider copy; retain only the canonical restored RGB.
        return try image(bytes: rgb, width: source.width, height: source.height, alpha: nil)
    }

    static func legacyRGB24CacheImage(source: CGImage, restored: CGImage,
                                     validatedMask: NativeAOTValidatedMask) throws -> CGImage? {
        guard let rgb = try legacyRGB24CachePixels(source: source, restored: restored,
            originalMask: validatedMask.bytes, validatedMask: validatedMask) else { return nil }
        return try image(bytes: rgb, width: source.width, height: source.height, alpha: nil)
    }

    private static func legacyRGB24CachePixels(source: CGImage, restored: CGImage,
                                              originalMask: [UInt8], validatedMask: NativeAOTValidatedMask? = nil) throws -> [UInt8]? {
        guard source.width == restored.width, source.height == restored.height else { return nil }
        // Preserve the previous RGB24 cache adapter's source raster admission.
        guard source.width <= 16_384, source.height <= 16_384,
              source.width <= 16_777_216 / source.height else { throw Failure.dimensions }
        let original = try prepare(source: source)
        guard !original.hasTransparency else { return nil }
        let result = try prepare(source: restored)
        guard legacyRGB24CacheCompatible(source: original, restored: result) else { return nil }
        // Preserve raw-array API's original order: mismatched/transparent image
        // returns nil before invalid-mask errors; only then validate actual mask.
        let snapshot: NativeAOTValidatedMask
        if let existing = validatedMask {
            try validateComposition(source: original, rgb: result.inferenceRGB, validatedMask: existing)
            snapshot = existing
        } else {
            snapshot = try validatedCompositionMask(source: original, rgb: result.inferenceRGB, mask: originalMask)
        }
        do {
            try validateOpaqueOutside(source: original, rgb: result.inferenceRGB, mask: snapshot.bytes)
            return result.inferenceRGB
        } catch Failure.opaqueOutsideMismatch {
            return nil
        }
    }

    private static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 32_000_000/height else { throw Failure.dimensions }
    }

    private static func validatedCompositionMask(source: Source, rgb: [UInt8], mask: [UInt8]) throws -> NativeAOTValidatedMask {
        guard rgb.count == source.width*source.height*3 else { throw Failure.restoredDimensions }
        do {
            return try NativeAOTValidatedMask(validating: mask, width: source.width,
                height: source.height, domain: .logical01Or255)
        } catch { throw Failure.invalidMask }
    }

    private static func validateComposition(source: Source, rgb: [UInt8], validatedMask: NativeAOTValidatedMask) throws {
        guard rgb.count == source.width*source.height*3 else { throw Failure.restoredDimensions }
        guard validatedMask.width == source.width, validatedMask.height == source.height else { throw Failure.invalidMask }
    }

    /// Supply the complete owned RGB24 raster before publishing an immutable provider.
    /// Failed/cancelled scatter or exterior validation releases the private allocation.
    static func opaqueImage(source: Source, validatedMask: NativeAOTValidatedMask,
                            write: (UnsafeMutableBufferPointer<UInt8>) throws -> Void) throws -> CGImage {
        guard !source.hasTransparency,
              source.width == validatedMask.width, source.height == validatedMask.height else { throw Failure.invalidMask }
        let count = source.inferenceRGB.count
        guard let storage = malloc(count) else { throw Failure.allocation }
        let pixels = UnsafeMutableBufferPointer(start: storage.bindMemory(to: UInt8.self, capacity: count), count: count)
        do {
            source.inferenceRGB.withUnsafeBufferPointer { pixels.baseAddress!.initialize(from: $0.baseAddress!, count: count) }
            try write(pixels)
            try validateOpaqueOutside(source: source, restored: UnsafeBufferPointer(pixels), mask: validatedMask.bytes)
        } catch {
            free(storage)
            throw error
        }
        guard let data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, pixels.baseAddress, count, kCFAllocatorMalloc) else {
            free(storage)
            throw Failure.allocation
        }
        return try image(data: data, width: source.width, height: source.height, alpha: nil)
    }

    private static func validateOpaqueOutside(source: Source, rgb: [UInt8], mask: [UInt8]) throws {
        try rgb.withUnsafeBufferPointer { try validateOpaqueOutside(source: source, restored: $0, mask: mask) }
    }

    private static func validateOpaqueOutside(source: Source, restored: UnsafeBufferPointer<UInt8>, mask: [UInt8]) throws {
        try source.inferenceRGB.withUnsafeBufferPointer { original in
            try mask.withUnsafeBufferPointer { allowed in
                // Equal spans need no mask lookup. Check individual pixels
                // wherever any byte differs, including the final partial span.
                for start in stride(from: 0, to: allowed.count, by: 256) {
                    let end = min(start + 256, allowed.count)
                    let firstByte = start * 3
                    guard memcmp(restored.baseAddress! + firstByte, original.baseAddress! + firstByte,
                                 (end - start) * 3) != 0 else { continue }
                    for p in start..<end where allowed[p] == 0 {
                        let i = p * 3
                        if restored[i] != original[i] || restored[i + 1] != original[i + 1] || restored[i + 2] != original[i + 2] {
                            throw Failure.opaqueOutsideMismatch
                        }
                    }
                }
            }
        }
    }

    private static func image(bytes: [UInt8], width: Int, height: Int, alpha: Encoding?) throws -> CGImage {
        try image(data: Data(bytes) as CFData, width: width, height: height, alpha: alpha)
    }

    private static func image(data: CFData, width: Int, height: Int, alpha: Encoding?) throws -> CGImage {
        let channels = alpha == nil ? 3 : 4
        let alphaInfo: CGImageAlphaInfo = alpha == nil ? .none : (alpha == .premultipliedRGBA8 ? .premultipliedLast : .last)
        let info = CGBitmapInfo(rawValue: alphaInfo.rawValue | (alpha == nil ? 0 : CGBitmapInfo.byteOrder32Big.rawValue))
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: channels*8,
                bytesPerRow: width*channels, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info,
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw Failure.allocation }
        return image
    }
}
