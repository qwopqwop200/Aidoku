import UIKit

/// Reader direction is supplied by the reader, never inferred from OCR language.
enum ReaderTranslationImagePreparation {
    static func needsPanelOrder(_ regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings) -> Bool {
        guard settings.rightToLeftPanelOrder, regions.count > 1 else { return false }
        guard regions.allSatisfy({ $0.translationOrderVersion == ReaderTranslationPanelOrder.cacheVersion }) else { return true }
        // Old, partially written, or malformed evidence must be recalculated.
        let ranks = regions.compactMap(\.translationOrder)
        return ranks.count != regions.count || Set(ranks) != Set(regions.indices)
    }

    static func needsImage(_ regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings) -> Bool {
        needsPanelOrder(regions, settings: settings)
    }

    static func translationJPEG(_ image: UIImage) throws -> Data {
        guard image.size.width > 0, image.size.height > 0 else {
            throw RemoteTranslationError.invalidRequest("The page image is empty.")
        }
        let ratio = min(1, 2048 / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, (image.size.width * ratio).rounded()),
                          height: max(1, (image.size.height * ratio).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = normalized.jpegData(compressionQuality: 0.85), data.count <= 4 * 1024 * 1024 else {
            throw RemoteTranslationError.invalidRequest("The page image could not be prepared for translation.")
        }
        return data
    }

    static func apply(_ regions: [ReaderTranslationRegion], image: UIImage,
                      settings: ReaderTranslationSettings) -> [ReaderTranslationRegion] {
        guard needsPanelOrder(regions, settings: settings) else { return regions }
        let pixels: CGImage?
        if image.imageOrientation == .up { pixels = image.cgImage } else {
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            pixels = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage
        }
        guard let pixels else { return regions }
        let ranks = ReaderTranslationPanelOrder.rightToLeftRanks(image: pixels,
            inputs: regions.map { .init(rect: $0.rect, isVertical: $0.sourceOrientation == .vertical) })
        return zip(regions, ranks).map { region, rank in
            var result = region
            result.translationOrder = rank
            result.translationOrderVersion = ReaderTranslationPanelOrder.cacheVersion
            return result
        }
    }
}
