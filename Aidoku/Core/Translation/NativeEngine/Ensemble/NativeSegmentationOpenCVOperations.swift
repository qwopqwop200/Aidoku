import Foundation
#if canImport(AidokuNativeCV)
import AidokuNativeCV
#endif

/// Exact OpenCV4.11 operations, provided by the bundled macOS/iOS native bridge.
struct NativeSegmentationOpenCVOperations: NativeSegmentationFinalFeatures.ImageOperations {
    enum Failure: Error { case unavailable, invalidInput, operation(String) }
    private func count(width: Int, height: Int, actual: Int) throws -> Int {
        guard width > 0, height > 0, width <= 1_500_000 / height, actual == width * height else { throw Failure.invalidInput }
        return actual
    }
    func boxMean(_ values: [Float], width: Int, height: Int, size: Int) throws -> [Float] {
        let n = try count(width: width, height: height, actual: values.count)
        guard size > 0, size <= 65535 else { throw Failure.invalidInput }
        #if canImport(AidokuNativeCV)
        var result = [Float](repeating: 0, count: n)
        let status = values.withUnsafeBufferPointer { source in result.withUnsafeMutableBufferPointer { output in
            acv_box_mean(source.baseAddress, output.baseAddress, Int32(width), Int32(height), Int32(size))
        } }
        try check(status)
        return result
        #else
        _ = n
        throw Failure.unavailable
        #endif
    }
    func distance(_ nonzero: [UInt8], width: Int, height: Int, metric: NativeSegmentationFinalFeatures.DistanceMetric,
                  labels: Bool) throws -> (values: [Float], labels: [Int32]?) {
        let n = try count(width: width, height: height, actual: nonzero.count)
        let kind: Int32, mask: Int32
        switch metric {
        case .chebyshev: kind = 3; mask = 3
        case .manhattan: kind = 1; mask = 3
        case .euclidean5: kind = 2; mask = 5
        }
        guard !labels || kind == 2 else { throw Failure.invalidInput }
        #if canImport(AidokuNativeCV)
        var result = [Float](repeating: 0, count: n), nearest = [Int32](repeating: 0, count: labels ? n : 0)
        let status = nonzero.withUnsafeBufferPointer { source in result.withUnsafeMutableBufferPointer { output in
            nearest.withUnsafeMutableBufferPointer { indices in
                acv_distance(source.baseAddress, output.baseAddress, labels ? indices.baseAddress : nil,
                    Int32(width), Int32(height), kind, mask)
            }
        } }
        try check(status)
        return (result, labels ? nearest : nil)
        #else
        _ = n; _ = mask
        throw Failure.unavailable
        #endif
    }
    func fillExternalContours(_ mask: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        let n = try count(width: width, height: height, actual: mask.count)
        #if canImport(AidokuNativeCV)
        var result = [UInt8](repeating: 0, count: n)
        let status = mask.withUnsafeBufferPointer { source in result.withUnsafeMutableBufferPointer { output in
            acv_fill_external(source.baseAddress, output.baseAddress, Int32(width), Int32(height))
        } }
        try check(status)
        return result
        #else
        _ = n
        throw Failure.unavailable
        #endif
    }
    #if canImport(AidokuNativeCV)
    private func check(_ status: Int32) throws {
        guard status == 0 else { throw Failure.operation(String(cString: acv_last_error())) }
    }
    #endif
}
