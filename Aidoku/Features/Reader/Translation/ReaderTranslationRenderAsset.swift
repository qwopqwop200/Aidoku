import UIKit
import CryptoKit

/// The source artwork stays in the image pipeline. Only the settled typography
/// and source-repair patches persist, so a reload needs no WebKit document.
struct ReaderTranslationRenderAsset: Codable, Sendable {
    static let currentVersion = 1
    static let maximumContentBytes = 16 * 1_024 * 1_024
    static let maximumEncodedBytes = 24 * 1_024 * 1_024

    let version: Int
    let typography: Data
    let layers: ReaderTranslationImageExporter.ExportLayers
    let displayRect: CGRect
    let sourceSize: CGSize
    let regionsDigest: String
    let sourceDigest: String?

    init(typography: Data, layers: ReaderTranslationImageExporter.ExportLayers,
         displayRect: CGRect, sourceSize: CGSize, regions: [ReaderTranslationRegion], sourceDigest: String?) {
        version = Self.currentVersion
        self.typography = typography
        self.layers = layers
        self.displayRect = displayRect
        self.sourceSize = sourceSize
        regionsDigest = Self.digest(regions)
        self.sourceDigest = sourceDigest
    }

    static func digest(_ regions: [ReaderTranslationRegion]) -> String {
        ReaderTranslationCacheIdentity.encoded(regions.map(ReaderTranslationStoredRegion.init))
    }

    /// Hash existing provider bytes; no PNG/JPEG encoding or redraw is needed.
    /// Call off MainActor, because a provider may lazily decode its source.
    static func digestSource(_ image: UIImage) -> String? {
        guard !Task.isCancelled, let pixels = image.cgImage, let bytes = pixels.dataProvider?.data else { return nil }
        let colorSpace = pixels.colorSpace
        let name = colorSpace?.name.map { $0 as String } ?? ""
        let description = "\(pixels.width),\(pixels.height),\(pixels.bytesPerRow),\(pixels.bitsPerPixel),\(pixels.bitsPerComponent),"
            + "\(pixels.bitmapInfo.rawValue),\(image.scale),\(image.imageOrientation.rawValue),\(colorSpace?.model.rawValue ?? -1),\(name)"
        var digest = SHA256()
        digest.update(data: Data(description.utf8))
        if let profile = colorSpace?.copyICCData() { digest.update(data: profile as Data) }
        digest.update(data: bytes as Data)
        guard !Task.isCancelled else { return nil }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var byteCost: Int {
        typography.count + layers.masks.reduce(0) { $0 + $1.png.utf8.count + 64 }
            + layers.surfaces.count * 96 + layers.paintBounds.count * 32
            + regionsDigest.utf8.count + (sourceDigest?.utf8.count ?? 0) + 256
    }

    var isValid: Bool {
        func validFrame(_ values: [CGFloat]) -> Bool {
            values.count == 4 && values.allSatisfy(\.isFinite) && values[2] > 0 && values[3] > 0
        }
        return version == Self.currentVersion && !typography.isEmpty && !regionsDigest.isEmpty && sourceDigest != nil
            && byteCost <= Self.maximumContentBytes
            && sourceSize.width.isFinite && sourceSize.height.isFinite && sourceSize.width > 0 && sourceSize.height > 0
            && validFrame([displayRect.minX, displayRect.minY, displayRect.width, displayRect.height])
            && layers.masks.allSatisfy { validFrame($0.frame) && $0.opacity.isFinite && (0...1).contains($0.opacity) }
            && layers.surfaces.allSatisfy {
                validFrame($0.frame) && $0.radius.isFinite && $0.radius >= 0
                    && $0.blur.isFinite && $0.blur >= 0 && $0.saturation.isFinite && $0.saturation >= 0
            }
            && layers.paintBounds.allSatisfy(validFrame)
    }

    func matches(regions: [ReaderTranslationRegion], sourceSize: CGSize, sourceDigest: String?) -> Bool {
        isValid && self.sourceSize == sourceSize && regionsDigest == Self.digest(regions)
            && sourceDigest != nil && self.sourceDigest == sourceDigest
    }
}
