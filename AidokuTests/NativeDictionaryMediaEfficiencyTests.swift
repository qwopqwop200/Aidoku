import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct NativeDictionaryMediaEfficiencyTests {
    @Test func largeRasterDecodesOnlyDisplayPixelsAndKeepsLayoutAndAltText() throws {
        let data = try rasterData(width: 1600, height: 800)
        let attachment = try media(data, node: ["width": 100, "height": 50, "alt": "図の説明"])
        let image = try #require(attachment.original.cgImage)
        let scale = min(3, UIScreen.main.scale)
        #expect(attachment.bounds.size == CGSize(width: 100, height: 50))
        #expect(image.width <= Int(ceil(100 * scale)) && image.height <= Int(ceil(50 * scale)))
        #expect(image.width < 1600 && image.height < 800)
        #expect(attachment.title == "図の説明")
    }

    @Test func intrinsicGeometryAndEXIFRotationSurviveDownsampling() throws {
        let ordinary = try media(rasterData(width: 1200, height: 600), availableWidth: 100)
        #expect(ordinary.bounds.size == CGSize(width: 100, height: 50))
        let rotated = try media(rasterData(width: 1200, height: 600, orientation: 6), availableWidth: 100)
        #expect(rotated.bounds.size == CGSize(width: 100, height: 200))
        let pixels = try #require(rotated.original.cgImage)
        #expect(pixels.height == pixels.width * 2)
        #expect(rotated.original.imageOrientation == .up)
    }

    @Test func smallAndPixelatedRastersKeepTheirSourcePixels() throws {
        let small = try media(rasterData(width: 16, height: 8), node: ["width": 160, "height": 80])
        #expect(small.original.cgImage?.width == 16 && small.original.cgImage?.height == 8)
        let pixelated = try media(rasterData(width: 800, height: 400),
                                  node: ["width": 40, "height": 20, "pixelated": true])
        #expect(pixelated.pixelated)
        #expect(pixelated.original.cgImage?.width == 800 && pixelated.original.cgImage?.height == 400)
        #expect(pixelated.bounds.size == CGSize(width: 40, height: 20))
    }

    @Test func repeatedTextKitRequestsReuseOnlyTheCurrentSize() throws {
        let attachment = try media(rasterData(width: 100, height: 50))
        let first = try #require(attachment.image(forBounds: attachment.bounds, textContainer: nil, characterIndex: 0))
        let repeated = try #require(attachment.image(forBounds: attachment.bounds, textContainer: nil, characterIndex: 8))
        #expect(first === repeated)
        let resizedBounds = CGRect(x: 0, y: 0, width: 40, height: 20)
        let resized = try #require(attachment.image(forBounds: resizedBounds, textContainer: nil, characterIndex: 0))
        #expect(resized !== first && resized.size == resizedBounds.size)
        let returned = try #require(attachment.image(forBounds: attachment.bounds, textContainer: nil, characterIndex: 0))
        #expect(returned !== first, "Returning to a prior size must replace the single cached bitmap, not accumulate size variants")
    }

    @Test func dynamicTintBorderAndBackgroundInvalidateCachedPixels() throws {
        let attachment = NativeDictionaryImageAttachment(image: try #require(UIImage(data: rasterData(width: 10, height: 10))),
            tint: UIColor { $0.userInterfaceStyle == .dark ? .white : .black }, pixelated: false, title: "fixture",
            borderWidth: 2, borderColor: UIColor { $0.userInterfaceStyle == .dark ? .yellow : .blue },
            background: UIColor { $0.accessibilityContrast == .high ? .red : .green })
        let bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
        func render(_ traits: UITraitCollection) throws -> UIImage {
            var result: UIImage?
            traits.performAsCurrent { result = attachment.image(forBounds: bounds, textContainer: nil, characterIndex: 0) }
            return try #require(result)
        }
        let lightTraits = UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: .light),
                                                        UITraitCollection(accessibilityContrast: .normal)])
        let light = try render(lightTraits)
        #expect(light === (try render(lightTraits)))
        let dark = try render(UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: .dark),
                                                           UITraitCollection(accessibilityContrast: .normal)]))
        #expect(dark !== light)
        let highContrast = try render(UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: .dark),
                                                                   UITraitCollection(accessibilityContrast: .high)]))
        #expect(highContrast !== dark)
        #expect(light.pngData() != dark.pngData())
    }

    private func media(_ data: Data, node: [String: Any] = [:], availableWidth: CGFloat = 260) throws -> NativeDictionaryImageAttachment {
        var node = node
        node["path"] = "fixture.jpg"
        let result = NativeDictionaryMedia.attachment(node, dictionary: "fixture",
            attributes: [.font: UIFont.systemFont(ofSize: 15)], availableWidth: availableWidth, load: { _, _ in data })
        return try #require(result.attribute(.attachment, at: 0, effectiveRange: nil) as? NativeDictionaryImageAttachment)
    }

    private func rasterData(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(UIColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
