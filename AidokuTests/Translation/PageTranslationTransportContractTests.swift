import Foundation
import Testing
import UIKit
@testable import Aidoku

@MainActor
struct PageTranslationTransportContractTests {
    @available(iOS 18.0, *)
    @Test(arguments: [RemoteTranslationProtocol.responses, .chatCompletions])
    func preparedPageOmitsInternalContourEvidence(apiProtocol: RemoteTranslationProtocol) async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let page = try ReaderTranslationImagePreparation.preparedPage(image)
        let identity = try #require(page.sourceIdentity)
        let bounds = [0.125, 0.25, 0.25, 0.5]
        var region = ReaderTranslationRegion(id: "bound", rect: CGRect(x: bounds[0], y: bounds[1],
            width: bounds[2], height: bounds[3]), source: "これは日本語の文章です")
        region.sourceRoleEvidence = TranslationBackgroundRolePolicy.make(source: region.source, bounds: bounds,
            imageIdentity: identity, contour: .init(bounds: bounds, spans: [0.125, 0.375],
                verified: nil, modelEstimated: false), rf: nil)
        let transport = ContractTransport(failure: .malformed)
        let service = ReaderTranslationService(client: RemoteTranslationClient(
            credentialStore: ContractCredential(), transport: transport))
        // Inspect an actual reader/client request even though this mock intentionally rejects its reply.
        await #expect(throws: RemoteTranslationError.self) {
            _ = try await service.translate(regions: [region], settings: settings(apiProtocol: apiProtocol), preparedPage: page)
        }
        #expect(await transport.requests.count == 1)
        let request = try #require(await transport.requests.first)
        let encodedBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: encodedBody) as? [String: Any])
        let messages = try #require(body[apiProtocol == .responses ? "input" : "messages"] as? [[String: Any]])
        let parts = try #require(messages.first { $0["role"] as? String == "user" }?["content"] as? [[String: Any]])
        #expect(parts.count == 2)
        let text = try #require(parts.compactMap { $0["text"] as? String }.first)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let segments = try #require(payload["segments"] as? [[String: Any]])
        #expect(segments.first?["role_evidence"] == nil)
        #expect(segments.first?["box_2d"] as? [Int] == [250, 125, 750, 375])
        #expect(!String(decoding: try #require(request.httpBody), as: UTF8.self)
            .contains("contour=observed enclosing outline"))
    }

    @Test(arguments: [RemoteTranslationProtocol.responses, .chatCompletions], [1, 2])
    func pageFailuresNeverSplitOrRetry(apiProtocol: RemoteTranslationProtocol, count: Int) async throws {
        for failure in ContractTransport.Failure.allCases {
            let transport = ContractTransport(failure: failure)
            let client = RemoteTranslationClient(credentialStore: ContractCredential(), transport: transport)
            let service = ReaderTranslationService(client: client)
            let settings = settings(apiProtocol: apiProtocol)
            let regions = (0..<count).map {
                ReaderTranslationRegion(id: "region-\($0)", rect: .zero,
                    source: "これは日本語で書かれた文章なので韓国語に翻訳する必要があります")
            }
            await #expect(throws: RemoteTranslationError.self) {
                _ = try await service.translate(regions: regions, settings: settings,
                    preparedImageJPEG: Data([1, 2, 3]))
            }
            // Count actual transport invocations through reader + service + client,
            // including both multi-segment splitting and singleton repair paths.
            #expect(await transport.requests.count == 1, "Unexpected retry for \(failure)")
        }
    }

    @Test(arguments: [RemoteTranslationProtocol.responses, .chatCompletions])
    func metadataHasIndependentTextOnlyTransportAndCache(apiProtocol: RemoteTranslationProtocol) async throws {
        let transport = ContractTransport()
        let service = ReaderTranslationService(client: RemoteTranslationClient(
            credentialStore: ContractCredential(), transport: transport))
        let settings = settings(apiProtocol: apiProtocol)
        let regions = [ReaderTranslationRegion(id: "title", rect: .zero, source: "これは物語の題名です")]
        let result = try await service.translateMetadata(regions: regions, settings: settings)
        #expect(result.first?.id == "title")
        #expect(result.first?.translation == "번역된 제목")
        _ = try await service.translateMetadata(regions: regions, settings: settings)
        #expect(await transport.requests.count == 1)
        let request = try #require(await transport.requests.first)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("Metadata context for this test"))
        for visualField in ["input_image", "image_url", "is_sfx", "text_role", "editorial_role"] {
            #expect(!body.contains(visualField))
        }
        // The exception is internal to metadata; the same settings cannot
        // accidentally authorize a page request without its required image.
        await #expect(throws: RemoteTranslationError.self) {
            _ = try await service.translate(regions: regions, settings: settings)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func metadataRetainsExistingFormatRepair() async throws {
        let transport = ContractTransport(failsFirstRequest: true)
        let service = ReaderTranslationService(client: RemoteTranslationClient(
            credentialStore: ContractCredential(), transport: transport))
        let result = try await service.translateMetadata(regions: [
            .init(id: "first", rect: .zero, source: "これは最初の題名です"),
            .init(id: "second", rect: .zero, source: "これは次の題名です")
        ], settings: settings(apiProtocol: .responses))
        #expect(result.map(\.id) == ["first", "second"])
        #expect(result.map(\.translation) == ["번역된 제목", "번역된 제목"])
        // One malformed metadata batch retains the existing two-part repair.
        #expect(await transport.requests.count == 3)
    }

    private func settings(apiProtocol: RemoteTranslationProtocol) -> ReaderTranslationSettings {
        var settings = ReaderTranslationSettings()
        settings.provider = .custom
        settings.custom.baseURL = "https://translation-contract.invalid/v1"
        settings.custom.apiProtocol = apiProtocol
        settings.model = "contract-test"
        settings.reasoningEffort = .none
        settings.sourceLanguage = "ja"
        settings.targetLanguage = "ko"
        settings.usesOCRLanguagePolicy = false
        settings.translationSourceLanguages = []
        settings.includePageImage = true
        settings.filterSFXWithLLM = true
        settings.filterBackgroundWithLLM = true
        settings.metadataInstructions = "\nMetadata context for this test"
        return settings
    }
}

@Suite(.serialized) @MainActor
struct ReaderTranslationFixtureLatencyTests {
    @Test func receivedPageBytesToReadyTranslatedImage() async throws {
        let bundle = Bundle(for: LatencyFixtureBundle.self)
        let fixture = try #require(bundle.url(forResource: "VerticalSingleGlyphBalloon", withExtension: "png"))
        let bytes = try Data(contentsOf: fixture)
        let otherFixture = try #require(bundle.url(forResource: "NativeClosedBalloonExclusion", withExtension: "bin"))
        var otherPixels = NativeRestorationPixels(width: 142, height: 240)
        otherPixels.rgba = Array(try Data(contentsOf: otherFixture))
        try #require(otherPixels.rgba.count == 142 * 240 * 4)
        let otherCrop = try #require(otherPixels.image())
        let otherBytes = try #require(UIImage(cgImage: otherCrop).pngData())
        try #require(bytes != otherBytes)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = ReaderTranslationDiskCache(directory: root)
        defer { Task { try? await disk.clear() } }
        let cache = ReaderTranslationRenderCache(disk: disk)
        defer { cache.clearMemory() }
        let transport = ContractTransport(pageReply: "빨리 움직여!")
        let service = ReaderTranslationService(client: RemoteTranslationClient(credentialStore: ContractCredential(), transport: transport))
        let preloader = ReaderTranslationPreloader(diskCache: disk, translationService: service)
        var settings = ReaderTranslationSettings()
        settings.provider = .custom
        settings.custom.baseURL = "https://fixture-latency.invalid/v1"
        settings.custom.apiProtocol = .responses
        settings.model = "fixture"
        settings.sourceLanguage = "ja"
        settings.targetLanguage = "ko"
        settings.usesOCRLanguagePolicy = false
        settings.translationSourceLanguages = []
        settings.includePageImage = true
        settings.filterSFXWithLLM = true
        settings.filterBackgroundWithLLM = true
        settings.ocr = .init(modelTier: .manga)
        settings.overlay = ReaderTranslationSettings.defaultOverlay
        func page(_ index: Int) -> Page { Page(sourceId: "latency-fixture", chapterId: root.lastPathComponent, index: index) }
        let first = page(0)
        let firstIdentity = ReaderTranslationCacheIdentity.translation(page: first.translationCacheKey, settings: settings)
        cache.setNearbyPages(pageKeys: [first.translationCacheKey], settings: settings)

        // The timed boundary starts with the selected crop's compressed PNG bytes in RAM.
        // Production lookups/writes remain in path. The local transport introduces no external wait.
        func render(_ phase: String, page: Page, png: Data, name: String) async throws -> (UIImage, UIImage, ReaderTranslationRegionArchive.Record) {
            let identity = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings)
            let start = CACurrentMediaTime()
            let source = try #require(UIImage(data: png)?.preparingForDisplay())
            let decoded = CACurrentMediaTime()
            var loadedPage = page
            loadedPage.image = source
            let record = try await preloader.translateRecord(loadedPage, settings: settings)
            let translated = CACurrentMediaTime()
            let key = ReaderTranslationCacheIdentity.render(page: page.translationCacheKey, settings: settings,
                imageSize: source.size, viewport: source.size, scale: 1, aspectFit: true, crop: ReaderTranslationSplitGeometry.unit, dark: false)
            let output = try await ReaderTranslationImageExporter.renderLoadedPresentation(
                image: source, regions: record.regions, settings: settings, viewport: source.size,
                scale: 1, aspectFit: true, dark: false, host: nil, cache: cache, key: key, pageIdentity: identity)
            let ready = CACurrentMediaTime()
            print("READER_FIXTURE_READY phase=\(phase) fixture=\(name) " +
                "width=\(Int(source.size.width)) height=\(Int(source.size.height)) regions=\(record.regions.count) " +
                "decode_ms=\((decoded-start)*1000) translate_ms=\((translated-decoded)*1000) " +
                "render_ms=\((ready-translated)*1000) total_ms=\((ready-start)*1000) network_wait_ms=0")
            return (source, output.image, record)
        }

        let (source, cold, record) = try await render("cold_page_cache", page: first, png: bytes, name: "VerticalSingleGlyphBalloon")
        try #require(record.sourceRasterClaim != nil && record.regions.contains { $0.translation == "빨리 움직여!" })
        let coldRequests = await transport.requests.count
        try #require(coldRequests == 1)
        // A completed foreground record is normally persisted by the session after delivery.
        let generation = await disk.currentGeneration(settings: settings)
        try await disk.storeRegions(record.regions, for: firstIdentity, kind: .translation,
                                    generation: generation, sourceRasterClaim: record.sourceRasterClaim)
        let (_, warm, reused) = try await render("warm_translation_disk_bitmap_ram", page: first, png: bytes, name: "VerticalSingleGlyphBalloon")
        #expect(await transport.requests.count == coldRequests)
        #expect(reused.sourceRasterClaim == record.sourceRasterClaim)
        try #require(reused.regions.count == record.regions.count)
        for (live, loaded) in zip(record.regions, reused.regions) {
            // OCR keeps detector receipts and original member records in memory. The
            // archive retains the exact member polygons consumed by a restored page.
            var expected = live
            expected.acceptedSource = .init()
            expected.detectorSeedEvidence = nil
            expected.cachedSourceMemberPolygons = live.sourceMemberPolygons
            #expect(loaded == expected)
            #expect(loaded.sourceMemberPolygons == live.sourceMemberPolygons)
            print("READER_FIXTURE_ARCHIVE acceptedSourceChanged=\(live.acceptedSource != loaded.acceptedSource) " +
                "seedEvidenceChanged=\(live.detectorSeedEvidence != loaded.detectorSeedEvidence) " +
                "cachedMemberBackingChanged=\(live.cachedSourceMemberPolygons != loaded.cachedSourceMemberPolygons)")
        }
        #expect(ReaderTranslationRegion.layoutItems(reused.regions, imageSize: source.size) ==
                ReaderTranslationRegion.layoutItems(record.regions, imageSize: source.size))
        #expect(warm === cold, "The validated loaded-page cache must return the exact completed bitmap")
        let comparison = try RecordedTranslationReplay.decodedPixelComparison(actual: #require(cold.cgImage), reference: #require(source.cgImage))
        #expect(comparison["equalDecodedPixels"] as? Bool == false)

        // A different page and a different source under the same resident models.
        // Repeat with a fresh page key and an empty provider-response cache to
        // compare two independently rendered outputs from the same second crop.
        func renderNewPage(_ index: Int, phase: String) async throws -> (UIImage, ReaderTranslationRegionArchive.Record) {
            let candidate = page(index)
            let key = candidate.translationCacheKey
            try #require(key != first.translationCacheKey)
            cache.setNearbyPages(pageKeys: [key], settings: settings)
            let identity = ReaderTranslationCacheIdentity.translation(page: key, settings: settings)
            let ocrKey = ReaderTranslationCacheIdentity.ocr(page: key, settings: settings)
            try #require(try await disk.contains(ocrKey, kind: .ocr) == false)
            try #require(try await disk.translatedRegionRecord(page: key, settings: settings) == nil)
            try #require(cache.needsImage(for: identity))
            let before = await transport.requests.count
            let (original, result, current) = try await render(phase, page: candidate, png: otherBytes, name: "NativeClosedBalloonExclusion")
            try #require(await transport.requests.count == before + 1)
            try #require(current.sourceRasterClaim != nil && current.sourceRasterClaim != record.sourceRasterClaim)
            try #require(current.regions.contains { $0.translation == "빨리 움직여!" && !$0.preservesOriginalText })
            try #require(current.regions.map(\.source) != record.regions.map(\.source))
            let painted = try RecordedTranslationReplay.decodedPixelComparison(actual: #require(result.cgImage), reference: #require(original.cgImage))
            try #require(painted["equalDecodedPixels"] as? Bool == false)
            return (result, current)
        }
        let (nextImage, nextRecord) = try await renderNewPage(1, phase: "resident_models_new_page")
        try await service.clearCache()
        let (repeatedImage, repeatedRecord) = try await renderNewPage(2, phase: "independent_repeat_same_crop")
        #expect(repeatedImage !== nextImage)
        #expect(repeatedRecord.sourceRasterClaim == nextRecord.sourceRasterClaim)
        #expect(ReaderTranslationRenderAsset.digest(repeatedRecord.regions) == ReaderTranslationRenderAsset.digest(nextRecord.regions))
        let parity = try RecordedTranslationReplay.decodedPixelComparison(actual: #require(repeatedImage.cgImage), reference: #require(nextImage.cgImage))
        #expect(parity["equalDecodedPixels"] as? Bool == true)
    }
}

private final class LatencyFixtureBundle: NSObject {}

private struct ContractCredential: TranslationCredentialProviding {
    func secret(for account: String) throws -> String { "local-mock-only" }
}

private actor ContractTransport: TranslationHTTPTransport {
    enum Failure: CaseIterable { case malformed, untranslated, http, transport }
    let failure: Failure?
    let failsFirstRequest: Bool
    let pageReply: String?
    private(set) var requests: [URLRequest] = []

    init(failure: Failure? = nil, failsFirstRequest: Bool = false, pageReply: String? = nil) {
        self.failure = failure
        self.failsFirstRequest = failsFirstRequest
        self.pageReply = pageReply
    }

    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        requests.append(request)
        if failure == .transport { throw URLError(.timedOut) }
        let requestURL = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: requestURL,
            statusCode: failure == .http ? 503 : 200, httpVersion: nil, headerFields: nil))
        if failure == .http || failure == .malformed || (failsFirstRequest && requests.count == 1) {
            return TranslationHTTPResponse(data: Data("{}".utf8), response: response)
        }
        let encodedBody = try #require(request.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: encodedBody) as? [String: Any])
        let isResponses = request.url?.lastPathComponent == "responses"
        let messages = try #require(root[isResponses ? "input" : "messages"] as? [[String: Any]])
        let content = try #require(messages.first(where: { $0["role"] as? String == "user" })?["content"])
        let text: String
        if let plain = content as? String { text = plain }
        else {
            let parts = try #require(content as? [[String: Any]])
            text = try #require(parts.compactMap { $0["text"] as? String }.first)
        }
        let payload = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let segments = try #require(payload["segments"] as? [[String: Any]])
        let translations = try segments.map { segment -> [String: Any] in
            var value: [String: Any] = ["id": try #require(segment["id"] as? String), "text": "번역된 제목"]
            if let pageReply {
                value["text"] = pageReply
                value["text_role"] = "dialogue"
            }
            if failure == .untranslated {
                value["text"] = (try #require(segment["text"] as? String)) + "！"
                value["text_role"] = "dialogue"
            }
            return value
        }
        let output = String(decoding: try JSONSerialization.data(withJSONObject: ["translations": translations]), as: UTF8.self)
        let envelope: [String: Any] = isResponses ? [
            "status": "completed", "output": [["type": "message", "status": "completed",
                "content": [["type": "output_text", "text": output]]]]
        ] : ["choices": [["index": 0, "finish_reason": "stop",
            "message": ["role": "assistant", "content": output]]]]
        return TranslationHTTPResponse(data: try JSONSerialization.data(withJSONObject: envelope), response: response)
    }
}
