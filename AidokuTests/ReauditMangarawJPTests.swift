import AidokuRunner
import CryptoKit
import Foundation
import SwiftSoup
import Testing
import UIKit
@testable import Aidoku

struct ReauditMangarawJPTests {
    @Test func absentAPIOrderKeyReturnsUnencryptedPages() async throws {
        let runner = runner(response: #"{"e":["/public/key/?id=1"]}"#)
        let pages = try await pages(runner)
        #expect(pages.count == 1)
        guard case .url(let url, let context) = pages[0].content else {
            Issue.record("Expected URL page")
            return
        }
        #expect(url.absoluteString == "https://img-cdn.stackpathcdn.app/public/key/?id=1")
        #expect(context?["key"] == "")
        let image = try fixture(width: 4, height: 6)
        let handle = try await runner.store(value: image)
        let response = AidokuRunner.Response(code: 200, headers: [:], request: .init(url: url, headers: [:]), image: handle)
        let output = try await runner.processPageImage(response: response, context: context)
        await runner.remove(value: handle)
        #expect(output === image)
    }

    @Test func absentAPIImageListAndEmptyObjectReturnNoPages() async throws {
        for response in [#"{"c":""}"#, #"{}"#] {
            #expect(try await pages(runner(response: response)).isEmpty)
        }
    }

    @Test func explicitNullFieldsRemainInvalidUnlikeMissingFields() async {
        for response in [#"{"c":null,"e":[]}"#, #"{"c":"","e":null}"#] {
            await #expect(throws: DecodingError.self) { try await pages(runner(response: response)) }
        }
    }

    @Test func asymmetricTileOrderUsesTopOriginForBothSourceAndDestination() throws {
        let image = try fixture(width: 4, height: 6)
        // Independent top-origin reference for order [2,0,3,1]: destination quadrants
        // receive bottom-left, top-left, bottom-right, top-right source quadrants.
        let expectedIndices = [12, 13, 0, 1, 16, 17, 4, 5, 20, 21, 8, 9,
                               14, 15, 2, 3, 18, 19, 6, 7, 22, 23, 10, 11]
        let decoded = try MangarawJPImageCodec.unscramble(image, key: "041a061a051a07")
        let cgImage = try #require(decoded.cgImage)
        let data = Array(try #require(cgImage.dataProvider?.data) as Data)
        for (destination, source) in expectedIndices.enumerated() {
            let offset = destination / 4 * cgImage.bytesPerRow + destination % 4 * 4
            let x = source % 4, y = source / 4
            #expect(Array(data[offset..<(offset + 4)]) == [UInt8(x), UInt8(y), UInt8(x + 3 * y), 255])
        }
    }

    @Test func fractionalTilesMatchCompleteUpstreamCanvasRasterReferences() throws {
        // Independent host harness recreates removed UIKit Canvas's initial flip,
        // per-copy flip, CGImage crop, adjusted destination and default draw settings.
        for (width, height, key, expected) in [
            (5, 7, "041a061a051a07", "aa8e3ef07a7cb3e26da7e7481a42de4ef2bf085bed79de2b63aabb64d52ded85"),
            (5, 7, "061a071a041a05", "dd8c7dcd6dd68089ddfa212877f510b1362e7e16b1a4cee3e751bcb7e1bd1437"),
            (7, 11, "0e1a061a011a071a001a041a031a051a02", "5ce5724ff80d787d7df76b638941802299f0ab09f44d4df8434eaef998d7759d")
        ] {
            let decoded = try MangarawJPImageCodec.unscramble(fixture(width: width, height: height), key: key)
            let image = try #require(decoded.cgImage)
            let data = try #require(image.dataProvider?.data) as Data
            var packed = Data()
            for row in 0..<height { packed.append(data[(row * image.bytesPerRow)..<(row * image.bytesPerRow + width * 4)]) }
            #expect(SHA256.hash(data: packed).map { String(format: "%02x", $0) }.joined() == expected)
        }
    }

    private func runner(response: String) -> MangarawJPSourceRunner {
        MangarawJPSourceRunner(fetch: { request in
            let body = request.httpMethod == "POST" ? response : "<script>window.MangaId=133;window.CNumber=10;</script>"
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    }

    private func pages(_ runner: MangarawJPSourceRunner) async throws -> [AidokuRunner.Page] {
        try await runner.getPageList(manga: .init(sourceKey: "ja.mangarawjp", key: "/manga-raw/a/", title: "A"),
                                     chapter: .init(key: "/manga-raw/a/第10話/"))
    }

    private func fixture(width: Int, height: Int) throws -> UIImage {
        var pixels: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width { pixels += [UInt8(x), UInt8(y), UInt8(x + 3 * y), 255] }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        return UIImage(cgImage: image)
    }
}
