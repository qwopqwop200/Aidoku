import UIKit

/// Positive enclosed-background evidence only. Open/uncertain backgrounds add no removal evidence.
enum ReaderJapaneseSFXImageEvidence {
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
        let kept = Set(ReaderJapaneseSFXFilter.apply(eligible, settings: settings, preparingImageEvidence: true).map(\.id))
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
