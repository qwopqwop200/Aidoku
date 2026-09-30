@testable import AidokuRunner
import Foundation
import Testing

struct NativeSourceRunnerRegistryTests {
    private struct FixtureRunner: Runner {
        let features = SourceFeatures()
        func getSearchMangaList(query: String?, page: Int, filters: [FilterValue]) throws -> MangaPageResult {
            .init(entries: [], hasNextPage: false)
        }
        func getMangaUpdate(manga: Manga, needsDetails: Bool, needsChapters: Bool) throws -> Manga { manga }
        func getPageList(manga: Manga, chapter: Chapter) throws -> [Page] { [] }
    }

    private enum FactoryFailure: Error { case rejected }

    private struct BaseUrlRunner: Runner {
        let features = SourceFeatures(providesBaseUrl: true)
        let baseUrl: @Sendable () async throws -> URL?
        func getBaseUrl() async throws -> URL? { try await baseUrl() }
        func getSearchMangaList(query: String?, page: Int, filters: [FilterValue]) throws -> MangaPageResult {
            .init(entries: [], hasNextPage: false)
        }
        func getMangaUpdate(manga: Manga, needsDetails: Bool, needsChapters: Bool) throws -> Manga { manga }
        func getPageList(manga: Manga, chapter: Chapter) throws -> [Page] { [] }
    }

    private actor BaseUrlGate {
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var completion: CheckedContinuation<URL?, Never>?

        func baseUrl() async -> URL? {
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
            return await withCheckedContinuation { completion = $0 }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }

        func resume() {
            completion?.resume(returning: URL(string: "https://replacement.invalid"))
            completion = nil
        }
    }

    private func manifest(key: String = "test.native", version: Int = 7) -> SourceInfo {
        .init(info: .init(id: key, name: "Native fixture", altNames: nil, version: version,
                         url: "https://example.invalid", urls: nil, contentRating: .safe, languages: ["en"]),
              listings: [.init(listing: .init(id: "latest", name: "Latest"))], config: nil)
    }

    private func directory(manifest: SourceInfo) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: url.appendingPathComponent("source.json"))
        return url
    }

    @Test func nativeSelectionDoesNotRequireExecutableAndPreservesMetadata() async throws {
        let registry = NativeSourceRunnerRegistry()
        let info = manifest()
        let url = try directory(manifest: info)
        defer { try? FileManager.default.removeItem(at: url) }
        let filters = [Filter(id: "artist", title: "Artist", value: .text(placeholder: nil))]
        let settings = [Setting(key: "fixture", title: "Fixture", value: .toggle(.init()))]
        try JSONEncoder().encode(filters).write(to: url.appendingPathComponent("filters.json"))
        try JSONEncoder().encode(settings).write(to: url.appendingPathComponent("settings.json"))
        try registry.register(sourceKey: info.info.id, supportedVersions: [7]) { context in
            #expect(context.directoryURL == url)
            #expect(context.sourceKey == info.info.id)
            #expect(context.version == 7)
            #expect(context.manifest.info.name == "Native fixture")
            return FixtureRunner()
        }
        let source = try await Source(url: url, nativeRunnerRegistry: registry)
        #expect(source.runner is FixtureRunner)
        #expect(source.version == 7)
        #expect(source.supportsArtistSearch)
        #expect(try await source.getSearchFilters() == filters)
        #expect(try await source.getSettings() == settings)
        #expect(try await source.getListings().map(\.id) == ["latest"])
        UserDefaults.standard.removeObject(forKey: "test.native.fixture")
    }

    @Test func unsupportedIdsAndVersionsFailExplicitlyWithoutExecutable() async throws {
        let registry = NativeSourceRunnerRegistry()
        try registry.register(sourceKey: "test.native", supportedVersions: [7]) { _ in FixtureRunner() }
        for info in [manifest(key: "other.native"), manifest(version: 8)] {
            let url = try directory(manifest: info)
            defer { try? FileManager.default.removeItem(at: url) }
            await #expect(throws: Source.InitError.unsupportedNativeSource(sourceKey: info.info.id, version: info.info.version)) {
                _ = try await Source(url: url, nativeRunnerRegistry: registry)
            }
        }
    }

    @Test func matchedFactoryFailureIsPropagated() async throws {
        let registry = NativeSourceRunnerRegistry()
        let url = try directory(manifest: manifest())
        defer { try? FileManager.default.removeItem(at: url) }
        try registry.register(sourceKey: "test.native", supportedVersions: [7]) { _ in throw FactoryFailure.rejected }
        await #expect(throws: FactoryFailure.self) {
            _ = try await Source(url: url, nativeRunnerRegistry: registry)
        }
    }

    @Test func dynamicBaseUrlCancellationIsPropagated() async throws {
        let registry = NativeSourceRunnerRegistry()
        let url = try directory(manifest: manifest())
        defer { try? FileManager.default.removeItem(at: url) }
        try registry.register(sourceKey: "test.native", supportedVersions: [7]) { _ in
            BaseUrlRunner(baseUrl: { throw CancellationError() })
        }
        await #expect(throws: CancellationError.self) {
            _ = try await Source(url: url, nativeRunnerRegistry: registry)
        }
    }

    @Test func cancellationDuringDynamicBaseUrlCannotReturnAnInitializedSource() async throws {
        let registry = NativeSourceRunnerRegistry()
        let url = try directory(manifest: manifest())
        defer { try? FileManager.default.removeItem(at: url) }
        let gate = BaseUrlGate()
        try registry.register(sourceKey: "test.native", supportedVersions: [7]) { _ in
            BaseUrlRunner(baseUrl: { await gate.baseUrl() })
        }
        let task = Task { try await Source(url: url, nativeRunnerRegistry: registry) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.resume()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func dynamicBaseUrlFailurePreservesManifestFallback() async throws {
        let registry = NativeSourceRunnerRegistry()
        let url = try directory(manifest: manifest())
        defer { try? FileManager.default.removeItem(at: url) }
        try registry.register(sourceKey: "test.native", supportedVersions: [7]) { _ in
            BaseUrlRunner(baseUrl: { throw FactoryFailure.rejected })
        }
        let source = try await Source(url: url, nativeRunnerRegistry: registry)
        #expect(source.urls == [URL(string: "https://example.invalid")!])
    }

    @Test func unsupportedVersionRejectsInstalledExecutableBytes() async throws {
        let registry = NativeSourceRunnerRegistry()
        try registry.register(sourceKey: "test.native", supportedVersions: [7]) { _ in FixtureRunner() }
        let url = try directory(manifest: manifest(version: 8))
        defer { try? FileManager.default.removeItem(at: url) }
        // Even a legacy executable in an archive does not permit runtime fallback.
        try Data([0, 97, 115, 109, 1, 0, 0, 0]).write(to: url.appendingPathComponent("main.wasm"))
        await #expect(throws: Source.InitError.unsupportedNativeSource(sourceKey: "test.native", version: 8)) {
            _ = try await Source(url: url, nativeRunnerRegistry: registry)
        }
    }

    @Test func overlappingRegistrationIsAtomic() async throws {
        let registry = NativeSourceRunnerRegistry()
        try registry.register(sourceKey: "test.native", supportedVersions: [7]) { _ in FixtureRunner() }
        #expect(throws: NativeSourceRunnerRegistry.RegistrationError.self) {
            try registry.register(sourceKey: "test.native", supportedVersions: [7, 8]) { _ in FixtureRunner() }
        }
        let context = NativeSourceRunnerRegistry.Context(directoryURL: URL(fileURLWithPath: "/unused"), manifest: manifest(version: 8))
        #expect(try await registry.makeRunner(context: context) == nil)
    }

    @Test func factoriesCanRegisterWithoutHoldingRegistryLock() async throws {
        let registry = NativeSourceRunnerRegistry()
        try registry.register(sourceKey: "test.native", supportedVersions: [7]) { _ in
            try registry.register(sourceKey: "nested.native", supportedVersions: [1]) { _ in FixtureRunner() }
            return FixtureRunner()
        }
        let context = NativeSourceRunnerRegistry.Context(directoryURL: URL(fileURLWithPath: "/unused"), manifest: manifest())
        #expect(try await registry.makeRunner(context: context) is FixtureRunner)
    }

    @Test func concurrentRegistrationAndLookupPreserveEveryVersion() async throws {
        let registry = NativeSourceRunnerRegistry()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for version in 1...32 {
                group.addTask {
                    try registry.register(sourceKey: "test.native", supportedVersions: [version]) { _ in FixtureRunner() }
                    let context = NativeSourceRunnerRegistry.Context(
                        directoryURL: URL(fileURLWithPath: "/unused"), manifest: manifest(version: version)
                    )
                    #expect(try await registry.makeRunner(context: context) is FixtureRunner)
                }
            }
            try await group.waitForAll()
        }
    }
}
