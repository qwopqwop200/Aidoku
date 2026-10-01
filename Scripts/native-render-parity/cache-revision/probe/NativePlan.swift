import Foundation
import CoreGraphics
struct NativeTranslationLayoutItem: Codable, Equatable, Sendable {}
enum NativeTranslationLayoutPlanner { static func validGeometry(imageSize:CGSize,sourceRect:CGRect,viewport:CGSize)->Bool { true } }
struct NativeTranslationLayout: Codable, Equatable, Sendable {
    static let currentVersion = 1
    let version: Int
    let imageSize: CGSize
    let sourceRect: CGRect
    let viewport: CGSize
    let items: [NativeTranslationLayoutItem]
    let readableRecoveryRemaining: Int?
    let sourceObjectFit: String?

    private enum CodingKeys: String, CodingKey { case version, imageSize, sourceRect, viewport, items, readableRecoveryRemaining, sourceObjectFit }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        imageSize = try values.decode(CGSize.self, forKey: .imageSize)
        sourceRect = try values.decode(CGRect.self, forKey: .sourceRect)
        viewport = try values.decode(CGSize.self, forKey: .viewport)
        items = try values.decode([NativeTranslationLayoutItem].self, forKey: .items)
        readableRecoveryRemaining = try values.decodeIfPresent(Int.self, forKey: .readableRecoveryRemaining)
        sourceObjectFit = try values.decodeIfPresent(String.self, forKey: .sourceObjectFit)
        guard version == Self.currentVersion,
              sourceObjectFit == nil || ["fill", "contain", "cover"].contains(sourceObjectFit!),
              NativeTranslationLayoutPlanner.validGeometry(imageSize: imageSize, sourceRect: sourceRect, viewport: viewport)
        else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid native layout version or geometry")) }
    }

    init(imageSize: CGSize, sourceRect: CGRect, viewport: CGSize, items: [NativeTranslationLayoutItem],
         readableRecoveryRemaining: Int? = nil, sourceObjectFit: String? = nil) {
        version = Self.currentVersion
        self.imageSize = imageSize
        self.sourceRect = sourceRect
        self.viewport = viewport
        self.items = items
        self.readableRecoveryRemaining = readableRecoveryRemaining
        self.sourceObjectFit = sourceObjectFit
    }
}

