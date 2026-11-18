import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Prepared geometry must never resurrect a removed owner or stale translation.
@Suite(.serialized) @MainActor
struct NativePreparedLayoutIdentityTests {
    private let size = CGSize(width: 300, height: 450)

    private func item(_ translation: String) -> BrowserOverlayItem {
        BrowserOverlayItem(stableRegionID: 7, rect: CGRect(x: 35, y: 70, width: 180, height: 90),
                           sourceText: "HELLO", translatedText: translation, confidence: 1,
                           sourceOrientation: .horizontal)
    }

    private func cachedLayout() async throws -> Data {
        try await NativeTranslationLayoutPlanner.prepareLayoutData(
            items: [item("이전 번역")], imageSize: size,
            sourceRect: CGRect(origin: .zero, size: size),
            settings: ReaderTranslationSettings.defaultOverlay,
            targetLanguage: "ko", viewport: size)
    }

    private func currentPlan(prepared: Data, viewport: CGSize? = nil) async throws -> Data {
        try await NativeTranslationLayoutPlanner.prepareLayoutData(
            items: [item("이전 번역")], imageSize: size, sourceRect: CGRect(origin: .zero, size: size),
            settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", viewport: viewport ?? size,
            prepared: prepared)
    }

    @Test func matchingPreparedLayoutPreservesExactBytes() async throws {
        let current = try await cachedLayout()
        let adopted = try await currentPlan(prepared: current)
        #expect(adopted == current)
    }

    @Test func corruptPreparedBytesCannotReplaceCurrentLayout() async throws {
        let current = try await cachedLayout()
        let recovered = try await currentPlan(prepared: Data([0xff, 0x00]))
        let decoder = JSONDecoder()
        #expect(try decoder.decode(NativeTranslationLayout.self, from: recovered) ==
                decoder.decode(NativeTranslationLayout.self, from: current))
    }

    @Test func invalidCurrentViewportRejectsOtherwiseValidPreparedLayout() async throws {
        let current = try await cachedLayout()
        await #expect(throws: NativeTranslationLayoutPlanner.Failure.self) {
            _ = try await currentPlan(prepared: current, viewport: .zero)
        }
    }

    @Test func cancelledConsumerCannotAdoptWarmLayout() async throws {
        let current = try await cachedLayout()
        let consumer = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await currentPlan(prepared: current)
        }
        await #expect(throws: CancellationError.self) { try await consumer.value }
    }

    @Test func removedOwnerDoesNotReappearFromPreparedLayout() async throws {
        let cached = try await cachedLayout()
        let result = try await NativeTranslationRenderer.render(
            image: nil, imageSize: size, items: [], settings: ReaderTranslationSettings.defaultOverlay,
            targetLanguage: "ko", viewport: size, aspectFit: false, preparedLayout: cached)
        let actual = try JSONDecoder().decode(NativeTranslationLayout.self, from: result.layoutData)
        #expect(actual.items.isEmpty)
        #expect(result.renderedItemCount == 0)
    }

    @Test func changedTranslationInvalidatesPreparedLayoutWithSameGeometry() async throws {
        let cached = try await cachedLayout()
        let result = try await NativeTranslationRenderer.render(
            image: nil, imageSize: size, items: [item("최신 번역")],
            settings: ReaderTranslationSettings.defaultOverlay,
            targetLanguage: "ko", viewport: size, aspectFit: false, preparedLayout: cached)
        let actual = try JSONDecoder().decode(NativeTranslationLayout.self, from: result.layoutData)
        #expect(actual.items.contains { $0.text.contains("최신 번역") })
        #expect(!actual.items.contains { $0.text.contains("이전 번역") })
    }

    @Test func hiddenCurrentSettingsCannotReuseVisiblePreparedLayout() async throws {
        let cached = try await cachedLayout()
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.visible = false
        let result = try await NativeTranslationRenderer.render(
            image: nil, imageSize: size, items: [item("이전 번역")], settings: settings,
            targetLanguage: "ko", viewport: size, aspectFit: false, preparedLayout: cached)
        let actual = try JSONDecoder().decode(NativeTranslationLayout.self, from: result.layoutData)
        #expect(actual.items.isEmpty)
        #expect(result.renderedItemCount == 0)
    }

    @Test func livePageMetadataFollowsTheConsumerWithoutChangingPaint() async throws {
        guard #available(iOS 18.0, *), NativeMainEnsembleRenderer.enabled else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("HELLO" as NSString).draw(at: CGPoint(x: 65, y: 92),
                withAttributes: [.font: UIFont.systemFont(ofSize: 32, weight: .semibold), .foregroundColor: UIColor.black])
        }
        let settings = ReaderTranslationSettings()
        let items = [item("새 번역")]
        func render(diagnostics: Bool = false, layout: Bool = true, prepared: Data? = nil) async throws -> NativeTranslationRenderer.Result {
            try await NativeTranslationRenderer.render(image: image, imageSize: size, items: items,
                settings: settings.overlay, targetLanguage: "ko", viewport: size, preparedLayout: prepared, collectDiagnostics: diagnostics,
                ocrConfiguration: settings.ocrConfiguration, includeLayoutData: layout)
        }
        let traced = try await render(diagnostics: true)
        let prepared = try await NativeTranslationLayoutPlanner.prepareLayoutData(items: items, imageSize: size,
            sourceRect: NativeTranslationRenderer.sourceRect(imageSize: size, viewport: size, aspectFit: true),
            settings: settings.overlay, targetLanguage: "ko", viewport: size)
        let live = try await render(prepared: prepared)
        let exported = try await render(layout: false)
        let data = try #require(traced.diagnosticData)
        let audit = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(audit["paintedTranslationItems"] as? Int == 1)
        #expect(live.diagnosticData == nil && exported.diagnosticData == nil && exported.layoutData.isEmpty)
        let decodedLayout = try JSONDecoder().decode(NativeTranslationLayout.self, from: live.layoutData)
        #expect(decodedLayout.items.count == 1 && decodedLayout.viewport == size)
        for result in [live, exported] {
            #expect(result.includesSourcePage && result.renderedItemCount == traced.renderedItemCount)
            #expect(try NativeMandatoryDisplayStroke.rgba(#require(result.image.cgImage))
                == NativeMandatoryDisplayStroke.rgba(#require(traced.image.cgImage)))
        }
    }
}

extension NativePreparedLayoutIdentityTests {
    @Test func preparedBytesCannotCrossAChangedProviderBatch() async throws {
        let segments = [
            RemoteTranslationSegment(id: "a", text: "First"),
            RemoteTranslationSegment(id: "b", text: "Second", bounds: [0.1, 0.2, 0.4, 0.5])
        ]
        func batch(_ segments: [RemoteTranslationSegment], generation: UInt64 = 1) -> TranslationCacheKey {
            TranslationCacheKey(configuration: .openAI(model: "fixture", credentialGeneration: generation),
                                endpoint: URL(string: "https://example.org/")!,
                                request: .init(sourceLanguage: "en", targetLanguage: "ko", segments: segments))
        }
        let first = batch(segments)
        let shared = first
        var changedText = segments
        changedText[1] = RemoteTranslationSegment(id: "b", text: "Last", bounds: segments[1].bounds)
        var changedBounds = segments
        changedBounds[1].bounds?[0] = Double(0.1).nextUp
        let mutations = [batch(changedText), batch(changedBounds), batch(segments, generation: 2)]
        func plan(_ keys: [TranslationCacheKey], prepared: Data? = nil) async throws -> Data {
            let cards = keys.enumerated().map { index, key in
                BrowserOverlayItem(stableRegionID: UInt64(700 + index),
                                   rect: CGRect(x: 20, y: 20 + index * 90, width: 150, height: 65),
                                   sourceText: "Original", translatedText: "동일한 번역", confidence: 1,
                                   sourceOrientation: .horizontal,
                                   translationReuseIdentity: .init(cacheKey: key, segmentID: index.isMultiple(of: 2) ? "a" : "b"))
            }
            return try await NativeTranslationLayoutPlanner.prepareLayoutData(
                items: cards, imageSize: size, sourceRect: CGRect(origin: .zero, size: size),
                settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", viewport: size,
                prepared: prepared)
        }
        let decoder = JSONDecoder()
        for changed in mutations {
            let previous = try await plan([first, shared, first, shared])
            let current = try await plan([first, changed, first, changed], prepared: previous)
            // Only the provider ownership changed. Equal decoded geometry is correct. Keeping the
            // old allocation alive lets us detect accidental adoption of its prepared bytes.
            let reusedPrevious = previous.withUnsafeBytes { old in
                current.withUnsafeBytes { new in new.baseAddress == old.baseAddress }
            }
            #expect(!reusedPrevious)
            #expect(try decoder.decode(NativeTranslationLayout.self, from: current) ==
                    decoder.decode(NativeTranslationLayout.self, from: previous))
        }
    }

    @Test func validPreparedPlanWithForgedTextIsIgnoredEvenAfterEviction() async throws {
        let current = try await cachedLayout()
        var json = try #require(JSONSerialization.jsonObject(with: current) as? [String: Any])
        var cards = try #require(json["items"] as? [[String: Any]])
        try #require(cards.count == 1)
        cards[0]["text"] = "바꿔 넣은 번역"
        json["items"] = cards
        let forged = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        let expected = try decoder.decode(NativeTranslationLayout.self, from: current)
        #expect(try decoder.decode(NativeTranslationLayout.self, from: forged) != expected)
        let warm = try await currentPlan(prepared: forged)
        #expect(try decoder.decode(NativeTranslationLayout.self, from: warm) == expected)

        for width in [size.width + 3, size.width + 7] {
            _ = try await currentPlan(prepared: forged, viewport: CGSize(width: width, height: size.height))
        }
        let cold = try await currentPlan(prepared: forged)
        #expect(try decoder.decode(NativeTranslationLayout.self, from: cold) == expected)
    }
}
