// Test-only v3 snapshot for paired performance and decision comparisons.
import CoreGraphics
import Foundation
import UIKit
@testable import Aidoku

/// Local lexical candidates plus deliberately conservative geometry. Never removes raw OCR.
enum ReaderSFXCorpusBaselineFilter {
    static let version = "japanese-sfx-v3-enclosed-background"
    static let contextVersion = "japanese-sfx-context-v2-strict"
    static let candidates = loadCandidates("JapaneseSFXCandidates")
    static let contextCandidates = loadCandidates("JapaneseSFXContextCandidates")
    // Build the union once, only when the optional setting is first used.
    static let expandedCandidates = candidates.union(contextCandidates)
    private static let edgePunctuation = CharacterSet(charactersIn: "!?！？.。…‥・·,、「」『』\"“”‘’()（）[]【】")

    private static func loadCandidates(_ resource: String) -> Set<String> {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(keys)
    }

    static func normalized(_ text: String) -> String {
        folded(text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func folded(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Unicode.Scalar in
            (0x3041...0x3096).contains(scalar.value) ? Unicode.Scalar(scalar.value + 0x60)! : scalar
        }
        return String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: edgePunctuation).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func apply(_ regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings) -> [ReaderTranslationRegion] {
        guard settings.filterJapaneseSFX, settings.sourceLanguage == "auto" || settings.sourceLanguage == "ja" else { return regions }
        if settings.filterJapaneseSFXContext {
            return filter(regions, candidates: expandedCandidates, contextualCandidates: contextCandidates)
        }
        return filter(regions, candidates: candidates)
    }

    private struct Features {
        let candidate: Bool
        let contextual: Bool
        let kanaOnly: Bool
        let japanese: Bool
        let count: Int
        let size: CGFloat
    }

    static func filter(
        _ regions: [ReaderTranslationRegion], candidates: Set<String>, contextualCandidates: Set<String> = []
    ) -> [ReaderTranslationRegion] {
        guard !candidates.isEmpty, !regions.isEmpty else { return regions }
        let features = regions.map { region in
            let text = region.source.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = folded(text)
            var kanaOnly = !text.isEmpty
            var japanese = false
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 0x3041...0x3096, 0x30A1...0x30FA:
                    japanese = true
                case 0x30FC, 0x301C, 0x7E, 0x21, 0xFF01, 0x2E, 0x3002, 0x2026, 0x2025, 0x30FB, 0xB7:
                    break
                default:
                    kanaOnly = false
                    if (0x3400...0x9FFF).contains(scalar.value) { japanese = true }
                }
            }
            let count = text.filter { !$0.isWhitespace }.count
            return Features(candidate: candidates.contains(key), contextual: contextualCandidates.contains(key),
                            kanaOnly: kanaOnly, japanese: japanese, count: count, size: thickness(region, characters: count))
        }
        guard features.contains(where: { $0.candidate && $0.kanaOnly }) else { return regions }
        // Keep every dictionary entry out of references/protectors, even when it survives.
        // Removing a candidate therefore cannot change the next filtering decision.
        let protectors = regions.indices.filter {
            !features[$0].candidate && features[$0].japanese && features[$0].size > 0 && regions[$0].confidence >= 0.5
        }
        let references = protectors.filter { features[$0].count >= 4 }
        guard references.count >= 3 else { return regions }
        let sizes = references.map { features[$0].size }.sorted()
        let median = sizes[sizes.count / 2]
        return regions.indices.compactMap { index in
            let region = regions[index]
            let feature = features[index]
            let ratio: CGFloat = feature.contextual ? 2.0 : 1.6
            let confidence = feature.contextual ? 0.8 : 0.5
            guard region.sfxEnclosedBackground != true, feature.candidate, feature.kanaOnly, region.confidence >= confidence,
                  feature.size >= median * ratio else { return region }
            let aspect = CGFloat(region.sourceImageAspectRatio ?? 1)
            // The three closest dialogue references protect enlarged text in a zoomed-in panel.
            // This is a local estimate, not a panel or balloon detector.
            var nearest: [(distance: CGFloat, size: CGFloat)] = []
            var nearestDialogueGap = CGFloat.infinity
            for ref in protectors {
                let rect = regions[ref].rect
                let dx = max(0, max(rect.minX - region.rect.maxX, region.rect.minX - rect.maxX)) * aspect
                let dy = max(0, max(rect.minY - region.rect.maxY, region.rect.minY - rect.maxY))
                nearestDialogueGap = min(nearestDialogueGap, max(dx, dy))
                guard features[ref].count >= 4 else { continue }
                let distance = dx * dx + dy * dy
                if nearest.count < 3 || distance < nearest[2].distance {
                    nearest.append((distance, features[ref].size))
                    nearest.sort { $0.distance < $1.distance }
                    if nearest.count > 3 { nearest.removeLast() }
                }
            }
            let localMedian = nearest.map(\.size).sorted()[1]
            guard feature.size >= max(median, localMedian) * ratio else { return region }
            // Short replies also protect nearby candidates; never infer a bubble's absence.
            let margin = min(0.02, max(median, localMedian) * 0.5)
            return nearestDialogueGap <= margin ? region : nil
        }
    }

    private static func thickness(_ region: ReaderTranslationRegion, characters: Int) -> CGFloat {
        let rect = region.rect
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return 0 }
        let aspect = CGFloat(region.sourceImageAspectRatio ?? 1)
        guard aspect.isFinite, aspect > 0 else { return 0 }
        // A merged balloon may contain several columns; its whole width is not a font size.
        let areaEstimate = sqrt(rect.width * aspect * rect.height / CGFloat(max(1, characters)))
        let crossAxis: CGFloat
        switch region.sourceOrientation {
        case .vertical: crossAxis = rect.width * aspect
        case .horizontal: crossAxis = rect.height
        default: crossAxis = min(rect.width * aspect, rect.height)
        }
        let size = min(crossAxis, areaEstimate)
        return size.isFinite ? size : 0
    }
}


/// Positive enclosed-background evidence only. Open/uncertain backgrounds add no removal evidence.
enum ReaderSFXCorpusBaselineImageEvidence {
    private struct Input: Equatable {
        let id: String
        let source: String
        let rect: CGRect
    }
    private final class Evidence {
        let inputs: [Input]
        let protectedIDs: Set<String>
        init(inputs: [Input], protectedIDs: Set<String>) {
            self.inputs = inputs
            self.protectedIDs = protectedIDs
        }
    }
    // Weak identity keys neither retain decoded page images nor confuse recycled image addresses.
    private static let cache = NSMapTable<UIImage, Evidence>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    private static let lock = NSLock()

    private static func samplingCandidates(_ regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings) -> [ReaderTranslationRegion] {
        guard settings.filterJapaneseSFX, settings.sourceLanguage == "auto" || settings.sourceLanguage == "ja" else { return [] }
        // Use the same reference population as the final filter, including language settings.
        var languageOnly = settings
        languageOnly.filterJapaneseSFX = false
        let eligible = ReaderTranslationLanguageFilter.apply(regions, settings: languageOnly)
        let kept = Set(ReaderSFXCorpusBaselineFilter.apply(eligible, settings: settings).map(\.id))
        return eligible.filter { !kept.contains($0.id) && $0.sfxEnclosedBackground == nil }
    }

    static func requiresSampling(_ regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings) -> Bool {
        !samplingCandidates(regions, settings: settings).isEmpty
    }

    static func apply(_ regions: [ReaderTranslationRegion], image: UIImage, pixels: CGImage,
                      settings: ReaderTranslationSettings) -> [ReaderTranslationRegion] {
        guard !Task.isCancelled else { return regions }
        let inputs = samplingCandidates(regions, settings: settings).prefix(16).map {
            Input(id: $0.id, source: $0.source, rect: $0.rect)
        }
        guard !inputs.isEmpty else { return regions }
        lock.lock()
        let previous = cache.object(forKey: image)
        lock.unlock()
        let evidence: Evidence
        if let previous, previous.inputs == inputs {
            evidence = previous
        } else {
            let size = CGSize(width: pixels.width, height: pixels.height)
            let groups = ReaderTranslationEnclosedBackground.enclosedRegionGroups(in: pixels,
                candidateInputs: inputs.map {
                    .init(id: $0.id, text: $0.source, rect: CGRect(x: $0.rect.minX * size.width,
                        y: $0.rect.minY * size.height, width: $0.rect.width * size.width, height: $0.rect.height * size.height))
                }, coordinateSize: size)
            guard !Task.isCancelled else { return regions }
            evidence = Evidence(inputs: inputs, protectedIDs: Set(groups.flatMap { $0 }))
            lock.lock()
            cache.setObject(evidence, forKey: image)
            lock.unlock()
        }
        let sampled = Set(inputs.map(\.id))
        return regions.map { region in
            guard sampled.contains(region.id) else { return region }
            var result = region
            result.sfxEnclosedBackground = evidence.protectedIDs.contains(region.id)
            return result
        }
    }
}
