@preconcurrency import CoreML
import CryptoKit
import Foundation

/// Host-only memo of model outputs, keyed by the exact input bytes (nil in the app: no hashing, no cost).
/// The host's store namespaces each kind by the model file it ran, so a hit returns what the model would.
/// Repeated replays (retune sweeps) then skip every prediction whose input did not change.
enum PipelineMemo {
    protocol Store: Sendable {
        func get(_ kind: Kind, _ key: String) -> Data?
        func put(_ kind: Kind, _ key: String, _ value: Data)
    }

    enum Kind: String, CaseIterable, Sendable {
        case layout, detect, recognize, mask, inpaint, decode
    }

    nonisolated(unsafe) static var store: (any Store)?

    /// SHA-256 of what `build` feeds the hasher.
    static func key(_ build: (inout SHA256) -> Void) -> String {
        var hasher = SHA256()
        build(&hasher)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Shape, strides, type and backing bytes (padding included: extra bytes only cost misses, never wrong hits).
    static func update(_ hasher: inout SHA256, _ array: MLMultiArray) {
        update(&hasher, array.shape.map(\.intValue) + array.strides.map(\.intValue) + [array.dataType.rawValue])
        if #available(iOS 15.4, macOS 12.3, *) {
            array.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        } else {
            // Strided extent of the elements (the store is host-only; this keeps older app targets compiling).
            let extent = zip(array.shape, array.strides).reduce(1) { $0 + ($1.0.intValue - 1) * $1.1.intValue }
            let width = max(1, (array.dataType.rawValue & 0xFFFF) / 8)
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: array.dataPointer, count: extent * width))
        }
    }

    static func update<T>(_ hasher: inout SHA256, _ values: [T]) {
        values.withUnsafeBytes { hasher.update(bufferPointer: $0) }
    }

    static func data<T>(_ values: [T]) -> Data { values.withUnsafeBytes { Data($0) } }

    static func values<T>(_ data: Data, as _: T.Type) -> [T] {
        let count = data.count / MemoryLayout<T>.stride
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            _ = data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
            initialized = count
        }
    }

    /// The stored value of `kind` for `key`, else `compute()` stored (no store: `compute()` alone).
    static func cached<T>(_ kind: Kind, key: () -> String, encode: (T) -> Data, decode: (Data) -> T?,
                          compute: () throws -> T) rethrows -> T {
        guard let store else { return try compute() }
        let key = key()
        if let data = store.get(kind, key), let value = decode(data) { return value }
        let value = try compute()
        store.put(kind, key, encode(value))
        return value
    }

    static func cached<T>(_ kind: Kind, key: () -> String, encode: (T) -> Data, decode: (Data) -> T?,
                          compute: () async throws -> T) async rethrows -> T {
        guard let store else { return try await compute() }
        let key = key()
        if let data = store.get(kind, key), let value = decode(data) { return value }
        let value = try await compute()
        store.put(kind, key, encode(value))
        return value
    }

    /// A row-major float32 copy of `array` and its shape (stored form of a model output).
    static func floats(_ array: MLMultiArray) -> (shape: [Int], values: [Float])? {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        guard array.dataType == .float32 else { return nil }
        let count = shape.reduce(1, *)
        var out = [Float](repeating: 0, count: count)
        let source = array.dataPointer.assumingMemoryBound(to: Float.self)
        for flat in 0..<count {
            var rest = flat, offset = 0
            for axis in stride(from: shape.count - 1, through: 0, by: -1) {
                offset += (rest % shape[axis]) * strides[axis]
                rest /= shape[axis]
            }
            out[flat] = source[offset]
        }
        return (shape, out)
    }

    /// `[rank, shape..., values...]` as bytes.
    static func encode(_ arrays: [(shape: [Int], values: [Float])]) -> Data {
        var out = Data()
        for array in arrays {
            out += data([Int32(array.shape.count)] + array.shape.map { Int32($0) })
            out += data(array.values)
        }
        return out
    }

    static func decodeArrays(_ data: Data) -> [MLMultiArray]? {
        var arrays: [MLMultiArray] = []
        var cursor = data.startIndex
        func int32() -> Int? {
            guard data.endIndex - cursor >= 4 else { return nil }
            defer { cursor += 4 }
            return Int(data[cursor..<cursor + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        }
        while cursor < data.endIndex {
            guard let rank = int32(), rank > 0 else { return nil }
            var shape: [Int] = []
            for _ in 0..<rank { guard let dim = int32() else { return nil }; shape.append(dim) }
            let bytes = shape.reduce(1, *) * 4
            guard data.endIndex - cursor >= bytes,
                  let array = try? MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32) else { return nil }
            let values: [Float] = Self.values(data[cursor..<cursor + bytes], as: Float.self)
            cursor += bytes
            // Row-major fill through the array's own strides.
            let strides = array.strides.map(\.intValue)
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            for flat in 0..<values.count {
                var rest = flat, offset = 0
                for axis in stride(from: shape.count - 1, through: 0, by: -1) {
                    offset += (rest % shape[axis]) * strides[axis]
                    rest /= shape[axis]
                }
                pointer[offset] = values[flat]
            }
            arrays.append(array)
        }
        return arrays
    }
}
