import Foundation
import Testing
import AidokuRunner
@testable import Aidoku

@MainActor
struct NativeAdapterBoundarySafetyTests {
    @Test func customSourceConfigDecodesSlicesAndRejectsOversizedLengths() throws {
        let config = CustomSourceConfig.komga(.init(key: "slice-key", name: "Slice", server: "https://example.invalid"))
        let encoded = config.encode()
        let wrapped = Data([0xff, 0xff]) + encoded
        #expect(try CustomSourceConfig(from: wrapped[2...]).encode() == encoded)
        // Oversized string length must throw rather than read past the buffer.
        #expect(throws: (any Error).self) { try CustomSourceConfig(from: Data([1] + Array(repeating: UInt8(0xff), count: 9) + [0x01])) }
    }
}
