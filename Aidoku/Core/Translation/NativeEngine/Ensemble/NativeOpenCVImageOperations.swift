import AidokuNativeCV
import CoreGraphics
import Foundation

/// Shared real OpenCV implementation for both macOS MAIN and iOS.
enum NativeOpenCV {
    enum Failure: Error { case invalidBuffer; case native(String) }
    static func check(_ status: Int32) throws {
        guard status == 0 else { throw Failure.native(String(cString: acv_last_error())) }
    }
    static func count(width: Int, height: Int, channels: Int = 1) throws -> Int {
        guard width > 0, height > 0, width <= Int(Int32.max), height <= Int(Int32.max),
              width <= Int(Int32.max) / height / channels else { throw Failure.invalidBuffer }
        return width * height * channels
    }
    static func transform<T, U>(_ input: [T], outputCount: Int, zero: U,
                                _ body: (UnsafePointer<T>, UnsafeMutablePointer<U>) -> Int32) throws -> [U] {
        guard !input.isEmpty, outputCount > 0 else { throw Failure.invalidBuffer }
        var result = [U](repeating: zero, count: outputCount)
        try input.withUnsafeBufferPointer { src in
            try result.withUnsafeMutableBufferPointer { dst in
                try check(body(src.baseAddress!, dst.baseAddress!))
            }
        }
        return result
    }
}

struct NativeOpenCVAppearanceImageOperations: NativeAppearanceImageOperations {
    func lab(rgb: [UInt8], width: Int, height: Int) throws -> [Float] {
        let n = try NativeOpenCV.count(width: width, height: height, channels: 3)
        guard rgb.count == n else { throw NativeOpenCV.Failure.invalidBuffer }
        return try labFloats(rgb.map { Float($0) / 255 }, width: width, height: height)
    }
    private func labFloats(_ values: [Float], width: Int, height: Int) throws -> [Float] {
        try NativeOpenCV.transform(values, outputCount: values.count, zero: Float(0)) {
            acv_rgb_to_lab($0, $1, Int32(width), Int32(height), 1)
        }
    }
    func lab(colors: [[Double]]) throws -> [[Float]] {
        guard !colors.isEmpty else { return [] }
        guard colors.count <= Int(Int32.max), colors.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else {
            throw NativeOpenCV.Failure.invalidBuffer
        }
        let result = try labFloats(colors.flatMap { $0.map { Float($0) / 255 } }, width: colors.count, height: 1)
        return stride(from: 0, to: result.count, by: 3).map { Array(result[$0..<$0 + 3]) }
    }
    func raster(polygons: [[CGPoint]], width: Int, height: Int) throws -> [UInt8] {
        let n = try NativeOpenCV.count(width: width, height: height)
        let valid = polygons.filter { !$0.isEmpty }
        guard !valid.isEmpty else { return [UInt8](repeating: 0, count: n) }
        guard valid.allSatisfy({ $0.count <= 1_000_000 }) else { throw NativeOpenCV.Failure.invalidBuffer }
        let xy = valid.flatMap { $0.flatMap { [Float($0.x), Float($0.y)] } }
        let counts = valid.map { Int32($0.count) }
        return try counts.withUnsafeBufferPointer { sizes in
            try NativeOpenCV.transform(xy, outputCount: n, zero: UInt8(0)) {
                acv_fill_poly($0, sizes.baseAddress, Int32(valid.count), $1, Int32(width), Int32(height), 1)
            }
        }
    }
    func distance(_ mask: [UInt8], width: Int, height: Int, maskSize: Int) throws -> [Float] {
        let n = try NativeOpenCV.count(width: width, height: height)
        guard mask.count == n, maskSize == 3 || maskSize == 5 else { throw NativeOpenCV.Failure.invalidBuffer }
        return try NativeOpenCV.transform(mask, outputCount: n, zero: Float(0)) {
            acv_distance($0, $1, nil, Int32(width), Int32(height), 2, Int32(maskSize))
        }
    }
    private func morph(_ mask: [UInt8], width: Int, height: Int, size: Int, operation: Int32, shape: Int32) throws -> [UInt8] {
        let n = try NativeOpenCV.count(width: width, height: height)
        guard mask.count == n, size > 0, size <= 65535 else { throw NativeOpenCV.Failure.invalidBuffer }
        return try NativeOpenCV.transform(mask, outputCount: n, zero: UInt8(0)) {
            acv_morphology($0, $1, Int32(width), Int32(height), 0, operation, shape, Int32(size), Int32(size), 0)
        }
    }
    func dilate(_ mask: [UInt8], width: Int, height: Int, radius: Int, ellipse: Bool) throws -> [UInt8] {
        guard radius >= 0, radius <= 32767 else { throw NativeOpenCV.Failure.invalidBuffer }
        return try morph(mask, width: width, height: height, size: radius * 2 + 1, operation: 1, shape: ellipse ? 2 : 0)
    }
    func close(_ mask: [UInt8], width: Int, height: Int, size: Int) throws -> [UInt8] {
        try morph(mask, width: width, height: height, size: size, operation: 3, shape: 0)
    }
    func fillHoles(_ mask: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        let n = try NativeOpenCV.count(width: width, height: height)
        guard mask.count == n else { throw NativeOpenCV.Failure.invalidBuffer }
        return try NativeOpenCV.transform(mask, outputCount: n, zero: UInt8(0)) {
            acv_fill_holes4($0, $1, Int32(width), Int32(height))
        }
    }
    func componentSizes(_ mask: [UInt8], width: Int, height: Int) throws -> [Int] {
        let n = try NativeOpenCV.count(width: width, height: height)
        guard mask.count == n else { throw NativeOpenCV.Failure.invalidBuffer }
        // Each 2×2 tile contains at most one distinct 8-connected component.
        let capacity = ((width + 1) / 2) * ((height + 1) / 2)
        var areas = [Int32](repeating: 0, count: capacity)
        var count: Int32 = 0
        try mask.withUnsafeBufferPointer { src in
            try areas.withUnsafeMutableBufferPointer { result in
                try NativeOpenCV.check(acv_component_areas8(src.baseAddress, Int32(width), Int32(height),
                    result.baseAddress, capacity, &count))
            }
        }
        return areas.prefix(Int(count)).map(Int.init)
    }
    func darkContrast(rgb: [UInt8], width: Int, height: Int, kernel: Int) throws -> [Float] {
        let n = try NativeOpenCV.count(width: width, height: height)
        guard rgb.count == n * 3, kernel > 0, kernel <= 65535 else { throw NativeOpenCV.Failure.invalidBuffer }
        let gray = try NativeOpenCV.transform(rgb, outputCount: n, zero: UInt8(0)) {
            acv_gray($0, $1, Int32(width), Int32(height))
        }
        let median = try NativeOpenCV.transform(gray, outputCount: n, zero: UInt8(0)) {
            acv_blur($0, $1, Int32(width), Int32(height), 1, 0, Int32(kernel), 0, 1, 1)
        }
        return zip(median, gray).map { Float(max(0, Int($0) - Int($1) - 3)) / 255 }
    }
    func rgbBoxMean(rgb: [UInt8], width: Int, height: Int, size: Int) throws -> [Float] {
        let n = try NativeOpenCV.count(width: width, height: height, channels: 3)
        guard rgb.count == n, size > 0, size <= 65535 else { throw NativeOpenCV.Failure.invalidBuffer }
        return try NativeOpenCV.transform(rgb, outputCount: n, zero: Float(0)) {
            acv_rgb_box_mean($0, $1, Int32(width), Int32(height), Int32(size))
        }
    }
    func rgbSobelMagnitude(rgb: [UInt8], width: Int, height: Int) throws -> [Float] {
        let n = try NativeOpenCV.count(width: width, height: height, channels: 3)
        guard rgb.count == n else { throw NativeOpenCV.Failure.invalidBuffer }
        return try NativeOpenCV.transform(rgb, outputCount: n / 3, zero: Float(0)) {
            acv_rgb_sobel_magnitude($0, $1, Int32(width), Int32(height))
        }
    }
    func minimumAreaRectangle(_ polygon: [CGPoint]) throws -> [Double] {
        guard !polygon.isEmpty, polygon.count <= Int(Int32.max) else { throw NativeOpenCV.Failure.invalidBuffer }
        let xy = polygon.flatMap { [Float($0.x), Float($0.y)] }
        var rectangle = try NativeOpenCV.transform(xy, outputCount: 5, zero: Float(0)) {
            acv_min_area_rect($0, Int32(polygon.count), $1)
        }.map(Double.init)
        // The appearance artifact uses OpenCV 4.13's [-90, 0) convention.
        // Keep the generic C primitive in its pinned 4.11 convention.
        if rectangle[4] == 90 {
            rectangle[4] = -90
        } else if rectangle[4] >= 0 && rectangle[4] < 90 {
            rectangle.swapAt(2, 3)
            rectangle[4] -= 90
        }
        return rectangle
    }
}
