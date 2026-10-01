import Foundation

/// ECMAScript TypedArray.fill indices are relative to the entire array. In
/// particular, a negative row-end index wraps from its end before clamping.
enum NativeTypedArrayFill {
    static func fill(_ bytes: inout [UInt8], value: UInt8, start: Double, end: Double? = nil) {
        func relative(_ raw: Double) -> Int {
            let integer = raw.isNaN ? 0 : raw.rounded(.towardZero)
            let count = Double(bytes.count)
            let bounded = integer < 0 ? max(count + integer, 0) : min(integer, count)
            return Int(bounded)
        }
        let first = relative(start), last = end.map(relative) ?? bytes.count
        guard first < last else { return }
        for index in first..<last { bytes[index] = value }
    }
}
