import Foundation

/// A verified C-order, little-endian tensor. Payloads remain mapped Data; JSON
/// metadata contains only Descriptor records, never expanded numeric objects.
public struct NativeFrozenTensor: Sendable {
    public enum Failure: Error { case invalidDescriptor, invalidPayload, checksumMismatch, invalidIndex, invalidDType }
    public struct Descriptor: Codable, Sendable {
        public let tensorAsset: String
        public let shape: [Int]
        public let dtype: String
        public let sha256: String
        public init(tensorAsset: String, shape: [Int], dtype: String, sha256: String) {
            self.tensorAsset = tensorAsset
            self.shape = shape
            self.dtype = dtype
            self.sha256 = sha256
        }
        public init(record: [String: Any]) throws {
            guard let asset = record["tensorAsset"] as? String, let dimensions = record["shape"] as? [Any],
                  let dtype = record["dtype"] as? String, let sha = record["sha256"] as? String else {
                throw Failure.invalidDescriptor
            }
            let shape = try dimensions.map { value -> Int in
                if let integer = value as? Int { return integer }
                guard let number = value as? Double, number.isFinite, number >= 0,
                      number < Double(Int.max), number.rounded(.towardZero) == number else { throw Failure.invalidDescriptor }
                return Int(number)
            }
            self.init(tensorAsset: asset, shape: shape, dtype: dtype, sha256: sha)
        }
    }
    public let descriptor: Descriptor
    public let elementCount: Int
    public let rowCount: Int
    public let rowWidth: Int
    public var shape: [Int] { descriptor.shape }
    public var dtype: String { descriptor.dtype }
    public var byteCount: Int { data.count }
    private let data: Data
    private let elementBytes: Int

    public init(directory: URL, record: [String: Any]) throws {
        try self.init(directory: directory, descriptor: Descriptor(record: record))
    }
    public init(directory: URL, descriptor: Descriptor) throws {
        let widths = ["f16": 2, "f32": 4, "f64": 8, "i8": 1, "u8": 1,
                      "i16": 2, "u16": 2, "i32": 4, "u32": 4, "i64": 8, "u64": 8]
        guard let width = widths[descriptor.dtype], !descriptor.shape.isEmpty,
              descriptor.shape.allSatisfy({ $0 > 0 }),
              descriptor.tensorAsset.hasPrefix("tensors/"), !descriptor.tensorAsset.contains(".."),
              descriptor.sha256.count == 64 else { throw Failure.invalidDescriptor }
        var count = 1
        for dimension in descriptor.shape {
            let product = count.multipliedReportingOverflow(by: dimension)
            guard !product.overflow else { throw Failure.invalidDescriptor }
            count = product.partialValue
        }
        let size = count.multipliedReportingOverflow(by: width)
        guard !size.overflow else { throw Failure.invalidDescriptor }
        let payload = try Data(contentsOf: directory.appendingPathComponent(descriptor.tensorAsset), options: .mappedIfSafe)
        guard payload.count == size.partialValue else { throw Failure.invalidPayload }
        guard NativeFrozenSourceSHA256.hex(payload) == descriptor.sha256 else { throw Failure.checksumMismatch }
        self.descriptor = descriptor
        elementCount = count
        rowCount = descriptor.shape[0]
        rowWidth = count / rowCount
        elementBytes = width
        data = payload
    }

    /// Pointer lifetime is restricted to the closure, exactly as with Data.
    /// Use loadUnaligned and little-endian conversion for typed raw reads.
    public func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
        try data.withUnsafeBytes(body)
    }
    /// Zero-copy typed view for the little-endian macOS/iOS targets. The buffer
    /// must not escape the closure or outlive this tensor.
    public func withUnsafeFloat32Buffer<Result>(_ body: (UnsafeBufferPointer<Float>) throws -> Result) throws -> Result {
        guard dtype == "f32" else { throw Failure.invalidDType }
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress,
                  Int(bitPattern: base) % MemoryLayout<Float>.alignment == 0 else { throw Failure.invalidPayload }
            return try body(bytes.bindMemory(to: Float.self))
        }
    }
    private func value(_ index: Int, _ bytes: UnsafeRawBufferPointer) -> Double {
        let offset = index * elementBytes
        switch dtype {
        case "f16": return Double(Float16(bitPattern: UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))))
        case "f32": return Double(Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))))
        case "f64": return Double(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
        case "i8": return Double(Int8(bitPattern: bytes[offset]))
        case "u8": return Double(bytes[offset])
        case "i16": return Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
        case "u16": return Double(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
        case "i32": return Double(Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self)))
        case "u32": return Double(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
        case "i64": return Double(Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int64.self)))
        default: return Double(UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
        }
    }
    public func double(at index: Int) throws -> Double {
        guard (0..<elementCount).contains(index) else { throw Failure.invalidIndex }
        return data.withUnsafeBytes { value(index, $0) }
    }
    public func readRowFloat32(_ row: Int) throws -> [Float] {
        guard dtype == "f32" else { throw Failure.invalidDType }
        guard (0..<rowCount).contains(row) else { throw Failure.invalidIndex }
        let start = row * rowWidth
        return data.withUnsafeBytes { bytes in
            (start..<(start + rowWidth)).map { index in
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
    }
    public func readRowDouble(_ row: Int) throws -> [Double] {
        guard (0..<rowCount).contains(row) else { throw Failure.invalidIndex }
        let start = row * rowWidth
        return data.withUnsafeBytes { bytes in (start..<(start + rowWidth)).map { value($0, bytes) } }
    }
}
