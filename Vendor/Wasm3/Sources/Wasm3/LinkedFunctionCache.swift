import Foundation

// Contexts belong to their runtime, never to a process-global cache.
typealias LinkedFunctionSignature = (
    UnsafeMutablePointer<UInt64>?, UnsafeMutableRawPointer?
) -> UnsafeRawPointer?

final class LinkedFunctionHolder {
    let function: LinkedFunctionSignature
    init(function: @escaping LinkedFunctionSignature) { self.function = function }
}
