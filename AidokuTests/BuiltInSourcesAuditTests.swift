import AidokuRunner
import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
import ZIPFoundation
@testable import Aidoku

/// Response bodies from self-hosted servers are capped instead of buffered without limit.
struct BuiltInSourceResponseLimitTests {
    @Test func komgaBodyWithinLimitIsReturned() async throws {
        let session = AuditBodyProtocol.session()
        defer { session.invalidateAndCancel() }
        let data = try await KomgaHelper.limitedBody(for: AuditBodyProtocol.request(bytes: 3000), session: session, maximum: 4096)
        #expect(data == Data(repeating: 0x20, count: 3000))
    }

    @Test func komgaOversizeBodyFailsAsNetworkError() async throws {
        let session = AuditBodyProtocol.session()
        defer { session.invalidateAndCancel() }
        await #expect(throws: SourceError.networkError) {
            try await KomgaHelper.limitedBody(for: AuditBodyProtocol.request(bytes: 64 * 1024), session: session, maximum: 4096)
        }
    }

    @Test func suwayomiBodyWithinLimitKeepsResponse() async throws {
        let session = AuditBodyProtocol.session()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await SuwayomiHelper.limitedData(
            for: AuditBodyProtocol.request(bytes: 4096), session: session, maximum: 4096
        )
        #expect(data.count == 4096)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test func suwayomiOversizeBodyIsRejected() async throws {
        let session = AuditBodyProtocol.session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await SuwayomiHelper.limitedData(for: AuditBodyProtocol.request(bytes: 4097), session: session, maximum: 4096)
            Issue.record("Expected an oversize body to be rejected")
        } catch let error as URLError {
            #expect(error.code == .dataLengthExceedsMaximum)
        }
    }
}

/// Relative dates built from server text never become non-finite.
struct MangarawBestRelativeDateAuditTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func ordinaryRelativeDatesAreUnchanged() {
        #expect(MangarawBestSourceRunner.relativeDate("2日前", now: now) == now.addingTimeInterval(-2 * 86400))
        #expect(MangarawBestSourceRunner.relativeDate("3 時間前", now: now) == now.addingTimeInterval(-3 * 3600))
    }

    @Test func overflowingCountsAreRejected() {
        // Finite count whose product with the unit overflows to infinity.
        #expect(MangarawBestSourceRunner.relativeDate(String(repeating: "9", count: 306) + "年前", now: now) == nil)
        // Digit run that parses to infinity (or fails to parse) on its own.
        #expect(MangarawBestSourceRunner.relativeDate(String(repeating: "9", count: 400) + "秒前", now: now) == nil)
    }
}

/// Imported photos are normalized into 8-bit pages, not extended-range 16-bit buffers.
@MainActor
struct LocalImageImportRangeAuditTests {
    @Test func wideColorPhotoIsNormalizedToStandardRange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("wide.png")
        try Self.writeWideColorPNG(to: source, width: 48, height: 32)

        let result = await LocalFileManager.shared.prepareImageImport(from: [source], name: "Wide.png")
        let info = try #require(result)
        let archive = try Archive(url: info.url, accessMode: .read)
        let entry = try #require(archive["00000001.png"])
        let data = try archive.extractData(entry, limit: 16 * 1024 * 1024)
        let imageSource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let page = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect(page.width == 48 && page.height == 32)
        #expect(page.bitsPerComponent == 8)
    }

    private static func writeWideColorPNG(to url: URL, width: Int, height: Int) throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(colorSpace: space, components: [0, 1, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

/// Serves `bytes` bytes (taken from the last path component) in 1 KiB chunks with no
/// Content-Length, so only the streamed byte count can enforce the limit.
private final class AuditBodyProtocol: URLProtocol, @unchecked Sendable {
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 5
        config.protocolClasses = [AuditBodyProtocol.self]
        return URLSession(configuration: config)
    }

    static func request(bytes: Int) -> URLRequest {
        URLRequest(url: URL(string: "https://\(UUID().uuidString).invalid/body/\(bytes)")!)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let total = Int(url.lastPathComponent),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var remaining = total
        while remaining > 0 {
            let count = min(1024, remaining)
            client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: count))
            remaining -= count
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
