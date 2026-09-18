import Foundation
import Testing
@testable import Aidoku

struct UpscaleLocalizationTests {
    @Test func bundledDescriptionsUseEveryLocaleAndPreserveAttribution() async throws {
        let catalog = await ModelManager.shared.bundledModels()
        #expect(catalog.count == 5)
        let locales = Bundle.main.localizations.filter { $0 != "Base" }
        #expect(locales.count == 41)
        for locale in locales {
            let url = try #require(Bundle.main.url(forResource: locale, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: url))
            for model in catalog {
                let original = try #require(model.info)
                let localized = try #require(model.localizedInfo(bundle: bundle))
                let originalParts = original.components(separatedBy: "\n\n")
                let localizedParts = localized.components(separatedBy: "\n\n")
                #expect(!localized.hasPrefix("UPSCALE_MODEL_"))
                #expect(!localizedParts[0].isEmpty)
                #expect(Array(localizedParts.dropFirst()) == Array(originalParts.dropFirst()))
                if locale != "en" {
                    #expect(localizedParts[0] != originalParts[0])
                }
            }
        }
    }

    @Test func remoteModelWithBundledFilenameKeepsItsOwnDescription() async throws {
        var model = try #require(await ModelManager.shared.bundledModels().first)
        model.bundledResource = nil
        model.info = "Remote model description\n\nRemote attribution"
        let url = try #require(Bundle.main.url(forResource: "fr", withExtension: "lproj"))
        let bundle = try #require(Bundle(url: url))
        #expect(model.localizedInfo(bundle: bundle) == model.info)
        model.infoKO = "원격 모델 설명"
        let koreanURL = try #require(Bundle.main.url(forResource: "ko", withExtension: "lproj"))
        let koreanBundle = try #require(Bundle(url: koreanURL))
        #expect(model.localizedInfo(bundle: koreanBundle) == model.infoKO)
    }

    @Test func missingLocalizationKeepsTheOriginalModelDescription() async throws {
        var model = try #require(await ModelManager.shared.bundledModels().first)
        model.info = "Original model description\n\nAuthor · License\nhttps://example.org/model"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpscaleLocalization-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try #require(Bundle(url: directory))
        #expect(model.localizedInfo(bundle: bundle) == model.info)
    }
}
