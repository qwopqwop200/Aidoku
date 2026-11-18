import Foundation
import ImageIO
import Testing
import UIKit
@testable import Aidoku

@MainActor
struct NativePNGMetadataTests {
    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 32, height: 48,
            bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        return try #require(context.makeImage())
    }

    @Test(arguments: Array(1...8), [false, true])
    func normalizedPNGKeepsPhysicalExtentAndFinalICC(orientation: Int, anisotropic: Bool) throws {
        let pixels = try image()
        let data = NSMutableData()
        let fixture = try #require(CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(fixture, pixels, [kCGImagePropertyOrientation: orientation,
            kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: anisotropic ? 144 : 72] as CFDictionary)
        #expect(CGImageDestinationFinalize(fixture))
        let source = try #require(CGImageSourceCreateWithData(data, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let metadata = NativePNGMetadata.Source(properties: properties)
        let normalized = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 48] as CFDictionary))
        // Logical UIKit points/scale must never become physical-file DPI authority.
        let upright = UIImage(cgImage: normalized, scale: 3, orientation: .up)
        #expect(upright.imageOrientation == .up)
        let final = try #require(upright.cgImage)
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, final,
            metadata.propertiesForUprightPixels(width: final.width, height: final.height) as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let saved = try #require(CGImageSourceCreateWithData(output, nil))
        let savedProperties = try #require(CGImageSourceCopyPropertiesAtIndex(saved, 0, nil) as? [String: Any])
        let decoded = try #require(CGImageSourceCreateImageAtIndex(saved, 0, nil))
        let dpiX = try #require(savedProperties[kCGImagePropertyDPIWidth as String] as? NSNumber).doubleValue
        let dpiY = try #require(savedProperties[kCGImagePropertyDPIHeight as String] as? NSNumber).doubleValue
        #expect(abs(Double(final.width) / dpiX - metadata.physicalWidthInches!) < 0.0002)
        #expect(abs(Double(final.height) / dpiY - metadata.physicalHeightInches!) < 0.0002)
        #expect((savedProperties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue == 1)
        let expectedICC = try #require(final.colorSpace?.copyICCData()) as Data
        let actualICC = try #require(decoded.colorSpace?.copyICCData()) as Data
        #expect(expectedICC == actualICC)
        // DPI must track the actual final resolution, including bounded export downsizing.
        let half = metadata.propertiesForUprightPixels(width: final.width / 2, height: final.height / 2)
        #expect(abs((half[kCGImagePropertyDPIWidth] as! Double) * 2 - dpiX) < 0.02)
    }

    @Test
    func unavailableResolutionDoesNotInventUIKitDPI() throws {
        let upright = UIImage(cgImage: try image(), scale: 4, orientation: .up)
        let metadata = NativePNGMetadata.Source(properties: [:])
        let properties = metadata.propertiesForUprightPixels(width: upright.cgImage!.width, height: upright.cgImage!.height)
        #expect(metadata.resolutionStatus == "missing-or-invalid-resolution")
        #expect(properties[kCGImagePropertyDPIWidth] == nil)
        #expect(properties[kCGImagePropertyDPIHeight] == nil)
        #expect((properties[kCGImagePropertyOrientation] as? Int) == 1)
    }

    @Test
    func missingOrientationIsUpButMalformedAuthorityRemainsUnknown() {
        let properties: [String: Any] = [kCGImagePropertyPixelWidth as String: 32,
            kCGImagePropertyPixelHeight as String: 48, kCGImagePropertyDPIWidth as String: 72,
            kCGImagePropertyDPIHeight as String: 144]
        #expect(NativePNGMetadata.Source(properties: properties).physicalWidthInches == 32.0 / 72)
        for bad in [0.0, -1.0, Double.nan, Double.infinity] {
            var altered = properties
            altered[kCGImagePropertyDPIWidth as String] = bad
            #expect(NativePNGMetadata.Source(properties: altered).physicalWidthInches == nil)
        }
        var malformed = properties
        malformed[kCGImagePropertyOrientation as String] = 9
        #expect(NativePNGMetadata.Source(properties: malformed).resolutionStatus == "invalid-orientation")
    }
}
