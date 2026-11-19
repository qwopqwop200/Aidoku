import AidokuRunner
import Foundation
import SwiftSoup
import Testing
import UIKit
@testable import Aidoku

struct NativeRawOtakuSourceTests {
    @Test func japaneseDecimalChaptersKeepFragmentIDsAndDiscardTitles() throws {
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

    @Test func jpegMeasurementRejectsTruncatedSegments() {
        #expect(RawOtakuSourceRunner.jpegSize(Data([0xff, 0xd8, 0xff, 0xc0])) == nil)
        #expect(RawOtakuSourceRunner.jpegSize(Data([0xff, 0xd8, 0xff, 0xe0, 0, 0])) == nil)
        let size = RawOtakuSourceRunner.jpegSize(Data([0xff, 0xd8, 0xff, 0xc0, 0, 17, 8, 208, 0, 5, 146]))
        #expect(size?.width == 1426 && size?.height == 53248)
    }

    @Test func slicesCoverWholeImageAndMalformedSliceCountsReturnOriginal() async throws {
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
        for count in [65, Int.max] {
            let result = try await runner.processPageImage(response: response, context: ["slice": String(count - 1), "slices": String(count)])
            #expect(result === image)
        }
        try await runner.remove(value: descriptor)
    }
}
