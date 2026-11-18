import CoreGraphics
import Foundation

/// Exact OpenCV/scipy image primitives used by the accepted source feature ABI.
/// Implementations must operate original crop grids, never resized predictions.
protocol NativeAppearanceImageOperations {
    /// OpenCV COLOR_RGB2Lab on float32 RGB/255, interleaved L,a,b.
    func lab(rgb: [UInt8], width: Int, height: Int) throws -> [Float]
    /// Same conversion for floating RGB values in original [0,255] units.
    func lab(colors: [[Double]]) throws -> [[Float]]
    func raster(polygons: [[CGPoint]], width: Int, height: Int) throws -> [UInt8]
    func distance(_ mask: [UInt8], width: Int, height: Int, maskSize: Int) throws -> [Float]
    func dilate(_ mask: [UInt8], width: Int, height: Int, radius: Int, ellipse: Bool) throws -> [UInt8]
    func close(_ mask: [UInt8], width: Int, height: Int, size: Int) throws -> [UInt8]
    /// scipy ndimage.binary_fill_holes default cross4, no diagonal flood.
    func fillHoles(_ mask: [UInt8], width: Int, height: Int) throws -> [UInt8]
    func componentSizes(_ mask: [UInt8], width: Int, height: Int) throws -> [Int]
    /// (medianBlur(RGB2GRAY_uint8,k)-GRAY-3).clip(min=0)/255 float32.
    func darkContrast(rgb: [UInt8], width: Int, height: Int, kernel: Int) throws -> [Float]
    /// OpenCV minAreaRect float32 points: cx,cy,width,height,angleDegrees.
    func minimumAreaRectangle(_ polygon: [CGPoint]) throws -> [Double]
    /// Float32 RGB/255 boxFilter BORDER_REFLECT, interleaved three channels.
    func rgbBoxMean(rgb: [UInt8], width: Int, height: Int, size: Int) throws -> [Float]
    /// Float32 RGB/255 -> gray -> default Sobel3 x/y -> hypot, original grid.
    func rgbSobelMagnitude(rgb: [UInt8], width: Int, height: Int) throws -> [Float]
}
