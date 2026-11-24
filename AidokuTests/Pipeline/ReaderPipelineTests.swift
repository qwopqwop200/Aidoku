import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

/// App integration of the pipeline: cache identity and memory budget, replay, provider filtering.
struct ReaderPipelineTests {
    @Test func cacheKeyIsPrefixedVersionedAndSettingsBound() {
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: "ReaderPipelineTests-\(UUID())")!)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let key = ReaderTranslationPipelineService.cacheKey(page: "page-1", crop: unit, settings: settings)
        #expect(key.hasPrefix("v2-" + ReaderTranslationPipelineService.version + "-"))
        #expect(key == ReaderTranslationPipelineService.cacheKey(page: "page-1", crop: unit, settings: settings))
        #expect(key != ReaderTranslationPipelineService.cacheKey(page: "page-2", crop: unit, settings: settings))
        #expect(key != ReaderTranslationPipelineService.cacheKey(page: "page-1",
            crop: CGRect(x: 0, y: 0, width: 0.5, height: 1), settings: settings))
        settings.targetLanguage = settings.targetLanguage == "en" ? "ko" : "en"
        #expect(key != ReaderTranslationPipelineService.cacheKey(page: "page-1", crop: unit, settings: settings))
    }

    @Test func memoryCacheEvictsLeastRecentlyUsedWithinBudget() {
        let image = PipelineSyntheticPages.make(width: 100, height: 100)
        let cost = PipelinePageMemoryCache.cost(image)
        var cache = PipelinePageMemoryCache()
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
        #expect(PipelinePageMemoryCache.byteLimit(available: 0, current: 0) == PipelinePageMemoryCache.minimumBytes)
        #expect(PipelinePageMemoryCache.byteLimit(available: 8 * gib, current: 0) == PipelinePageMemoryCache.maximumBytes)
    }

    @Test func replayReappliesOnlyMatchingBlocks() {
        let stored = [block(0, "こんにちは", translation: "안녕"), block(1, "さようなら", translation: "잘 가")]
            .map(PipelineStoredTranslation.init)
        let replayed = ReaderTranslationPipelineService.replay(stored, onto: [block(0, "こんにちは"), block(1, "別の文"), block(2, "新しい")])
        #expect(replayed.map(\.translation) == ["안녕", nil, nil])
    }

    @Test func storedTranslationKeepsOnlyTheReplayFieldsAndReadsFullBlockRows() throws {
        let blocks = [block(0, "こんにちは", translation: "안녕"), block(1, "ドン")]
        let slim = try #require(PipelineStoredTranslation.encode(blocks))
        let full = try JSONEncoder().encode(blocks)
        #expect(slim.count < full.count / 2)
        #expect(PipelineStoredTranslation.decode(slim) == blocks.map(PipelineStoredTranslation.init))
        #expect(PipelineStoredTranslation.decode(full) == blocks.map(PipelineStoredTranslation.init))
        #expect(PipelineStoredTranslation.decode(Data("{}".utf8)) == nil)
        #expect(ReaderTranslationDiskCache.isPipelinePageRow(kind: .translation, unpacked: slim, linkedToRegionBase: false))
        #expect(ReaderTranslationDiskCache.isPipelinePageRow(kind: .translation, unpacked: full, linkedToRegionBase: false))
    }

    /// Deterministic textured page; `edit` repaints one rectangle (top-left origin).
    private func pageRaster(width: Int, height: Int, edit: CGRect? = nil) -> PipelinePageRaster {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let edited = edit?.contains(CGPoint(x: x, y: y)) ?? false
                let value = edited ? UInt8((x + y) % 2 == 0 ? 20 : 235) : UInt8(truncatingIfNeeded: (x &* 37) ^ (y &* 91))
                for channel in 0..<3 { bytes[(y * width + x) * 4 + channel] = value }
            }
        }
        return PipelinePageRaster(width: width, height: height, rgba: bytes)
    }

    @Test func storedPageKeepsTheErasedBackgroundAndRebuildsOverTheSource() throws {
        let width = 320, height = 448, edit = CGRect(x: 100, y: 200, width: 50, height: 40)
        let source = try pageRaster(width: width, height: height).image()
        let restored = pageRaster(width: width, height: height, edit: edit)
        // The erased region is the 16 px tiles the removal mask touches: (96, 192) to (160, 240).
        var removal = [UInt8](repeating: 0, count: width * height)
        for y in 200..<240 { for x in 100..<150 { removal[y * width + x] = 1 } }
        let regions = PipelineBackgroundPatch.regions(removal: removal, width: width, height: height)
        let patch = CGRect(x: 96, y: 192, width: 64, height: 48)
        #expect(regions == [patch])
        #expect(PipelineBackgroundPatch.regions(removal: [UInt8](repeating: 0, count: width * height), width: width, height: height).isEmpty)
        let background = PipelineBackgroundPatch.capture(regions, from: restored.rgba, width: width)
        #expect(background.first?.rgba.count == 64 * 48 * 4)

        let row = try #require(ReaderTranslationPagePatches.encode(try restored.image(), background: background, blocks: [], placed: []))
        let whole = try #require(ReaderTranslationPagePatches.encode(try restored.image(), background: nil, blocks: [], placed: []))
        #expect(ReaderTranslationPagePatches.isPatches(row) && ReaderTranslationPagePatches.isStoredPage(row))
        #expect(ReaderTranslationDiskCache.isPipelinePageRow(kind: .layout, unpacked: row, linkedToRegionBase: false))
        #expect(row.count < whole.count / 4)

        #expect(ReaderTranslationPagePatches.decode(row, source: nil) == nil)
        let rebuilt = try PipelinePageRaster(try #require(ReaderTranslationPagePatches.decode(row, source: source)))
        #expect(rebuilt.width == width && rebuilt.height == height)
        var worstInside = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if patch.contains(CGPoint(x: x, y: y)) {
                    worstInside = max(worstInside, abs(Int(rebuilt.rgba[index]) - Int(restored.rgba[index])))
                } else if rebuilt.rgba[index] != restored.rgba[index] {
                    Issue.record("pixel outside the patch changed at \(x),\(y)")
                    return
                }
            }
        }
        #expect(worstInside < 96)  // JPEG noise on a hard checkerboard, not a wrong region

        // A page that was not restored in place is stored whole and still rebuilds; an untouched page stores no patch.
        let scaled = try #require(ReaderTranslationPagePatches.decode(whole, source: try pageRaster(width: 8, height: 8).image()))
        #expect(scaled.width == width && scaled.height == height)
        let untouched = try #require(ReaderTranslationPagePatches.encode(source, background: [], blocks: [], placed: []))
        #expect(untouched.count <= 32)
        let same = try PipelinePageRaster(try #require(ReaderTranslationPagePatches.decode(untouched, source: source)))
        #expect(same.rgba == pageRaster(width: width, height: height).rgba)
        #expect(ReaderTranslationPagePatches.decode(row.prefix(row.count - 10), source: source) == nil)
    }

    @Test func storedPageRepaintsItsTextWhenRebuilt() throws {
        let width = 320, height = 160
        let white = PipelinePageRaster(width: width, height: height, rgba: [UInt8](repeating: 255, count: width * height * 4))
        let style = PipelineStyle(fontPixels: 28, bold: false, textColor: PipelineRGB(r: 0, g: 0, b: 0), strokeColor: nil, strokeWidth: 0)
        let blocks = [PipelineBlock(id: 7, lines: [], bounds: CGRect(x: 32, y: 32, width: 240, height: 64), polygon: [], vertical: false,
                              readingOrder: 0, sourceText: "こんにちは", translation: "안녕하세요", style: style)]
        let placed = [PipelinePlacedText(blockID: 7, frame: CGRect(x: 40, y: 48, width: 220, height: 36), fontPixels: 28,
                                   vertical: false, lines: ["안녕하세요"])]
        var pixels = white.rgba
        let rendered = try #require(PipelinePainter.paint(pixels: &pixels, width: width, height: height, blocks: blocks, placed: placed))
        let erased = [CGRect(x: 32, y: 32, width: 240, height: 64)]
        let row = try #require(ReaderTranslationPagePatches.encode(
            rendered, background: PipelineBackgroundPatch.capture(erased, from: white.rgba, width: width), blocks: blocks, placed: placed))
        let rebuilt = try PipelinePageRaster(try #require(ReaderTranslationPagePatches.decode(row, source: try white.image())))
        let expected = try PipelinePageRaster(rendered)
        #expect(expected.rgba.contains { $0 < 64 })  // the text was painted
        #expect(rebuilt.rgba == expected.rgba)
        // A block missing for a placed item is a broken row, not a silent page without text.
        #expect(ReaderTranslationPagePatches.encode(rendered, background: [], blocks: [], placed: placed) == nil)
    }

    private func block(_ id: Int, _ text: String, translation: String? = nil) -> PipelineBlock {
        PipelineBlock(id: id, lines: [], bounds: CGRect(x: 0, y: 0, width: 10, height: 10), polygon: [], vertical: true,
                readingOrder: id, sourceText: text, translation: translation)
    }

    @Test func excludedLanguageBlocksAreNeverSentToTheProvider() async throws {
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: "ReaderPipelineTests-\(UUID())")!)
        settings.targetLanguage = "ko"
        settings.sourceLanguage = "auto"
        let blocks = [block(0, "今日はいい天気ですね"), block(1, "안녕하세요 반갑습니다")]
        let sent = PipelineSentIDs()
        let translated = try await ReaderTranslationPipelineService.translateEligible(blocks, settings: settings) { eligible in
            sent.append(eligible.map(\.id))
            return eligible.map { var output = $0; output.translation = "번역"; return output }
        }
        #expect(sent.ids == [0])
        #expect(translated.map(\.translation) == ["번역", nil])
        let none = try await ReaderTranslationPipelineService.translateEligible([block(1, "안녕하세요 반갑습니다")],
                                                                          settings: settings) { _ in
            Issue.record("No eligible block may reach the provider")
            return []
        }
        #expect(none.map(\.translation) == [nil])
    }
}

final class PipelineSentIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    var ids: [Int] { lock.withLock { values } }
    func append(_ ids: [Int]) { lock.withLock { values += ids } }
}

/// Synthetic manga-like pages drawn in code (never dataset images): white
/// balloons with vertical Japanese lettering over a light tone background.
enum PipelineSyntheticPages {
    static let lines = [["本当に", "大丈夫？"], ["ありがとう", "ございます"], ["今日はいい天気", "ですね"]]

    static func make(width: Int = 1_200, height: Int = 1_700) -> CGImage {
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
        for (balloon, text) in lines.enumerated() {
            let column = balloon % 2, row = balloon / 2
            let center = CGPoint(x: 330 + CGFloat(column) * 520, y: CGFloat(height) - 380 - CGFloat(row) * 820)
            let ellipse = CGRect(x: center.x - 170, y: center.y - 260, width: 340, height: 520)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fillEllipse(in: ellipse)
            context.setLineWidth(4)
            context.strokeEllipse(in: ellipse)
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

/// Model-backed end-to-end check (AidokuFull: loads every pipeline model).
struct ReaderPipelineAdmissionTests {
    private typealias PageTask = Task<ReaderTranslationPipelineService.PageOutput, Error>

    /// Starts a look-ahead and a visible request for one key; both are joined once the provider call waits on `gate`.
    private func joinedRequests(gate: PipelineGate, calls: PipelineSentIDs) async throws
        -> (page: CGImage, lookahead: PageTask, visible: PageTask) {
        let service = ReaderTranslationPipelineService(
            translateBlocks: { blocks, _, _, _, _ in
                calls.append([blocks.count])
                await gate.wait()
                try Task.checkCancellation()
                return blocks.map { var output = $0; output.translation = "번역"; return output }
            },
            diskCache: nil, observesMemoryWarnings: false)
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: "PipelineAdmission-\(UUID())")!)
        settings.sourceLanguage = "auto"
        _ = try await service.residentModels()
        let page = PipelineSyntheticPages.make()
        let lookahead = Task { try await service.translatePage(page, cacheKey: "k", settings: settings, priority: .prefetch) }
        while await gate.waiters == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        let visible = Task { try await service.translatePage(page, cacheKey: "k", settings: settings) }
        while await service.consumerCount("k") < 2 { await Task.yield() }
        return (page, lookahead, visible)
    }

    /// Visible demand joins a running look-ahead for the same key (one provider
    /// call) and both receive the rendered page.
    @Test func sameKeyCoalescesIntoOneProviderCall() async throws {
        let gate = PipelineGate(), calls = PipelineSentIDs()
        let (page, lookahead, visible) = try await joinedRequests(gate: gate, calls: calls)
        await gate.open()
        let first = try await lookahead.value
        let second = try await visible.value
        #expect(calls.ids.count == 1)
        #expect(first.image.width == page.width && first.image.height == page.height && !first.fromCache)
        #expect(second.image.width == page.width)
    }

    /// A translated page is stored as patches: a new session rebuilds it over the source without a provider call.
    @Test func storedPageRebuildsFromDiskInANewSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PipelineStoredPage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: "PipelineStoredPage-\(UUID())")!)
        settings.sourceLanguage = "auto"
        let page = PipelineSyntheticPages.make()
        let first = ReaderTranslationPipelineService(
            translateBlocks: { blocks, _, _, _, _ in blocks.map { var output = $0; output.translation = "번역"; return output } },
            diskCache: disk, observesMemoryWarnings: false)
        let rendered = try await first.translatePage(page, cacheKey: "k", settings: settings)
        #expect(!rendered.fromCache)

        let calls = PipelineSentIDs()
        let second = ReaderTranslationPipelineService(
            translateBlocks: { blocks, _, _, _, _ in calls.append([blocks.count]); return blocks },
            diskCache: disk, observesMemoryWarnings: false)
        var rebuilt: CGImage?
        for _ in 0..<500 where rebuilt == nil {  // the row is written after the page is returned
            rebuilt = await second.cachedPage(cacheKey: "k", source: page)
            if rebuilt == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let image = try #require(rebuilt)
        #expect(image.width == page.width && image.height == page.height)
        // Erased regions carry JPEG noise; everything else, repainted text included, matches the rendered page.
        let expected = try PipelinePageRaster(rendered.image).rgba, actual = try PipelinePageRaster(image).rgba
        var exact = 0, far = 0
        for index in stride(from: 0, to: expected.count, by: 4) {
            let difference = abs(Int(expected[index]) - Int(actual[index]))
            if difference == 0 { exact += 1 } else if difference > 64 { far += 1 }
        }
        #expect(exact * 10 >= expected.count / 4 * 8 && far * 200 <= expected.count / 4)
        let third = ReaderTranslationPipelineService(
            translateBlocks: { blocks, _, _, _, _ in calls.append([blocks.count]); return blocks },
            diskCache: disk, observesMemoryWarnings: false)
        #expect(await third.cachedPage(cacheKey: "k") == nil)  // patches need the source
        #expect(try await third.translatePage(page, cacheKey: "k", settings: settings).fromCache)
        #expect(calls.ids.isEmpty)

        // A page without text stores no pixels: its row is a header, not a whole-page JPEG.
        let blank = try PipelinePageRaster(width: 512, height: 512, rgba: [UInt8](repeating: 255, count: 512 * 512 * 4)).image()
        let before = try await disk.statistics().payloadBytes
        #expect(try await first.translatePage(blank, cacheKey: "blank", settings: settings).image === blank)
        var stored: CGImage?
        for _ in 0..<500 where stored == nil {
            stored = await second.cachedPage(cacheKey: "blank", source: blank)
            if stored == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        #expect(stored != nil)
        #expect(try await disk.statistics().payloadBytes - before < 512)
    }

    /// A cancelled joiner returns at once; the shared page keeps running for the other consumer.
    @Test func cancelledJoinerReturnsWithoutStoppingTheSharedPage() async throws {
        let gate = PipelineGate()
        let (page, lookahead, visible) = try await joinedRequests(gate: gate, calls: PipelineSentIDs())
        visible.cancel()
        await #expect(throws: CancellationError.self) { try await visible.value }
        await gate.open()
        #expect(try await lookahead.value.image.width == page.width)
    }
}

actor PipelineGate {
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
