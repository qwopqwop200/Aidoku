import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct MetadataTranslationTaskWindowTests {
    @Test func thousandSuspendedOperationsStayBoundedAndAllFinishInInputOrder() async throws {
        let eagerProbe = WindowProbe()
        let input = Array(0..<1000)
        // Preserve the former task-group shape as a measured reference, with
        // the same suspended operation and no provider/cache/network work.
        let eager = Task { await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for value in input { group.addTask { await eagerProbe.run(value) } }
            var result: [Int] = []
            for await value in group { result.append(value) }
            return result.sorted()
        } }
        defer { eager.cancel() }
        try await wait { await eagerProbe.started == 1000 }
        #expect(await eagerProbe.active == 1000)
        await eagerProbe.release()
        #expect(await eager.value == input.map { $0 + 10_000 })
        let probe = WindowProbe()
        let task = Task { await MetadataTranslationTaskWindow.map(input, fallback: { $0 }) { await probe.run($0) } }
        defer { task.cancel() }
        try await wait { await probe.started == MetadataTranslationTaskWindow.maximumTasks }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await probe.started == 64)
        #expect(await probe.active == 64)
        await probe.release()
        let result = await task.value
        #expect(result == input.map { $0 + 10_000 })
        #expect(await probe.started == 1000)
        #expect(await probe.peak <= 64)
        #expect(await probe.active == 0)
        let report: [String: Any] = ["inputs": 1000, "eagerPeakTasks": await eagerProbe.peak,
            "windowPeakTasks": await probe.peak, "windowCompletedInputs": await probe.started,
            "scope": "suspended fake operations; no API; task count not process memory or user latency"]
        let folder = URL.documentsDirectory.appendingPathComponent("MetadataWindowAudit")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: folder.appendingPathComponent("suspended-tasks.json"), options: .atomic)
    }

    @Test func cancellationDoesNotScheduleRemaining936InputsAndPreservesFallbacks() async throws {
        let probe = WindowProbe()
        let input = Array(0..<1000)
        let task = Task { await MetadataTranslationTaskWindow.map(input, fallback: { $0 }) { await probe.run($0) } }
        defer { task.cancel() }
        try await wait { await probe.started == 64 }
        task.cancel()
        #expect(await task.value == input)
        #expect(await probe.started == 64)
        #expect(await probe.active == 0)
    }

    @Test func realSourceMenuPathKeepsAll1000UniqueMappingsAndRequestContracts() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let client = WindowMetadataClient()
        let service = ReaderTranslationService(client: client)
        let input = (0..<1000).map { "A source category number \($0)" }
        let output = await SourceMenuTranslation.translate(input + [input[0], ""], settings: fixture.settings,
            service: service, diskCache: fixture.disk)
        #expect(output == Dictionary(uniqueKeysWithValues: input.map { ($0, "번역[" + $0 + "]") }))
        let requests = await client.requests
        #expect(requests.count == input.count)
        #expect(Set(requests.flatMap(\.segments).map(\.text)) == Set(input))
        #expect(requests.allSatisfy { $0.segments.count == 1 })
        #expect(await client.instructions.allSatisfy { $0 == TitleTranslation.effectiveSettings(fixture.settings, kind: .sourceLabel).configuration.instructions })
    }

    @Test func thousandDescriptionLinesPreserveOrderBlanksChunksAndFailures() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let client = WindowMetadataClient()
        let service = ReaderTranslationService(client: client)
        let lines = (0..<1000).map { "A distant traveler begins story number \($0)." }
        let long = String(repeating: "A traveler crosses the quiet valley. ", count: 400)
        let original = (lines + ["", "  ", "A failing story.", long]).joined(separator: "\n")
        let expectedLong = MangaDescriptionTranslation.chunks(long).map { "번역[" + $0 + "]" }.joined()
        let expected = (lines.map { "번역[" + $0 + "]" } + ["", "  ", "A failing story.", expectedLong]).joined(separator: "\n")
        #expect(await MangaDescriptionTranslation.translate(original, settings: fixture.settings,
            service: service, diskCache: fixture.disk) == expected)
        let sources = await client.requests.flatMap(\.segments).map(\.text)
        let expectedSources = lines + ["A failing story."] + MangaDescriptionTranslation.chunks(long)
        #expect(sources.count == expectedSources.count && Set(sources) == Set(expectedSources))
        #expect(await client.instructions.allSatisfy { $0 == TitleTranslation.effectiveSettings(fixture.settings, kind: .description).configuration.instructions })
    }

    @Test func publicCancellationKeepsSourceKeysAndWholeNormalizedDescription() async throws {
        for description in [false, true] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let client = WindowMetadataClient(suspended: true)
            let service = ReaderTranslationService(client: client)
            let lines = (0..<1000).map { "A cancelled English story number \($0)." }
            var done = false
            let task = Task { () -> [String: String] in
                defer { done = true }
                if description {
                    let original = lines.joined(separator: "\n\n")
                    let result = await MangaDescriptionTranslation.translate(original, settings: fixture.settings,
                        service: service, diskCache: fixture.disk)
                    return [original: result]
                }
                return await SourceMenuTranslation.translate(lines, settings: fixture.settings,
                    service: service, diskCache: fixture.disk)
            }
            defer { task.cancel() }
            try await wait { await client.requests.count > 0 }
            task.cancel()
            try await wait { done }
            let result = await task.value
            if description {
                let original = lines.joined(separator: "\n\n")
                #expect(result == [original: original])
            } else { #expect(result == Dictionary(uniqueKeysWithValues: lines.map { ($0, $0) })) }
            #expect(await client.active == 0)
        }
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let limit = Date().addingTimeInterval(10)
        while !(await condition()) { try #require(Date() < limit); try await Task.sleep(for: .milliseconds(5)) }
    }
}

private actor WindowProbe {
    var started = 0, active = 0, peak = 0
    private var released = false
    func release() { released = true }
    func run(_ value: Int) async -> Int {
        started += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        while !released && !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return value }
        }
        return Task.isCancelled ? value : value + 10_000
    }
}

private actor WindowMetadataClient: RemoteTranslating {
    let suspended: Bool
    var requests: [RemoteTranslationRequest] = []
    var instructions: [String] = []
    var active = 0
    init(suspended: Bool = false) { self.suspended = suspended }
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        requests.append(request); instructions.append(configuration.instructions)
        active += 1; defer { active -= 1 }
        if suspended { try await Task.sleep(for: .seconds(30)) }
        if request.segments.contains(where: { $0.text == "A failing story." }) { throw URLError(.notConnectedToInternet) }
        return .init(translations: request.segments.map { .init(id: $0.id, text: "번역[" + $0.text + "]") },
                     source: .network, providerRequestID: nil)
    }
}

@MainActor private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-window-" + UUID().uuidString)
    let domain = "metadata-window-" + UUID().uuidString
    let disk: ReaderTranslationDiskCache
    let defaults: UserDefaults
    var settings: ReaderTranslationSettings
    init() throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        settings = ReaderTranslationSettings(defaults: defaults)
        settings.targetLanguage = "ko"
        settings.translateSourceLabels = true; settings.translateMangaDescriptions = true
        settings.sourceLabelSourceLanguages = []; settings.mangaDescriptionSourceLanguages = []
        disk = ReaderTranslationDiskCache(directory: root)
    }
    func close() { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
}
