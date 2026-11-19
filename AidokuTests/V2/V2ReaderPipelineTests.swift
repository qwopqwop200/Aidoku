import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

/// App integration of the V2 pipeline: cache identity and memory budget, replay, provider filtering.
struct V2ReaderPipelineTests {
    @Test func cacheKeyIsPrefixedVersionedAndSettingsBound() {
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: "V2ReaderPipelineTests-\(UUID())")!)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let key = ReaderTranslationV2Service.cacheKey(page: "page-1", crop: unit, settings: settings)
        #expect(key.hasPrefix("v2-" + ReaderTranslationV2Service.version + "-"))
        #expect(key == ReaderTranslationV2Service.cacheKey(page: "page-1", crop: unit, settings: settings))
        #expect(key != ReaderTranslationV2Service.cacheKey(page: "page-2", crop: unit, settings: settings))
        #expect(key != ReaderTranslationV2Service.cacheKey(page: "page-1",
            crop: CGRect(x: 0, y: 0, width: 0.5, height: 1), settings: settings))
        settings.targetLanguage = settings.targetLanguage == "en" ? "ko" : "en"
        #expect(key != ReaderTranslationV2Service.cacheKey(page: "page-1", crop: unit, settings: settings))
    }

    @Test func memoryCacheEvictsLeastRecentlyUsedWithinBudget() {
        let image = V2SyntheticPages.make(index: 0, width: 100, height: 100)
        let cost = V2PageMemoryCache.cost(image)
        var cache = V2PageMemoryCache()
        cache.insert(image, for: "a", limit: cost * 2)
        cache.insert(image, for: "b", limit: cost * 2)
        #expect(cache.image(for: "a") != nil) // a becomes most recent
        cache.insert(image, for: "c", limit: cost * 2)
        #expect(cache.image(for: "b") == nil)
        #expect(cache.image(for: "a") != nil && cache.image(for: "c") != nil)
        #expect(cache.bytes == cost * 2 && cache.count == 2)
        cache.insert(image, for: "d", limit: cost - 1)
        #expect(cache.image(for: "d") == nil)
        cache.removeAll()
        #expect(cache.count == 0 && cache.bytes == 0)
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        #expect(V2PageMemoryCache.byteLimit(available: 0, current: 0) == V2PageMemoryCache.minimumBytes)
        #expect(V2PageMemoryCache.byteLimit(available: 8 * gib, current: 0) == V2PageMemoryCache.maximumBytes)
    }

    @Test func replayReappliesOnlyMatchingBlocks() {
        func block(_ id: Int, _ text: String, translation: String? = nil) -> V2Block {
            V2Block(id: id, lines: [], bounds: .zero, polygon: [], vertical: true, readingOrder: id,
                    sourceText: text, translation: translation)
        }
        let stored = [block(0, "こんにちは", translation: "안녕"), block(1, "さようなら", translation: "잘 가")]
        let replayed = ReaderTranslationV2Service.replay(stored, onto: [block(0, "こんにちは"), block(1, "別の文"), block(2, "新しい")])
        #expect(replayed.map(\.translation) == ["안녕", nil, nil])
    }

    private static func freshSettings() -> ReaderTranslationSettings {
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: "V2ReaderPipelineTests-\(UUID())")!)
        settings.targetLanguage = "ko"
        return settings
    }

    private func block(_ id: Int, _ text: String) -> V2Block {
        V2Block(id: id, lines: [], bounds: CGRect(x: 0, y: 0, width: 10, height: 10), polygon: [], vertical: true,
                readingOrder: id, sourceText: text)
    }

    @Test func excludedLanguageBlocksAreNeverSentToTheProvider() async throws {
        var settings = Self.freshSettings()
        settings.sourceLanguage = "auto"
        let blocks = [block(0, "今日はいい天気ですね"), block(1, "안녕하세요 반갑습니다")]
        let sent = V2SentIDs()
        let translated = try await ReaderTranslationV2Service.translateEligible(blocks, settings: settings) { eligible in
            sent.append(eligible.map(\.id))
            return eligible.map { var output = $0; output.translation = "번역"; return output }
        }
        #expect(sent.ids == [0])
        #expect(translated.map(\.translation) == ["번역", nil])
        let none = try await ReaderTranslationV2Service.translateEligible([block(1, "안녕하세요 반갑습니다")],
                                                                          settings: settings) { _ in
            Issue.record("No eligible block may reach the provider")
            return []
        }
        #expect(none.map(\.translation) == [nil])
    }
}

final class V2SentIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    var ids: [Int] { lock.withLock { values } }
    func append(_ ids: [Int]) { lock.withLock { values += ids } }
}

/// Synthetic manga-like pages drawn in code (never dataset images): white
/// balloons with vertical Japanese lettering over a light tone background.
enum V2SyntheticPages {
    static let lines = [
        ["今日はいい天気", "ですね"], ["明日も晴れると", "いいな"], ["テスト用の", "文字列です"],
        ["どこへ行くの", "待って！"], ["本当に", "大丈夫？"], ["ありがとう", "ございます"]
    ]

    static func make(index: Int, width: Int = 1_200, height: Int = 1_700) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.86, green: 0.86, blue: 0.86, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Panel borders.
        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.setLineWidth(6)
        context.stroke(CGRect(x: 30, y: 30, width: width - 60, height: height / 2 - 45))
        context.stroke(CGRect(x: 30, y: height / 2 + 15, width: width - 60, height: height / 2 - 45))
        let font = CTFontCreateWithName("HiraginoSans-W6" as CFString, 44, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        let balloons = 3 + index % 2
        for balloon in 0..<balloons {
            let column = balloon % 2, row = balloon / 2
            let center = CGPoint(x: 330 + CGFloat(column) * 520, y: CGFloat(height) - 380 - CGFloat(row) * 820)
            let ellipse = CGRect(x: center.x - 170, y: center.y - 260, width: 340, height: 520)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fillEllipse(in: ellipse)
            context.setLineWidth(4)
            context.strokeEllipse(in: ellipse)
            let text = lines[(index * 2 + balloon) % lines.count]
            // Vertical columns right to left, one glyph per 50 px.
            for (columnIndex, columnText) in text.enumerated() {
                let x = center.x + 40 - CGFloat(columnIndex) * 70
                for (glyphIndex, character) in columnText.enumerated() {
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: attributes))
                    context.textPosition = CGPoint(x: x - 22, y: center.y + 170 - CGFloat(glyphIndex) * 50)
                    CTLineDraw(line, context)
                }
            }
        }
        return context.makeImage()!
    }
}

/// Model-backed end-to-end check (AidokuFull: loads every V2 model).
struct V2ReaderPipelineAdmissionTests {
    /// Visible demand joins a running look-ahead for the same key (one provider
    /// call) and both receive the rendered page.
    @Test func sameKeyCoalescesIntoOneProviderCall() async throws {
        let calls = V2SentIDs()
        let gate = V2Gate()
        let service = ReaderTranslationV2Service(
            translateBlocks: { blocks, _, _, _, _ in
                calls.append([blocks.count])
                await gate.wait()
                try Task.checkCancellation()
                return blocks.map { var output = $0; output.translation = "번역"; return output }
            },
            diskCache: nil, observesMemoryWarnings: false)
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: "V2Coalesce-\(UUID())")!)
        settings.sourceLanguage = "auto"
        _ = try await service.residentModels()
        let page = V2SyntheticPages.make(index: 2)
        let lookahead = Task { try await service.translatePage(page, cacheKey: "k", settings: settings, priority: .prefetch) }
        while await gate.waiters == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        let visible = Task { try await service.translatePage(page, cacheKey: "k", settings: settings) }
        while await service.consumerCount("k") < 2 { await Task.yield() }
        await gate.open()
        let first = try await lookahead.value
        let second = try await visible.value
        #expect(calls.ids.count == 1)
        #expect(first.image.width == page.width && first.image.height == page.height && !first.fromCache)
        #expect(second.image.width == page.width)
        #expect(await service.inflightCount == 0)
    }
}

actor V2Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var waiters = 0

    func wait() async {
        guard !isOpen else { return }
        waiters += 1
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}
