import Foundation
import ImageIO

/// File metadata only. UIImage.scale is not a physical-resolution authority.
enum NativePNGMetadata {
    struct Source: Sendable {
        let physicalWidthInches: Double?
        let physicalHeightInches: Double?
        let resolutionStatus: String

        init(properties: [String: Any]) {
            func number(_ key: CFString) -> Double? {
                guard let value = properties[key as String] as? NSNumber,
                      CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
                return value.doubleValue
            }
            let rawOrientation = number(kCGImagePropertyOrientation)
            let orientation = rawOrientation ?? 1
            let orientationValid = properties[kCGImagePropertyOrientation as String] == nil
                || (rawOrientation != nil && orientation.isFinite && orientation.rounded() == orientation && (1...8).contains(orientation))
            if orientationValid,
               let width = number(kCGImagePropertyPixelWidth), let height = number(kCGImagePropertyPixelHeight),
               let dpiX = number(kCGImagePropertyDPIWidth), let dpiY = number(kCGImagePropertyDPIHeight),
               [width, height, dpiX, dpiY].allSatisfy({ $0.isFinite && $0 > 0 }),
               (width / dpiX).isFinite, (height / dpiY).isFinite,
               width / dpiX > 0, height / dpiY > 0 {
                let swapped = orientation >= 5
                physicalWidthInches = swapped ? height / dpiY : width / dpiX
                physicalHeightInches = swapped ? width / dpiX : height / dpiY
                resolutionStatus = "observed-physical-extent"
            } else {
                physicalWidthInches = nil
                physicalHeightInches = nil
                resolutionStatus = orientationValid ? "missing-or-invalid-resolution" : "invalid-orientation"
            }
        }

        init(unavailableProperties: Void) {
            physicalWidthInches = nil
            physicalHeightInches = nil
            resolutionStatus = "source-properties-unavailable"
        }

        /// Whole-source extent only. Crop callers must not reuse the original physical extent.
        /// Caller must have baked orientation into upright pixels, not just changed a tag.
        func propertiesForUprightPixels(width: Int, height: Int) -> [CFString: Any] {
            var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
            guard width > 0, height > 0, let physicalWidthInches, let physicalHeightInches else { return properties }
            let x = Double(width) / physicalWidthInches, y = Double(height) / physicalHeightInches
            guard x.isFinite, y.isFinite, x > 0, y > 0 else { return properties }
            properties[kCGImagePropertyDPIWidth] = x
            properties[kCGImagePropertyDPIHeight] = y
            return properties
        }
    }

    static func source(at url: URL) -> Source {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return Source(unavailableProperties: ())
        }
        return Source(properties: properties)
    }
    // ICC comes from the final CGImage supplied to ImageIO, never the source properties.
    // This contract deliberately does not forward EXIF/IPTC/XMP or source orientation tags.
}
