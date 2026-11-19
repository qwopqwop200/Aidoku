import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

/// App integration of the opt-in V2 pipeline: iOS resource policy, cache identity, replay.
struct V2ReaderPipelineTests {
    @Test func iosPoolSizesFollowPhysicalMemory() {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        #expect(ReaderTranslationV2Service.poolSizes(physicalMemory: 6 * gib)
            == .init(recognizer: 2, detector: 1, inpainter: 1))
        #expect(ReaderTranslationV2Service.poolSizes(physicalMemory: 8 * gib)
            == .init(recognizer: 3, detector: 2, inpainter: 1))
    }

    @Test func cacheKeyIsPrefixedVersionedAndSettingsBound() {
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: "V2ReaderPipelineTests-\(UUID())")!)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let key = ReaderTranslationV2Service.cacheKey(page: "page-1", crop: unit, settings: settings)
        #expect(key.hasPrefix("v2-" + ReaderTranslationV2Service.version + "-"))
        #expect(key != ReaderTranslationCacheIdentity.translation(page: "page-1", settings: settings))
        #expect(key == ReaderTranslationV2Service.cacheKey(page: "page-1", crop: unit, settings: settings))
        #expect(key != ReaderTranslationV2Service.cacheKey(page: "page-2", crop: unit, settings: settings))
        #expect(key != ReaderTranslationV2Service.cacheKey(page: "page-1",
            crop: CGRect(x: 0, y: 0, width: 0.5, height: 1), settings: settings))
        settings.targetLanguage = settings.targetLanguage == "en" ? "ko" : "en"
        #expect(key != ReaderTranslationV2Service.cacheKey(page: "page-1", crop: unit, settings: settings))
    }

    @Test func pipelineSettingDefaultsOffAndPersists() throws {
        let defaults = UserDefaults(suiteName: "V2ReaderPipelineTests-\(UUID())")!
        var settings = ReaderTranslationSettings(defaults: defaults)
        #expect(!settings.pipelineV2)
        settings.pipelineV2 = true
        try settings.autosave(defaults: defaults, credentialStore: V2NoCredentials())
        #expect(defaults.bool(forKey: "Reader.translationPipelineV2"))
        #expect(ReaderTranslationSettings(defaults: defaults).pipelineV2)
        var legacy = settings
        legacy.pipelineV2 = false
        #expect(!settings.hasSameTranslation(as: legacy))
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

    static let japaneseDialogue = ["今日はいい天気ですね", "明日も晴れるといいな", "待って！", "本当に大丈夫？",
                                   "ありがとうございます", "どこへ行くの", "えっ", "先生"]

    @Test func sourceLanguageFilterMatchesLegacyRuleAndKeepsJapaneseDialogue() {
        let others = ["안녕하세요 반갑습니다", "This is clearly an English sentence for the filter test."]
        let blocks = (Self.japaneseDialogue + others).enumerated().map { block($0.offset, $0.element) }
        var configurations: [ReaderTranslationSettings] = []
        var auto = Self.freshSettings()
        auto.sourceLanguage = "auto"
        configurations.append(auto)
        var autoJapanese = auto
        autoJapanese.translationSourceLanguages = ["ja"]
        configurations.append(autoJapanese)
        var fixed = auto
        fixed.sourceLanguage = "ja"
        configurations.append(fixed)
        for settings in configurations {
            let eligible = ReaderTranslationV2Service.eligibleForTranslation(blocks, settings: settings)
            // Same per-text rule as the legacy region filter (manga recognizer tier).
            var legacySettings = settings
            legacySettings.modelTier = .manga
            for candidate in blocks {
                let region = ReaderTranslationRegion(id: "\(candidate.id)", rect: CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
                    source: candidate.sourceText)
                // Never stricter than the legacy region filter.
                if !ReaderTranslationLanguageFilter.apply([region], settings: legacySettings).isEmpty {
                    #expect(eligible.contains(candidate.id), "\(candidate.sourceText)")
                }
            }
            // Dialogue recall for the allowed language: every Japanese line is sent.
            let missing = Self.japaneseDialogue.indices.filter { !eligible.contains($0) }.map { Self.japaneseDialogue[$0] }
            #expect(missing.isEmpty, "\(settings.sourceLanguage) \(settings.translationSourceLanguages): \(missing)")
            // Target-language and model-unsupported text keeps its source pixels.
            #expect(!eligible.contains(Self.japaneseDialogue.count))
            #expect(!eligible.contains(Self.japaneseDialogue.count + 1))
        }
    }

    @Test func disallowedLanguageIsExcluded() {
        var settings = Self.freshSettings()
        settings.sourceLanguage = "auto"
        settings.translationSourceLanguages = ["zh-Hans"]
        let blocks = [block(0, "今日はいい天気ですね、本当に気持ちがいいです")]
        #expect(ReaderTranslationV2Service.eligibleForTranslation(blocks, settings: settings).isEmpty)
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

    @Test func computeSlotsAdmitForegroundBeforeLookaheadAndCancelWaiters() async throws {
        let slots = V2ComputeSlots(count: 1)
        try await slots.acquire(priority: .foreground)
        let order = V2SentIDs()
        let lookahead = Task { try await slots.acquire(priority: .prefetch); order.append([1]); slots.release() }
        while slots.waitingCount < 1 { await Task.yield() }
        let visible = Task { try await slots.acquire(priority: .foreground); order.append([0]); slots.release() }
        while slots.waitingCount < 2 { await Task.yield() }
        let cancelled = Task { try await slots.acquire(priority: .foreground) }
        while slots.waitingCount < 3 { await Task.yield() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        slots.release()
        try await visible.value
        try await lookahead.value
        #expect(order.ids == [0, 1])
        #expect(slots.availableCount == 1)
    }

    @Test func lookaheadFollowsLegacyCountAndLimit() {
        let pages = (0..<6).map { Page(sourceId: "v2-source", chapterId: "v2-chapter", index: $0, imageURL: "https://example.com/\($0).png") }
        let visible: Set<String> = [pages[1].translationCacheKey]
        var settings = Self.freshSettings()
        settings.automaticallyTranslate = true
        settings.translateInBackground = false
        settings.maximumPretranslatedPages = nil
        func indices(_ presented: Bool, _ settings: ReaderTranslationSettings) -> [Int] {
            ReaderTranslationCoordinator.v2LookaheadPages(upcoming: pages, visibleKeys: visible, currentIndex: 1,
                visiblePresented: presented, settings: settings).map(\.index)
        }
        #expect(indices(false, settings) == [2])
        #expect(indices(true, settings) == [2, 3])
        settings.maximumPretranslatedPages = 0
        #expect(indices(true, settings).isEmpty)
        settings.maximumPretranslatedPages = 1
        #expect(indices(true, settings) == [2])
        // Background-only mode prepares the visible page and two after it.
        settings.maximumPretranslatedPages = nil
        settings.automaticallyTranslate = false
        settings.translateInBackground = true
        #expect(indices(false, settings) == [1, 2, 3])
        settings.translateInBackground = false
        #expect(indices(true, settings).isEmpty)
    }

    @Test func jpegRoundTripKeepsPageSize() throws {
        let page = V2SyntheticPages.make(index: 0)
        let data = try #require(ReaderTranslationV2Service.encode(page))
        let decoded = try #require(ReaderTranslationV2Service.decode(data))
        #expect(decoded.width == page.width && decoded.height == page.height)
    }
}

final class V2SentIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    var ids: [Int] { lock.withLock { values } }
    func append(_ ids: [Int]) { lock.withLock { values += ids } }
}

private struct V2NoCredentials: TranslationCredentialManaging {
    func secret(for account: String) throws -> String { "" }
    func save(_ secret: String, for account: String) throws {}
    func containsSecret(for account: String) throws -> Bool { false }
    func deleteSecret(for account: String) throws {}
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

/// Model-backed admission/coalescing checks (AidokuFull: loads every V2 model).
struct V2ReaderPipelineAdmissionTests {
    /// A page waiting on its provider call holds no compute slot: with one
    /// front and one back slot, a second page completes while the first waits.
    @Test func providerWaitHoldsNoComputeSlot() async throws {
        let gate = V2Gate()
        let calls = V2SentIDs()
        let service = ReaderTranslationV2Service(
            translateBlocks: { blocks, _, _, _, _ in
                calls.append([blocks.count])
                // The first page's provider call blocks until the second page is done.
                if calls.ids.count == 1 { await gate.wait() }
                return blocks.map { var output = $0; output.translation = "번역"; return output }
            },
            diskCache: nil, observesMemoryWarnings: false, frontSlots: 1, backSlots: 1)
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: "V2Admission-\(UUID())")!)
        settings.sourceLanguage = "auto"
        _ = try await service.residentModels()
        let blocked = Task { try await service.translatePage(V2SyntheticPages.make(index: 1), cacheKey: nil, settings: settings) }
        while await gate.waiters == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(service.frontSlots.availableCount == 1)
        let free = try await service.translatePage(V2SyntheticPages.make(index: 0), cacheKey: nil, settings: settings)
        #expect(free.image.width == 1_200 && !free.fromCache)
        await gate.open()
        _ = try await blocked.value
        #expect(service.frontSlots.availableCount == 1 && service.backSlots.availableCount == 1)
    }

    /// Visible demand joins a running look-ahead for the same key (one provider
    /// call); cancelling the only consumer cancels the shared work.
    @Test func sameKeyCoalescesAndLastCancellationStopsWork() async throws {
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
        #expect(first.image.width == second.image.width)
        #expect(await service.inflightCount == 0)

        let closed = V2Gate()
        let cancelling = ReaderTranslationV2Service(
            translateBlocks: { blocks, _, _, _, _ in
                await closed.wait()
                try Task.checkCancellation()
                return blocks
            },
            diskCache: nil, observesMemoryWarnings: false)
        _ = try await cancelling.residentModels()
        let only = Task { try await cancelling.translatePage(page, cacheKey: "c", settings: settings, priority: .prefetch) }
        while await closed.waiters == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        only.cancel()
        while await cancelling.inflightCount != 0 { await Task.yield() }
        await closed.open()
        await #expect(throws: (any Error).self) { try await only.value }
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

/// Simulator/device measurement harness (AidokuFull only: loads every V2
/// model). Runs three synthetic pages through V2Pipeline with an in-process
/// translator (no LLM) and prints per-stage timings.
struct V2ReaderPipelineBenchmarkTests {
    @Test func syntheticPagesRenderWithStageTimings() async throws {
        let service = ReaderTranslationV2Service(
            translateBlocks: { blocks, _, _, _, _ in
                blocks.map { block in
                    var output = block
                    if !V2Translation.translatable([block]).isEmpty { output.translation = "테스트 번역 \(block.id)" }
                    return output
                }
            },
            diskCache: nil, observesMemoryWarnings: false)
        let settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: "V2ReaderPipelineBench-\(UUID())")!)
        let loadStart = DispatchTime.now().uptimeNanoseconds
        _ = try await service.residentModels()
        let loadMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - loadStart) / 1_000_000
        print("V2-BENCH model_load_ms=\(Int(loadMilliseconds)) pools=\(ReaderTranslationV2Service.poolSizes())")
        var totals: [[String: Double]] = []
        for pass in 0..<2 {
            for index in 0..<3 {
                let page = V2SyntheticPages.make(index: index)
                let output = try await service.translatePage(page, cacheKey: nil, settings: settings)
                #expect(output.image.width == page.width && output.image.height == page.height)
                let stages = try #require(output.timings).stages
                if pass == 1 { totals.append(stages) }
                let summary = stages.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\(String(format: "%.1f", $0.value))" }.joined(separator: " ")
                print("V2-BENCH pass=\(pass) page=\(index) \(summary)")
            }
        }
        let keys = Set(totals.flatMap(\.keys)).sorted()
        let median = keys.map { key -> String in
            let values = totals.compactMap { $0[key] }.sorted()
            return "\(key)=\(String(format: "%.1f", values[values.count / 2]))"
        }.joined(separator: " ")
        print("V2-BENCH warm_median \(median)")
    }
}
