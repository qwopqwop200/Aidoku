import CoreGraphics
import Foundation

@available(iOS 18.0, *)
struct PaddleOCRPoint: Codable, Equatable, Sendable {
    let x: CGFloat
    let y: CGFloat
}

@available(iOS 18.0, *)
struct PaddleOCRLine: Codable, Equatable, Sendable {
    let poly: [PaddleOCRPoint]
    let text: String
    let score: Double
    /// Kept as an optional raw value so older runtimes can omit the field and
    /// newer runtimes can add orientations without making the whole OCR
    /// response undecodable.
    let orientationRaw: String?
    /// Merge-time geometry fact. `false` is materially different from an old
    /// runtime omitting the field: a multi-column vertical region must never
    /// be squeezed into one source-width column by the renderer.
    let singleVerticalColumn: Bool?

    private enum CodingKeys: String, CodingKey {
        case poly
        case text
        case score
        case orientation
        case singleVerticalColumn
    }

    init(
        poly: [PaddleOCRPoint],
        text: String,
        score: Double,
        orientationRaw: String?,
        singleVerticalColumn: Bool? = nil
    ) {
        self.poly = poly
        self.text = text
        self.score = score
        self.orientationRaw = orientationRaw
        self.singleVerticalColumn = singleVerticalColumn
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        poly = try container.decode([PaddleOCRPoint].self, forKey: .poly)
        text = try container.decode(String.self, forKey: .text)
        score = try container.decode(Double.self, forKey: .score)
        orientationRaw = try container.decodeIfPresent(
            String.self,
            forKey: .orientation
        )
        singleVerticalColumn = try container.decodeIfPresent(
            Bool.self,
            forKey: .singleVerticalColumn
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(poly, forKey: .poly)
        try container.encode(text, forKey: .text)
        try container.encode(score, forKey: .score)
        try container.encodeIfPresent(orientationRaw, forKey: .orientation)
        try container.encodeIfPresent(
            singleVerticalColumn,
            forKey: .singleVerticalColumn
        )
    }

    var sourceOrientation: BrowserOCRSourceOrientation {
        BrowserOCRSourceOrientation(tolerantRawValue: orientationRaw)
    }

    var boundingRect: CGRect {
        guard
            let minimumX = poly.map(\.x).min(),
            let maximumX = poly.map(\.x).max(),
            let minimumY = poly.map(\.y).min(),
            let maximumY = poly.map(\.y).max()
        else {
            return .null
        }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }
}
