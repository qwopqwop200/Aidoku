import CoreGraphics
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationTests {
    @Test func unchangedTextKeepsSourcePixelsWithoutDroppingDialogueIDs() {
        let sources = ["18000", "١٢٣", "$60.00", "60Ko", "...", "Bang", "１２", "12"]
        let translations = ["18000", "١٢٣", "$60.00", "60Ko", "...", "Bang", "12", "열둘"]
        let regions = zip(sources, translations).enumerated().map { index, pair in
            ReaderTranslationRegion(id: "r-\(index)", rect: CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
                                    source: pair.0, translation: pair.1)
        }
        let items = ReaderTranslationRegion.overlayItems(regions, imageSize: CGSize(width: 100, height: 100))
        #expect(items.compactMap(\.stableRegionID) == [6, 7])
        #expect(items.compactMap(\.translatedText) == Array(translations.dropFirst(6)))
        // Pending regions still participate in progressive identity matching.
        var pending = regions[0]
        pending.translation = nil
        #expect(!pending.preservesOriginalText)
    }

    @Test func aspectFitAndWebtoonCoordinates() {
        let region = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        #expect(ReaderTranslationGeometry.displayRect(
            region, imageSize: CGSize(width: 200, height: 400), bounds: bounds, aspectFit: true
        ) == CGRect(x: 150, y: 100, width: 100, height: 200))
        #expect(ReaderTranslationGeometry.displayRect(
            region, imageSize: CGSize(width: 200, height: 400), bounds: bounds, aspectFit: false
        ) == CGRect(x: 100, y: 100, width: 200, height: 200))
    }

    @Test func largeChaptersAreBatchedWithoutLosingIDsOrUTF8Text() throws {
        let suite = "ReaderTranslationBatchTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.sourceLanguage = "auto"
        settings.translationSourceLanguages = []
        let sourceText = String(repeating: "猫", count: 2_000)
        let regions = (0..<100).map { index in
            ReaderTranslationRegion(id: "line-\(index)", rect: .zero, source: sourceText)
        }
        let requests = try ReaderTranslationService.requests(regions: regions, settings: settings)
        #expect(requests.count > 3)
        let capacity = min(RemoteTranslationRequest.maximumSegments,
                           RemoteTranslationRequest.maximumSourceBytes / sourceText.utf8.count)
        #expect(requests.count == (regions.count + capacity - 1) / capacity)
        #expect(requests.dropLast().allSatisfy { $0.segments.count == capacity })
        #expect(requests.allSatisfy { $0.segments.count <= RemoteTranslationRequest.maximumSegments })
        #expect(requests.flatMap(\.segments).map(\.id) == regions.map(\.id))
        #expect(requests.flatMap(\.segments).map(\.text) == regions.map(\.source))
        #expect(requests.allSatisfy { $0.segments.reduce(0) { $0 + $1.text.utf8.count } <= RemoteTranslationRequest.maximumSourceBytes })
        #expect(try ReaderTranslationService.requests(regions: [], settings: settings).isEmpty)
    }

    @Test func invalidSettingsAreRejectedWithoutPersisting() throws {
        let suite = "ReaderTranslationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.model = " "
        #expect(throws: RemoteTranslationError.self) { try settings.save(defaults: defaults) }
        #expect(defaults.string(forKey: ReaderTranslationSettings.keyPrefix + "model") == nil)
        settings.model = "gpt-5-mini"
        settings.targetLanguage = "en"
        settings.modelTier = .small
        try settings.save(defaults: defaults)
        #expect(ReaderTranslationSettings(defaults: defaults) == settings)
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.lowercased().contains("apikey") })
    }

    @Test @MainActor func overlayUsesOriginalPixelsAndReusesOCRAcrossLanguages() async throws {
        let source = Self.image()
        let imageView = UIImageView(image: source)
        imageView.frame = CGRect(x: 0, y: 0, width: 320, height: 440)
        let calls = RecognitionCounter()
        let page = ReaderTranslationPage(imageView: imageView, recognize: { _, _ in
            await calls.record()
            return Self.regions
        }, translate: { regions, settings in
            regions.map {
                var result = $0
                result.translation = settings.targetLanguage == "ko" ? "안녕, 세상!" : "Bonjour !"
                return result
            }
        })
        var settings = ReaderTranslationSettings()
        settings.targetLanguage = "ko"
        settings.sourceLanguage = "auto"
        settings.translationSourceLanguages = []
        #expect(try await page.process(translate: true, settings: settings) == 1)
        #expect(imageView.image === source)
        #expect(page.regions.first?.translation == "안녕, 세상!")
        #expect(imageView.subviews.contains { $0 is ReaderTranslationOverlayView && !$0.isHidden })
        settings.targetLanguage = "fr"
        _ = try await page.process(translate: true, settings: settings)
        #expect(page.regions.first?.translation == "Bonjour !")
        #expect(await calls.count == 1)
        page.showOriginal()
        #expect(imageView.subviews.allSatisfy { $0.isHidden })
        _ = try await page.process(translate: false, settings: settings)
        #expect(page.regions.first?.translation == nil)
        #expect(await calls.count == 1)
        page.reset()
        #expect(page.regions.isEmpty)
        #expect(imageView.subviews.isEmpty)
    }

    @Test @MainActor func cancelledOrReplacedPageNeverReceivesLateResults() async throws {
        for replaceImage in [false, true] {
            let imageView = UIImageView(image: Self.image())
            let barrier = RecognitionBarrier()
            let page = ReaderTranslationPage(imageView: imageView, recognize: { _, _ in
                await barrier.wait()
                return Self.regions
            })
            let task = Task { try await page.process(translate: false, settings: ReaderTranslationSettings()) }
            while !(await barrier.started) { await Task.yield() }
            if replaceImage { imageView.image = Self.image() } else { page.cancel() }
            await barrier.release()
            do {
                _ = try await task.value
                Issue.record("An obsolete OCR result was accepted")
            } catch is CancellationError {
                // Expected even when a recognizer ignores cooperative cancellation.
            }
            #expect(page.regions.isEmpty)
            #expect(imageView.subviews.isEmpty)
        }
    }

    @Test @MainActor func bundledCoreMLRecognizesAnActualPage() async throws {
        for tier in IPhoneOCRModelTier.allCases {
            let profile = NativeCoreMLOCRModelProfile.profile(for: tier)
            #expect(Bundle.main.url(forResource: profile.detectorResourceName, withExtension: "mlmodelc") != nil)
            #expect(Bundle.main.url(forResource: profile.recognizerResourceName, withExtension: "mlmodelc") != nil)
            let dictionary = try #require(Bundle.main.url(forResource: profile.dictionaryResourceName, withExtension: "txt"))
            #expect(try String(contentsOf: dictionary, encoding: .utf8).split(separator: "\n").count > 6_000)
        }
        let image = Self.image()
        let pixels = try #require(image.cgImage)
        let regions = try await ReaderOCRService.shared.recognize(image: pixels, tier: .medium)
        #expect(!regions.isEmpty)
        #expect(regions.contains { $0.source.uppercased().contains("HELLO") })
        #expect(regions.allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.rect) })
        await ReaderOCRService.shared.purge()
    }

    private static let regions = [ReaderTranslationRegion(
        id: "region-0", rect: CGRect(x: 0.1, y: 0.1, width: 0.75, height: 0.2), source: "HELLO WORLD"
    )]

    @MainActor private static func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 640, height: 880), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 880))
            ("HELLO WORLD" as NSString).draw(at: CGPoint(x: 60, y: 100), withAttributes: [
                .font: UIFont.systemFont(ofSize: 48, weight: .bold), .foregroundColor: UIColor.black
            ])
            ("こんにちは" as NSString).draw(at: CGPoint(x: 80, y: 280), withAttributes: [
                .font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black
            ])
        }
    }
}

private actor RecognitionCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor RecognitionBarrier {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}
