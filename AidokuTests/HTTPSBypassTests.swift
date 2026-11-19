import Foundation
import Network
import Testing
@testable import Aidoku

struct HTTPSBypassTests {
    @Test func splitsInsideSNIWithoutChangingTheHandshakeOrFollowingRecords() throws {
        let original = hello()
        let trailing = Data([20, 3, 3, 0, 1, 1])
        guard case .split(let first, let second) = TLSClientHello.inspect(original + trailing) else {
            Issue.record("Expected a fragmented ClientHello"); return
        }
        #expect(!first.contains(Data("reader.example.org".utf8)))
        #expect(!second.contains(Data("reader.example.org".utf8)))
        #expect(try payloads(first + second) == payloads(original + trailing))
        #expect(second.suffix(trailing.count) == trailing)
        #expect(first.count + second.count == original.count + trailing.count + 5)
    }

    @Test func nonTLSMissingSNIAndInvalidLengthsPassThroughUnmodified() {
        #expect(TLSClientHello.inspect(Data("GET / HTTP/1.1\r\n".utf8)) == .passthrough)
        #expect(TLSClientHello.inspect(hello(name: nil)) == .passthrough)
        #expect(TLSClientHello.inspect(Data([22, 3, 3, 255, 255])) == .passthrough)
        #expect(TLSClientHello.inspect(Data(repeating: 22, count: TLSClientHello.maximumBytes + 1)) == .passthrough)
        var invalid = hello()
        invalid[5] = 2
        #expect(TLSClientHello.inspect(invalid) == .passthrough)
        // Each damaged length/direction byte must remain bounded and never trap.
        let original = hello()
        for index in original.indices {
            var malformed = original; malformed[index] = 255
            _ = TLSClientHello.inspect(malformed)
        }
    }

    @Test func bypassConfigurationIsExplicitAndNeverFallsBackDirectly() async throws {
        let network = SourceNetwork()
        let direct = try await network.configuration(.ephemeral, bypass: false)
        #expect(direct.proxyConfigurations.isEmpty)
        let bypass = try await network.configuration(.ephemeral, bypass: true)
        #expect(bypass.proxyConfigurations.count == 1)
        #expect(bypass.proxyConfigurations.first?.allowFailover == false)
        #expect(bypass.httpCookieStorage === direct.httpCookieStorage || bypass.httpCookieStorage != nil)
    }

    @Test func DNSAnswersAcceptOnlyLiteralAddressesOfTheDeclaredFamily() {
        let answers: [HTTPSDNSResolver.Answer] = [
            .init(type: 5, TTL: 20, data: "alias.example"),
            .init(type: 1, TTL: 20, data: "192.0.2.1"),
            .init(type: 1, TTL: 20, data: "192.0.2.1"),
            .init(type: 28, TTL: 20, data: "2001:db8::1"),
            .init(type: 1, TTL: 20, data: "not.an.ip"),
            .init(type: 28, TTL: 20, data: "192.0.2.2")
        ]
        #expect(HTTPSDNSResolver.validAddresses(answers) == ["192.0.2.1", "2001:db8::1"])
    }

    private func hello(name: String? = "reader.example.org") -> Data {
        var extensions: [UInt8] = [0, 43, 0, 3, 2, 3, 4] // supported_versions before SNI
        if let name {
            let host = Array(name.utf8)
            let list = [UInt8(0)] + u16(host.count) + host
            let body = u16(list.count) + list
            extensions += [0, 0] + u16(body.count) + body
        }
        let body: [UInt8] = [3, 3] + Array(repeating: 0, count: 32) + [0, 0, 2, 0x13, 1, 1, 0] + u16(extensions.count) + extensions
        return record(Data([1, 0, UInt8(body.count >> 8), UInt8(body.count & 255)] + body))
    }

    private func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 255)] }
    private func record(_ body: Data) -> Data { Data([22, 3, 1] + u16(body.count)) + body }
    private func payloads(_ data: Data) throws -> Data {
        var cursor = 0
        var result = Data()
        while cursor < data.count {
            try #require(cursor + 5 <= data.count)
            let size = Int(data[cursor + 3]) * 256 + Int(data[cursor + 4])
            try #require(cursor + 5 + size <= data.count)
            result.append(data[(cursor + 5)..<(cursor + 5 + size)])
            cursor += 5 + size
        }
        return result
    }
}
