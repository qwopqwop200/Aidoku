import AidokuNativeCV
import Foundation

/// Borrows the mapped float32 TRAIN tensor; never expands/copies the bank.
enum NativeCosineNeighbors {
    struct Result {
        let indices: [Int32]       // queryCount * 8, original TRAIN row indexes
        let distances: [Float]    // queryCount * 8, clipped cosine distances
    }
    static func search(queries: [Float], queryCount: Int, references: UnsafeBufferPointer<Float>,
                       referenceCount: Int, dimension: Int, excluded: [Int32] = []) throws -> Result {
        guard queryCount >= 0, queryCount <= Int(Int32.max), referenceCount >= 8,
              referenceCount <= Int(Int32.max), dimension > 0, dimension <= 262144,
              queryCount <= Int.max / dimension, referenceCount <= Int.max / dimension,
              queryCount <= Int.max / 8, excluded.count <= Int(Int32.max),
              queries.count == queryCount * dimension, references.count == referenceCount * dimension else {
            throw NativeOpenCV.Failure.invalidBuffer
        }
        var indices = [Int32](repeating: -1, count: queryCount * 8)
        var distances = [Float](repeating: 0, count: queryCount * 8)
        try queries.withUnsafeBufferPointer { query in
            try excluded.withUnsafeBufferPointer { omit in
                try indices.withUnsafeMutableBufferPointer { outIndex in
                    try distances.withUnsafeMutableBufferPointer { outDistance in
                        try NativeOpenCV.check(acv_cosine_neighbors(query.baseAddress, Int32(queryCount), references.baseAddress,
                            Int32(referenceCount), Int32(dimension), excluded.isEmpty ? nil : omit.baseAddress,
                            Int32(excluded.count), 8, outIndex.baseAddress, outDistance.baseAddress))
                    }
                }
            }
        }
        return Result(indices: indices, distances: distances)
    }
}
