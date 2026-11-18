import Foundation

@main
struct NativeFrozenTensorReplay {
    struct Result: Encodable {
        let shape: [Int]
        let dtype: String
        let elementCount: Int
        let byteCount: Int
        let first: [Double]
        let last: [Double]
        let floatBits: [UInt32]
        let pointerBits: UInt32?
        let rejectsInvalidRow: Bool
        let metadataStaysRecord: Bool
    }
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let payload = try Data(contentsOf: directory.appendingPathComponent("descriptor.json"))
        let decoded = try JSONDecoder().decode(NativeFrozenSourceModel.Value.self, from: payload)
        guard let record = decoded.foundationValue as? [String: Any] else { throw NativeFrozenTensor.Failure.invalidDescriptor }
        let tensor = try NativeFrozenTensor(directory: directory, record: record)
        let descriptor = try JSONDecoder().decode(NativeFrozenTensor.Descriptor.self, from: payload)
        guard tensor.descriptor.shape == descriptor.shape else { throw NativeFrozenTensor.Failure.invalidDescriptor }
        let first = try tensor.readRowDouble(0), last = try tensor.readRowDouble(tensor.rowCount - 1)
        let bits = try tensor.dtype == "f32" ? tensor.readRowFloat32(tensor.rowCount - 1).map(\.bitPattern) : []
        let pointerBits: UInt32? = try tensor.dtype == "f32"
            ? tensor.withUnsafeFloat32Buffer { $0[tensor.elementCount - 1].bitPattern } : nil
        var rejectsInvalidRow = false
        do { _ = try tensor.readRowDouble(tensor.rowCount) } catch { rejectsInvalidRow = true }
        let result = Result(shape: tensor.shape, dtype: tensor.dtype, elementCount: tensor.elementCount,
                            byteCount: tensor.byteCount, first: first, last: last, floatBits: bits,
                            pointerBits: pointerBits, rejectsInvalidRow: rejectsInvalidRow,
                            metadataStaysRecord: record["tensorAsset"] is String && record["shape"] is [Any])
        FileHandle.standardOutput.write(try JSONEncoder().encode(result))
    }
}
