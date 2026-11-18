import Foundation
import ImageIO
import Testing
import UIKit
@testable import Aidoku

@MainActor
struct NativePNGFinalICCMetadataTests {
    @Test
    func sourceForecastProfileCannotOverwriteFinalImageProfile() throws {
        let sourceSpace = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let finalSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 64, height: 96, bitsPerComponent: 8,
            bytesPerRow: 256, space: finalSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
        let rendered = try #require(context.makeImage())
        let final = try #require(UIImage(cgImage: rendered, scale: 2, orientation: .up).cgImage)
        let metadata = NativePNGMetadata.Source(properties: [
            kCGImagePropertyPixelWidth as String: 32, kCGImagePropertyPixelHeight as String: 48,
            kCGImagePropertyDPIWidth as String: 72, kCGImagePropertyDPIHeight as String: 72,
            kCGImagePropertyProfileName as String: "authored source P3"])
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, final,
            metadata.propertiesForUprightPixels(width: final.width, height: final.height) as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let saved = try #require(CGImageSourceCreateWithData(output, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(saved, 0, nil))
        let originalICC = try #require(sourceSpace.copyICCData()) as Data
        let finalICC = try #require(final.colorSpace?.copyICCData()) as Data
        let savedICC = try #require(decoded.colorSpace?.copyICCData()) as Data
        #expect(originalICC != finalICC)
        #expect(savedICC == finalICC)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(saved, 0, nil) as? [String: Any])
        #expect((properties[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue == 144)
        #expect((properties[kCGImagePropertyDPIHeight as String] as? NSNumber)?.doubleValue == 144)
    }
}
