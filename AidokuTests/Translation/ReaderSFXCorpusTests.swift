import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderSFXCorpusTests {
    private nonisolated static var folder: URL { URL.documentsDirectory.appendingPathComponent("SFXCorpus") }
    @Test(.enabled(if: FileManager.default.fileExists(atPath: folder.appendingPathComponent("run.json").path)))
    func exportJapaneseCorpus() async throws {
        let root = Self.folder
        let run = try JSONDecoder().decode(Run.self, from: Data(contentsOf: root.appendingPathComponent("run.json")))
        let output = root.appendingPathComponent(run.label)
        let ocr = root.appendingPathComponent("ocr")
        for url in [output, ocr] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let suite = "SFXCorpus.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.sourceLanguage = "ja"
        settings.filterSFXWithLLM = false
        settings.rightToLeftPanelOrder = false
        settings.filterJapaneseSFX = true
        if run.label != "baseline-v3" { #expect(ReaderJapaneseSFXFilter.speechSensitiveCandidates.count == 1676) }
        await ReaderOCRService.shared.purge()
        for (index, fixture) in run.fixtures.enumerated() {
            try Task.checkCancellation()
            let data = try Data(contentsOf: root.appendingPathComponent(fixture.image))
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == fixture.sha256)
            let image = try #require(UIImage(data: data))
            let pixels = try #require(image.cgImage)
            let rawFile = ocr.appendingPathComponent(fixture.id + ".json")
            var raw: [ReaderTranslationRegion]
            let start = CFAbsoluteTimeGetCurrent()
            if let cached = try? Data(contentsOf: rawFile) {
                raw = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: cached).map(\.region)
            } else {
                raw = try await ReaderOCRService.shared.recognize(image: pixels, configuration: ReaderOCRConfiguration(modelTier: .medium))
                try JSONEncoder().encode(raw.map(ReaderTranslationStoredRegion.init)).write(to: rawFile, options: .atomic)
            }
            let ocrMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            for i in raw.indices { raw[i].sfxEnclosedBackground = nil }
            settings.filterJapaneseSFXContext = false
            let filterStart = CFAbsoluteTimeGetCurrent()
            let basicInput = ReaderTranslationImagePreparation.apply(raw, image: image, settings: settings)
            let basic = ReaderTranslationLanguageFilter.apply(basicInput, settings: settings)
            settings.filterJapaneseSFXContext = true
            let expandedInput = ReaderTranslationImagePreparation.apply(raw, image: image, settings: settings)
            let expanded = ReaderTranslationLanguageFilter.apply(expandedInput, settings: settings)
            let filterMs = (CFAbsoluteTimeGetCurrent() - filterStart) * 1000
            var languageOnly = settings
            languageOnly.filterJapaneseSFX = false
            let eligible = ReaderTranslationLanguageFilter.apply(raw, settings: languageOnly)
            let legacyInput = ReaderSFXCorpusBaselineImageEvidence.apply(eligible, image: image, pixels: pixels, settings: settings)
            let legacy = ReaderSFXCorpusBaselineFilter.apply(legacyInput, settings: settings)
            var paired: [[Double]] = [[], []]
            var cold: [[Double]] = [[], []]
            // Both paths receive the same already-recognized regions and image. Alternate
            // order to reduce systematic warm-up bias; include preparation/cache lookup.
            for iteration in 0..<10 {
                for version in (iteration.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
                    let begin = CFAbsoluteTimeGetCurrent()
                    if version == 0 {
                        let input = ReaderSFXCorpusBaselineImageEvidence.apply(eligible, image: image, pixels: pixels, settings: settings)
                        _ = ReaderSFXCorpusBaselineFilter.apply(input, settings: settings)
                    } else {
                        let input = ReaderJapaneseSFXImageEvidence.apply(eligible, image: image, pixels: pixels, settings: settings)
                        _ = ReaderJapaneseSFXFilter.apply(input, settings: settings)
                    }
                    paired[version].append((CFAbsoluteTimeGetCurrent() - begin) * 1000)
                }
            }
            for iteration in 0..<4 {
                for version in (iteration.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
                    let freshImage = UIImage(cgImage: pixels)
                    let begin = CFAbsoluteTimeGetCurrent()
                    if version == 0 {
                        let input = ReaderSFXCorpusBaselineImageEvidence.apply(eligible, image: freshImage, pixels: pixels, settings: settings)
                        _ = ReaderSFXCorpusBaselineFilter.apply(input, settings: settings)
                    } else {
                        let input = ReaderJapaneseSFXImageEvidence.apply(eligible, image: freshImage, pixels: pixels, settings: settings)
                        _ = ReaderJapaneseSFXFilter.apply(input, settings: settings)
                    }
                    cold[version].append((CFAbsoluteTimeGetCurrent() - begin) * 1000)
                }
            }
            #expect(ReaderJapaneseSFXFilter.apply(expanded, settings: settings) == expanded)
            // Offline audit also samples exact lexical candidates that the current size gate keeps.
            let lexical = raw.filter { ReaderJapaneseSFXFilter.expandedCandidates.contains(ReaderJapaneseSFXFilter.normalized($0.source)) }
            let size = CGSize(width: pixels.width, height: pixels.height)
            let enclosed = ReaderTranslationEnclosedBackground.enclosedRegionGroups(in: pixels,
                candidateInputs: lexical.map { .init(id: $0.id, text: $0.source, rect: CGRect(
                    x: $0.rect.minX * size.width, y: $0.rect.minY * size.height,
                    width: $0.rect.width * size.width, height: $0.rect.height * size.height)) }, coordinateSize: size)
            let report = Result(id: fixture.id, basicKept: basic.map(\.id), expandedKept: expanded.map(\.id),
                lexical: lexical.map(\.id), enclosed: enclosed.flatMap { $0 }, ocrMs: ocrMs, filterMs: filterMs,
                languageOnlyKept: eligible.map(\.id), legacyExpandedKept: legacy.map(\.id),
                baselineWarmMs: paired[0], candidateWarmMs: paired[1],
                baselineColdMs: cold[0], candidateColdMs: cold[1],
                sampled: expandedInput.filter { $0.sfxEnclosedBackground != nil }.map(\.id))
            try JSONEncoder().encode(report).write(to: output.appendingPathComponent(fixture.id + ".json"), options: .atomic)
            print("SFXCorpus \(index + 1)/\(run.fixtures.count) \(fixture.id) regions=\(raw.count) lexical=\(lexical.count) ocrMs=\(Int(ocrMs))")
        }
        await ReaderOCRService.shared.purge()
        print("SFXCorpus output: \(root.path)")
    }
    private struct Run: Decodable { let label: String; let fixtures: [Fixture] }
    private struct Fixture: Decodable { let id: String; let image: String; let sha256: String }
    private struct Result: Encodable {
        let id: String; let basicKept: [String]; let expandedKept: [String]
        let lexical: [String]; let enclosed: [String]; let ocrMs: Double; let filterMs: Double
        let languageOnlyKept: [String]; let legacyExpandedKept: [String]
        let baselineWarmMs: [Double]; let candidateWarmMs: [Double]
        let baselineColdMs: [Double]; let candidateColdMs: [Double]
        let sampled: [String]
    }
}
