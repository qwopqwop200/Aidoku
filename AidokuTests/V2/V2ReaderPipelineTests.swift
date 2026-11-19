import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

/// App integration of the V2 pipeline: iOS resource policy, cache identity, replay.
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
        #expect(key == ReaderTranslationV2Service.cacheKey(page: "page-1", crop: unit, settings: settings))
        #expect(key != ReaderTranslationV2Service.cacheKey(page: "page-2", crop: unit, settings: settings))
        #expect(key != ReaderTranslationV2Service.cacheKey(page: "page-1",
            crop: CGRect(x: 0, y: 0, width: 0.5, height: 1), settings: settings))
        settings.targetLanguage = settings.targetLanguage == "en" ? "ko" : "en"
        #expect(key != ReaderTranslationV2Service.cacheKey(page: "page-1", crop: unit, settings: settings))
    }

    @Test func retiredPipelineAndOCRKeysAreIgnoredAndRemovedOnSave() throws {
        let defaults = UserDefaults(suiteName: "V2ReaderPipelineTests-\(UUID())")!
        // An old backup: legacy pipeline toggle, a non-manga OCR tier and thresholds.
        defaults.set(false, forKey: "Reader.translationPipelineV2")
        defaults.set("medium", forKey: ReaderTranslationSettings.keyPrefix + "modelTier")
        let oldOCR = ReaderOCRConfiguration(modelTier: .small, confidenceThreshold: 0.9)
        defaults.set(try JSONEncoder().encode(oldOCR), forKey: ReaderTranslationSettings.keyPrefix + "ocr")
        defaults.set(Data("{\"unexpected\":true}".utf8), forKey: ReaderTranslationSettings.keyPrefix + "overlay")
        let settings = ReaderTranslationSettings(defaults: defaults)
        #expect(settings.ocr == ReaderOCRConfiguration())
        #expect(settings.modelTier == .manga)
        #expect(settings.overlay.visible)
        try settings.autosave(defaults: defaults, credentialStore: V2NoCredentials())
        for key in ReaderTranslationSettings.retiredKeys { #expect(defaults.object(forKey: key) == nil, "\(key)") }
    }

    @Test func readingDirectionKeysOnlyNonRightToLeftPages() {
        var settings = Self.freshSettings()
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        settings.readingDirection = .rightToLeft
        let rightToLeft = ReaderTranslationV2Service.cacheKey(page: "p", crop: unit, settings: settings)
        settings.readingDirection = .leftToRight
        let leftToRight = ReaderTranslationV2Service.cacheKey(page: "p", crop: unit, settings: settings)
        settings.readingDirection = .topToBottom
        let topToBottom = ReaderTranslationV2Service.cacheKey(page: "p", crop: unit, settings: settings)
        #expect(Set([rightToLeft, leftToRight, topToBottom]).count == 3)
        // Right-to-left keeps the key rows were cached under before direction-aware ordering.
        settings.readingDirection = .rightToLeft
        #expect(settings.rightToLeftPanelOrder)
        settings.rightToLeftPanelOrder = false
        #expect(settings.readingDirection == .leftToRight)
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

    @Test func cachedPageServesTemporaryResultsFromMemoryOnly() async throws {
        let service = ReaderTranslationV2Service(
            loadModels: { throw CancellationError() }, translateBlocks: { blocks, _, _, _, _ in blocks },
            diskCache: nil, observesMemoryWarnings: false)
        #expect(await service.cachedPage(cacheKey: "missing", persists: false) == nil)
        #expect(await service.memoryCachedCount == 0)
    }

    @Test func lookaheadTranslatesSplitHalvesInReadingOrder() {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let left = CGRect(x: 0, y: 0, width: 0.5, height: 1), right = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let wide = CGSize(width: 2_000, height: 1_400), tall = CGSize(width: 1_000, height: 1_400)
        #expect(ReaderTranslationCoordinator.v2LookaheadCrops(imageSize: wide, splitsWidePages: true, direction: .rightToLeft) == [right, left])
        #expect(ReaderTranslationCoordinator.v2LookaheadCrops(imageSize: wide, splitsWidePages: true, direction: .leftToRight) == [left, right])
        #expect(ReaderTranslationCoordinator.v2LookaheadCrops(imageSize: wide, splitsWidePages: false, direction: .rightToLeft) == [unit])
        #expect(ReaderTranslationCoordinator.v2LookaheadCrops(imageSize: tall, splitsWidePages: true, direction: .rightToLeft) == [unit])
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
            // Target-language text keeps its source pixels; English follows the source filter.
            #expect(!eligible.contains(Self.japaneseDialogue.count))
            let allowsEnglish = settings.sourceLanguage == "auto" && settings.translationSourceLanguages.isEmpty
            #expect(eligible.contains(Self.japaneseDialogue.count + 1) == allowsEnglish)
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

    /// A memory-pressure release while a page still holds the models (or while they
    /// are loading) must not load a second set next to the first.
    @Test func releaseWhileInUseReusesTheHeldModels() async throws {
        let loads = V2SentIDs()
        let gate = DispatchSemaphore(value: 0)
        let service = ReaderTranslationV2Service(
            loadModels: {
                loads.append([0])
                gate.wait()
                return try V2Models.load(bundle: .main, detectorInstances: 1, inpainterInstances: 1)
            },
            translateBlocks: { blocks, _, _, _, _ in blocks }, diskCache: nil, observesMemoryWarnings: false)
        let first = Task { try await service.residentModels() }
        while loads.ids.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        await service.releaseModels()
        let second = Task { try await service.residentModels() }
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.signal()
        gate.signal() // never deadlock a (regressed) second load
        let held = try await first.value
        #expect(try await second.value === held)
        await service.releaseModels()
        #expect(await !service.hasResidentModels)
        #expect(try await service.residentModels() === held)
        #expect(loads.ids.count == 1)
    }

    /// A page cancelled during S5 skips the tail instead of running S6/S7/S10
    /// without a back slot; it returns the source pixels.
    @Test func cancelledPageSkipsTheUnadmittedTail() async throws {
        let models = try await ReaderTranslationV2Service(diskCache: nil, observesMemoryWarnings: false).residentModels()
        let page = V2Page(id: "cancelled", image: V2SyntheticPages.make(index: 0))
        let gate = V2Gate()
        let run = Task {
            await V2Pipeline.run(page, models: models, translate: { _, blocks in
                await gate.wait()
                return blocks.map { var output = $0; output.translation = "번역"; return output }
            }, hooks: V2PipelineHooks(acquireBack: { try Task.checkCancellation() }))
        }
        while await gate.waiters == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        run.cancel()
        await gate.open()
        let result = await run.value
        #expect(result.output === page.image)
        #expect(result.placed.isEmpty && result.failure?.contains("cancelled") == true)
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
