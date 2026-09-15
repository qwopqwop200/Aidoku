import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderJapaneseSFXFilterTests {
    private var regions: [ReaderTranslationRegion] {
        (0..<3).map { i in ReaderTranslationRegion(id: "d\(i)", rect: CGRect(x: 0.05, y: 0.1 + Double(i) * 0.2, width: 0.2, height: 0.025), source: "今日は晴れですね") } +
        [ReaderTranslationRegion(id: "sfx", rect: CGRect(x: 0.7, y: 0.7, width: 0.15, height: 0.12), source: "ドン")]
    }

    @Test func dictionaryAndNormalization() {
        #expect(ReaderJapaneseSFXFilter.candidates.count == 14946)
        #expect(ReaderJapaneseSFXFilter.candidates.contains("ドン"))
        #expect(ReaderJapaneseSFXFilter.normalized("ｶﾞﾁｬ") == "ガチャ")
        #expect(ReaderJapaneseSFXFilter.normalized("どん！") == "ドン")
        #expect(ReaderJapaneseSFXFilter.normalized("ドーン") != "ドン")
        #expect(ReaderJapaneseSFXFilter.normalized("キャ") != "キヤ")
        #expect(ReaderJapaneseSFXFilter.speechSensitiveCandidates.count == 1676)
        #expect(ReaderJapaneseSFXFilter.speechSensitiveCandidates.contains("ウワア"))
    }

    @Test func visuallyCheckedCandidatesRecoverModerateAndNearbyOversizedEffects() {
        var input = regions
        input[3] = ReaderTranslationRegion(id: "sfx", rect: CGRect(x: 0.7, y: 0.7, width: 0.05, height: 0.045),
                                           source: "ドン", confidence: 0.95)
        // 1.34x the dialogue size: recovered only after sampling the actual page.
        #expect(ReaderJapaneseSFXFilter.filter(input, candidates: ["ドン"]) == input)
        #expect(ReaderJapaneseSFXFilter.filter(input, candidates: ["ドン"], preparingImageEvidence: true).count == 3)
        input[3].sfxEnclosedBackground = false
        #expect(ReaderJapaneseSFXFilter.filter(input, candidates: ["ドン"]).count == 3)
        input[3].sfxEnclosedBackground = true
        #expect(ReaderJapaneseSFXFilter.filter(input, candidates: ["ドン"]) == input)

        input = regions
        input[3] = ReaderTranslationRegion(id: "sfx", rect: CGRect(x: 0.26, y: 0.1, width: 0.15, height: 0.12),
                                           source: "ドン", confidence: 0.95)
        #expect(ReaderJapaneseSFXFilter.filter(input, candidates: ["ドン"]) == input)
        input[3].sfxEnclosedBackground = false
        let kept = ReaderJapaneseSFXFilter.filter(input, candidates: ["ドン"])
        #expect(kept.count == 3)
        #expect(ReaderJapaneseSFXFilter.filter(kept, candidates: ["ドン"]) == kept)
        input[3].confidence = 0.7
        #expect(ReaderJapaneseSFXFilter.filter(input, candidates: ["ドン"]) == input)
    }

    @Test func speechSensitiveExclamationsSurviveEvenWithoutAnEnclosedBalloon() {
        for text in ["うわあ", "よー", "フン！", "いや…"] {
            var input = regions
            input[3] = ReaderTranslationRegion(id: "speech", rect: regions[3].rect, source: text, confidence: 0.99)
            input[3].sfxEnclosedBackground = false
            #expect(ReaderJapaneseSFXFilter.filter(input, candidates: ReaderJapaneseSFXFilter.expandedCandidates,
                contextualCandidates: ReaderJapaneseSFXFilter.contextCandidates) == input)
        }
    }

    @Test func compatibilityExpandedPunctuationDoesNotShrinkPrintedFontSize() {
        var input = regions
        input[3] = ReaderTranslationRegion(id: "sfx", rect: CGRect(x: 0.7, y: 0.7, width: 0.06, height: 0.06),
                                           source: "ドン…", confidence: 0.95)
        input[3].sfxEnclosedBackground = false
        #expect(ReaderJapaneseSFXFilter.normalized(input[3].source) == "ドン")
        #expect(ReaderJapaneseSFXFilter.filter(input, candidates: ["ドン"]).count == 3)
    }

    @Test func filtersOnlyLargeIsolatedCandidatesAndIsIdempotent() {
        let output = ReaderJapaneseSFXFilter.filter(regions, candidates: ["ドン"])
        #expect(output.map(\.id) == ["d0", "d1", "d2"])
        #expect(ReaderJapaneseSFXFilter.filter(output, candidates: ["ドン"]) == output)
        var near = regions
        near[3] = ReaderTranslationRegion(id: "sfx", rect: CGRect(x: 0.26, y: 0.1, width: 0.15, height: 0.12), source: "ドン")
        #expect(ReaderJapaneseSFXFilter.filter(near, candidates: ["ドン"]) == near)
        #expect(ReaderJapaneseSFXFilter.filter([regions[3]], candidates: ["ドン"]).count == 1)
        for text in ["ドン？", "ドンです", "ドン\nドン", "ドン ドン", "BOOM", "응"] {
            var values = regions
            values[3] = ReaderTranslationRegion(id: "sfx", rect: regions[3].rect, source: text)
            #expect(ReaderJapaneseSFXFilter.filter(values, candidates: ["ドン"]) == values)
        }
    }

    @Test func togglePersistsAndSeparatesTranslationButNotOCR() throws {
        let name = "SFXTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let off = ReaderTranslationSettings(defaults: defaults)
        #expect(!off.filterJapaneseSFX)
        var on = off; on.filterJapaneseSFX = true
        try on.autosave(defaults: defaults)
        #expect(ReaderTranslationSettings(defaults: defaults).filterJapaneseSFX)
        #expect(!off.hasSameTranslation(as: on))
        #expect(TitleTranslation.cacheKey("title", kind: .manga, settings: off) == TitleTranslation.cacheKey("title", kind: .manga, settings: on))
        #expect(ReaderTranslationCacheIdentity.ocr(page: "p", settings: off) == ReaderTranslationCacheIdentity.ocr(page: "p", settings: on))
        #expect(ReaderTranslationCacheIdentity.translation(page: "p", settings: off) != ReaderTranslationCacheIdentity.translation(page: "p", settings: on))
        #expect(ReaderJapaneseSFXFilter.apply(regions, settings: off) == regions)
        #expect(ReaderJapaneseSFXFilter.apply(regions, settings: on).count == 3)
        on.sourceLanguage = "en"
        #expect(ReaderJapaneseSFXFilter.apply(regions, settings: on) == regions)
    }

    @Test func requestToggleAndCacheRoundTrip() async throws {
        let name = "SFXRequests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        let off = settings
        settings.filterJapaneseSFX = true
        #expect(try ReaderTranslationService.requests(regions: regions, settings: settings).flatMap(\.segments).contains { $0.text == "ドン" } == false)
        #expect(try ReaderTranslationService.requests(regions: regions, settings: off).flatMap(\.segments).contains { $0.text == "ドン" })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        try await cache.storeRegions(regions.map { region in var value = region; value.sfxEnclosedBackground = false; return value }, for: ReaderTranslationCacheIdentity.translation(page: "p", settings: off), kind: .translation, generation: 0)
        #expect(try await cache.translatedRegions(page: "p", settings: settings)?.count == 3)
        #expect(try await cache.translatedRegions(page: "p", settings: off)?.count == 4)
    }

    @Test func contextTogglePersistsFiltersRequestsAndSeparatesCaches() async throws {
        #expect(ReaderJapaneseSFXFilter.contextCandidates.count == 8587)
        #expect(ReaderJapaneseSFXFilter.candidates.isDisjoint(with: ReaderJapaneseSFXFilter.contextCandidates))
        #expect(ReaderJapaneseSFXFilter.expandedCandidates.count == 23533)
        #expect(ReaderJapaneseSFXFilter.contextCandidates.contains("ザワザワ"))
        let name = "SFXContext.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        #expect(!settings.filterJapaneseSFXContext)
        let off = settings
        settings.filterJapaneseSFXContext = true
        var input = regions
        input[3] = ReaderTranslationRegion(id: "context", rect: regions[3].rect, source: "ザワザワ")
        #expect(ReaderJapaneseSFXFilter.apply(input, settings: settings) == input)
        #expect(off.hasSameTranslation(as: settings))
        settings.filterJapaneseSFX = true
        let expanded = settings
        try expanded.autosave(defaults: defaults)
        #expect(ReaderTranslationSettings(defaults: defaults).filterJapaneseSFXContext)
        settings.filterJapaneseSFXContext = false
        let basic = settings
        #expect(ReaderJapaneseSFXFilter.apply(input, settings: basic) == input)
        let kept = ReaderJapaneseSFXFilter.apply(input, settings: expanded)
        #expect(kept.map(\.id) == ["d0", "d1", "d2"])
        #expect(ReaderJapaneseSFXFilter.apply(kept, settings: expanded) == kept)
        #expect(!basic.hasSameTranslation(as: expanded))
        #expect(ReaderTranslationCacheIdentity.ocr(page: "p", settings: basic) == ReaderTranslationCacheIdentity.ocr(page: "p", settings: expanded))
        #expect(ReaderTranslationCacheIdentity.translation(page: "p", settings: basic) != ReaderTranslationCacheIdentity.translation(page: "p", settings: expanded))
        #expect(TitleTranslation.cacheKey("title", kind: .manga, settings: basic) == TitleTranslation.cacheKey("title", kind: .manga, settings: expanded))
        #expect(try ReaderTranslationService.requests(regions: input, settings: expanded).flatMap(\.segments).contains { $0.text == "ザワザワ" } == false)
        #expect(try ReaderTranslationService.requests(regions: input, settings: basic).flatMap(\.segments).contains { $0.text == "ザワザワ" })
        var foreign = expanded
        foreign.sourceLanguage = "en"
        #expect(ReaderJapaneseSFXFilter.apply(input, settings: foreign) == input)
        var near = input
        near[3] = ReaderTranslationRegion(id: "context", rect: CGRect(x: 0.26, y: 0.1, width: 0.15, height: 0.12), source: "ザワザワ")
        #expect(ReaderJapaneseSFXFilter.apply(near, settings: expanded) == near)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        try await cache.storeRegions(input.map { region in var value = region; value.sfxEnclosedBackground = false; return value }, for: ReaderTranslationCacheIdentity.translation(page: "p", settings: off), kind: .translation, generation: 0)
        #expect(try await cache.translatedRegions(page: "p", settings: expanded)?.count == 3)
        #expect(try await cache.translatedRegions(page: "p", settings: basic)?.count == 4)
        #expect(try await cache.translatedRegions(page: "p", settings: off)?.count == 4)
    }

    @Test func shortRepliesProtectNearbySFX() {
        let reply = ReaderTranslationRegion(id: "reply", rect: CGRect(x: 0.64, y: 0.7, width: 0.055, height: 0.025), source: "はい")
        let input = regions + [reply]
        #expect(ReaderJapaneseSFXFilter.filter(input, candidates: ["ドン"]) == input)
    }

    @Test func localDialogueSizeProtectsZoomedPanels() {
        let distant = (0..<4).map { i in
            ReaderTranslationRegion(id: "small\(i)", rect: CGRect(x: 0.05, y: Double(i) * 0.15, width: 0.2, height: 0.025), source: "今日は晴れですね")
        }
        let near = [CGPoint(x: 0.5, y: 0.75), CGPoint(x: 0.75, y: 0.5), CGPoint(x: 0.75, y: 0.93)].enumerated().map { i, point in
            ReaderTranslationRegion(id: "large\(i)", rect: CGRect(origin: point, size: CGSize(width: 0.2, height: 0.07)), source: "今日はね")
        }
        let candidate = ReaderTranslationRegion(id: "word", rect: CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.08), source: "ドン")
        let input = distant + near + [candidate]
        #expect(ReaderJapaneseSFXFilter.filter(input, candidates: ["ドン"]) == input)
    }

    @Test func contextualCandidatesRequireStrongerEvidence() {
        var input = regions
        input[3] = ReaderTranslationRegion(id: "context", rect: CGRect(x: 0.7, y: 0.7, width: 0.09, height: 0.09), source: "ザワザワ")
        #expect(ReaderJapaneseSFXFilter.filter(input, candidates: ["ザワザワ"]).count == 3)
        #expect(ReaderJapaneseSFXFilter.filter(input, candidates: ["ザワザワ"], contextualCandidates: ["ザワザワ"]) == input)
        input[3] = ReaderTranslationRegion(id: "context", rect: regions[3].rect, source: "ザワザワ", confidence: 0.7)
        #expect(ReaderJapaneseSFXFilter.filter(input, candidates: ["ザワザワ"], contextualCandidates: ["ザワザワ"]) == input)
    }

    @Test func whitespaceAndInvalidGeometryAreHandledConservatively() {
        var input = regions
        input[3] = ReaderTranslationRegion(id: "sfx", rect: regions[3].rect, source: " どん！ \n")
        #expect(ReaderJapaneseSFXFilter.filter(input, candidates: ["ドン"]).count == 3)
        input[3] = ReaderTranslationRegion(id: "sfx", rect: CGRect(x: CGFloat.nan, y: 0.7, width: 0.15, height: 0.12), source: "ドン")
        #expect(ReaderJapaneseSFXFilter.filter(input, candidates: ["ドン"]).count == 4)
        let english = (0..<3).map { i in
            ReaderTranslationRegion(id: "en\(i)", rect: regions[i].rect, source: "Hello there")
        } + [regions[3]]
        #expect(ReaderJapaneseSFXFilter.filter(english, candidates: ["ドン"]) == english)
    }

    @Test func enclosedBalloonProtectsCandidateAndPersists() async throws {
        let name = "SFXVisual.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.filterJapaneseSFX = true
        func page(closed: Bool, outline: Bool = true) -> UIImage {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 1000), format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
                if outline {
                    context.cgContext.setStrokeColor(UIColor.black.cgColor)
                    context.cgContext.setLineWidth(6)
                    context.cgContext.strokeEllipse(in: CGRect(x: 620, y: 600, width: 330, height: 350))
                    if !closed { context.fill(CGRect(x: 910, y: 710, width: 60, height: 100)) }
                }
                ("ドン" as NSString).draw(at: CGPoint(x: 710, y: 720), withAttributes: [.font: UIFont.systemFont(ofSize: 50), .foregroundColor: UIColor.black])
            }
        }
        let closed = page(closed: true)
        #expect(ReaderJapaneseSFXFilter.apply(regions, settings: settings).count == 3)
        let start = CFAbsoluteTimeGetCurrent()
        let prepared = ReaderTranslationImagePreparation.apply(regions, image: closed, settings: settings)
        let firstMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        #expect(prepared[3].sfxEnclosedBackground == true)
        #expect(ReaderJapaneseSFXFilter.apply(prepared, settings: settings).count == 4)
        let repeatStart = CFAbsoluteTimeGetCurrent()
        let repeated = ReaderTranslationImagePreparation.apply(regions, image: closed, settings: settings)
        print("SFX visual timing: firstMs=\(firstMs) repeatedMs=\((CFAbsoluteTimeGetCurrent() - repeatStart) * 1000)")
        #expect(repeated == prepared)
        for image in [page(closed: false), page(closed: false, outline: false)] {
            let open = ReaderTranslationImagePreparation.apply(regions, image: image, settings: settings)
            #expect(open[3].sfxEnclosedBackground == false)
            #expect(ReaderJapaneseSFXFilter.apply(open, settings: settings).count == 3)
        }
        var disabled = settings; disabled.filterJapaneseSFX = false
        #expect(ReaderTranslationImagePreparation.apply(regions, image: closed, settings: disabled) == regions)
        let encoded = try JSONEncoder().encode(prepared.map(ReaderTranslationStoredRegion.init))
        let restored = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: encoded).map(\.region)
        #expect(restored[3].sfxEnclosedBackground == true)
        #expect(ReaderJapaneseSFXFilter.apply(restored, settings: settings).count == 4)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        try await cache.storeRegions(regions, for: ReaderTranslationCacheIdentity.unfilteredTranslation(page: "legacy", settings: disabled), kind: .translation, generation: 0)
        #expect(try await cache.translatedRegions(page: "legacy", settings: settings) == nil)
        var cachedPage = Page(sourceId: "sfx-visual", chapterId: "test", index: 0, image: closed)
        let rawKey = ReaderTranslationCacheIdentity.ocr(page: cachedPage.translationCacheKey, settings: settings)
        try await cache.storeRegions(regions, for: rawKey, kind: .ocr, generation: 0)
        let preloader = ReaderTranslationPreloader(diskCache: cache, translator: { input, _, _ in input }, recognizer: { _, _ in
            throw URLError(.unknown) // Cached OCR must be reused.
        })
        defer { preloader.cancel() }
        let output = try await preloader.translate(cachedPage, settings: settings)
        #expect(output.count == 4)
        #expect(output.last?.sfxEnclosedBackground == true)
        #expect(try await cache.regions(for: rawKey, kind: .ocr)?.last?.sfxEnclosedBackground == true)
        cachedPage.image = nil
        settings.targetLanguage = "en"
        let restarted = ReaderTranslationPreloader(diskCache: cache, translator: { input, _, _ in input })
        defer { restarted.cancel() }
        let reused = try await restarted.translate(cachedPage, settings: settings)
        #expect(reused.count == 4)
        #expect(reused.last?.sfxEnclosedBackground == true)

    }

    @Test func measureLocalFilteringCost() {
        let coldStart = CFAbsoluteTimeGetCurrent()
        let keys = ReaderJapaneseSFXFilter.expandedCandidates
        let loadMilliseconds = (CFAbsoluteTimeGetCurrent() - coldStart) * 1000
        let page = Array(repeating: regions, count: 25).flatMap { $0 }
        var samples: [Double] = []
        var keptCount = 0
        for _ in 0..<200 {
            let start = CFAbsoluteTimeGetCurrent()
            keptCount += ReaderJapaneseSFXFilter.filter(page, candidates: keys, contextualCandidates: ReaderJapaneseSFXFilter.contextCandidates).count
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        samples.sort()
        #expect(keptCount > 0)
        print("SFX timing: regions=100 runs=200 dictionaryAccessMs=\(loadMilliseconds) medianMs=\(samples[100]) p95Ms=\(samples[190])")
    }

    @Test func replayAvailableRealPages() throws {
        let folder = URL.documentsDirectory.appendingPathComponent("MangaQuality/real-before")
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let output = URL.documentsDirectory.appendingPathComponent("SFXValidation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var counts: [String: [String: Int]] = [:]
        var excluded: [String: [String]] = [:]
        let inputs = ["pepper-ja-1", "reference", "pepper-en-1", "pepper-fr-1", "pepper-es-1"].map { (folder, $0, "-regions.json") } +
            (0...6).map { (URL.documentsDirectory.appendingPathComponent("MangaQuality/sequence-current-ocr"), String(format: "sequence-%02d", $0), "-ocr.json") }
        for (inputFolder, name, suffix) in inputs {
            let file = inputFolder.appendingPathComponent(name + suffix)
            guard let data = try? Data(contentsOf: file), let image = UIImage(contentsOfFile: inputFolder.appendingPathComponent(name + "-source.png").path) else { continue }
            var raw = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: data).map(\.region)
            for i in raw.indices { raw[i].sourceImageAspectRatio = Double(image.size.width / image.size.height) }
            let kept = ReaderJapaneseSFXFilter.filter(raw, candidates: ReaderJapaneseSFXFilter.candidates)
            let visualDefaults = UserDefaults(suiteName: "SFXReplay.\(UUID())")!
            var visualSettings = ReaderTranslationSettings(defaults: visualDefaults)
            visualSettings.filterJapaneseSFX = true
            visualSettings.filterJapaneseSFXContext = true
            if name == "reference", let pixels = image.cgImage {
                let groups = ReaderTranslationEnclosedBackground.enclosedRegionGroups(in: pixels,
                    candidateInputs: raw.map { .init(id: $0.id, text: $0.source,
                        rect: CGRect(x: $0.rect.minX * image.size.width, y: $0.rect.minY * image.size.height,
                                     width: $0.rect.width * image.size.width, height: $0.rect.height * image.size.height)) },
                    coordinateSize: image.size)
                let ids = Set(groups.flatMap { $0 })
                let recognizedBalloons = raw.filter { ids.contains($0.id) }.map(\.source)
                print("SFX real enclosed backgrounds: \(recognizedBalloons)")
                #expect(!recognizedBalloons.isEmpty)
                #expect(!recognizedBalloons.contains("ぱん"))
            }
            let visualStart = CFAbsoluteTimeGetCurrent()
            let visual = ReaderTranslationImagePreparation.apply(raw, image: image, settings: visualSettings)
            print("SFX visual replay: \(name) ms=\((CFAbsoluteTimeGetCurrent() - visualStart) * 1000) protected=\(visual.filter { $0.sfxEnclosedBackground == true }.count)")
            let expanded = ReaderJapaneseSFXFilter.filter(visual, candidates: ReaderJapaneseSFXFilter.expandedCandidates, contextualCandidates: ReaderJapaneseSFXFilter.contextCandidates)
            let ids = Set(expanded.map(\.id))
            excluded[name] = raw.filter { !ids.contains($0.id) }.map(\.source)
            #expect(ReaderJapaneseSFXFilter.filter(expanded, candidates: ReaderJapaneseSFXFilter.expandedCandidates, contextualCandidates: ReaderJapaneseSFXFilter.contextCandidates) == expanded)
            #expect(kept.allSatisfy { raw.contains($0) })
            #expect(ReaderJapaneseSFXFilter.filter(kept, candidates: ReaderJapaneseSFXFilter.candidates) == kept)
            counts[name] = ["raw": raw.count, "kept": kept.count, "excluded": raw.count - kept.count, "expandedExcluded": raw.count - expanded.count]
            let rendered = UIGraphicsImageRenderer(size: image.size).image { context in
                image.draw(at: .zero)
                for r in raw {
                    context.cgContext.setStrokeColor((ids.contains(r.id) ? UIColor.systemBlue : .systemRed).cgColor)
                    context.cgContext.setLineWidth(3)
                    context.cgContext.stroke(CGRect(x: r.rect.minX * image.size.width, y: r.rect.minY * image.size.height, width: r.rect.width * image.size.width, height: r.rect.height * image.size.height))
                }
            }
            try rendered.pngData()?.write(to: output.appendingPathComponent(name + "-audit.png"))
        }
        #expect(counts.count >= 3)
        try JSONEncoder().encode(excluded).write(to: output.appendingPathComponent("excluded.json"))
        print("SFX validation output: \(output.path)")
        try JSONEncoder().encode(counts).write(to: output.appendingPathComponent("counts.json"))
    }
}
