import AidokuRunner
import Foundation
import SwiftSoup
import Testing
import UIKit
@testable import Aidoku

struct NativeRawOtakuSourceTests {
    @Test
    func recoveredStackedMeasurementsMatchTemplate() {
        for (width, height, expected) in [(1426, 53248, 26), (800, 64809, 57), (1125, 64000, 40),
                                          (800, 5673, 5), (1125, 1600, 1), (0, 49152, 1), (0, 0, 1), (100, 49152, 1)] {
            #expect(RawOtakuSourceRunner.sliceCount(width: width, height: height) == expected)
        }
    }

    @Test
    func jpegMeasurementRejectsTruncatedSegments() {
        #expect(RawOtakuSourceRunner.jpegSize(Data([0xff, 0xd8, 0xff, 0xc0])) == nil)
        #expect(RawOtakuSourceRunner.jpegSize(Data([0xff, 0xd8, 0xff, 0xe0, 0, 0])) == nil)
        let size = RawOtakuSourceRunner.jpegSize(Self.jpeg(width: 1426, height: 53248))
        #expect(size?.width == 1426)
        #expect(size?.height == 53248)
    }

    @Test
    func japaneseDecimalChaptersKeepFragmentIDsAndDiscardTitles() throws {
        let document = try SwiftSoup.parse("""
        <ul id="ja-chaps">
          <li data-id="82"><a href="/read/book/chapter-8.2"><span class="name">第8.2話: 第8.2話</span></a></li>
          <li data-id="9"><a href="/read/book/chapter-9"><span class="name">第9話: 第9話</span></a></li>
        </ul>
        """, RawOtakuSourceRunner.base)
        let chapters = try RawOtakuSourceRunner.parseChapters(document)
        #expect(chapters.map(\.chapterNumber) == [9, 8.2])
        #expect(chapters.map(\.key) == ["/read/book/chapter-9#9", "/read/book/chapter-8.2#82"])
        #expect(chapters.allSatisfy { $0.title == nil && $0.language == "ja" })
    }

    @Test
    func searchUsesRecoveredParameterNamesAndEncodedQuery() {
        let path = RawOtakuSourceRunner.searchPath(query: "語+句&猫", page: 2, filters: [])
        let components = URLComponents(string: path)
        #expect(components?.queryItems?.first(where: { $0.name == "q" })?.value == "語+句&猫")
        #expect(components?.queryItems?.first(where: { $0.name == "p" })?.value == "2")
        let filters: [AidokuRunner.FilterValue] = [.sort(.init(id: "sort", index: 1, ascending: false)), .select(id: "status", value: "Finished")]
        let filtered = URLComponents(string: RawOtakuSourceRunner.searchPath(query: nil, page: 3, filters: filters))
        #expect(filtered?.path == "/filter")
        #expect(filtered?.queryItems?.first(where: { $0.name == "sort" })?.value == "latest-update")
        #expect(filtered?.queryItems?.first(where: { $0.name == "status" })?.value == "Finished")
    }

    @Test
    func chapterJSONRequestAndStackedPageContextsMatchRecoveredPort() async throws {
        let recorder = RawOtakuFetchRecorder()
        let runner = RawOtakuSourceRunner(fetch: { request in
            await recorder.append(request)
            let data: Data
            if request.url?.path == "/json/chapter" {
                data = try JSONSerialization.data(withJSONObject: ["html": "<div class='container-reader-chapter'><div><img src='https://images.test/stack.jpg'></div></div>"])
            } else { data = Self.jpeg(width: 1426, height: 53248) }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let pages = try await runner.getPageList(manga: Self.manga, chapter: .init(key: "/read/book/chapter-1#42"))
        #expect(pages.count == 26)
        for (index, page) in pages.enumerated() {
            guard case .url(let url, let context) = page.content else { Issue.record("Expected URL page"); return }
            #expect(url.absoluteString == "https://images.test/stack.jpg")
            #expect(context == ["slice": String(index), "slices": "26"])
        }
        let requests = await recorder.requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "Referer") == "https://rawotaku.com/read/book/chapter-1")
        #expect(requests[0].value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first(where: { $0.name == "id" })?.value == "42")
        #expect(query?.first(where: { $0.name == "mode" })?.value == "vertical")
        #expect(requests[1].value(forHTTPHeaderField: "Range") == "bytes=0-16383")
    }

    @Test
    func normalChapterWithMoreThanFourImagesSkipsAllMeasurementRequests() async throws {
        let recorder = RawOtakuFetchRecorder()
        let runner = RawOtakuSourceRunner(fetch: { request in
            await recorder.append(request)
            let images = (0..<5).map { "<div><img src='https://images.test/\($0).jpg'></div>" }.joined()
            let data = try JSONSerialization.data(withJSONObject: ["html": "<div class='container-reader-chapter'>\(images)</div>"])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let pages = try await runner.getPageList(manga: Self.manga, chapter: .init(key: "/read/book/chapter-1#42"))
        #expect(pages.count == 5)
        #expect(await recorder.requests.count == 1)
        for page in pages {
            guard case .url(_, let context) = page.content else { Issue.record("Expected URL page"); return }
            #expect(context == nil)
        }
    }

    @Test
    func integerRowSlicesCoverWholeImageAndDescriptorsCanBeReleased() async throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 7, bitsPerComponent: 8, bytesPerRow: 8,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = UIImage(cgImage: try #require(context.makeImage()))
        let runner = RawOtakuSourceRunner()
        let descriptor = try await runner.store(value: image)
        let response = AidokuRunner.Response(code: 200, headers: [:], request: .init(url: nil, headers: [:]), image: descriptor)
        var heights: [Int] = []
        for slice in 0..<3 {
            let result = try await runner.processPageImage(response: response, context: ["slice": String(slice), "slices": "3"])
            heights.append(try #require(result?.cgImage?.height))
        }
        #expect(heights == [2, 2, 3])
        try await runner.remove(value: descriptor)
        await #expect(throws: AidokuRunner.SourceError.deserializeError) {
            _ = try await runner.processPageImage(response: response, context: nil)
        }
    }

    private static var manga: AidokuRunner.Manga { .init(sourceKey: "ja.rawotaku", key: "/read/book/", title: "Book") }
    private static func jpeg(width: Int, height: Int) -> Data {
        Data([0xff, 0xd8, 0xff, 0xc0, 0, 17, 8, UInt8(height >> 8), UInt8(height & 255),
              UInt8(width >> 8), UInt8(width & 255)])
    }
}

private actor RawOtakuFetchRecorder {
    var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
}
