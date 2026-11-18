import Foundation
import Testing
import UIKit
@testable import Aidoku

@MainActor
struct ConnectedBalloonSourceConservationTests {
    private let sources = ["午前は図書館へ", "午後は公園へ"]

    @Test(arguments: [false, true])
    func connectedParagraphsSurviveEveryMergeAndProviderPlan(reversed: Bool) throws {
        let (image, original) = try fixture()
        let input = reversed ? Array(original.reversed()) : original
        let enclosure = ReaderTranslationEnclosedBackground.ComponentMap(image: image)
        let merged = ReaderTranslationBalloonMerger.apply(input, image: image, enclosure: enclosure)
        let chromatic = ReaderTranslationChromaticBalloon.applying(merged, image: image)
        let units = ReaderTranslationBalloonMerger.joinBalloonUnits(chromatic, image: image,
            enclosure: enclosure, separates: { first, second, _ in enclosure.separates(first, second) })

        for stage in [merged, chromatic, units] {
            // Check against the pre-merge inventory, never against an already reduced final payload.
            #expect(stage.count == original.count)
            #expect(Set(stage.map(\.id)) == Set(original.map(\.id)))
            for source in sources {
                #expect(stage.reduce(0) { $0 + occurrences(source, in: $1.source) } == 1)
            }
            for source in original {
                #expect(stage.first(where: { $0.id == source.id })?.source == source.source)
            }
        }

        let plans = ReaderTranslationService.plans(regions: units, settings: settings())
        let segments = plans.flatMap { $0.request.segments }
        #expect(segments.count == original.count)
        #expect(Set(segments.map(\.id)) == Set(original.map(\.id)))
        for source in sources {
            #expect(segments.reduce(0) { $0 + occurrences(source, in: $1.text) } == 1)
        }
        for plan in plans {
            try plan.request.validate()
            for segment in plan.request.segments {
                let index = try #require(plan.inputIndicesBySegmentID[segment.id])
                #expect(units.indices.contains(index))
                guard units.indices.contains(index) else { continue }
                #expect(units[index].id == segment.id)
                #expect(units[index].source == segment.text)
            }
        }
    }

    @Test func missingOrDuplicatedLobeResponseCannotCompleteThePage() throws {
        let (_, regions) = try fixture()
        let plan = try #require(ReaderTranslationService.plans(regions: regions, settings: settings()).first)
        let ids = plan.request.segments.map(\.id)
        #expect(ids == ["upper", "lower"])
        for translations in [
            [["id": "lower", "text": "오후에는 공원으로"]],
            [["id": "upper", "text": "오전에는 도서관으로"],
             ["id": "upper", "text": "오전에는 도서관으로"]]
        ] {
            let response = try response(translations)
            do {
                _ = try TranslationHTTPCodec.responseTranslations(from: response,
                    protocol: .responses, expectedSegmentIDs: ids)
                Issue.record("A missing or duplicated connected-lobe ID was accepted")
            } catch {
                #expect(error is RemoteTranslationError)
            }
        }
    }

    @Test func reorderedLobeResponseReturnsEachRequestedOwnerExactlyOnce() throws {
        let (_, regions) = try fixture()
        let plan = try #require(ReaderTranslationService.plans(regions: regions, settings: settings()).first)
        let ids = plan.request.segments.map(\.id)
        let response = try response([
            ["id": "lower", "text": "오후에는 공원으로"],
            ["id": "upper", "text": "오전에는 도서관으로"]
        ])
        let translated = try TranslationHTTPCodec.responseTranslations(from: response,
            protocol: .responses, expectedSegmentIDs: ids)
        #expect(translated.map(\.id) == ids)
        #expect(translated.map(\.text) == ["오전에는 도서관으로", "오후에는 공원으로"])
        #expect(Set(translated.map(\.id)).count == 2)
    }

    private func settings() -> ReaderTranslationSettings {
        var settings = ReaderTranslationSettings()
        settings.sourceLanguage = "ja"
        settings.targetLanguage = "ko"
        settings.rightToLeftPanelOrder = false
        settings.filterSFXWithLLM = false
        settings.filterBackgroundWithLLM = false
        return settings
    }

    private func occurrences(_ phrase: String, in text: String) -> Int {
        text.components(separatedBy: phrase).count - 1
    }

    private func response(_ translations: [[String: String]]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: ["translations": translations])
        let envelope = try #require(String(data: data, encoding: .utf8))
        return try JSONSerialization.data(withJSONObject: [
            "output": [["content": [["type": "output_text", "text": envelope]]]]
        ])
    }

    private func fixture() throws -> (CGImage, [ReaderTranslationRegion]) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // Overlapping oval tips form a narrow neck; each body owns one independent paragraph.
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 360, height: 480), format: format)
            .image { context in
                UIColor(white: 0.85, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 360, height: 480))
                UIColor(red: 0.45, green: 0.27, blue: 0.5, alpha: 1).setFill()
                for y in [CGFloat(93.75), CGFloat(217.5)] {
                    UIBezierPath(ovalIn: CGRect(x: 93.75, y: y, width: 157.5, height: 142.5)).fill()
                }
            }.cgImage)
        let regions = zip(["upper", "lower"], [127.5, 236.25]).enumerated().map { index, value in
            ReaderTranslationRegion(id: value.0,
                rect: CGRect(x: 138.75 / 360, y: value.1 / 480, width: 60.0 / 360, height: 75.0 / 480),
                source: sources[index], confidence: 0.95, sourceImageAspectRatio: 0.75,
                sourceOrientation: .vertical, sourceSingleVerticalColumn: false)
        }
        return (image, regions)
    }
}
