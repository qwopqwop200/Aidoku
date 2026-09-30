import AidokuRunner
import Foundation
import Testing
import UIKit
@testable import Aidoku

struct ReauditSoraRawTests {
    private let uuid = "003a8cfd16281b2b1d255d06524d8639ac1f7497533220824247f76eba48aeb9"
    private let encryptedPath = "UQajtZjw1-nFt7IgA1ot0f9ahvQL5noTTVZv-2P0EASrNeOXH94Kyw"

    private func runner(header: Data, mode: String = "image", imageCount: Int = 1) throws -> SoraRawSourceRunner {
        let chapter = """
        <script id="__NEXT_DATA__">{"props":{"pageProps":{"data":{"chapter":{
        "uuid":"\(uuid)","_b":"https://images.example.test","mode":"\(mode)"
        }}}}}</script>
        """
        let images = (0..<imageCount).map { ["order": String($0 + 1), "b": encryptedPath] }
        let plain = try JSONSerialization.data(withJSONObject: images)
        let key = Array("/fuCkYou!!!".utf8)
        let encoded = Data(plain.enumerated().map { $0.element ^ key[$0.offset % key.count] }).base64EncodedString()
        let payload = try JSONSerialization.data(withJSONObject: ["d": encoded])
        return SoraRawSourceRunner(fetch: { request in
            let url = try #require(request.url)
            let body: Data
            let code: Int
            if url.host == "api.mangarawgo.site" {
                body = payload; code = 200
            } else if url.host == "images.example.test" {
                #expect(mode != "canva2" && imageCount <= 4)
                #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-16383")
                body = header; code = 206
            } else {
                body = Data(chapter.utf8); code = 200
            }
            return (body, HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
        })
    }

    private func pages(_ source: SoraRawSourceRunner) async throws -> [AidokuRunner.Page] {
        try await source.getPageList(
            manga: .init(sourceKey: "ja.soraraw", key: "book", title: "Book"),
            chapter: .init(key: "60652/722455", url: URL(string: "https://soraraw.com/manga/book/ch-70"))
        )
    }

    @Test func partialJPEGResponseSplitsAndEverySliceKeepsItsPixelRows() async throws {
        // A complete real JPEG is encoded first; the fetch only returns its 16KB Range prefix.
        // Its frame is intentionally noisy so the file cannot fit inside that response.
        let width = 128, height = 1810
        var state: UInt32 = 0xACED
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 1_664_525 &+ 1_013_904_223
            pixels[offset] = UInt8(truncatingIfNeeded: state >> 24)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: state >> 16)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: state >> 8)
            pixels[offset + 3] = 255
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let image = UIImage(cgImage: cgImage)
        let jpeg = try #require(image.jpegData(compressionQuality: 0.9))
        #expect(jpeg.count > 16 * 1024)
        let result = try await pages(runner(header: Data(jpeg.prefix(16 * 1024))))
        #expect(result.count == 10)
        var restoredRows = 0
        for (index, page) in result.enumerated() {
            guard case let .url(url, context) = page.content else { Issue.record("Expected URL page"); continue }
            #expect(url.absoluteString == "https://images.example.test/c722455/001_25706548.jpg")
            #expect(context == ["slice": String(index), "slices": "10"])
            let sliced = try #require(SoraRawImageCodec.slice(image, slice: index, slices: 10)?.cgImage)
            #expect(sliced.width == width)
            #expect(sliced.height == height * (index + 1) / 10 - height * index / 10)
            restoredRows += sliced.height
        }
        #expect(restoredRows == height)
    }

    @Test func partialWebPFrameRestoresTenSliceContexts() async throws {
        // Real lossy VP8 frame header for 1133x16000, carrying no complete compressed image.
        let header = Data([
            0x52, 0x49, 0x46, 0x46, 0x72, 0x7E, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50,
            0x56, 0x50, 0x38, 0x20, 0x66, 0x7E, 0x00, 0x00, 0x50, 0xF0, 0x0E,
            0x9D, 0x01, 0x2A, 0x6D, 0x04, 0x80, 0x3E
        ])
        let result = try await pages(runner(header: header))
        #expect(result.count == 10)
        for (index, page) in result.enumerated() {
            guard case let .url(_, context) = page.content else { Issue.record("Expected URL page"); continue }
            #expect(context == ["slice": String(index), "slices": "10"])
        }
    }

    @Test func scrambledAndLongChaptersSkipHeaderMeasurements() async throws {
        let scrambled = try await pages(runner(header: Data(), mode: "canva2"))
        #expect(scrambled.count == 1)
        guard case let .url(_, context) = scrambled.first?.content else { Issue.record("Expected URL page"); return }
        #expect(context == ["seed": "722455"])
        let ordinary = try await pages(runner(header: Data(), imageCount: 5))
        #expect(ordinary.count == 5)
        for page in ordinary {
            guard case let .url(_, context) = page.content else { Issue.record("Expected URL page"); continue }
            #expect(context == nil)
        }
    }

    @Test func headerParsingIsBoundedAndInvalidDimensionsKeepOnePage() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00,
                         0xFF, 0xC0, 0x00, 0x11, 0x08, 0xC0, 0x00, 0x05, 0xAA])
        let size = SoraRawImageCodec.headerSize(jpeg)
        #expect(size?.width == 1450)
        #expect(size?.height == 49152)
        #expect(SoraRawImageCodec.headerSize(Data(jpeg.prefix(8)))?.width == nil)
        #expect(SoraRawImageCodec.headerSize(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0]))?.width == nil)
        #expect(SoraRawImageCodec.headerSize(Data([0xFF, 0xD8, 0xFF, 0xE0, 0xFF, 0xFF]))?.width == nil)
        #expect(SoraRawImageCodec.headerSize(Data(repeating: 0, count: 16 * 1024) + jpeg)?.width == nil)
        for (width, height, expected) in [(1450, 49152, 24), (800, 24003, 21), (1133, 16000, 10),
                                          (960, 1376, 1), (0, 49152, 1), (0, 0, 1), (100, 49152, 1),
                                          (8, 724, 64), (8, 736, 1), (Int.max, Int.max, 1)] {
            #expect(SoraRawImageCodec.stackedPageCount(width: width, height: height) == expected)
        }
    }

    @Test func suspendedDetailsCannotDeliverToReplacementSubscriber() async throws {
        let gate = SoraRawReauditFetchGate()
        let html = #"<script id="__NEXT_DATA__">{"props":{"pageProps":{"data":{"manga":{"id":1,"name":"Updated","slug":"book","chapters":[]}}}}}</script>"#
        let source = SoraRawSourceRunner(fetch: { request in
            await gate.suspend()
            return (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let publisher = try #require(await source.partialMangaPublisher)
        let original = SoraRawReauditResults(), replacement = SoraRawReauditResults()
        let firstToken = await publisher.sink { original.append($0.title) }
        let manga = AidokuRunner.Manga(sourceKey: "ja.soraraw", key: "book", title: "Old")
        let stale = Task {
            try await PartialResultSubscription.$id.withValue(firstToken) {
                try await source.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: true)
            }
        }
        await gate.waitForRequest()
        let replacementToken = await publisher.sink { replacement.append($0.title) }
        await gate.release()
        _ = try await stale.value
        #expect(original.titles.isEmpty)
        #expect(replacement.titles.isEmpty)
        _ = try await PartialResultSubscription.$id.withValue(replacementToken) {
            try await source.getMangaUpdate(manga: manga, needsDetails: true, needsChapters: true)
        }
        #expect(replacement.titles == ["Updated"])
        await publisher.removeSink(token: replacementToken)
    }
}

private actor SoraRawReauditFetchGate {
    private var entered = false
    private var released = false
    private var observer: CheckedContinuation<Void, Never>?
    private var suspended: CheckedContinuation<Void, Never>?

    func suspend() async {
        guard !released else { return }
        entered = true
        observer?.resume(); observer = nil
        await withCheckedContinuation { suspended = $0 }
    }

    func waitForRequest() async {
        guard !entered else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        released = true
        suspended?.resume(); suspended = nil
    }
}

private final class SoraRawReauditResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var titles: [String] { lock.withLock { values } }
    func append(_ title: String) { lock.withLock { values.append(title) } }
}
