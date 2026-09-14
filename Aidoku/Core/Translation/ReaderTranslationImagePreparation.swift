import UIKit

/// Reader direction is supplied by the reader, never inferred from OCR language.
enum ReaderTranslationImagePreparation {
    static func apply(_ regions: [ReaderTranslationRegion], image: UIImage,
                      settings: ReaderTranslationSettings) -> [ReaderTranslationRegion] {
        let prepared = regions
        guard settings.rightToLeftPanelOrder, prepared.count > 1 else { return prepared }
        let pixels: CGImage?
        if image.imageOrientation == .up { pixels = image.cgImage } else {
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            pixels = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage
        }
        guard let pixels else { return prepared }
        let ranks = ReaderTranslationPanelOrder.rightToLeftRanks(image: pixels,
            inputs: prepared.map { .init(rect: $0.rect, isVertical: $0.sourceOrientation == .vertical) })
        return zip(prepared, ranks).map { region, rank in
            var result = region
            result.translationOrder = rank
            return result
        }
    }
}
