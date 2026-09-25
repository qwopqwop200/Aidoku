import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Golden oracle frozen from baseline formatter implementation before the fast-hex change.
/// Intentionally independent of production digest/encoded; no persistent key version changes.
@Suite(.serialized) @MainActor
struct ReaderTranslationDigestEquivalenceTests {
    @Test func knownSHA256Fixtures() {
        let fixtures = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("The quick brown fox jumps over the lazy dog", "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
        ]
        for (input, golden) in fixtures {
            #expect(ReaderTranslationCacheIdentity.digest(input) == golden)
            #expect(ReaderTranslationCacheIdentity.digest(Data(input.utf8)) == golden)
        }
    }

    @Test func everyInputByteAndLeadingZeroDigestsRemainExact() {
        for value in UInt16(0)...255 {
            let input = Data([UInt8(value)])
            let expected = FrozenFormatterIdentity.digest(input)
            let actual = ReaderTranslationCacheIdentity.digest(input)
            #expect(actual == expected, "Single input byte: \(value)")
            #expect(actual.utf8.count == 64)
            #expect(actual.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        }
        // Concatenated full byte domain also rejects ordering/truncation errors.
        let allBytes = Data((0...255).map(UInt8.init))
        #expect(ReaderTranslationCacheIdentity.digest(allBytes) == FrozenFormatterIdentity.digest(allBytes))
        // Known input whose SHA256 starts with 00: exact comparison must retain both zeros.
        let leadingZeroInput = Data("286".utf8)
        #expect(FrozenFormatterIdentity.digest(leadingZeroInput).hasPrefix("00"))
        #expect(ReaderTranslationCacheIdentity.digest(leadingZeroInput) == FrozenFormatterIdentity.digest(leadingZeroInput))
    }

    @Test func utf8AndSortedJSONInputsRemainUnchanged() {
        for text in ["한국어/日本語?x=1#fragment", "\u{0000}\n\r\t", "-0.0", "local|chapter|0001"] {
            #expect(ReaderTranslationCacheIdentity.digest(text) == FrozenFormatterIdentity.digest(text))
        }
        let first = ["z": "last", "a": "first"]
        var second: [String: String] = [:]; second["a"] = "first"; second["z"] = "last"
        #expect(ReaderTranslationCacheIdentity.encoded(first) == FrozenFormatterIdentity.encoded(first))
        #expect(ReaderTranslationCacheIdentity.encoded(second) == FrozenFormatterIdentity.encoded(first))
        #expect(ReaderTranslationCacheIdentity.encoded(["-0.0", "0.0"]) == FrozenFormatterIdentity.encoded(["-0.0", "0.0"]))
    }

    @Test func persistedOCRTranslationAndRenderKeyContractsRemainExact() throws {
        let suite = "DigestEquivalence-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.includePageImage = false
        for variant in 0..<3 {
            settings.credentialGeneration = UInt64(variant)
            settings.rightToLeftPanelOrder = variant == 1
            settings.targetLanguage = variant == 2 ? "ja" : "ko"
            settings.overlay.opacity = variant == 2 ? 0.5 : 0.84
            let page = "local/chapter-\(variant)|0"
            #expect(ReaderTranslationCacheIdentity.ocr(page: page, settings: settings) == FrozenFormatterIdentity.ocr(page: page, settings: settings))
            #expect(ReaderTranslationCacheIdentity.translation(page: page, settings: settings) == FrozenFormatterIdentity.translation(page: page, settings: settings))
            let size = CGSize(width: 640, height: 960)
            let viewport = CGSize(width: 240.125, height: 360.25)
            let crop = variant == 1 ? CGRect(x: 0.5, y: 0, width: 0.5, height: 1) : CGRect(x: 0, y: 0, width: 1, height: 1)
            let actual = ReaderTranslationCacheIdentity.render(page: page, settings: settings, imageSize: size, viewport: viewport,
                scale: CGFloat(variant + 1), aspectFit: variant != 2, crop: crop, dark: variant == 2)
            let expected = FrozenFormatterIdentity.render(page: page, settings: settings, imageSize: size, viewport: viewport,
                scale: CGFloat(variant + 1), aspectFit: variant != 2, crop: crop, dark: variant == 2)
            #expect(actual == expected)
        }
    }
}

private enum FrozenFormatterIdentity {
    static func digest(_ value: String) -> String { digest(Data(value.utf8)) }
    static func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    static func encoded<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return digest((try? encoder.encode(value)) ?? Data())
    }
    static func ocr(page: String, settings: ReaderTranslationSettings) -> String {
        // OCR entries contain merged regions. A merger change must also
        // invalidate derived translations/layouts instead of replaying old boxes.
        encoded(["reader-ocr-v57-fp16-detector", page, encoded(settings.ocrConfiguration)])
    }
    static func translation(page: String, settings: ReaderTranslationSettings) -> String {
        let previous = unfilteredTranslation(page: page, settings: settings)
        let base = settings.rightToLeftPanelOrder ? encoded([previous, ReaderTranslationPanelOrder.cacheVersion]) : previous
        guard let filter = ReaderTranslationLanguageFilter.identity(settings: settings) else { return base }
        return encoded([base] + filter)
    }
    static func unfilteredTranslation(page: String, settings: ReaderTranslationSettings) -> String {
        let config = settings.configuration
        return encoded([
            "reader-translation-v2-neighbor-context", ocr(page: page, settings: settings), config.provider.rawValue, config.apiProtocol.rawValue,
            config.baseURL, config.model, config.credentialAccount, String(config.credentialGeneration), config.reasoningEffort.rawValue,
            config.instructions, settings.sourceLanguage, settings.targetLanguage
        ] + (settings.includePageImage ? ["page-image-v2-auto-fallback", String(TranslationImageSupport.shared.revision(for: config))] : []) + (settings.filterSFXWithLLM ? [settings.shouldAttachPageImage ? TranslationHTTPCodec.sfxPolicy : TranslationHTTPCodec.textOnlySFXPolicy] : []) + (settings.filterBackgroundWithLLM ? [settings.shouldAttachPageImage ? TranslationHTTPCodec.backgroundPolicy : TranslationHTTPCodec.textOnlyBackgroundPolicy] : []))
    }
    // Every geometry/appearance input must be included to reject stale pixels after a reader change.
    // swiftlint:disable:next function_parameter_count
    static func render(page: String, settings: ReaderTranslationSettings, imageSize: CGSize, viewport: CGSize,
                       scale: CGFloat, aspectFit: Bool, crop: CGRect, dark: Bool) -> String {
        // Auto Layout rounds view edges to display pixels. Mathematical prefetch
        // sizes differ by tiny fractions (568.016 pt vs 568 pt); those are one raster.
        let pixelScale = max(1, scale)
        let viewport = CGSize(width: (viewport.width * pixelScale).rounded() / pixelScale,
                              height: (viewport.height * pixelScale).rounded() / pixelScale)
        return encoded([
            "reader-render-v106-paper-outline", translation(page: page, settings: settings), encoded(settings.overlay),
            encoded(imageSize), encoded(viewport), String(Double(scale)), String(aspectFit), encoded(crop), String(dark),
            "balanced-columns-v15-visible-balloon-fit", "source-rotation-v7-native-balloon-fit",
            ProcessInfo.processInfo.operatingSystemVersionString
        ])
    }
}
